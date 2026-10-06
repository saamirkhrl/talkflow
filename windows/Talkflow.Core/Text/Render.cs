namespace Talkflow.Core.Text;

/// <summary>
/// Transcript to what goes on screen, and the pure rules around delivering it
/// (the static half of Dictation.swift). The live caption and the final pass
/// run the identical function.
/// </summary>
public static class Render
{
    /// <summary>
    /// <paramref name="structure"/> is off for live updates (greeting break
    /// only); <paramref name="corrections"/> defaults to the same and collapses
    /// spoken self-corrections.
    /// </summary>
    public static string Text(string transcript, string leadingSpace, bool structure, bool? corrections = null, WritingStyle style = WritingStyle.Formal)
    {
        var tidied = Cleanup.Tidy(transcript);
        var commanded = TextCommands.ApplyAll(tidied);
        var withCommands = (corrections ?? structure) ? SelfCorrection.Apply(commanded) : commanded;
        // Release: sign-off, then lists, so the list pass sees the greeting
        // and sign-off as their own paragraphs.
        var structured = structure
            ? ListFormat.Apply(StructurePolish.PunctuateSignOff(StructurePolish.Apply(withCommands)))
            : StructurePolish.Apply(withCommands, signOff: false);
        // Capitalisation runs last, once the paragraph breaks are in the string.
        var cased = style.Apply(TextCommands.CapitalizeAfterSentenceEnds(structured));
        return cased.Length == 0 ? "" : leadingSpace + cased;
    }

    /// <summary>The caption's solid and dimmed halves. A revised word is never shown as settled.</summary>
    public static (string Settled, string Pending) CaptionParts(string committed, string rendered)
    {
        var trimmed = rendered.TrimStart();
        var settled = committed.TrimStart();
        if (!trimmed.StartsWith(settled, StringComparison.Ordinal)) return ("", trimmed);
        return (settled, trimmed[settled.Length..]);
    }

    /// <summary>How many key events a destructive keystroke rewrite may cost before it is refused.</summary>
    public const int CorrectionEventBudget = 160;

    /// <summary>One event per deleted character, one per chunk of the replacement.</summary>
    public static int EventCost(int deleting, string inserting) => deleting + FieldEdit.Chunked(inserting).Count;

    /// <summary>Windows writes only by keystrokes, so every correction is held to the budget.</summary>
    public static bool CorrectionIsAffordable(int deleting, string inserting) =>
        EventCost(deleting, inserting) <= CorrectionEventBudget;

    /// <summary>
    /// Which text the correction half of the release pass should write, if
    /// any: the corrected render when it is affordable, else the uncorrected
    /// one, else nothing (the words on screen stay).
    /// </summary>
    public static (string? Target, string? Note) CorrectionTarget(string screen, string corrected, string verbatim)
    {
        if (screen == corrected) return (null, null);
        var full = FieldEdit.Edit(screen, corrected);
        if (CorrectionIsAffordable(full.Deleting, full.Inserting)) return (corrected, null);

        var fullCost = $"-{full.Deleting} +{Chars.Count(full.Inserting)} = {EventCost(full.Deleting, full.Inserting)} keystroke events";
        if (corrected == verbatim)
            return (null, $"refused the correction pass, {fullCost} is more than can be delivered reliably; the dictation stays as it was spoken");
        if (screen == verbatim)
            return (null, $"skipped a self-correction, {fullCost} is more than can be delivered reliably; the false start stays");
        var rest = FieldEdit.Edit(screen, verbatim);
        if (CorrectionIsAffordable(rest.Deleting, rest.Inserting))
            return (verbatim, $"skipped a self-correction, {fullCost} is more than can be delivered reliably; applied the rest of the release pass");
        return (null, $"refused the correction pass including a self-correction, {fullCost} is more than can be delivered reliably; the dictation stays as it was spoken");
    }

    /// <summary>Size and structure of a transcript, with none of its content, for the log.</summary>
    public static string Shape(string text, int segments = 1)
    {
        int words = text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
        return $"{Chars.Count(text)} chars / {words} words" + (segments > 1 ? $" / {segments} segments" : "");
    }
}
