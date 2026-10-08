using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using Talkflow.Core.Text;
using Forms = System.Windows.Forms;

namespace Talkflow;

/// <summary>
/// Writes into the focused field (LiveType.swift), on one background thread,
/// in order.
///
/// Text of PasteThreshold characters or more goes in as one Ctrl+V paste,
/// with the user's clipboard saved first and put back after. Measured in
/// Windows 11 Notepad (11.2607) with a 292-character dictation: keystrokes
/// carrying 16 characters per SendInput call came out garbled (260 of 292
/// characters, letters repeated, the rest turned into a row of dots), one
/// character per call came out exact but took 4.6 s, and the paste was exact
/// in 5 ms. The Mac never pastes, because Cmd+V silently did nothing there;
/// on Windows it is the reliable path, and keystrokes are the fallback.
///
/// Shorter text, any paste while a modifier is still held (Ctrl+V would
/// arrive as Ctrl+Win+V), and any paste that cannot get the clipboard, go as
/// KEYEVENTF_UNICODE keystrokes, one character per SendInput call, paced. A
/// newline is sent as Shift+Enter, a line break everywhere and never "send" in
/// a chat app.
/// </summary>
static class KeyboardWriter
{
    const int EventGapMs = 2;       // small edits
    const int BurstEventGapMs = 4;  // long rewrites
    const int BurstThreshold = 24;
    const int BurstSettleMs = 150;
    /// <summary>Inserts at least this long are pasted.</summary>
    const int PasteThreshold = 24;
    /// <summary>How long the pasted text stays on the clipboard before the user's comes back: the app reads it after Ctrl+V arrives.</summary>
    const int PasteRestoreMs = 750;
    /// <summary>How long a paste waits for the user to let go of Ctrl, Shift, Alt and Win.</summary>
    const int ModifierWaitMs = 1000;

    const ushort VK_BACK = 0x08, VK_RETURN = 0x0D, VK_SHIFT = 0x10, VK_CONTROL = 0x11, VK_MENU = 0x12, VK_LWIN = 0x5B, VK_RWIN = 0x5C, VK_V = 0x56;

    static readonly BlockingCollection<Action> Queue = new();

    static KeyboardWriter()
    {
        var thread = new Thread(() =>
        {
            foreach (var work in Queue.GetConsumingEnumerable())
            {
                try { work(); }
                catch (Exception e) { Log.Write($"keystroke writer: {e.Message}"); }
            }
        }) { IsBackground = true, Name = "talkflow typing" };
        thread.SetApartmentState(ApartmentState.STA); // the clipboard needs it
        thread.Start();
    }

    /// <summary>Deletes <paramref name="deleteCount"/> characters, then inserts <paramref name="text"/>, as one ordered unit.</summary>
    public static void Rewrite(int deleteCount, string text, bool paste = true) => Queue.Add(() =>
    {
        int characters = Chars.Count(text);
        int gap = deleteCount + characters >= BurstThreshold ? BurstEventGapMs : EventGapMs;
        var watch = Stopwatch.StartNew();
        for (int i = 0; i < deleteCount; i++)
        {
            Send(Native.Key(VK_BACK, false), Native.Key(VK_BACK, true));
            Thread.Sleep(gap);
        }
        if (deleteCount >= BurstThreshold) Thread.Sleep(BurstSettleMs);
        string how = paste && characters >= PasteThreshold && Paste(text) ? "pasted" : Type(text, gap);
        if (deleteCount + characters >= BurstThreshold)
            Log.Write($"write -{deleteCount} +{characters}, {how}, in {watch.Elapsed.TotalSeconds:F2}s");
    });

    /// <summary>Runs <paramref name="block"/> once everything queued so far has been written.</summary>
    public static void WhenDrained(Action block) => Queue.Add(block);

    /// <summary>One character (one grapheme: an emoji's units go together) per SendInput call.</summary>
    static string Type(string text, int gap)
    {
        foreach (var character in Chars.Graphemes(text))
        {
            if (Chars.IsNewline(character))
            {
                Send(Native.Key(VK_SHIFT, false), Native.Key(VK_RETURN, false), Native.Key(VK_RETURN, true), Native.Key(VK_SHIFT, true));
            }
            else
            {
                var inputs = new Native.INPUT[character.Length * 2];
                for (int i = 0; i < character.Length; i++)
                {
                    inputs[i] = Native.Unicode(character[i], false);
                    inputs[character.Length + i] = Native.Unicode(character[i], true);
                }
                Send(inputs);
            }
            Thread.Sleep(gap);
        }
        return "typed";
    }

    static bool ModifierHeld() =>
        new[] { VK_SHIFT, VK_CONTROL, VK_MENU, VK_LWIN, VK_RWIN }.Any(vk => Native.GetAsyncKeyState(vk) < 0);

