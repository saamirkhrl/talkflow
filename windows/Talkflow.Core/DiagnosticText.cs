using System.Text.RegularExpressions;

namespace Talkflow.Core;

/// <summary>
/// What a diagnostics file may contain from the logs: never dictated text
/// (the Windows app's Diagnostics.cs builds the file).
/// </summary>
public static class DiagnosticText
{
    /// <summary>"transcribed 3 sentences in 0.82s: what was said" loses what was said.</summary>
    static readonly Regex Transcript = new(@"^(.*\btranscribed\b.*? in [0-9.]+s): .*$", RegexOptions.Multiline);

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
}
