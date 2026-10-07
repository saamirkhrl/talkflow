using System;
using System.Diagnostics;
using System.Linq;
using System.Text;
using System.Threading;
using System.Windows.Threading;
using Microsoft.Diagnostics.Runtime;

namespace Talkflow;

/// <summary>
/// Notices when the UI thread stops answering. A background thread asks the
/// dispatcher for an empty work item every quarter second; when one is not
/// done within half a second, the log gets a STALL line with what the UI
/// thread was doing (<see cref="Step"/>) and, once per stall, the UI thread's
/// managed call stack, read from a snapshot of this process. A freeze in the
/// field then leaves its cause in talkflow.log. Never logs dictated text.
/// </summary>
static class UiWatchdog
{
    public const int ThresholdMs = 500;
    const int MaxStackDumps = 5;

    /// <summary>What the UI thread is doing now, e.g. "begin: open microphone". Set by the dictation steps.</summary>
    public static volatile string Step = "idle";

    static int _uiManagedThreadId;
    static int _stackDumps;
    static int _stalls;

    /// <summary>Stalls seen since launch; the end-to-end test asserts this stays zero.</summary>
    public static int Stalls => _stalls;

    public static void Start(Dispatcher dispatcher)
    {
        _uiManagedThreadId = dispatcher.Thread.ManagedThreadId;
        new Thread(() => Watch(dispatcher)) { IsBackground = true, Name = "talkflow ui watchdog" }.Start();
    }

    static void Watch(Dispatcher dispatcher)
    {
        while (!dispatcher.HasShutdownStarted)
        {
            Thread.Sleep(250);
            var watch = Stopwatch.StartNew();
            var ping = dispatcher.BeginInvoke(DispatcherPriority.Send, new Action(() => { }));
            if (ping.Wait(TimeSpan.FromMilliseconds(ThresholdMs)) == DispatcherOperationStatus.Completed) continue;
            if (dispatcher.HasShutdownStarted) return;

            var step = Step;
            Interlocked.Increment(ref _stalls);
            Log.Write($"STALL: the UI thread has not answered for {ThresholdMs} ms (step: {step})");
            if (Interlocked.Increment(ref _stackDumps) <= MaxStackDumps) Log.Write("STALL stack:" + UiStack());
            while (ping.Wait(TimeSpan.FromSeconds(1)) != DispatcherOperationStatus.Completed && !dispatcher.HasShutdownStarted)
                Log.Write($"STALL: still blocked after {watch.ElapsedMilliseconds} ms (step: {Step})");
            Log.Write($"STALL ended after {watch.ElapsedMilliseconds} ms (step at start: {step})");
        }
    }

    /// <summary>The UI thread's managed frames, innermost first, from a snapshot of this process.</summary>
    static string UiStack()
    {
        try
        {
            using var target = DataTarget.CreateSnapshotAndAttach(Environment.ProcessId);
            using var runtime = target.ClrVersions[0].CreateRuntime();
            var thread = runtime.Threads.FirstOrDefault(t => t.ManagedThreadId == _uiManagedThreadId);
            if (thread is null) return " (UI thread not found)";
            var text = new StringBuilder();
            foreach (var frame in thread.EnumerateStackTrace().Take(40))
                text.Append("\n    ").Append(frame.Method?.Signature ?? frame.FrameName ?? $"[{frame.Kind}]");
            return text.Length == 0 ? " (no managed frames)" : text.ToString();
        }
        catch (Exception e)
        {
            return $" (could not read the stack: {e.GetType().Name}: {e.Message})";
        }
    }
}

