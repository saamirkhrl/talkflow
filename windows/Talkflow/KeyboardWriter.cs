using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
using Talkflow.Core.Text;

namespace Talkflow;

/// <summary>
/// Types into the focused field with SendInput (LiveType.swift). Text goes as
/// KEYEVENTF_UNICODE events, in chunks of at most 16 UTF-16 units, paced, so
/// no app drops characters out of the middle. A newline is its own event and
/// is sent as Shift+Enter, a line break everywhere and never "send" in a chat
/// app. All writing happens in order on one background thread.
/// </summary>
static class KeyboardWriter
{
    const int EventGapMs = 2;       // small edits
    const int BurstEventGapMs = 4;  // long rewrites and the release insert
    const int BurstThreshold = 24;
    const int BurstSettleMs = 150;

    const ushort VK_BACK = 0x08, VK_RETURN = 0x0D, VK_SHIFT = 0x10;

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
        thread.Start();
    }

    /// <summary>Deletes <paramref name="deleteCount"/> characters, then types <paramref name="text"/>, as one ordered unit.</summary>
    public static void Rewrite(int deleteCount, string text) => Queue.Add(() =>
    {
        var chunks = FieldEdit.Chunked(text);
        int events = deleteCount + chunks.Count;
        int gap = events >= BurstThreshold ? BurstEventGapMs : EventGapMs;
        var watch = Stopwatch.StartNew();
        for (int i = 0; i < deleteCount; i++)
        {
            Send(Native.Key(VK_BACK, false), Native.Key(VK_BACK, true));
            Thread.Sleep(gap);
        }
        if (deleteCount >= BurstThreshold) Thread.Sleep(BurstSettleMs);
        foreach (var chunk in chunks)
        {
            if (Chars.IsNewline(chunk))
            {
                Send(Native.Key(VK_SHIFT, false), Native.Key(VK_RETURN, false), Native.Key(VK_RETURN, true), Native.Key(VK_SHIFT, true));
            }
            else
            {
                var inputs = new Native.INPUT[chunk.Length * 2];
                for (int i = 0; i < chunk.Length; i++)
                {
                    inputs[2 * i] = Native.Unicode(chunk[i], false);
                    inputs[2 * i + 1] = Native.Unicode(chunk[i], true);
                }
                Send(inputs);
            }
            Thread.Sleep(gap);
        }
        if (events >= BurstThreshold)
            Log.Write($"keystroke write -{deleteCount} +{Chars.Count(text)} = {events} events in {watch.Elapsed.TotalSeconds:F2}s");
    });

    /// <summary>Runs <paramref name="block"/> once everything queued so far has been typed.</summary>
    public static void WhenDrained(Action block) => Queue.Add(block);

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
