using System;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;
using Talkflow.Core;

namespace Talkflow;

/// <summary>
/// The one download of small.en, owned by the app rather than by a window, so
/// it carries on when setup is closed, never runs twice however many windows
/// ask, and starts the speech engine by itself when it is done. All members
/// are for the UI thread; <see cref="Changed"/> is raised there too.
/// </summary>
sealed class ModelDownload
{
    readonly App _app;
    bool _running;

    public ModelDownload(App app) => _app = app;

    /// <summary>Bytes are arriving right now.</summary>
    public bool Downloading { get; private set; }

    /// <summary>Why the last attempt failed, as a sentence; null when none has, or while a new one runs.</summary>
    public string? Error { get; private set; }

    public DownloadMeter Meter { get; } = new();

    /// <summary>Progress, completion or failure.</summary>
    public event Action? Changed;

    /// <summary>
    /// Downloads the model unless it is there, a download is under way, or the
    /// last one failed (that waits for <see cref="Retry"/>, so an offline PC
    /// is not hammered).
    /// </summary>
    public void StartIfNeeded()
    {
        if (_running || Error is not null) return;
        _ = Run();
    }

    /// <summary>The "Try again" button.</summary>
    public void Retry()
    {
        if (_running) return;
        Error = null;
        _ = Run();
    }

    async Task Run()
    {
        _running = true;
        bool downloaded = false;
        var watch = Stopwatch.StartNew();
        try
        {
            // The file check is off the UI thread like the download itself.
            if (!await Task.Run(() => SpeechEngine.Small.ModelIsComplete))
            {
                Meter.Reset();
                Downloading = true;
                Log.Write($"model download started ({SpeechEngine.Small.Name})");
                Changed?.Invoke();
                var progress = new Progress<(long Written, long? Total)>(p =>
                {
                    if (!Downloading) return;
                    Meter.Report(p.Written, p.Total, watch.Elapsed.TotalSeconds);
                    Changed?.Invoke();
                });
                await Task.Run(() => SpeechEngine.Download(SpeechEngine.Small, progress, CancellationToken.None));
                downloaded = true;
                Log.Write($"model download finished in {watch.Elapsed.TotalSeconds:F1}s");
            }
        }
        catch (Exception e)
        {
            Error = DownloadText.Failure(e);
            Log.Write($"model download failed after {watch.Elapsed.TotalSeconds:F1}s: {e.GetType().Name}: {e.Message}");
        }
        Downloading = false;
        _running = false;
        Changed?.Invoke();
        if (!downloaded) return;
        bool up = await _app.StartEngine();
        // With setup closed nobody is watching the progress, so say when it works.
        if (up && !_app.OnboardingOpen)
            _app.Tray.Notify("talkflow is ready", $"Hold {_app.Hotkey.Spec.Describe()} and speak, anywhere you type.");
    }
}
