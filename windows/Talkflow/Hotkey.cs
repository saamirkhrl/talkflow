using System;
using System.Collections.Generic;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;

namespace Talkflow;

/// <summary>
/// The hold-to-dictate shortcut: groups of keys that must all be held, each
/// satisfied by any of its virtual-key codes (left or right Ctrl, say).
/// </summary>
sealed record HotkeySpec(int[][] Groups)
{
    public const int LCtrl = 0xA2, RCtrl = 0xA3, LShift = 0xA0, RShift = 0xA1, LAlt = 0xA4, RAlt = 0xA5, LWin = 0x5B, RWin = 0x5C;

    static readonly int[] Ctrl = { LCtrl, RCtrl, 0x11 };
    static readonly int[] Shift = { LShift, RShift, 0x10 };
    static readonly int[] Alt = { LAlt, RAlt, 0x12 };
    static readonly int[] Win = { LWin, RWin };

    /// <summary>Hold Ctrl + Win.</summary>
    public static readonly HotkeySpec Default = new(new[] { Ctrl, Win });

    public static readonly (string Name, HotkeySpec Spec)[] Presets =
    {
        ("Ctrl + Win", Default),
        ("Ctrl + Alt", new HotkeySpec(new[] { Ctrl, Alt })),
        ("Ctrl + Shift", new HotkeySpec(new[] { Ctrl, Shift })),
        ("Right Alt", new HotkeySpec(new[] { new[] { RAlt } })),
        ("Right Ctrl", new HotkeySpec(new[] { new[] { RCtrl } })),
    };

    public bool Contains(int vk) => Groups.Any(g => g.Contains(vk));

    public bool UsesWin => Groups.Any(g => g.Contains(LWin) || g.Contains(RWin));

    public bool IsModifier(int vk) => Ctrl.Contains(vk) || Shift.Contains(vk) || Alt.Contains(vk) || Win.Contains(vk);

    public bool SatisfiedBy(IReadOnlyCollection<int> down) => Groups.All(g => g.Any(down.Contains));

    /// <summary>The group a pressed key belongs to when recording a new shortcut.</summary>
    public static int[] GroupFor(int vk)
    {
        foreach (var family in new[] { Ctrl, Shift, Alt, Win })
            if (family.Contains(vk)) return family;
        return new[] { vk };
    }

    /// <summary>Builds a shortcut from recorded keys. "Right Alt" alone stays right-only.</summary>
    public static HotkeySpec FromRecorded(IReadOnlyCollection<int> keys)
    {
        if (keys.Count == 1 && keys.First() is RAlt or RCtrl or RShift) return new HotkeySpec(new[] { new[] { keys.First() } });
        var groups = new List<int[]>();
        foreach (var vk in keys.OrderBy(k => Rank(k)))
        {
            var group = GroupFor(vk);
            if (!groups.Any(g => g.SequenceEqual(group))) groups.Add(group);
        }
        return new HotkeySpec(groups.ToArray());
    }

    static int Rank(int vk) => Ctrl.Contains(vk) ? 0 : Shift.Contains(vk) ? 1 : Alt.Contains(vk) ? 2 : Win.Contains(vk) ? 3 : 4;

    public string Describe() => string.Join(" + ", Groups.Select(DescribeGroup));

    static string DescribeGroup(int[] group)
    {
        if (group.SequenceEqual(Ctrl)) return "Ctrl";
        if (group.SequenceEqual(Shift)) return "Shift";
        if (group.SequenceEqual(Alt)) return "Alt";
        if (group.SequenceEqual(Win)) return "Win";
        return group.Length == 1 ? KeyName(group[0]) : string.Join("/", group.Select(KeyName));
    }

    public static string KeyName(int vk) => vk switch
    {
        LCtrl => "Left Ctrl", RCtrl => "Right Ctrl", LShift => "Left Shift", RShift => "Right Shift",
        LAlt => "Left Alt", RAlt => "Right Alt", LWin => "Left Win", RWin => "Right Win",
        0x20 => "Space", 0x14 => "Caps Lock", 0x13 => "Pause", 0x91 => "Scroll Lock", 0x09 => "Tab",
        >= 0x70 and <= 0x87 => "F" + (vk - 0x6F),
        >= 0x30 and <= 0x39 or >= 0x41 and <= 0x5A => ((char)vk).ToString(),
        _ => $"key {vk:X2}",
    };

