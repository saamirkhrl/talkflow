using System.Text;

namespace Talkflow.Core.Text;

/// <summary>The pure parts of Transcriber.swift: placeholder segments, segment joining, the whisper prompt.</summary>
public static class Transcript
{
    static readonly HashSet<string> Placeholders = new()
    {
        "[blank_audio]", "[silence]", "[typing]", "[music]", "[music playing]",
        "(soft music)", "(silence)", "[no speech]", "[inaudible]", "[applause]",
        "(upbeat music)", "[sound]", "(music)",
    };

    /// <summary>Whisper's bracketed narration of the audio, never a transcript.</summary>
    public static bool IsPlaceholder(string text)
    {
        var trimmed = Chars.Lower(Chars.Trim(text));
        if (trimmed.Length == 0) return true;
        if (Placeholders.Contains(trimmed)) return true;
        return (trimmed.StartsWith('[') && trimmed.EndsWith(']')) || (trimmed.StartsWith('(') && trimmed.EndsWith(')'));
    }

    /// <summary>
    /// Whisper-server returns one segment per line. Placeholder segments are
    /// dropped whole and the rest joined with a space; a period whisper put at
    /// a mid-sentence window cut is dropped when the next segment opens lowercase.
    /// </summary>
    public static string JoinSegments(string text)
    {
        var kept = text.Replace("\r\n", "\n").Split('\n')
            .Select(Chars.TrimSpaces)
            .Where(s => !IsPlaceholder(s));
        var joined = new StringBuilder();
        foreach (var segment in kept)
        {
            if (joined.Length > 0)
            {
                var first = Chars.First(segment);
                if (first is not null && Chars.IsLowercase(first) && ClosesWithCutPeriod(joined.ToString())) joined.Length -= 1;
                joined.Append(' ');
            }
            joined.Append(segment);
        }
        return joined.ToString();
    }

    static readonly HashSet<string> Abbreviations = new() { "mr", "mrs", "ms", "dr", "prof", "st", "vs", "etc", "e.g", "i.e", "jr", "sr" };

    static bool ClosesWithCutPeriod(string text)
    {
        if (!text.EndsWith('.') || text.EndsWith("..", StringComparison.Ordinal)) return false;
        var words = Chars.Words(text[..^1]);
        var lastWord = words.Length > 0 ? Chars.Lower(words[^1]) : "";
        return lastWord.Length > 0 && !Abbreviations.Contains(lastWord);
    }

    /// <summary>"Samir Kharel" -> "I'm Samir, and I use talkflow, a dictation app."</summary>
    public static string Prompt(string fullName)
    {
        var words = Chars.Words(fullName);
        var first = words.Length > 0 ? words[0] : "";
        var graphemes = Chars.Graphemes(first);
        if (graphemes.Count == 0 || !Chars.IsLetter(graphemes[0])
            || !graphemes.All(c => Chars.IsLetter(c) || c is "'" or "-"))
            return "I use talkflow, a dictation app.";
        return $"I'm {Chars.Upper(graphemes[0]) + string.Concat(graphemes.Skip(1))}, and I use talkflow, a dictation app.";
    }

    /// <summary>The multipart body whisper-server's /inference expects.</summary>
    public static byte[] MultipartBody(byte[] wav, string boundary, string prompt)
    {
        using var body = new MemoryStream();
        void Append(string s)
        {
            var bytes = Encoding.UTF8.GetBytes(s);
            body.Write(bytes, 0, bytes.Length);
        }
        Append($"--{boundary}\r\n");
        Append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n");
        Append("Content-Type: audio/wav\r\n\r\n");
        body.Write(wav, 0, wav.Length);
        Append($"\r\n--{boundary}\r\n");
        Append("Content-Disposition: form-data; name=\"response_format\"\r\n\r\ntext\r\n");
        if (prompt.Length > 0)
        {
            Append($"--{boundary}\r\n");
            Append($"Content-Disposition: form-data; name=\"prompt\"\r\n\r\n{prompt}\r\n");
        }
        Append($"--{boundary}--\r\n");
        return body.ToArray();
    }
}
