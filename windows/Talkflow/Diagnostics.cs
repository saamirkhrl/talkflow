using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using NAudio.CoreAudioApi;
using NAudio.Wave;
using Talkflow.Core;

namespace Talkflow;

/// <summary>
/// "Report a problem...": one zip on the Desktop with what is needed to find
/// out why talkflow misbehaved on someone's PC: the version and architecture,
/// the --enginecheck report, the microphones and a one-second test of the
/// default one, the settings switches, what was measured on this PC (the speed
/// tests, the final-pass verdict, the thread count), the microphone's keep-open
/// and speech-gate settings with the last holds' decisions, the end of
/// talkflow.log and the speech engine's startup and error lines.
///
/// Never what was dictated: transcripts are cut out of the log (they are only
/// there when TALKFLOW_LOG_TRANSCRIPTS=1), the engine log keeps only lines it
/// prints about itself, and learned words and API keys are left out. The
/// microphone test keeps only counts and a level, never the sound.
/// </summary>
static class Diagnostics
{
    const int LogLines = 400;

    /// <summary>What --enginecheck prints: the version, the engine, the model, the microphone.</summary>
    public static string EngineReport()
    {
        var report = new StringBuilder();
        report.AppendLine($"version: {Updater.CurrentVersion} ({RuntimeInformation.ProcessArchitecture}, {Updater.DisplayVersion})");
        report.AppendLine($"windows: {Environment.OSVersion.VersionString}, {RuntimeInformation.OSArchitecture}, {Environment.ProcessorCount} logical processors");
        report.AppendLine($"whisper-server: {(SpeechEngine.EngineInstalled ? Paths.ServerExe : "not found")}");
        report.AppendLine($"model complete: {SpeechEngine.Small.ModelIsComplete} ({SpeechEngine.Small.ModelPath})");
        report.AppendLine($"server responding on :{SpeechEngine.Small.Port}: {SpeechEngine.IsResponding(SpeechEngine.Small.Port)}");
        report.AppendLine($"final-pass model complete: {SpeechEngine.Large.ModelIsComplete}, responding on :{SpeechEngine.Large.Port}: {SpeechEngine.IsResponding(SpeechEngine.Large.Port)}");
        report.AppendLine($"microphone: {Microphone.Check()}");
        report.AppendLine($"data folder: {Paths.DataDir}");
        return report.ToString();
    }

