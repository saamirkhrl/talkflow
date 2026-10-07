// Win32 helpers for windows/tests/e2e.ps1 (loaded with Add-Type). Holds keys
// the way a person does (SendInput), brings a window to the front, checks
// whether a process's windows answer messages, and takes screenshots.
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class E2e
{
    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT { public ushort wVk, wScan; public uint dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    [StructLayout(LayoutKind.Explicit)]
    struct InputUnion { [FieldOffset(0)] public MOUSEINPUT mi; [FieldOffset(0)] public KEYBDINPUT ki; }
    [StructLayout(LayoutKind.Sequential)]
    struct INPUT { public uint type; public InputUnion U; }

    [DllImport("user32.dll", SetLastError = true)] static extern uint SendInput(uint n, INPUT[] inputs, int size);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hwnd, int cmd);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr hwnd);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern int GetWindowLong(IntPtr hwnd, int index);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder text, int max);
    delegate bool EnumProc(IntPtr hwnd, IntPtr param);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc proc, IntPtr param);
    [DllImport("user32.dll")] static extern IntPtr SendMessageTimeout(IntPtr hwnd, uint msg, IntPtr w, IntPtr l, uint flags, uint timeout, out IntPtr result);
    [DllImport("user32.dll", SetLastError = true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Unicode)] static extern bool GetUserObjectInformation(IntPtr obj, int index, StringBuilder info, int length, out int needed);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("kernel32.dll")] static extern bool ProcessIdToSessionId(uint pid, out uint session);
    [DllImport("kernel32.dll")] static extern uint WTSGetActiveConsoleSessionId();

    public const int VK_LCONTROL = 0xA2, VK_LWIN = 0x5B, VK_MENU = 0x12;

    static INPUT Key(int vk, bool up)
    {
        var input = new INPUT { type = 1 };
        input.U.ki.wVk = (ushort)vk;
        input.U.ki.dwFlags = (up ? 2u : 0u) | (vk == VK_LWIN ? 1u : 0u);
        return input;
    }

    /// <summary>Presses (or releases) one key; returns the number of events Windows accepted.</summary>
    public static uint Press(int vk, bool up)
    {
        return SendInput(1, new[] { Key(vk, up) }, Marshal.SizeOf(typeof(INPUT)));
    }

    public static bool IsDown(int vk) { return (GetAsyncKeyState(vk) & 0x8000) != 0; }

    /// <summary>Brings a window to the front. An Alt tap first lifts Windows' foreground lock.</summary>
    public static bool Focus(IntPtr hwnd)
    {
        for (int attempt = 0; attempt < 10; attempt++)
        {
            ShowWindow(hwnd, 9); // SW_RESTORE
            Press(VK_MENU, false);
            Press(VK_MENU, true);
            BringWindowToTop(hwnd);
            SetForegroundWindow(hwnd);
            Thread.Sleep(200);
            if (GetForegroundWindow() == hwnd) return true;
        }
        return false;
    }

    public static uint ProcessOf(IntPtr hwnd) { uint pid; GetWindowThreadProcessId(hwnd, out pid); return pid; }

    public static string Describe(IntPtr hwnd)
    {
        var title = new StringBuilder(256);
        var cls = new StringBuilder(256);
        GetWindowText(hwnd, title, 256);
        GetClassName(hwnd, cls, 256);
        uint pid = ProcessOf(hwnd);
        string name = "?";
        try { name = Process.GetProcessById((int)pid).ProcessName; } catch (Exception) { }
        return string.Format("0x{0:X} '{1}' class={2} pid={3} ({4})", hwnd.ToInt64(), title, cls, pid, name);
    }

    /// <summary>Visible top-level windows of a process.</summary>
    public static List<IntPtr> VisibleWindows(int pid)
    {
        var found = new List<IntPtr>();
        EnumWindows((hwnd, _) => { if (ProcessOf(hwnd) == pid && IsWindowVisible(hwnd)) found.Add(hwnd); return true; }, IntPtr.Zero);
        return found;
    }

    /// <summary>All top-level windows of a process, visible or not (the tray's message window is hidden).</summary>
    public static List<IntPtr> AllWindows(int pid)
    {
        var found = new List<IntPtr>();
        EnumWindows((hwnd, _) => { if (ProcessOf(hwnd) == pid) found.Add(hwnd); return true; }, IntPtr.Zero);
        return found;
    }

    /// <summary>The first visible top-level window whose title contains <paramref name="part"/>.</summary>
    public static IntPtr FindWindow(string part)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows((hwnd, _) =>
        {
            if (!IsWindowVisible(hwnd)) return true;
            var title = new StringBuilder(512);
            GetWindowText(hwnd, title, 512);
            if (title.ToString().IndexOf(part, StringComparison.OrdinalIgnoreCase) < 0) return true;
            found = hwnd;
            return false;
        }, IntPtr.Zero);
        return found;
    }

    public static bool IsTopmostToolWindow(IntPtr hwnd)
    {
        int ex = GetWindowLong(hwnd, -20);
        return (ex & 0x8) != 0 && (ex & 0x80) != 0; // WS_EX_TOPMOST, WS_EX_TOOLWINDOW
    }

    /// <summary>
    /// The slowest answer, in milliseconds, of any of the process's top-level
    /// windows to WM_NULL (a window owned by a blocked UI thread does not
    /// answer). -1 when none answered within the timeout; -2 when it has no windows.
    /// </summary>
    public static long SlowestAnswer(int pid, uint timeoutMs)
    {
        var windows = AllWindows(pid);
        if (windows.Count == 0) return -2;
        long slowest = 0;
        foreach (var hwnd in windows)
        {
            var watch = Stopwatch.StartNew();
            IntPtr result;
            // SMTO_ABORTIFHUNG off: measure the real wait.
            if (SendMessageTimeout(hwnd, 0, IntPtr.Zero, IntPtr.Zero, 0, timeoutMs, out result) == IntPtr.Zero) return -1;
            slowest = Math.Max(slowest, watch.ElapsedMilliseconds);
        }
        return slowest;
    }

    /// <summary>Where the test runs: session, console session and the input desktop's name.</summary>
    public static string Session()
    {
        uint session;
        ProcessIdToSessionId((uint)Process.GetCurrentProcess().Id, out session);
        string desktop = "(no input desktop: error " + Marshal.GetLastWin32Error() + ")";
        IntPtr handle = OpenInputDesktop(0, false, 0x0001); // DESKTOP_READOBJECTS
        if (handle != IntPtr.Zero)
        {
            var name = new StringBuilder(256);
            int needed;
            if (GetUserObjectInformation(handle, 2, name, 512, out needed)) desktop = name.ToString(); // UOI_NAME
            CloseDesktop(handle);
        }
        return string.Format("session {0}, console session {1}, interactive {2}, input desktop {3}",
            session, WTSGetActiveConsoleSessionId(), Environment.UserInteractive, desktop);
    }

    public static void Screenshot(string path)
    {
        var bounds = System.Windows.Forms.Screen.PrimaryScreen.Bounds;
        using (var bitmap = new Bitmap(bounds.Width, bounds.Height))
        {
            using (var g = Graphics.FromImage(bitmap)) g.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size);
            bitmap.Save(path, ImageFormat.Png);
        }
    }
}
