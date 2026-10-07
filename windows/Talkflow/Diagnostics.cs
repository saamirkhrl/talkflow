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
/// default one, the settings switches, the end of talkflow.log and the speech
/// engine's startup and error lines.
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
        report.AppendLine($"version: {Updater.CurrentVersion} ({RuntimeInformation.ProcessArchitecture})");
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
            Add(zip, "report.txt", Report());
            Add(zip, "talkflow.log", DiagnosticText.Redact(Tail(Log.FilePath, LogLines)));
            foreach (var engineLog in Directory.Exists(Paths.LogsDir) ? Directory.EnumerateFiles(Paths.LogsDir, "whisper-server-*.log") : Enumerable.Empty<string>())
                Add(zip, Path.GetFileName(engineLog), DiagnosticText.EngineLines(ReadShared(engineLog)));
        }
        Log.Write($"saved diagnostics to {path}");
        return path;
    }

    static string Report()
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
        text.Append(Microphones());
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
            foreach (var device in devices.EnumerateAudioEndPoints(DataFlow.Capture, DeviceState.All))
            {
                using (device)
                {
                    var marks = (device.ID == console ? " [default]" : "") + (device.ID == communications ? " [default for calls]" : "");
                    string format = "";
                    if (device.State == DeviceState.Active)
                    {
                        try
                        {
                            var mix = device.AudioClient.MixFormat;
                            format = $", {mix.SampleRate} Hz, {mix.Channels} ch";
                        }
                        catch (Exception e)
                        {
                            format = $", format unreadable: {Describe(e)}";
                        }
                    }
                    text.AppendLine($"  {device.FriendlyName}: {device.State}{format}{marks}");
                }
            }
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