    /// <summary>Writes the zip to the Desktop (or %TEMP% when there is none) and returns its path.</summary>
    public static string Create()
    {
        var folder = Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory);
        if (folder.Length == 0 || !Directory.Exists(folder)) folder = Path.GetTempPath();
        var path = Path.Combine(folder, $"talkflow-diagnostics-{DateTime.Now:yyyyMMdd-HHmmss}.zip");
        using (var zip = ZipFile.Open(path, ZipArchiveMode.Create))
        {
            var log = DiagnosticText.Redact(Tail(Log.FilePath, LogLines));
            Add(zip, "report.txt", Report(log));
            Add(zip, "talkflow.log", log);
            foreach (var engineLog in Directory.Exists(Paths.LogsDir) ? Directory.EnumerateFiles(Paths.LogsDir, "whisper-server-*.log") : Enumerable.Empty<string>())
                Add(zip, Path.GetFileName(engineLog), DiagnosticText.EngineLines(ReadShared(engineLog)));
        }
        Log.Write($"saved diagnostics to {path}");
        return path;
    }

    static string Report(string log)
    {
        var text = new StringBuilder();
        text.AppendLine($"talkflow diagnostics, {DateTime.Now:yyyy-MM-dd HH:mm:ss zzz}");
        text.AppendLine();
        text.Append(EngineReport());
        text.AppendLine($"install folder: {Paths.InstallDir}");
        text.AppendLine($"process: {(Environment.Is64BitProcess ? "64" : "32")}-bit {RuntimeInformation.ProcessArchitecture}, elevated: {Environment.IsPrivilegedProcess}");
        text.AppendLine($"talkflow processes running: {Process.GetProcessesByName("talkflow").Length}, whisper-server: {Process.GetProcessesByName("whisper-server").Length}");
        text.AppendLine();
        text.AppendLine("settings (switches only; learned words are left out):");
        try
        {
            var settings = new SettingsStore(Paths.SettingsFile);
            text.AppendLine($"  writing style: {settings.WritingStyle}");
            text.AppendLine($"  type while speaking: {settings.TypeWhileSpeaking}");
            text.AppendLine($"  accurate final pass: {settings.AccurateFinalPass}");
            text.AppendLine($"  OpenAI transcription: {settings.UseOpenAITranscription} (key saved: {ApiKeys.Has(ApiKeys.Provider.OpenAI)})");
            text.AppendLine($"  Claude punctuation: {settings.UseClaudePunctuation} (key saved: {ApiKeys.Has(ApiKeys.Provider.Anthropic)})");
            text.AppendLine($"  learned words: {settings.LearnedWords.Count}");
            text.AppendLine($"  shortcut: {new WindowsPrefs().Hotkey.Describe()}");
        }
        catch (Exception e)
        {
            text.AppendLine($"  could not read settings: {e.Message}");
        }
        text.AppendLine($"  start with Windows: {StartupEntry.IsEnabled}");
        text.AppendLine();
        text.Append(Speed(log));
        text.AppendLine();
        text.Append(Microphones());
        return text.ToString();
    }

    /// <summary>
    /// How this PC was tuned: processors and engine threads, what small.en and
    /// the final-pass model measured here (device.json, kept by the app), whether
    /// live captions run, how long the microphone stays open, the speech gate's
    /// thresholds, and the last holds' decisions from the log. Nothing dictated.
    /// </summary>
    static string Speed(string log)
    {
        var text = new StringBuilder();
        text.AppendLine("speed on this PC:");
        text.AppendLine($"  {Environment.ProcessorCount} logical processors, {SpeechEngine.PhysicalCores?.ToString() ?? "an unknown number of"} cores; speech engine threads: {SpeechEngine.Threads}");
        text.AppendLine($"  engine build: {SpeechEngine.Stamp}");
        try
        {
            var entries = new DeviceStore(Paths.DeviceFile).All();
            text.AppendLine("  measured here (kept 30 days; the app measures when a model, engine build or device is new):");
            text.AppendLine("  " + DiagnosticText.DeviceLines(entries).Replace("\n", "\n  "));
            var small = entries.Where(e => e.Key.StartsWith("ggml-small", StringComparison.Ordinal)).Select(e => e.Entry.Seconds).FirstOrDefault();
            text.AppendLine($"  live captions: {(small is null ? "on (not measured yet)" : DevicePolicy.LivePreviews(small) ? $"on (limit {DevicePolicy.SlowSmallSeconds:F1} s per 1 s clip)" : $"off, small.en needs {small:F2} s per 1 s clip and the limit is {DevicePolicy.SlowSmallSeconds:F1} s")}");
            var plan = DevicePolicy.DecideFinalPass(new SettingsStore(Paths.SettingsFile).AccurateFinalPass, entries.Where(e => e.Key.StartsWith("ggml-large", StringComparison.Ordinal)).Select(e => e.Entry).FirstOrDefault(), small);
            text.AppendLine($"  final pass: {plan} (model file {(SpeechEngine.Large.ModelIsComplete ? "downloaded" : "not downloaded")}; skipped without a download when small.en needs more than {DevicePolicy.FinalPassBudgetSeconds / DevicePolicy.LargeToSmallRatio:F2} s)");
        }
        catch (Exception e)
        {
            text.AppendLine($"  could not read what was measured: {e.Message}");
        }
        text.AppendLine($"  microphone stays open after a hold: {DevicePolicy.FastOpenKeepMs / 1000} s if it opens in under {DevicePolicy.SlowOpenMs} ms, otherwise {DevicePolicy.SlowOpenKeepMs / 1000} s");
        text.AppendLine($"  speech gate: a frame at {SpeechGate.VoicedRms:F4} RMS or more is sound; {SpeechGate.MinVoicedMs} ms of it is needed or nothing is sent to the engine; a hold of {HoldCheck.DeadMs} ms or more with no audio at all is a dead microphone");
        text.AppendLine("  last decisions from talkflow.log:");
        text.AppendLine(DiagnosticText.RecentDecisions(log));
        return text.ToString();
    }

    /// <summary>
    /// Every input device Windows knows, which one is the default, and one
    /// second from the default through each API talkflow can record with: how
    /// many buffers arrived, how soon, and how loud. On a thread of its own
    /// (MTA, for WASAPI; --diagnostics calls this from the STA main thread),
    /// and given up on after 15 s, since an audio driver can hang.
    /// </summary>
    static string Microphones()
    {
        string? result = null;
        var thread = new Thread(() =>
        {
            var text = ListAndProbeMicrophones();
            Volatile.Write(ref result, text);
        }) { IsBackground = true, Name = "talkflow diagnostics microphone" };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
        thread.Join(TimeSpan.FromSeconds(15));
        return Volatile.Read(ref result) ?? "microphones: the check did not finish within 15 s (an audio driver is not answering)\n";
    }

    static string ListAndProbeMicrophones()
    {
        var text = new StringBuilder();
        text.AppendLine("microphones (WASAPI):");
        try
        {
            using var devices = new MMDeviceEnumerator();
            string? console = DefaultId(devices, Role.Console);
            string? communications = DefaultId(devices, Role.Communications);
            // One endpoint at a time: a single bad one (0xE000020B on the PC this
            // was written for) must not hide the rest.
            var endpoints = devices.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.All);
            int count = endpoints.Count;
            for (int i = 0; i < count; i++)
                text.AppendLine(DescribeEndpoint(endpoints, i, console, communications));
            if (count == 0) text.AppendLine("  none");
            if (console is null) text.AppendLine("  no default input device");
        }
        catch (Exception e)
        {
            text.AppendLine($"  could not list them: {Describe(e)}");
        }
        text.AppendLine("microphones (waveIn):");
        try
        {
            int count = WaveInEvent.DeviceCount;
            for (int i = 0; i < count; i++) text.AppendLine($"  {i}: {WaveInEvent.GetCapabilities(i).ProductName}");
            if (count == 0) text.AppendLine("  none");
        }
        catch (Exception e)
        {
            text.AppendLine($"  could not list them: {Describe(e)}");
        }
        text.AppendLine($"one second from the default microphone, WASAPI: {Probe(() => new WasapiCapture(WasapiCapture.GetDefaultCaptureDevice(), false, 100) { WaveFormat = new WaveFormat(Recorder.SampleRate, 16, 1) })}");
        text.AppendLine($"one second from the default microphone, waveIn: {Probe(() => new WaveInEvent { DeviceNumber = -1, WaveFormat = new WaveFormat(Recorder.SampleRate, 16, 1), BufferMilliseconds = 50, NumberOfBuffers = 4 })}");
        return text.ToString();
    }

    /// <summary>One line for the endpoint at an index; each property is read on its own, so what cannot be read is named and the line still comes out.</summary>
    static string DescribeEndpoint(MMDeviceCollection endpoints, int index, string? console, string? communications)
    {
        MMDevice device;
        try
        {
            device = endpoints[index];
        }
        catch (Exception e)
        {
            return $"  endpoint #{index}: could not be opened: {Describe(e)}";
        }
        using (device)
        {
            string id = Attempt(() => device.ID, out var idError) ?? $"(id unreadable: {idError})";
            string name = Attempt(() => device.FriendlyName, out var nameError) ?? $"(name unreadable: {nameError})";
            string state = Attempt(() => device.State.ToString(), out var stateError) ?? $"(state unreadable: {stateError})";
            var marks = (id == console ? " [default]" : "") + (id == communications ? " [default for calls]" : "");
            string format = "";
            if (state == nameof(DeviceState.Active))
            {
                format = Attempt(() => { var mix = device.AudioClient.MixFormat; return $", {mix.SampleRate} Hz, {mix.Channels} ch"; }, out var formatError)
                    ?? $", format unreadable: {formatError}";
            }
            return $"  endpoint #{index}: {name}: {state}{format}{marks}";
        }
    }

    /// <summary>The value, or null with the reason in <paramref name="error"/>.</summary>
    static string? Attempt(Func<string> read, out string error)
    {
        try
        {
            error = "";
            return read();
        }
        catch (Exception e)
        {
            error = Describe(e);
            return null;
        }
    }

    static string? DefaultId(MMDeviceEnumerator devices, Role role)
    {
        try
        {
            if (!devices.HasDefaultAudioEndpoint(DataFlow.Capture, role)) return null;
            using var device = devices.GetDefaultAudioEndpoint(DataFlow.Capture, role);
            return device.ID;
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>Records one second as 16 kHz mono and keeps only the buffer count, the first buffer's delay and the peak.</summary>
    static string Probe(Func<IWaveIn> open)
    {
        var gate = new object();
        int buffers = 0;
        double first = -1;
        int peak = 0;
        var watch = Stopwatch.StartNew();
        IWaveIn? wave = null;
        try
        {
            wave = open();
            wave.DataAvailable += (_, e) =>
            {
                if (e.BytesRecorded == 0) return;
                int loudest = 0;
                for (int i = 0; i + 1 < e.BytesRecorded; i += 2)
                    loudest = Math.Max(loudest, Math.Abs((int)BitConverter.ToInt16(e.Buffer, i)));
                lock (gate)
                {
                    if (buffers++ == 0) first = watch.Elapsed.TotalMilliseconds;
                    peak = Math.Max(peak, loudest);
                }
            };
            watch.Restart();
            wave.StartRecording();
            Thread.Sleep(1000);
            wave.StopRecording();
        }
        catch (Exception e)
        {
            return $"failed after {watch.ElapsedMilliseconds} ms: {Describe(e)}";
        }
        finally
        {
            try { wave?.Dispose(); } catch (Exception) { }
        }
        lock (gate)
        {
            return buffers == 0
                ? "no audio arrived"
                : $"{buffers} buffers, first after {first:F0} ms, peak {peak / 32768.0:F3}" + (peak == 0 ? " (digital silence)" : "");
        }
    }

    static string Describe(Exception e) =>
        e is COMException ? $"{e.Message} (0x{e.HResult:X8})" : e.Message;

    static void Add(ZipArchive zip, string name, string text)
    {
        var entry = zip.CreateEntry(name, CompressionLevel.Optimal);
        using var writer = new StreamWriter(entry.Open(), new UTF8Encoding(false));
        writer.Write(text);
    }

    /// <summary>The file's text, even while talkflow or whisper-server still has it open.</summary>
    static string ReadShared(string path)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream);
            return reader.ReadToEnd();
        }
        catch (Exception e)
        {
            return $"(could not read {Path.GetFileName(path)}: {e.Message})";
        }
    }

    static string Tail(string path, int lines)
    {
        var text = File.Exists(path) ? ReadShared(path) : "";
        if (text.Length == 0 && File.Exists(path + ".1")) text = ReadShared(path + ".1");
        var all = text.Replace("\r\n", "\n").Split('\n');
        return string.Join("\n", all.Skip(Math.Max(0, all.Length - lines)));
    }

    /// <summary>Shows the zip in Explorer, selected.</summary>
    public static void Reveal(string path)
    {
        try
        {
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
        }
        catch (Exception e)
        {
            Log.Write($"could not show the diagnostics file: {e.Message}");
        }
    }
}
