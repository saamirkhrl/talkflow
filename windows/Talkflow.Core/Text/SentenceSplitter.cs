namespace Talkflow.Core.Text;

/// <summary>
/// Sentence boundaries, standing in for Apple's NLTokenizer(unit: .sentence),
/// which StructurePolish.swift uses and Windows does not have. The rules were
/// read off NLTokenizer's own answers (windows/tests/golden records them) and
/// cover what dictation produces:
///
///  - a newline always ends a sentence;
///  - "?" or "!" ends one, before any next word;
///  - "." ends one only when whitespace and then a capital (or a quoted capital)
///    follow, so "3 p.m. where", "hi. 5 people" and "$3.50" stay whole;
///  - never after a title ("Mr.", "Mrs.", "Ms.", "Dr.", "Prof."), "vs." or a dotted
///    acronym ("U.K.", "e.g."), except "a.m." and "p.m.", which usually close a
///    sentence when a capital follows.
/// </summary>
public static class SentenceSplitter
{
    static readonly HashSet<string> Titles = new() { "mr.", "mrs.", "ms.", "dr.", "prof.", "vs." };
    const string Closers = "\"')]”’»";
    const string Openers = "\"“‘";

    /// <summary>The sentences, each with the whitespace that follows it, in order.</summary>
    public static List<string> Split(string text)
    {
        var sentences = new List<string>();
        int start = 0, n = text.Length, i = 0;

        void Cut(int end)
        {
            if (end > start) sentences.Add(text[start..end]);
            start = end;
        }

        while (i < n)
        {
            char c = text[i];
            if (c == '\n')
            {
                Cut(i + 1);
                i++;
                continue;
            }
            if (c is not ('.' or '!' or '?'))
            {
                i++;
                continue;
            }

            int j = i;
            while (j < n && text[j] is '.' or '!' or '?') j++;
            int k = j;
            while (k < n && Closers.Contains(text[k])) k++;
            bool strong = text.AsSpan(i, j - i).IndexOfAny('!', '?') >= 0;

            int m = k;
            while (m < n && text[m] != '\n' && char.IsWhiteSpace(text[m])) m++;

            if (strong)
            {
                Cut(m);
                i = m;
                continue;
            }

            if (m > k && m < n && text[m] != '\n' && StartsSentence(text, m) && !IsNonFinal(text, i, j))
            {
                Cut(m);
                i = m;
                continue;
            }
            i = j;
        }
        Cut(n);
        return sentences;
    }

    static bool StartsSentence(string text, int index)
    {
        char c = text[index];
        if (char.IsUpper(c)) return true;
        return Openers.Contains(c) && index + 1 < text.Length && char.IsUpper(text[index + 1]);
    }

    /// <summary>Whether the dots ending at <paramref name="end"/> close a title or an acronym.</summary>
    static bool IsNonFinal(string text, int dot, int end)
    {
        if (end - dot != 1) return false; // "..." is a real stop
        int start = dot;
        while (start > 0 && (char.IsLetter(text[start - 1]) || text[start - 1] == '.')) start--;
        var word = Chars.Lower(text[start..end]);
        if (Titles.Contains(word)) return true;
        if (word is "a.m." or "p.m.") return false;
        // Dotted acronym: two or more single letters, each followed by a dot.
        if (word.Length >= 4 && word.Length % 2 == 0)
        {
            for (int p = 0; p < word.Length; p += 2)
                if (!char.IsLetter(word[p]) || word[p + 1] != '.') return false;
            return true;
        }
        return false;
    }
}
