using System.Text;
using System.Text.RegularExpressions;

namespace Talkflow.Core.Text;

/// <summary>
/// Voice-command text transforms: spoken punctuation, emoji and paragraph
/// breaks (numbered lists live in <see cref="ListFormat"/>). A port of
/// TextCommands.swift; applied once to the complete transcript, before any of it
/// reaches the screen. The emoji tables are generated from the Swift source.
/// </summary>
public static partial class TextCommands
{
    /// <summary>
    /// Captures up to three words before "emoji" and resolves them in the
    /// tables rather than baking every phrase into the pattern. The trailing
    /// <c>[,.!?]?</c> eats the punctuation whisper puts after the phrase.
    /// </summary>
    static readonly Regex EmojiPattern = new(
        @"\b((?:[\p{L}']+\s+){0,2}[\p{L}']+)\s+emojis?\b[,.!?]?\s*",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    /// <summary>Longest phrase first, so "red heart" wins over "heart".</summary>
    public static (string Symbol, int WordsUsed)? ResolveEmoji(string phrase)
    {
        var words = Chars.Words(Chars.Lower(phrase));
        if (words.Length == 0) return null;
        for (int take = Math.Min(3, words.Length); take >= 1; take--)
        {
            var candidate = string.Join(" ", words.Skip(words.Length - take));
            if (LookupEmoji(candidate) is { } symbol) return (symbol, take);
        }
        return null;
    }

    static string? LookupEmoji(string name)
    {
        if (EmojiMap.TryGetValue(name, out var symbol)) return symbol;
        if (EmojiAliases.TryGetValue(name, out var aliased) && EmojiMap.TryGetValue(aliased, out symbol)) return symbol;
        // "cowboy face emoji": drop a trailing "face" and try the bare name.
        if (name.EndsWith(" face", StringComparison.Ordinal))
        {
            var bare = name[..^5];
            if (EmojiMap.TryGetValue(bare, out symbol)) return symbol;
            if (EmojiAliases.TryGetValue(bare, out aliased) && EmojiMap.TryGetValue(aliased, out symbol)) return symbol;
        }
        // Spoken plurals: "rockets emoji".
        if (name.EndsWith('s') && EmojiMap.TryGetValue(Chars.DropLast(name), out symbol)) return symbol;
        return null;
    }

    static readonly Regex NewParagraphPattern = new(
        @"\s*\bnew paragraph\b,?\s*", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

    public static string ApplyAll(string text)
    {
        var result = ApplySpokenPunctuation(text);
        result = ApplyEmoji(result);
        result = ApplyParagraphBreaks(result);
        return result;
    }

    /// <summary>
    /// Spoken punctuation. Whisper has usually punctuated the command word as
    /// speech too ("Dear Sarah, comma, can you"), so the punctuation on either
    /// side of it collapses into the one mark.
    /// </summary>
    static readonly Dictionary<string, string> SpokenPunctuation = new()
    {
        ["comma"] = ",", ["period"] = ".", ["full stop"] = ".", ["question mark"] = "?",
        ["exclamation mark"] = "!", ["exclamation point"] = "!", ["colon"] = ":",
        ["semicolon"] = ";", ["open paren"] = "(", ["close paren"] = ")",
        ["open parenthesis"] = "(", ["close parenthesis"] = ")",
        ["new line"] = "\n", ["newline"] = "\n", ["next line"] = "\n",
    };

    static readonly Regex SpokenPunctuationPattern = BuildSpokenPunctuationPattern();

    static Regex BuildSpokenPunctuationPattern()
    {
        var keys = SpokenPunctuation.Keys.OrderByDescending(k => k.Length).ThenBy(k => k, StringComparer.Ordinal);
        var alternation = string.Join("|", keys.Select(Regex.Escape));
        return new Regex(@"\s*[,.!?;:]*\s*\b(" + alternation + @")\b[,.!?;:]*\s*",
            RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    }

    public static string ApplySpokenPunctuation(string text)
    {
        var matches = SpokenPunctuationPattern.Matches(text);
        if (matches.Count == 0) return text;

        var result = new StringBuilder();
        int lastEnd = 0;
        foreach (Match match in matches)
        {
            result.Append(text, lastEnd, match.Index - lastEnd);
            var key = Chars.Lower(match.Groups[1].Value);
            var mark = SpokenPunctuation.GetValueOrDefault(key, "");
            lastEnd = match.Index + match.Length;

            // "new line" at the very start would only indent the insertion.
            if (Chars.Trim(result.ToString()).Length == 0 && mark == "\n") continue;
            result.Append(mark);
            if (lastEnd < text.Length && mark != "\n") result.Append(' ');
        }
        result.Append(text, lastEnd, text.Length - lastEnd);
        return result.ToString();
    }

    /// <summary>
    /// A spoken "period" ends a sentence and a spoken "new line" starts one,
    /// so the next word is capitalised. The first word is left alone, and a
    /// period only ends a sentence when whitespace follows and it does not
    /// close an abbreviation ("3 p.m. where").
    /// </summary>
    public static string CapitalizeAfterSentenceEnds(string text)
    {
        var characters = Chars.Graphemes(text);
        bool startOfSentence = false;
        bool afterMark = false;
        for (int index = 0; index < characters.Count; index++)
        {
            var character = characters[index];
            if (character == "\n")
            {
                startOfSentence = true;
                afterMark = false;
            }
            else if (afterMark)
            {
                afterMark = false;
                startOfSentence = Chars.IsWhitespace(character);
            }
            else if (startOfSentence && Chars.IsLetter(character))
            {
                characters[index] = Chars.Upper(character);
                startOfSentence = false;
            }
            else if (character is "." or "!" or "?")
            {
                afterMark = !(character == "." && EndsAbbreviation(characters, index));
                startOfSentence = false;
            }
            else if (!Chars.IsWhitespace(character))
            {
                startOfSentence = false;
            }
        }
        return string.Concat(characters);
    }

    static readonly HashSet<string> Abbreviations = new()
    {
        "a.m.", "p.m.", "e.g.", "i.e.", "etc.", "vs.", "approx.", "mr.", "mrs.", "ms.", "dr.", "prof.", "st.",
    };

    static bool EndsAbbreviation(List<string> characters, int index)
    {
        int start = index;
        while (start > 0 && (Chars.IsLetter(characters[start - 1]) || characters[start - 1] == ".")) start--;
        var word = string.Concat(characters.Skip(start).Take(index - start + 1));
        return Abbreviations.Contains(Chars.Lower(word));
    }

    public static string ApplyEmoji(string text)
    {
        var matches = EmojiPattern.Matches(text);
        if (matches.Count == 0) return text;

        var result = new StringBuilder();
        int lastEnd = 0;
        foreach (Match match in matches)
        {
            var phrase = match.Groups[1].Value;
            if (ResolveEmoji(phrase) is not { } hit) continue; // unknown name: leave the words alone

            result.Append(text, lastEnd, match.Index - lastEnd);

            // "send the water emoji" captures "send the water" but only
            // "water" names the symbol; the other words stay.
            var phraseWords = Chars.Words(phrase);
            var kept = phraseWords.Take(Math.Max(0, phraseWords.Length - hit.WordsUsed)).ToArray();
            if (kept.Length > 0) result.Append(string.Join(" ", kept)).Append(' ');

            result.Append(hit.Symbol);
            lastEnd = match.Index + match.Length;
            if (lastEnd < text.Length) result.Append(' ');
        }
        result.Append(text, lastEnd, text.Length - lastEnd);
        return result.ToString();
    }

    public static string ApplyParagraphBreaks(string text)
    {
        var matches = NewParagraphPattern.Matches(text);
        if (matches.Count == 0) return text;

        var result = new StringBuilder();
        int lastEnd = 0;
        foreach (Match match in matches)
        {
            result.Append(text, lastEnd, match.Index - lastEnd);
            if (Chars.Trim(result.ToString()).Length != 0) result.Append("\n\n");
            lastEnd = match.Index + match.Length;
        }
        result.Append(text, lastEnd, text.Length - lastEnd);
        return result.ToString();
    }
}
