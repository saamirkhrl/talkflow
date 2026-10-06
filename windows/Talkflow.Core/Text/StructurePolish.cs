using System.Text;
using System.Text.RegularExpressions;

namespace Talkflow.Core.Text;

/// <summary>
/// Inserts blank lines between an email's greeting, body and sign-off
/// (StructurePolish.swift). A pure transform that never removes content: the
/// result must equal the input once all whitespace is stripped, or the input
/// comes back unchanged.
/// </summary>
public static class StructurePolish
{
    /// <summary>"Dear Mr. Clark,", "Hi Sarah,", "Good morning,". Hi/Hey/Hello need a name.</summary>
    static readonly Regex GreetingPattern = new(
        @"^(?:(?:Hi|Hey|Hello)\s+[^,]{1,40}|Dear\b[^,]{0,40}|Good (?:morning|afternoon|evening)\b[^,]{0,40}),",
        RegexOptions.CultureInvariant);

    /// <summary>
    /// A sign-off plus a name at the very end: "Best, Samir", "Thanks Sarah",
    /// "Thank you, Sincerely, Samir". Group 1 is the sign-off itself.
    /// </summary>
    static readonly Regex SignOffPattern = new(
        @"(?:^|,\s*|[.!?]\s+)"
        + @"((?:(?i:best regards|best wishes|best|thanks again|thanks|thank you|regards|sincerely|cheers|talk soon)(?:\s*,)?\s*){1,3}"
        + @"(?:[a-z]+(?:\s*,)?\s*)?[A-Z][A-Za-z]*\.?)\s*$",
        RegexOptions.CultureInvariant);

    /// <summary>A sign-off run straight into the last sentence: "...talkflow best Samira".</summary>
    static readonly Regex BareSignOffPattern = new(
        @"(?<=[\p{Ll}\d])\s+((?i:best regards|best wishes|best|regards|sincerely|cheers|thanks)\s+[A-Z][A-Za-z'-]*\.?)\s*$",
        RegexOptions.CultureInvariant);

    /// <summary>A comma-less greeting that is a whole sentence: "Good morning Emily."</summary>
    static readonly Regex BareGreetingPattern = new(
        @"^(?:Good (?:morning|afternoon|evening)|Dear|Hi|Hey|Hello)\s+(?:(?:Mr|Mrs|Ms|Dr|Prof)\.?\s+)?[A-Z][A-Za-z'-]*(?:\s+[A-Z][A-Za-z'-]*)?[.!]$",
        RegexOptions.CultureInvariant);

    /// <summary>A name or title left over after the greeting's comma: "Mr. Joseph", "Sarah".</summary>
    static readonly Regex GreetingNamePattern = new(
        @"^(?:Mr|Mrs|Ms|Dr|Prof)\.?\s+[A-Z][A-Za-z]*\.?$|^[A-Z][A-Za-z]*\.?$",
        RegexOptions.CultureInvariant);

    /// <summary>A sign-off paragraph without its comma: "Best Samir." Group 1 closer, group 2 name.</summary>
    static readonly Regex CommaLessSignOff = new(
        @"^((?i:best regards|best wishes|best|thanks again|thanks|thank you|regards|sincerely|cheers|talk soon))\s+([A-Z][A-Za-z'-]*\.?)$",
        RegexOptions.CultureInvariant);

    /// <summary>"Best Samir." -> "Best, Samir." on a final paragraph already split off as a sign-off.</summary>
    public static string PunctuateSignOff(string text)
    {
        int breakAt = text.LastIndexOf("\n\n", StringComparison.Ordinal);
        if (breakAt < 0) return text;
        var head = text[..(breakAt + 2)];
        var last = text[(breakAt + 2)..];
        var match = CommaLessSignOff.Match(last);
        if (!match.Success) return text;
        return head + match.Groups[1].Value + ", " + match.Groups[2].Value;
    }

    /// <summary>
    /// Returns the text with blank lines between sections. <paramref name="signOff"/>
    /// false is the live mode: only the greeting break is decided.
    /// </summary>
    public static string Apply(string text, bool signOff = true)
    {
        if (text.Contains('\n')) return ApplyAroundBreaks(text, signOff);
        return ApplySingleLine(text, greeting: true, signOff: signOff);
    }

