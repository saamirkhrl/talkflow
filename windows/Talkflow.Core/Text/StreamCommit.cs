using System.Text;

namespace Talkflow.Core.Text;

/// <summary>
/// Decides how much of a still-changing transcript is safe to put on screen
/// (StreamCommit.swift, LocalAgreement-2): a word is committed once two
/// consecutive transcripts agree on it, and once committed it is never taken
/// back, so a live update can only append.
/// </summary>
public sealed class StreamCommit
{
    public readonly record struct Token(string Leading, string Word);

    /// <summary>Exactly what has been handed to the screen. Only ever grows, at the end.</summary>
    public string Committed { get; private set; } = "";

    List<Token> _previous = new();
    int _committedWords;

    public void Reset()
    {
        Committed = "";
        _previous = new List<Token>();
        _committedWords = 0;
    }

    /// <summary>
    /// Feeds one transcript of the whole buffer. Returns the full text that
    /// should now be on screen, or null when nothing new is stable enough.
    /// </summary>
    public string? Advance(string hypothesis)
    {
        var current = Tokenize(hypothesis);
        try
        {
            if (current.Count == 0) return null;

            int agreed = 0;
            while (agreed < current.Count && agreed < _previous.Count && current[agreed] == _previous[agreed]) agreed++;

            // The last agreed word is held back until another word sits behind it.
            int stable = Math.Min(agreed, current.Count - 1);
            if (stable <= _committedWords) return null;

            var sb = new StringBuilder(Committed);
            for (int i = _committedWords; i < stable; i++) sb.Append(current[i].Leading).Append(current[i].Word);
            Committed = sb.ToString();
            _committedWords = stable;
            return Committed;
        }
        finally
        {
            _previous = current;
        }
    }

    /// <summary>Words and the whitespace before each; whitespace after the last word is dropped.</summary>
    public static List<Token> Tokenize(string text)
    {
        var tokens = new List<Token>();
        var leading = new StringBuilder();
        var word = new StringBuilder();
        foreach (var character in Chars.Graphemes(text))
        {
            if (Chars.IsWhitespace(character))
            {
                if (word.Length > 0)
                {
                    tokens.Add(new Token(leading.ToString(), word.ToString()));
                    word.Clear();
                    leading.Clear();
                }
                leading.Append(character);
            }
            else
            {
                word.Append(character);
            }
        }
        if (word.Length > 0) tokens.Add(new Token(leading.ToString(), word.ToString()));
        return tokens;
    }
}
