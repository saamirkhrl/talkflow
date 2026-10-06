using System.Text;

namespace Talkflow.Core.Text;

/// <summary>
/// The pure halves of FieldSync.swift and LiveType.swift: what edit brings a
/// field from one string to another, the append that deletes nothing, and how
/// text is cut into key events.
/// </summary>
public static class FieldEdit
{
    /// <summary>How many Characters come off the end of <paramref name="current"/>, and what goes on.</summary>
    public static (int Deleting, string Inserting) Edit(string current, string desired)
    {
        var old = Chars.Graphemes(current);
        var @new = Chars.Graphemes(desired);
        int shared = 0;
        while (shared < old.Count && shared < @new.Count && old[shared] == @new[shared]) shared++;
        return (old.Count - shared, string.Concat(@new.Skip(shared)));
    }

    /// <summary>
    /// <paramref name="current"/> plus the words of <paramref name="final"/> that
    /// were never on screen; word-aligned because the live path commits whole
    /// words. Null when there is nothing to add.
    /// </summary>
    public static string? AppendOnlyTarget(string current, string final)
    {
        int onScreen = StreamCommit.Tokenize(current).Count;
        var tokens = StreamCommit.Tokenize(final);
        if (tokens.Count <= onScreen) return null;
        var tail = string.Concat(tokens.Skip(onScreen).Select(t => t.Leading + t.Word));
        return tail.Length == 0 ? null : current + tail;
    }

    /// <summary>
    /// A single synthetic key event only carries a short unicode payload
    /// reliably, so inserts go out in chunks of at most this many UTF-16 units.
    /// </summary>
    public const int MaxUnitsPerEvent = 16;

    /// <summary>
    /// Splits into events, never mid-character, and gives every newline its
    /// own event (it is sent as Shift+Enter, never mixed with other text).
    /// </summary>
    public static List<string> Chunked(string text)
    {
        var chunks = new List<string>();
        var current = new StringBuilder();
        int units = 0;

        void Flush()
        {
            if (current.Length > 0) chunks.Add(current.ToString());
            current.Clear();
            units = 0;
        }

        foreach (var character in Chars.Graphemes(text))
        {
            if (Chars.IsNewline(character))
            {
                Flush();
                chunks.Add(character);
                continue;
            }
            if (units + character.Length > MaxUnitsPerEvent) Flush();
            current.Append(character);
            units += character.Length;
        }
        Flush();
        return chunks;
    }
}