    public bool Equals(HotkeySpec? other) =>
        other is not null && Groups.Length == other.Groups.Length && Groups.Zip(other.Groups).All(p => p.First.SequenceEqual(p.Second));

    public override int GetHashCode() => Groups.Length;
}

/// <summary>
/// A low-level keyboard hook (WH_KEYBOARD_LL) on a thread of its own. Windows
/// silently removes a low-level hook whose callback is slow, so it never runs
/// on the UI thread: the callback only updates key state and posts events.
///
/// Modifier keys pass through to the system untouched, key-ups included, so
/// nothing talkflow does can leave a key logically held down. A non-modifier
/// key that is part of the shortcut (Space in Ctrl + Shift + Space) is
/// swallowed while the shortcut is held, so it is not also typed.
/// </summary>
sealed class HotkeyListener : IDisposable
{
    public event Action? Pressed;
    public event Action? Released;
    /// <summary>Another key went down while the shortcut was held: a different shortcut, not dictation.</summary>
    public event Action? Interrupted;
    /// <summary>Recording a new shortcut finished: the keys that were held together.</summary>
    public event Action<IReadOnlyCollection<int>>? Recorded;

    readonly Thread _thread;
    readonly Native.LowLevelKeyboardProc _proc;
    /// <summary>Delivers events in order on the UI thread; the hook callback never waits for them.</summary>
    readonly Action<Action> _post;
    readonly HashSet<int> _down = new();
    readonly object _gate = new();
    IntPtr _hook;
    uint _threadId;
    volatile HotkeySpec _spec;
    bool _active;
    bool _recording;
    readonly HashSet<int> _recorded = new();

    public HotkeyListener(HotkeySpec spec, Action<Action> post)
    {
        _spec = spec;
        _post = post;
        _proc = Callback;
        var ready = new ManualResetEventSlim();
        _thread = new Thread(() => Run(ready)) { IsBackground = true, Name = "talkflow hotkey" };
        _thread.SetApartmentState(ApartmentState.STA);
        _thread.Start();
        ready.Wait(TimeSpan.FromSeconds(5));
    }

    public bool IsInstalled => _hook != IntPtr.Zero;

    public HotkeySpec Spec
    {
        get => _spec;
        set { lock (_gate) { _spec = value; _active = false; } }
    }

    /// <summary>Captures the next combination the user presses, instead of dictating.</summary>
    public void StartRecording()
    {
        lock (_gate)
        {
            _recording = true;
            _recorded.Clear();
            _active = false;
        }
    }

    public void CancelRecording()
    {
        lock (_gate) _recording = false;
    }

    /// <summary>Whether every group is still physically down; a lost key-up (the lock screen) must not leave a hold running.</summary>
    public bool IsPhysicallyHeld()
    {
        var spec = _spec;
        return spec.Groups.All(g => g.Any(vk => (Native.GetAsyncKeyState(vk) & 0x8000) != 0));
    }

    /// <summary>Whether any key of the shortcut is still down, so typing can wait for the user to let go.</summary>
    public bool AnyKeyHeld()
    {
        var spec = _spec;
        return spec.Groups.SelectMany(g => g).Any(vk => (Native.GetAsyncKeyState(vk) & 0x8000) != 0);
    }

    void Run(ManualResetEventSlim ready)
    {
        _threadId = Native.GetCurrentThreadId();
        _hook = Native.SetWindowsHookEx(Native.WH_KEYBOARD_LL, _proc, Native.GetModuleHandle(null), 0);
        if (_hook == IntPtr.Zero) Log.Write($"keyboard hook failed: error {Marshal.GetLastWin32Error()}");
        ready.Set();
        while (Native.GetMessage(out var msg, IntPtr.Zero, 0, 0) > 0) { }
        if (_hook != IntPtr.Zero) Native.UnhookWindowsHookEx(_hook);
    }

    IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return Native.CallNextHookEx(_hook, nCode, wParam, lParam);
        var info = Marshal.PtrToStructure<Native.KBDLLHOOKSTRUCT>(lParam);
        // Keystrokes talkflow typed itself are never the shortcut. Other
        // programs' injected keys are ignored too, except in the end-to-end
        // test, which holds the shortcut with SendInput.
        bool injected = (info.flags & Native.LLKHF_INJECTED) != 0;
        if (injected && (info.dwExtraInfo == Native.InjectedTag || !TestHooks.AcceptInjectedKeys))
            return Native.CallNextHookEx(_hook, nCode, wParam, lParam);

        int message = (int)wParam;
        bool isDown = message is Native.WM_KEYDOWN or Native.WM_SYSKEYDOWN;
        int vk = (int)info.vkCode;
        bool swallow = false;
        Action? fire = null;
        IReadOnlyCollection<int>? recorded = null;

        lock (_gate)
        {
            var spec = _spec;
            if (_recording)
            {
                if (isDown) { _down.Add(vk); _recorded.Add(vk); }
                else
                {
                    _down.Remove(vk);
                    if (_down.Count == 0 && _recorded.Count > 0)
                    {
                        _recording = false;
                        recorded = _recorded.ToArray();
                    }
                }
                swallow = true;
            }
            else if (isDown)
            {
                bool repeat = _down.Contains(vk);
                ForgetReleasedKeys(vk);
                _down.Add(vk);
                if (!_active && spec.SatisfiedBy(_down))
                {
                    _active = true;
                    fire = Pressed;
                    // Releasing Win opens Start unless another key came
                    // between its press and release. Tell Windows now, while
                    // Win is still down, so its key-up can pass through as is.
                    if (_down.Contains(HotkeySpec.LWin) || _down.Contains(HotkeySpec.RWin)) MaskStartMenu();
                }
                else if (_active && !repeat && !spec.Contains(vk))
                {
                    _active = false;
                    fire = Interrupted;
                }
                swallow = _active && spec.Contains(vk) && !spec.IsModifier(vk);
            }
            else
            {
                bool wasActive = _active;
                _down.Remove(vk);
                if (_active && !spec.SatisfiedBy(_down))
                {
                    _active = false;
                    fire = Released;
                }
                swallow = wasActive && spec.Contains(vk) && !spec.IsModifier(vk);
            }
        }

        if (fire is not null) _post(fire);
        if (recorded is not null) _post(() => Recorded?.Invoke(recorded));
        return swallow ? (IntPtr)1 : Native.CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    /// <summary>
    /// A key-up the hook never saw (Win+L locks the screen before Win comes
    /// up; a UAC prompt takes the keyboard) would leave that key in the set
    /// forever, and Ctrl alone would then start a dictation. Before each
    /// key-down, keys Windows no longer reports as down are dropped.
    /// </summary>
    void ForgetReleasedKeys(int pressing)
    {
        if (_down.Count == 0) return;
        foreach (var vk in _down.ToArray())
        {
            if (vk != pressing && (Native.GetAsyncKeyState(vk) & 0x8000) == 0)
            {
                _down.Remove(vk);
                var name = HotkeySpec.KeyName(vk);
                // Never write files inside the hook: Windows drops a slow hook.
                ThreadPool.QueueUserWorkItem(_ => Log.Write($"shortcut: {name} was released without the hook seeing it; forgot it"));
            }
        }
        if (_active && !_spec.SatisfiedBy(_down))
        {
            _active = false;
            _post(() => Released?.Invoke());
        }
    }

    /// <summary>
    /// An unassigned key tapped while Win is held: Windows then treats Win as
    /// part of a shortcut and does not open Start when it comes up. If the
    /// tap is blocked (the foreground app runs as administrator), the worst
    /// case is that Start opens; no key is ever held back.
    /// </summary>
    static void MaskStartMenu()
    {
        const ushort unassigned = 0xE8;
        var inputs = new[] { Native.Key(unassigned, false), Native.Key(unassigned, true) };
        uint sent = Native.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Native.INPUT>());
        if (sent != inputs.Length)
        {
            int error = Marshal.GetLastWin32Error();
            ThreadPool.QueueUserWorkItem(_ => Log.Write($"shortcut: the Start menu mask was not delivered (error {error})"));
        }
    }

    public void Dispose()
    {
        if (_threadId != 0) Native.PostThreadMessage(_threadId, Native.WM_QUIT, IntPtr.Zero, IntPtr.Zero);
    }
}
