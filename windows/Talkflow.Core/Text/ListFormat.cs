using System.Text.RegularExpressions;

namespace Talkflow.Core.Text;

/// <summary>
/// Turns a dictated enumeration ("number one, it's free. Number two, ...")
/// into a numbered list (ListFormat.swift). Run once at release on the whole
/// transcript; the spoken cue is consumed and replaced by the marker, nothing
/// else is removed.
/// </summary>
public static class ListFormat
{
    static readonly Dictionary<string, int> NumberWords = new()
    {
        ["one"] = 1, ["two"] = 2, ["three"] = 3, ["four"] = 4, ["five"] = 5,
        ["six"] = 6, ["seven"] = 7, ["eight"] = 8, ["nine"] = 9, ["ten"] = 10,
        ["first"] = 1, ["second"] = 2, ["third"] = 3, ["fourth"] = 4, ["fifth"] = 5,
        ["sixth"] = 6, ["seventh"] = 7, ["eighth"] = 8, ["ninth"] = 9, ["tenth"] = 10,
    };

    /// <summary>"number two", "number 2", "second," or "third of all".</summary>
    static readonly Regex CuePattern = new(
        @"(?:\b(?:and|then)\s+)?\b(?:number\s+(one|two|three|four|five|six|seven|eight|nine|ten|\d{1,2})\b"
        + @"|(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)(?:\s+of\s+all\b|(?=\s*,)))[,.:]?\s*",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// <summary>A bare ordinal with no comma; counts only as a whole chain from "first".</summary>
    static readonly Regex BareCuePattern = new(
        @"(?:\b(?:and|then)\s+){0,2}\b(first|second|third|fourth|fifth|sixth|seventh|eighth|ninth|tenth)\b[,.:]?\s*",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// <summary>Words that make the ordinal after them an adjective: "the first time".</summary>
    static readonly HashSet<string> AdjectiveLeads = new()
    {
        "the", "a", "an", "my", "our", "your", "his", "her", "their", "its", "this", "that", "at", "every",
        "each", "for", "in", "on", "to", "of", "was", "be", "came", "come", "finished", "went",
    };

    readonly record struct Cue(int Location, int Length, int Value)
    {
        public int End => Location + Length;
    }

    static List<Cue> BareChain(string paragraph)
    {
        var chain = new List<Cue>();
        foreach (Match match in BareCuePattern.Matches(paragraph))
        {
            if (ValueOf(match.Groups[1].Value) is not { } value) continue;
            bool joined = match.Groups[1].Index > match.Index; // "and then third"
            var before = Chars.TrimSpaces(paragraph[..match.Index]);
            var words = Chars.Words(before);
            var previousWord = words.Length > 0 ? Chars.Lower(words[^1]) : "";
            if (value == 1 && chain.Count <= 1)
            {
                // A later "first" replaces an unanswered earlier one.
                chain = AdjectiveLeads.Contains(previousWord) ? new List<Cue>() : new List<Cue> { new(match.Index, match.Length, 1) };
                continue;
            }
            if (chain.Count == 0 || value != chain[^1].Value + 1) continue;
            bool opensClause = joined || before.EndsWith(',') || before.EndsWith('.') || before.EndsWith(';');
            if (!opensClause) continue;
            chain.Add(new Cue(match.Index, match.Length, value));
        }
        return chain.Count >= 2 ? chain : new List<Cue>();
    }

    public static string Apply(string text) =>
        string.Join("\n\n", text.Split("\n\n").Select(FormatParagraph));

    static string FormatParagraph(string paragraph)
    {
        var cues = new List<Cue>();
        foreach (Match match in CuePattern.Matches(paragraph))
        {
            var word = match.Groups[1].Success ? match.Groups[1] : match.Groups[2].Success ? match.Groups[2] : null;
            if (word is null || ValueOf(word.Value) is not { } value) continue;
            cues.Add(new Cue(match.Index, match.Length, value));
        }

        // A list opens at 1 and climbs. Cues that don't continue it are prose.
        var chain = new List<Cue>();
        foreach (var cue in cues)
        {
            if (chain.Count == 0) { if (cue.Value == 1) chain.Add(cue); }
            else if (cue.Value > chain[^1].Value) chain.Add(cue);
        }
        var bare = BareChain(paragraph);
        if (bare.Count > chain.Count) chain = bare;
        if (chain.Count < 2) return paragraph;

        var items = new List<string>();
        for (int index = 0; index < chain.Count; index++)
        {
            var cue = chain[index];
            int start = cue.End;
            int end = index + 1 < chain.Count ? chain[index + 1].Location : paragraph.Length;
            var item = Chars.Trim(paragraph[start..end]);
            if (item.Length == 0) return paragraph; // cue with nothing after it
            if (index + 1 < chain.Count && (item.EndsWith(',') || item.EndsWith(';'))) item = Chars.DropLast(item);
            item = Chars.CapitalizeFirst(item);
            items.Add($"{cue.Value}. {item}");
        }

        var intro = Chars.Trim(paragraph[..chain[0].Location]);
        if (intro.Length > 0)
        {
            if (intro.EndsWith(',') || intro.EndsWith(';')) intro = Chars.DropLast(intro);
            var last = Chars.Last(intro);
            if (last is not null && !(last is "." or "!" or "?" or ":")) intro += ":";
            return intro + "\n" + string.Join("\n", items);
        }
        return string.Join("\n", items);
    }

    static int? ValueOf(string word)
    {
        var lower = Chars.Lower(word);
        if (NumberWords.TryGetValue(lower, out var value)) return value;
        return int.TryParse(lower, System.Globalization.NumberStyles.None, System.Globalization.CultureInfo.InvariantCulture, out var n) ? n : null;
    }
}
