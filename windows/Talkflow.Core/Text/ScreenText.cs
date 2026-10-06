namespace Talkflow.Core.Text;

/// <summary>
/// The pure rules of ScreenContext.swift: the whisper prompt with names and
/// learned words, whether a dictation continues a sentence, lowercasing its
/// first word when it does, and chat styling.
/// </summary>
public static class ScreenText
{
    /// <summary>
    /// Whether a capitalised word is a name. The Mac asks Apple's NLTagger,
    /// which Windows does not have; the default here keeps the capital on
    /// anything that is not an everyday English word, and the app adds the
    /// Windows spell checker on top (a word it only accepts capitalised is a name).
    /// </summary>
    public static Func<string, bool> IsName { get; set; } = word => !CommonWords.Contains(Chars.Lower(word));

    /// <summary>The fixed vocabulary sentence plus names on screen and learned words.</summary>
    public static string Prompt(string vocabularyPrompt, IEnumerable<string> names, IEnumerable<string> learned)
    {
        var words = new List<string>();
        foreach (var word in names.Concat(learned))
            if (!words.Any(w => string.Equals(w, word, StringComparison.OrdinalIgnoreCase))) words.Add(word);
        var kept = words.Take(25).ToList();
        if (kept.Count == 0) return vocabularyPrompt;
        return vocabularyPrompt + " Names and words here: " + string.Join(", ", kept) + ".";
    }

    /// <summary>Something is before the caret on the same line and it does not end a sentence.</summary>
    public static bool ContinuesSentence(string? before)
    {
        if (before is null) return false;
        var line = before.Split('\n')[^1];
        var last = Chars.Graphemes(line).LastOrDefault(g => !Chars.IsWhitespace(g));
        if (last is null) return false;
        return !(last is "." or "!" or "?" or ":" or ";") && !Chars.IsNewline(last);
    }

    /// <summary>
    /// Lowercases the dictation's first word when it continues a sentence,
    /// unless it is "I", an acronym or a name.
    /// </summary>
    public static string LowercasingStart(string text, IReadOnlyCollection<string> names)
    {
        var all = Chars.Graphemes(text);
        int bodyStart = 0;
        while (bodyStart < all.Count && Chars.IsWhitespace(all[bodyStart])) bodyStart++;
        var body = all.Skip(bodyStart).ToList();
        var firstWord = string.Concat(body.TakeWhile(g => !Chars.IsWhitespace(g)));
        var bare = Chars.TrimPunctuation(firstWord);
        var first = Chars.First(bare);
        if (first is null || !Chars.IsUppercase(first)) return text;
        if (bare == "I" || bare.StartsWith("I'", StringComparison.Ordinal)) return text;
        var bareChars = Chars.Graphemes(bare);
        if (bareChars.Count > 1 && bareChars.All(c => Chars.IsUppercase(c) || !Chars.IsLetter(c))) return text; // "NASA", "OK"
        if (names.Any(n => Chars.Words(n).Contains(bare))) return text;
        if (IsName(bare)) return text;
        var leading = string.Concat(all.Take(bodyStart));
        return leading + Chars.Lower(first) + string.Concat(body.Skip(1));
    }

    /// <summary>
    /// Chat apps, by process name. A one-line message there conventionally has
    /// no final period.
    /// </summary>
    static readonly HashSet<string> ChatProcesses = new(StringComparer.OrdinalIgnoreCase)
    {
        "slack", "discord", "whatsapp", "whatsapp.root", "telegram", "signal", "ms-teams", "teams", "messenger",
    };

    public static bool IsChat(string? processName) => processName is not null && ChatProcesses.Contains(processName);

    /// <summary>A single-sentence chat message loses its final period. Not "?", "!" or "...".</summary>
    public static string ChatStyled(string text)
    {
        if (!text.EndsWith('.') || text.EndsWith("..", StringComparison.Ordinal) || text.Contains('\n')) return text;
        var body = text[..^1];
        if (body.IndexOfAny(new[] { '.', '!', '?' }) >= 0) return text;
        return body;
    }
}
