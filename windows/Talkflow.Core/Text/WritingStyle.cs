using System.Text.RegularExpressions;

namespace Talkflow.Core.Text;

/// <summary>How dictated text is written (WritingStyle.swift). Only letter case and the closing full stop change.</summary>
public enum WritingStyle
{
    /// <summary>Capitals and full stops.</summary>
    Formal,
    /// <summary>Lowercase, no closing full stop, "I" kept.</summary>
    Casual,
    /// <summary>Every letter lowercase.</summary>
    Lowercase,
}

public static class WritingStyles
{
    public static readonly WritingStyle[] All = { WritingStyle.Formal, WritingStyle.Casual, WritingStyle.Lowercase };

    /// <summary>The value stored in settings.json, shared with the Mac app.</summary>
    public static string RawValue(this WritingStyle style) => style switch
    {
        WritingStyle.Casual => "casual",
        WritingStyle.Lowercase => "lowercase",
        _ => "formal",
    };

    public static WritingStyle Parse(string? raw) => raw switch
    {
        "casual" => WritingStyle.Casual,
        "lowercase" => WritingStyle.Lowercase,
        _ => WritingStyle.Formal,
    };

    public static string Title(this WritingStyle style) => style switch
    {
        WritingStyle.Casual => "Casual",
        WritingStyle.Lowercase => "all lowercase",
        _ => "Formal",
    };

    public static string Detail(this WritingStyle style) => style switch
    {
        WritingStyle.Casual => "lowercase, no final full stop.",
        WritingStyle.Lowercase => "all lowercase.",
        _ => "Capitals and full stops.",
    };

    static readonly Regex LoneI = new(@"(?<![\p{L}\p{N}])i(?=$|[^\p{L}\p{N}]|'[a-z])", RegexOptions.CultureInvariant);

    public static string Apply(this WritingStyle style, string text)
    {
        switch (style)
        {
            case WritingStyle.Lowercase:
                return Chars.Lower(text);
            case WritingStyle.Casual:
                var output = Chars.Lower(text);
                // "I", "I'm", "I'll": a lowercase "i" alone reads as a typo.
                output = LoneI.Replace(output, "I");
                // The closing full stop, unless it ends an ellipsis.
                var trailing = Chars.TrailingWhitespace(output);
                var body = output[..^trailing.Length];
                if (body.EndsWith('.') && !body.EndsWith("..", StringComparison.Ordinal))
                    output = body[..^1] + trailing;
                return output;
            default:
                return text;
        }
    }
}
