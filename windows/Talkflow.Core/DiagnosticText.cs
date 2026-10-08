using System.Globalization;
using System.Text.RegularExpressions;

namespace Talkflow.Core;

/// <summary>
/// What a diagnostics file may contain from the logs: never dictated text
/// (the Windows app's Diagnostics.cs builds the file).
/// </summary>
public static class DiagnosticText
{
    /// <summary>"transcribed 3 sentences in 0.82s: what was said" loses what was said (0,82s on a comma-decimal Windows).</summary>
    static readonly Regex Transcript = new(@"^(.*\btranscribed\b.*? in [0-9.,]+s): .*$", RegexOptions.Multiline);

    public static string Redact(string log) => Transcript.Replace(log, "$1: [dictated text removed]");

    /// <summary>
    /// The lines whisper-server prints about itself, never a transcript:
    /// whisper.cpp's logging starts each line with the snake_case function
    /// that wrote it ("whisper_init_from_file: loading model", "ggml_..."),
    /// plus a few fixed starts. A line is kept only by its start, never for
    /// a word inside it, so a sentence that mentions an error is not kept.
    /// Everything else is counted, not copied.
    /// </summary>
    static readonly Regex EngineLine = new(
        @"^\s*([a-z0-9]+_[a-z0-9_]*\s*:|main:|system_info:|error:|warning:|Received request|Running whisper|whisper server listening|load_backend|register_backend)",
        RegexOptions.None);

    public static string EngineLines(string log)
    {
        var kept = new List<string>();
        int omitted = 0;
        foreach (var line in log.Replace("\r\n", "\n").Split('\n'))
        {
            if (EngineLine.IsMatch(line)) kept.Add(line);
            else if (line.Trim().Length > 0) omitted++;
        }
        if (kept.Count > 300) kept = kept.Take(150).Append($"... ({kept.Count - 300} lines) ...").Concat(kept.Skip(kept.Count - 150)).ToList();
        kept.Add($"({omitted} other lines omitted, so no transcript can be included)");
        return string.Join("\n", kept);
    }

    /// <summary>The log lines that record a decision about the microphone, the speech gate, the speed tests and the final pass.</summary>
    static readonly Regex Decision = new(
        @"^\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+ (finish:|recording:|microphone (opened|still open|ready)|closing |pill:|speed test|device:|slow PC|live captions|final-pass|downloading the final|speech engine|test:)",
        RegexOptions.None);

    /// <summary>The last <paramref name="max"/> decision lines of an (already redacted) log, oldest first, indented for report.txt.</summary>
    public static string RecentDecisions(string log, int max = 25)
    {
        var lines = log.Replace("\r\n", "\n").Split('\n').Where(l => Decision.IsMatch(l)).ToList();
        if (lines.Count == 0) return "  (none in the log)";
        return string.Join("\n", lines.Skip(Math.Max(0, lines.Count - max)).Select(l => "  " + l));
    }

    static string Seconds(double s) => s.ToString("F2", CultureInfo.InvariantCulture) + " s";

    /// <summary>What was measured on this PC (device.json), one line each, for report.txt.</summary>
    public static string DeviceLines(IReadOnlyList<(string Key, DeviceEntry Entry)> entries)
    {
        if (entries.Count == 0) return "  nothing measured yet";
        var lines = new List<string>();
        foreach (var (key, entry) in entries)
        {
            var parts = key.Split('|');
            string what = parts.Length >= 3 ? $"{parts[0]} on {parts[2]}" : key;
            string when = entry.At.ToLocalTime().ToString("yyyy-MM-dd", CultureInfo.InvariantCulture);
            string took = entry.Seconds is { } s ? $"a 1 s clip took {Seconds(s)}" : "no timing";
            string verdict;
            if (entry.TooSlow is { } slow)
                verdict = slow ? $"too slow (budget {Seconds(DevicePolicy.FinalPassBudgetSeconds)}), so it is not used" : "fast enough, so it is used";
            else if (entry.CpuSeconds is { } cpu)
                verdict = $"{Seconds(cpu)} on the CPU; runs on the {(entry.UseCpu == true ? "CPU" : "GPU")}";
            else
                verdict = "runs on the CPU";
            lines.Add($"  {what}: {took}, {verdict} (measured {when})");
        }
        return string.Join("\n", lines);
    }
}
