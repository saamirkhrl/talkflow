using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using Talkflow.Core;

namespace Talkflow;

/// <summary>
/// "Report a problem...": one zip on the Desktop with what is needed to find
/// out why talkflow misbehaved on someone's PC: the version and architecture,
/// the --enginecheck report, the settings switches, the end of talkflow.log
/// and the speech engine's startup and error lines.
///
/// Never what was dictated: transcripts are cut out of the log (they are only
/// there when TALKFLOW_LOG_TRANSCRIPTS=1), the engine log keeps only lines it
/// prints about itself, and learned words and API keys are left out.
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
        return text.ToString();
    }

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