    /// <summary>Ctrl+V with the text on the clipboard, then the user's clipboard back. False when it could not paste; nothing was written then.</summary>
    static bool Paste(string text)
    {
        var waited = Stopwatch.StartNew();
        while (ModifierHeld() && waited.ElapsedMilliseconds < ModifierWaitMs) Thread.Sleep(20);
        if (ModifierHeld())
        {
            Log.Write("paste: a modifier key is still held, typing instead");
            return false;
        }
        Forms.IDataObject? saved;
        try
        {
            saved = Save(Forms.Clipboard.GetDataObject());
        }
        catch (Exception e)
        {
            Log.Write($"paste: could not read the clipboard ({e.Message}), typing instead");
            return false;
        }
        var data = new Forms.DataObject();
        data.SetData(Forms.DataFormats.UnicodeText, text.Replace("\r\n", "\n").Replace("\n", "\r\n"));
        // Kept out of clipboard history (Win+V) and the cloud clipboard: it is a dictation in transit, not a copy.
        data.SetData("ExcludeClipboardContentFromMonitorProcessing", new MemoryStream(new byte[4]));
        data.SetData("CanIncludeInClipboardHistory", new MemoryStream(BitConverter.GetBytes(0)));
        data.SetData("CanUploadToCloudClipboard", new MemoryStream(BitConverter.GetBytes(0)));
        try
        {
            Forms.Clipboard.SetDataObject(data, true, 5, 40);
        }
        catch (Exception e)
        {
            Log.Write($"paste: could not set the clipboard ({e.Message}), typing instead");
            return false;
        }
        uint ours = Native.GetClipboardSequenceNumber();
        Send(Native.Key(VK_CONTROL, false), Native.Key(VK_V, false), Native.Key(VK_V, true), Native.Key(VK_CONTROL, true));
        Thread.Sleep(PasteRestoreMs);
        if (Native.GetClipboardSequenceNumber() != ours)
        {
            Log.Write("paste: the clipboard changed after the paste; left as it is");
            return true;
        }
        try
        {
            if (saved is null) Forms.Clipboard.Clear();
            else Forms.Clipboard.SetDataObject(saved, true, 5, 40);
        }
        catch (Exception e)
        {
            Log.Write($"paste: could not put the clipboard back ({e.Message})");
        }
        return true;
    }

    /// <summary>A copy of every format on the clipboard that can be read, or null when it is empty.</summary>
    static Forms.IDataObject? Save(Forms.IDataObject? current)
    {
        if (current is null) return null;
        var formats = current.GetFormats(false);
        if (formats.Length == 0) return null;
        var copy = new Forms.DataObject();
        foreach (var format in formats)
        {
            try
            {
                if (current.GetData(format, false) is { } value) copy.SetData(format, false, value);
            }
            catch (Exception)
            {
                // Some formats are rendered on demand by the app that copied them and cannot be read back.
            }
        }
        return copy;
    }

    static void Send(params Native.INPUT[] inputs)
    {
        uint sent = Native.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<Native.INPUT>());
        if (sent != inputs.Length) Log.Write($"SendInput delivered {sent} of {inputs.Length} events (error {Marshal.GetLastWin32Error()})");
    }
}

/// <summary>Which app has the keyboard, and whether talkflow is allowed to type into it.</summary>
sealed record FocusTarget(IntPtr Window, uint ProcessId, string? ProcessName)
{
    public static FocusTarget Current()
    {
        var hwnd = Native.GetForegroundWindow();
        var root = Native.GetAncestor(hwnd, Native.GA_ROOT);
        if (root != IntPtr.Zero) hwnd = root;
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        return new FocusTarget(hwnd, pid, pid == 0 ? null : NameOf(pid));
    }

    /// <summary>
    /// "notepad" for C:\Windows\notepad.exe. Asks for that one process only;
    /// Process.ProcessName would snapshot every process on the PC, several
    /// times per dictation, on the UI thread.
    /// </summary>
    static string? NameOf(uint pid)
    {
        if (pid == (uint)Environment.ProcessId) return OwnName;
        var process = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, pid);
        if (process == IntPtr.Zero) return null;
        try
        {
            var path = new System.Text.StringBuilder(1024);
            int size = path.Capacity;
            return Native.QueryFullProcessImageName(process, 0, path, ref size) ? System.IO.Path.GetFileNameWithoutExtension(path.ToString()) : null;
        }
        finally
        {
            Native.CloseHandle(process);
        }
    }

    static readonly string OwnName = Process.GetCurrentProcess().ProcessName;

    public bool SameAppAs(FocusTarget other) => ProcessId != 0 && ProcessId == other.ProcessId;

    public bool IsTalkflow => ProcessId == (uint)Environment.ProcessId;

    /// <summary>
    /// Windows blocks keystrokes from a normal app into one running as
    /// administrator, and says nothing about it. Such a target gets the
    /// clipboard instead of a dictation that silently vanishes.
    /// </summary>
    public bool IsElevatedAboveUs()
    {
        if (ProcessId == 0 || IsTalkflow) return false;
        var process = Native.OpenProcess(Native.PROCESS_QUERY_LIMITED_INFORMATION, false, ProcessId);
        if (process == IntPtr.Zero) return true;
        try
        {
            if (!Native.OpenProcessToken(process, Native.TOKEN_QUERY, out var token)) return true;
            try
            {
                return Native.GetTokenInformation(token, Native.TokenElevation, out int elevated, sizeof(int), out _) && elevated != 0
                       && !IsSelfElevated;
            }
            finally
            {
                Native.CloseHandle(token);
            }
        }
        finally
        {
            Native.CloseHandle(process);
        }
    }

    static readonly bool IsSelfElevated = Environment.IsPrivilegedProcess;
}
