using System.Globalization;
using System.Net.Sockets;

namespace Talkflow.Core;

/// <summary>The three steps of first-run setup, in order.</summary>
public enum SetupStage { Microphone, Speech, TryIt }

/// <summary>Where the speech engine step stands: the model download, then the server.</summary>
public enum SpeechPhase { EngineMissing, Preparing, Downloading, DownloadFailed, Starting, EngineFailed, Ready }

/// <summary>
/// The decisions behind the setup window, kept free of WPF so they can be
/// tested: which step is current, where the speech step stands, what the
/// footer button says, and the words for trying it out.
/// </summary>
public static class SetupFlow
{
    /// <summary>The first step that is not done yet; the one that gets the primary action.</summary>
    public static SetupStage Current(bool microphoneAllowed, SpeechPhase speech) =>
        !microphoneAllowed ? SetupStage.Microphone
        : speech != SpeechPhase.Ready ? SetupStage.Speech
        : SetupStage.TryIt;

    /// <summary>
    /// A running engine wins over everything. Then a download in progress or
    /// failed, then a model that is not there yet (the download is about to
    /// start by itself), then the server starting or failing to start.
    /// </summary>
    public static SpeechPhase Speech(bool engineInstalled, bool modelComplete, bool downloading, bool downloadFailed,
        bool engineReady, bool engineStarting, bool engineFailed)
    {
        if (!engineInstalled) return SpeechPhase.EngineMissing;
        if (engineReady) return SpeechPhase.Ready;
        if (downloading) return SpeechPhase.Downloading;
        if (!modelComplete) return downloadFailed ? SpeechPhase.DownloadFailed : SpeechPhase.Preparing;
        if (engineStarting) return SpeechPhase.Starting;
        return engineFailed ? SpeechPhase.EngineFailed : SpeechPhase.Starting;
    }

    /// <summary>The footer button: "Finish later" until everything works, then "Done", which is the primary action once the user has tried it.</summary>
    public static (string Label, bool Primary) Footer(SetupStage stage, bool tried) =>
        stage == SetupStage.TryIt ? ("Done", tried) : ("Finish later", false);

    public static string TryPrompt(string shortcut) => $"Hold {shortcut} and say something";

    public static string TrySuccess(string shortcut) => $"That's it. Hold {shortcut} anywhere.";
}

/// <summary>Words for a model download: sizes, percent, time left and what went wrong.</summary>
public static class DownloadText
{
    static readonly CultureInfo Inv = CultureInfo.InvariantCulture;

    /// <summary>"212 MB of 488 MB", both in the unit of the total. Without a total, just what has arrived.</summary>
    public static string Sizes(long written, long? total)
    {
        bool gb = (total ?? written) >= 1_000_000_000;
        string Show(long bytes) => gb
            ? (bytes / 1e9).ToString("F1", Inv) + " GB"
            : Math.Round(bytes / 1e6).ToString("F0", Inv) + " MB";
        return total is { } all && all > 0 ? $"{Show(written)} of {Show(all)}" : $"{Show(written)} downloaded";
    }

    /// <summary>Whole percent, rounded down so 100 only appears once the file is complete. Null when the total is unknown.</summary>
    public static int? Percent(long written, long? total) =>
        total is { } all && all > 0 ? (int)Math.Clamp(written * 100 / all, 0, 99) : null;

    /// <summary>"about 2 minutes left"; rounded, because anything finer would be a guess.</summary>
    public static string TimeLeft(double seconds)
    {
        if (seconds < 5) return "a few seconds left";
        if (seconds < 55) return $"about {(int)(Math.Round(seconds / 5) * 5)} seconds left";
        if (seconds >= 5400) return "more than an hour left";
        int minutes = Math.Max(1, (int)Math.Round(seconds / 60));
        return minutes == 1 ? "about 1 minute left" : $"about {minutes} minutes left";
    }

    /// <summary>The detail line under the progress bar. The time left appears only once there is a measured speed.</summary>
    public static string Progress(long written, long? total, double? bytesPerSecond)
    {
        var sizes = Sizes(written, total);
        if (total is not { } all || all <= 0) return sizes;
        if (bytesPerSecond is not { } speed || speed <= 0) return sizes + ", working out the time left";
        return $"{sizes}, {TimeLeft(Math.Max(0, all - written) / speed)}";
    }

    /// <summary>A failed download in a sentence a person can act on.</summary>
    public static string Failure(Exception e)
    {
        if (e is IOException io && (io.HResult & 0xFFFF) is 0x70 or 0x27) return "There is not enough free disk space for the model (about 500 MB).";
        if (e is UnauthorizedAccessException) return "talkflow could not write to its models folder.";
        if (e is OperationCanceledException) return "The download stalled. Check your internet connection.";
        if (e is HttpRequestException { StatusCode: null } || HasSocketCause(e)) return "Could not reach the download server. Check your internet connection.";
        return e.Message;
    }

    static bool HasSocketCause(Exception e)
    {
        for (var inner = e; inner is not null; inner = inner.InnerException)
            if (inner is SocketException) return true;
        return false;
    }
}

/// <summary>
/// Smooths a download's speed so the time left does not jump around. Fed the
/// bytes written so far and the clock in seconds; knows nothing about WPF or
/// HTTP, so it is tested with a made-up clock.
/// </summary>
public sealed class DownloadMeter
{
    /// <summary>Seconds of data needed before a time left is shown at all.</summary>
    const double WarmUp = 3;
    const double MinimumSample = 0.5;

    bool _started;
    double _startedAt, _lastAt, _now;
    long _lastBytes;
    double? _speed;

    public long Written { get; private set; }
    public long? Total { get; private set; }

    public void Reset()
    {
        _started = false;
        _speed = null;
        Written = 0;
        Total = null;
    }

    public void Report(long written, long? total, double seconds)
    {
        Written = written;
        Total = total;
        _now = seconds;
        if (!_started)
        {
            _started = true;
            _startedAt = _lastAt = seconds;
            _lastBytes = written;
            return;
        }
        double dt = seconds - _lastAt;
        if (dt < MinimumSample) return;
        double current = (written - _lastBytes) / dt;
        _speed = _speed is { } before ? before * 0.7 + current * 0.3 : current;
        _lastAt = seconds;
        _lastBytes = written;
    }

    /// <summary>Smoothed speed; null until enough has been seen to say.</summary>
    public double? BytesPerSecond => _started && _now - _startedAt >= WarmUp && _speed is > 0 ? _speed : null;

    public int? Percent => DownloadText.Percent(Written, Total);

    public string Describe() => DownloadText.Progress(Written, Total, BytesPerSecond);
}
