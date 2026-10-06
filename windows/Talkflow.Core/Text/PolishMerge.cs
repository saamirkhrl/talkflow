using System.Text;

namespace Talkflow.Core.Text;

/// <summary>
/// The guard on the optional AI punctuation pass (Polish.merge in Polish.swift):
/// the model's answer is aligned word by word with the original, and only the
/// punctuation, capitalisation and line breaks around words both agree on are
/// taken. The words of the output are exactly the words of the input.
/// </summary>
public static class PolishMerge
{
    public const string Instructions =
        "You fix punctuation, capitalization and line breaks in dictated text. " +
        "Never add, remove, reorder or change any word. You may add commas, periods, " +
        "colons, question marks and line breaks. Reply with the corrected text only.";

    public static string Merge(string original, string suggestion, IReadOnlyCollection<string>? names = null)
    {
        names ??= Array.Empty<string>();
        var old = SelfCorrection.Tokenize(original);
        var @new = SelfCorrection.Tokenize(suggestion);
        if (old.Count == 0 || @new.Count == 0) return original;
        var a = old.Select(t => t.Norm).ToArray();
        var b = @new.Select(t => t.Norm).ToArray();

        // Longest common subsequence of the normalised words.
        var lcs = new int[a.Length + 1, b.Length + 1];
        for (int i = a.Length - 1; i >= 0; i--)
            for (int j = b.Length - 1; j >= 0; j--)
                lcs[i, j] = a[i] == b[j] ? lcs[i + 1, j + 1] + 1 : Math.Max(lcs[i + 1, j], lcs[i, j + 1]);
        var pairs = new Dictionary<int, int>();
        {
            int i = 0, j = 0;
            while (i < a.Length && j < b.Length)
            {
                if (a[i] == b[j]) { pairs[i] = j; i++; j++; }
                else if (lcs[i + 1, j] >= lcs[i, j + 1]) i++;
                else j++;
            }
        }

        var output = new StringBuilder();
        for (int index = 0; index < old.Count; index++)
        {
            var token = old[index];
            if (!pairs.TryGetValue(index, out var match) || a[index].Length == 0)
            {
                output.Append(token.Leading).Append(token.Word);
                continue;
            }
            var suggested = @new[match];
            var word = suggested.Word;
            var mine = Chars.Graphemes(token.Word);
            var theirs = Chars.Graphemes(word);
            var myFirst = mine.FirstOrDefault(Chars.IsLetter);
            var theirFirst = theirs.FirstOrDefault(Chars.IsLetter);
            if (myFirst is not null && Chars.IsUppercase(myFirst) && theirFirst is not null && Chars.IsLowercase(theirFirst)
                && KeepsCapital(token.Norm, names))
            {
                var prefix = string.Concat(mine.TakeWhile(g => !Chars.IsLetter(g)));
                var rest = string.Concat(theirs.SkipWhile(g => !Chars.IsLetter(g)).Skip(1));
                word = prefix + myFirst + rest;
            }
            // Spacing is the original's, except a line break the model added
            // between two words that both kept their place.
            var leading = token.Leading;
            if (index > 0 && suggested.Leading.Contains('\n') && pairs.ContainsKey(index - 1)
                && suggested.Leading.All(c => c is '\n' or ' '))
            {
                leading = suggested.Leading.Contains("\n\n", StringComparison.Ordinal) ? "\n\n" : "\n";
            }
            output.Append(leading).Append(word);
        }
        return output.Append(Chars.TrailingWhitespace(original)).ToString();
    }

    static bool KeepsCapital(string norm, IReadOnlyCollection<string> names)
    {
        if (norm == "i" || norm.StartsWith("i'", StringComparison.Ordinal)) return true;
        if (names.Any(n => Chars.Lower(n) == norm)) return true;
        return ScreenText.IsName(Chars.CapitalizeFirst(norm));
    }
}
