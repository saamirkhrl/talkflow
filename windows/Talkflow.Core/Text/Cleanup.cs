using System.Text.RegularExpressions;

namespace Talkflow.Core.Text;

/// <summary>
/// Removes filler sounds from a transcript (Cleanup.swift). Deletion only,
/// from a fixed list of sounds that are never words: "like", "you know" and "I
/// mean" are real English as often as filler and are deliberately not here.
/// </summary>
public static class Cleanup
{
    static readonly string[] Fillers = { "um", "umm", "ummm", "uh", "uhh", "uhhh", "erm", "hmm", "mmm" };

    static readonly Regex FillerPattern = new(
        @"\b(?:" + string.Join("|", Fillers.OrderByDescending(f => f.Length).ThenBy(f => f, StringComparer.Ordinal).Select(Regex.Escape)) + @")\b[,]?\s*",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    static readonly Regex Runs = new(@"\s{2,}");
    static readonly Regex SpaceBeforePunctuation = new(@"\s+([,.!?;:])");

    public static string Tidy(string raw)
    {
        var text = FillerPattern.Replace(raw, "");
        text = Runs.Replace(text, " ");
        text = SpaceBeforePunctuation.Replace(text, "$1");
        text = Chars.Trim(text);
        if (text.Length == 0) return text;
        // Removing a leading filler can leave the sentence starting lowercase.
        return Chars.CapitalizeFirst(text);
    }
}
