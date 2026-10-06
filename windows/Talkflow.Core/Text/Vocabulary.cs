namespace Talkflow.Core.Text;

/// <summary>
/// Learns the words whisper gets wrong from the fixes the user makes by hand
/// (Vocabulary.swift). A word counts as a fix only when it sits where a
/// dictated word was, between the same two neighbours, and the dictated word
/// was not a real word.
/// </summary>
public static class Vocabulary
{
    public const int Limit = 50;

    public static List<string> Fixes(string inserted, string fieldText, Func<string, bool> isKnown)
    {
        var typed = SelfCorrection.Tokenize(inserted);
        var now = SelfCorrection.Tokenize(fieldText);
        var nowWords = now.Select(t => t.Norm).ToHashSet();
        var found = new List<string>();
        if (typed.Count < 3 || now.Count < 3) return found;

        for (int i = 1; i < typed.Count - 1; i++)
        {
            if (nowWords.Contains(typed[i].Norm)) continue;
            var before = typed[i - 1].Norm;
            var after = typed[i + 1].Norm;
            for (int k = 1; k < now.Count - 1; k++)
            {
                if (now[k - 1].Norm != before || now[k + 1].Norm != after) continue;
                var candidate = Chars.TrimPunctuation(now[k].Word);
                var old = typed[i].Norm;
                var @new = Chars.Lower(candidate);
                var candidateChars = Chars.Graphemes(candidate);
                // Plausibly the same word: same first letter or under half its letters changed.
                if (candidateChars.Count < 3 || @new == old) continue;
                if (!candidateChars.All(c => Chars.IsLetter(c) || Chars.IsNumber(c) || c is "'" or "-")) continue;
                if (isKnown(Chars.TrimPunctuation(typed[i].Word))) continue;
                var oldFirst = Chars.First(old);
                var newFirst = Chars.First(@new);
                if (!(oldFirst == newFirst || Distance(old, @new) <= Math.Max(Chars.Count(old), Chars.Count(@new)) / 2)) continue;
                if (!found.Contains(candidate)) found.Add(candidate);
            }
        }
        return found;
    }

    /// <summary>Adds <paramref name="words"/> to the learned list, newest first, without duplicates.</summary>
    public static List<string> Remember(IReadOnlyList<string> learned, IReadOnlyList<string> words)
    {
        if (words.Count == 0) return learned.ToList();
        var list = learned.Where(old => !words.Any(w => string.Equals(w, old, StringComparison.OrdinalIgnoreCase))).ToList();
        list.InsertRange(0, words);
        return list.Take(Limit).ToList();
    }

    /// <summary>Levenshtein distance over Characters.</summary>
    public static int Distance(string first, string second)
    {
        var a = Chars.Graphemes(first);
        var b = Chars.Graphemes(second);
        if (a.Count == 0) return b.Count;
        if (b.Count == 0) return a.Count;
        var row = Enumerable.Range(0, b.Count + 1).ToArray();
        for (int i = 1; i <= a.Count; i++)
        {
            int previous = row[0];
            row[0] = i;
            for (int j = 1; j <= b.Count; j++)
            {
                int current = row[j];
                row[j] = a[i - 1] == b[j - 1] ? previous : Math.Min(previous, Math.Min(row[j], row[j - 1])) + 1;
                previous = current;
            }
        }
        return row[b.Count];
    }
}