    static string ApplyAroundBreaks(string text, bool signOff)
    {
        var lines = text.Split('\n');
        int firstIndex = Array.FindIndex(lines, l => Chars.TrimSpaces(l).Length > 0);
        int lastIndex = Array.FindLastIndex(lines, l => Chars.TrimSpaces(l).Length > 0);
        if (firstIndex < 0 || lastIndex < 0) return text;
        var firstLine = lines[firstIndex];
        lines[firstIndex] = ApplySingleLine(firstLine, greeting: true, signOff: false);
        if (signOff)
        {
            lines[lastIndex] = ApplySingleLine(lines[lastIndex], greeting: firstIndex == lastIndex, signOff: true,
                afterGreeting: lines[firstIndex] != firstLine);
        }
        return string.Join("\n", lines);
    }

    static string ApplySingleLine(string text, bool greeting, bool signOff, bool afterGreeting = false)
    {
        // The greeting has no length guard (the live path decides it as words
        // arrive); the sign-off is only decided at release and keeps one.
        var (clauses, forced) = Split(text, greeting, signOff && Chars.Count(text) > 40, afterGreeting);
        if (clauses.Count < 2 || forced.Count == 0) return text;
        if (Chars.StripWhitespace(text) != Chars.StripWhitespace(string.Join(" ", clauses))) return text;
        return Assemble(text, clauses, forced);
    }

    public static (List<string> Clauses, HashSet<int> ForcedBreaks) Split(string text, bool greeting = true, bool signOff = true, bool afterGreeting = false)
    {
        var clauses = SentenceSplitter.Split(text).Select(Chars.Trim).Where(s => s.Length > 0).ToList();
        var forced = new HashSet<int>();
        if (clauses.Count == 0) return (clauses, forced);

        if (greeting && clauses.Count > 1 && BareGreetingPattern.IsMatch(clauses[0]))
        {
            forced.Add(1);
        }
        else if (greeting && FirstMatch(GreetingPattern, clauses[0]) is { } match && match.End < clauses[0].Length)
        {
            var first = clauses[0];
            var greetingText = first[..match.End];
            var rest = Chars.TrimSpaces(first[match.End..]);
            if (rest.Length == 0 || GreetingNamePattern.IsMatch(rest))
            {
                // "Good afternoon, Mr. Joseph." is all greeting.
                if (clauses.Count > 1) forced.Add(1);
            }
            else
            {
                clauses.RemoveAt(0);
                clauses.InsertRange(0, new[] { greetingText, rest });
                forced.Add(1);
            }
        }

        bool isEmail = afterGreeting || forced.Contains(1);
        if (signOff && clauses.Count > 1)
        {
            var last = clauses[^1];
            var found = FirstMatch(SignOffPattern, last) ?? (isEmail ? FirstMatch(BareSignOffPattern, last) : null);
            if (found is { } signOffMatch)
            {
                if (signOffMatch.Start == 0)
                {
                    forced.Add(clauses.Count - 1);
                }
                else
                {
                    var head = Chars.TrimSpaces(last[..signOffMatch.Start]);
                    var tail = Chars.TrimSpaces(last[signOffMatch.Start..]);
                    if (head.Length > 0 && tail.Length > 0)
                    {
                        clauses.RemoveAt(clauses.Count - 1);
                        clauses.Add(head);
                        clauses.Add(tail);
                        forced.Add(clauses.Count - 1);
                    }
                }
            }
        }
        return (clauses, forced);
    }

    readonly record struct Span(int Start, int End);

    /// <summary>Group 1's range when the pattern has one, so a pattern can anchor on text it does not consume.</summary>
    static Span? FirstMatch(Regex regex, string text)
    {
        var match = regex.Match(text);
        if (!match.Success) return null;
        var group = match.Groups.Count > 1 && match.Groups[1].Success ? match.Groups[1] : (Group)match;
        return new Span(group.Index, group.Index + group.Length);
    }

    static string Assemble(string text, List<string> clauses, HashSet<int> breaks)
    {
        var sb = new StringBuilder(Chars.LeadingWhitespace(text));
        for (int index = 0; index < clauses.Count; index++)
        {
            if (index > 0) sb.Append(breaks.Contains(index) ? "\n\n" : " ");
            sb.Append(clauses[index]);
        }
        return sb.Append(Chars.TrailingWhitespace(text)).ToString();
    }
}
