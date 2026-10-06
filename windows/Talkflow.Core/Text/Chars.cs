using System.Globalization;
using System.Text;

namespace Talkflow.Core.Text;

/// <summary>
/// Swift's String works in Characters (grapheme clusters) and C# in UTF-16
/// units. The rules were written against Characters, so everything that counts,
/// drops or tests "a character" goes through here to behave the same way: an
/// emoji with a variation selector is one Character, not two chars.
/// </summary>
public static class Chars
{
    /// <summary>The text split into grapheme clusters, Swift's Characters.</summary>
    public static List<string> Graphemes(string text)
    {
        var list = new List<string>();
        var e = StringInfo.GetTextElementEnumerator(text);
        while (e.MoveNext()) list.Add((string)e.Current);
        return list;
    }

    public static int Count(string text) => new StringInfo(text).LengthInTextElements;

    /// <summary>Character.isWhitespace, for one grapheme.</summary>
    public static bool IsWhitespace(string g) => g.Length > 0 && char.IsWhiteSpace(g, 0);

    /// <summary>Character.isNewline.</summary>
    public static bool IsNewline(string g) => g is "\n" or "\r" or "\r\n" or "\u000B" or "\u000C" or "\u0085" or "\u2028" or "\u2029";

    public static bool IsLetter(string g) => g.Length > 0 && char.IsLetter(g, 0);

    public static bool IsNumber(string g) => g.Length > 0 && char.IsNumber(g, 0);

    /// <summary>Character.isUppercase: has an uppercase mapping that differs, i.e. is cased upper.</summary>
    public static bool IsUppercase(string g) => g.Length > 0 && char.IsUpper(g, 0);

    public static bool IsLowercase(string g) => g.Length > 0 && char.IsLower(g, 0);

    /// <summary>String.uppercased() / lowercased(), locale independent like Swift's.</summary>
    public static string Upper(string s) => s.ToUpperInvariant();

    public static string Lower(string s) => s.ToLowerInvariant();

    /// <summary><c>text.prefix(1).uppercased() + text.dropFirst()</c>.</summary>
    public static string CapitalizeFirst(string text)
    {
        if (text.Length == 0) return text;
        int first = StringInfo.GetNextTextElementLength(text);
        return Upper(text[..first]) + text[first..];
    }

    /// <summary>Drops the last Character (Swift's removeLast / dropLast()).</summary>
    public static string DropLast(string text, int count = 1)
    {
        if (count <= 0) return text;
        var g = Graphemes(text);
        if (count >= g.Count) return "";
        return string.Concat(g.Take(g.Count - count));
    }

    public static string? Last(string text)
    {
        if (text.Length == 0) return null;
        var g = Graphemes(text);
        return g[^1];
    }

    public static string? First(string text)
    {
        if (text.Length == 0) return null;
        return text[..StringInfo.GetNextTextElementLength(text)];
    }

    /// <summary>CharacterSet.whitespacesAndNewlines membership, for one UTF-16 unit.</summary>
    public static bool IsWhitespaceOrNewline(char c) => char.IsWhiteSpace(c);

    /// <summary>CharacterSet.whitespaces: horizontal whitespace only (Zs and tab).</summary>
    public static bool IsHorizontalWhitespace(char c) =>
        c == '\t' || CharUnicodeInfo.GetUnicodeCategory(c) == UnicodeCategory.SpaceSeparator;

    /// <summary><c>trimmingCharacters(in: .whitespacesAndNewlines)</c>.</summary>
    public static string Trim(string s) => s.Trim();

    /// <summary><c>trimmingCharacters(in: .whitespaces)</c>: leaves newlines.</summary>
    public static string TrimSpaces(string s)
    {
        int start = 0, end = s.Length;
        while (start < end && IsHorizontalWhitespace(s[start])) start++;
        while (end > start && IsHorizontalWhitespace(s[end - 1])) end--;
        return s[start..end];
    }

    /// <summary><c>trimmingCharacters(in: .punctuationCharacters)</c> (general category P*).</summary>
    public static string TrimPunctuation(string s) => TrimWhere(s, char.IsPunctuation);

    public static string TrimWhere(string s, Func<char, bool> predicate)
    {
        int start = 0, end = s.Length;
        while (start < end && predicate(s[start])) start++;
        while (end > start && predicate(s[end - 1])) end--;
        return s[start..end];
    }

    /// <summary>Whitespace after the last non-whitespace Character.</summary>
    public static string TrailingWhitespace(string text)
    {
        var g = Graphemes(text);
        int i = g.Count;
        while (i > 0 && IsWhitespace(g[i - 1])) i--;
        return string.Concat(g.Skip(i));
    }

    /// <summary>Whitespace before the first non-whitespace Character.</summary>
    public static string LeadingWhitespace(string text)
    {
        var g = Graphemes(text);
        int i = 0;
        while (i < g.Count && IsWhitespace(g[i])) i++;
        return string.Concat(g.Take(i));
    }

    /// <summary><c>split(separator: " ")</c>: empty pieces omitted.</summary>
    public static string[] Words(string text) => text.Split(' ', StringSplitOptions.RemoveEmptyEntries);

    /// <summary>Removes every whitespace or newline scalar.</summary>
    public static string StripWhitespace(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (char c in s) if (!char.IsWhiteSpace(c)) sb.Append(c);
        return sb.ToString();
    }
}
