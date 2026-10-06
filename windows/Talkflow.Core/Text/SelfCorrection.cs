using System.Text;

namespace Talkflow.Core.Text;

/// <summary>
/// Collapses spoken self-corrections, stutters and comma-set hedges into what
/// was meant (SelfCorrection.swift). It can only delete whole words, and the
/// result is checked mechanically (<see cref="IsDeletionOnly"/>) or the input
/// comes back untouched. When unsure, nothing happens.
/// </summary>
public static class SelfCorrection
{
    public struct Token
    {
        public string Leading;
        public string Word;

        public Token(string leading, string word)
        {
            Leading = leading;
            Word = word;
        }

        /// <summary>Lowercased, edge punctuation removed: "Friday," -> "friday".</summary>
        public readonly string Norm => Normalize(Word);

        public readonly char? TrailingPunctuation
        {
            get
            {
                var last = Chars.Last(Word);
                return last is { Length: 1 } && ",.!?;:".Contains(last[0]) ? last[0] : null;
            }
        }

        public readonly bool EndsSentence => TrailingPunctuation is '.' or '!' or '?';
        public readonly bool BreaksLine => Leading.Contains('\n');
    }

    public static string Apply(string text)
    {
        var tokens = Tokenize(text);
        // One edit per pass, re-scanned from the start, bounded in case two
        // rules ever disagree about a fixed point.
        for (int pass = 0; pass < 16; pass++)
        {
            var next = ScratchThat(tokens) ?? TypedRepair(tokens) ?? Restart(tokens) ?? Stutter(tokens) ?? Hedge(tokens);
            if (next is null) break;
            tokens = next;
        }
        var sb = new StringBuilder();
        foreach (var t in tokens) sb.Append(t.Leading).Append(t.Word);
        var result = sb.Append(Chars.TrailingWhitespace(text)).ToString();
        return IsDeletionOnly(text, result) ? result : text;
    }

    /// <summary><paramref name="result"/> may only be <paramref name="original"/> with whole words removed.</summary>
    public static bool IsDeletionOnly(string original, string result)
    {
        var source = Tokenize(original).Select(t => t.Norm).ToList();
        int index = 0;
        foreach (var word in Tokenize(result).Select(t => t.Norm))
        {
            int found = source.IndexOf(word, index);
            if (found < 0) return false;
            index = found + 1;
        }
        return true;
    }

    // MARK: - Markers

    sealed record Marker(string[] Words, bool Strong, bool NeedsClauseEnd)
    {
        public bool TrustsPlainWords => Strong || Words.SequenceEqual(new[] { "or", "rather" }) || Words.SequenceEqual(new[] { "correction" });
    }

    static readonly Marker[] FixedMarkers =
    {
        new(new[] { "or", "rather" }, false, false),
        new(new[] { "make", "that" }, false, false),
        new(new[] { "i", "mean" }, false, false),
        new(new[] { "correction" }, false, false),
        new(new[] { "rather" }, false, false),
    };

    static readonly HashSet<string> RunWords = new() { "oh", "wait", "no", "actually", "sorry" };

    static Marker? Run(int index, List<Token> tokens)
    {
        var words = new List<string>();
        int i = index;
        while (i < tokens.Count && words.Count < 3 && RunWords.Contains(tokens[i].Norm) && (i == index || !tokens[i].BreaksLine))
        {
            words.Add(tokens[i].Norm);
            i++;
        }
        // A lone "no" is an answer and a lone "oh" is an exclamation.
        if (words.Count == 0 || (words.Count == 1 && (words[0] == "no" || words[0] == "oh"))) return null;
        bool hasWait = words.Contains("wait");
        return new Marker(words.ToArray(), hasWait && words.Count >= 2, !hasWait && !words.Contains("no"));
    }

    static List<(Marker Marker, int End)> MarkersAt(int index, List<Token> tokens)
    {
        var found = new List<(Marker, int)>();
        if (index <= 0) return found; // nothing before it to replace
        var candidates = new List<Marker>(FixedMarkers);
        if (Run(index, tokens) is { } run) candidates.Add(run);
        foreach (var marker in candidates)
        {
            int end = index + marker.Words.Length;
            if (end >= tokens.Count) continue; // nothing after it either
            bool same = true;
            for (int k = 0; k < marker.Words.Length; k++)
                if (tokens[index + k].Norm != marker.Words[k]) { same = false; break; }
            if (!same) continue;
            bool brokenInside = false;
            for (int k = index + 1; k < end; k++) if (tokens[k].BreaksLine) brokenInside = true;
            if (brokenInside || tokens[end].BreaksLine) continue;
            if (!marker.Strong && tokens[index - 1].TrailingPunctuation is null && LeadIn(end, tokens) == 0) continue;
            found.Add((marker, end));
        }
        return found;
    }

    // MARK: - Rules

    const int MaxUnits = 6;

    enum Kind { Day, Month, Number, Name, Other }

    readonly record struct Unit(int Lower, int Upper, Kind Kind, string Norm);

    static List<Token>? TypedRepair(List<Token> tokens)
    {
        for (int m = 0; m < tokens.Count; m++)
        {
            foreach (var (marker, markerEnd) in MarkersAt(m, tokens))
            {
                int staticLead = LeadIn(markerEnd, tokens);
                bool setOff = marker.Strong || tokens[m - 1].TrailingPunctuation is not null;
                int[] leads = staticLead > 0 ? (setOff ? new[] { staticLead, 0 } : new[] { staticLead }) : new[] { 0 };
                foreach (int lead in leads)
                {
                    int after = markerEnd + lead;
                    if (after >= tokens.Count) continue;
                    var old = UnitsBackward(m, tokens);
                    var @new = UnitsForward(after, tokens);
                    for (int n = 1; n <= MaxUnits; n++)
                    {
                        if (n > old.Count || n > @new.Count) continue;
                        var olds = old.Take(n).Reverse().ToList();
                        var news = @new.Take(n).ToList();
                        if (!Aligns(olds, news, tokens, marker, lead)) continue;
                        return Delete(tokens, olds[0].Lower, after);
                    }
                }
            }
        }
        return null;
    }

    static List<Unit> UnitsBackward(int end, List<Token> tokens)
    {
        var units = new List<Unit>();
        int i = end - 1;
        while (i >= 0 && units.Count < MaxUnits)
        {
            if (units.Count > 0)
            {
                if (!(tokens[i].TrailingPunctuation is null || IsAbbreviation(tokens[i])) || tokens[i + 1].BreaksLine) break;
            }
            int start = i;
            if (KindOf(tokens, i) == Kind.Number)
            {
                while (start > 0 && i - start < 2 && KindOf(tokens, start - 1) == Kind.Number
                       && tokens[start - 1].TrailingPunctuation is null && !tokens[start].BreaksLine) start--;
            }
            units.Add(MakeUnit(start, i + 1, tokens));
            i = start - 1;
        }
        return units;
    }

    static List<Unit> UnitsForward(int start, List<Token> tokens)
    {
        var units = new List<Unit>();
        int i = start;
        while (i < tokens.Count && units.Count < MaxUnits)
        {
            if (i > start && tokens[i].BreaksLine) break;
            int end = i + 1;
            if (KindOf(tokens, i) == Kind.Number)
            {
                while (end < tokens.Count && end - i < 3 && tokens[end - 1].TrailingPunctuation is null
                       && KindOf(tokens, end) == Kind.Number && !tokens[end].BreaksLine) end++;
            }
            units.Add(MakeUnit(i, end, tokens));
            if (tokens[end - 1].TrailingPunctuation is { } p && (!IsAbbreviation(tokens[end - 1]) || p != '.')) break;
            i = end;
        }
        return units;
    }

    static Unit MakeUnit(int lower, int upper, List<Token> tokens)
    {
        var kind = upper - lower > 1 ? Kind.Number : KindOf(tokens, lower);
        var norm = string.Join(" ", tokens.Skip(lower).Take(upper - lower).Select(t => t.Norm));
        return new Unit(lower, upper, kind, norm);
    }

    /// <summary>"p.m." and "a.m." end in a full stop that ends nothing.</summary>
    static bool IsAbbreviation(Token token) => token.Norm is "p.m" or "a.m";

    static bool Aligns(List<Unit> old, List<Unit> @new, List<Token> tokens, Marker marker, int lead)
    {
        int changedValues = 0;
        var changedWords = new List<int>();
        bool changedName = false;
        for (int index = 0; index < Math.Min(old.Count, @new.Count); index++)
        {
            var o = old[index];
            var r = @new[index];
            if (o.Norm == r.Norm) continue;
            if (o.Kind != r.Kind) return false;
            if (o.Kind == Kind.Other)
            {
                if (StutterWords.Contains(o.Norm) || StutterWords.Contains(r.Norm)) return false;
                changedWords.Add(index);
            }
            else
            {
                changedValues++;
                if (o.Kind == Kind.Name) changedName = true;
            }
        }
        if (changedValues == 0)
        {
            // "There is no wait, fine" must not lose "is".
            if (!(changedWords.Count == 1 && lead == 0 && marker.TrustsPlainWords
                  && tokens[old[^1].Upper - 1].TrailingPunctuation is not null)) return false;
        }
        if (marker.NeedsClauseEnd || changedName || changedWords.Count > 0)
        {
            int end = @new[^1].Upper;
            if (!(end == tokens.Count || tokens[end - 1].TrailingPunctuation is not null)) return false;
        }
        return true;
    }

    static readonly string[][] LeadIns =
    {
        new[] { "let's", "make", "that" }, new[] { "let's", "make", "it" }, new[] { "make", "that" }, new[] { "make", "it" },
        new[] { "let's", "say" }, new[] { "let's", "do" }, new[] { "let's", "go", "with" }, new[] { "i", "meant", "to", "say" },
        new[] { "i", "mean", "to", "say" }, new[] { "i", "meant" }, new[] { "i", "mean" }, new[] { "i", "said" }, new[] { "it", "should", "be" },
        new[] { "it", "is" }, new[] { "it's" }, new[] { "how", "about" },
    };

    static int LeadIn(int index, List<Token> tokens)
    {
        foreach (var phrase in LeadIns)
        {
            if (index + phrase.Length >= tokens.Count) continue;
            bool ok = true;
            for (int k = 0; k < phrase.Length && ok; k++)
            {
                var t = tokens[index + k];
                if (t.Norm != phrase[k] || t.TrailingPunctuation is not null || t.BreaksLine) ok = false;
            }
            if (ok) return phrase.Length;
        }
        return 0;
    }

    /// <summary>"I went home, I mean I went to the office": the clause restarts.</summary>
    static List<Token>? Restart(List<Token> tokens)
    {
        for (int m = 0; m < tokens.Count; m++)
        {
            foreach (var (_, after) in MarkersAt(m, tokens))
            {
                if (after + 1 >= tokens.Count) continue;
                if (tokens[after + 1].BreaksLine) continue;
                var opening0 = tokens[after].Norm;
                var opening1 = tokens[after + 1].Norm;
                int start = Math.Max(ClauseStart(tokens, m - 1), m - 12);
                for (int p = m - 2; p >= start; p--)
                {
                    if (tokens[p].Norm == opening0 && tokens[p + 1].Norm == opening1 && tokens[p].TrailingPunctuation is null)
                        return Delete(tokens, p, after);
                }
            }
        }
        return null;
    }

    static readonly HashSet<string> RetractVerbs = new() { "scratch", "strike", "ignore", "disregard" };

    /// <summary>"..., scratch that, ..." drops the clause before it.</summary>
    static List<Token>? ScratchThat(List<Token> tokens)
    {
        for (int m = 1; m < tokens.Count; m++)
        {
            if (m + 2 >= tokens.Count) continue;
            if (!(RetractVerbs.Contains(tokens[m].Norm) && tokens[m + 1].Norm == "that"
                  && tokens[m - 1].TrailingPunctuation is not null
                  && tokens[m + 1].TrailingPunctuation is not null
                  && !tokens[m + 1].BreaksLine
                  && !tokens[m + 2].BreaksLine)) continue;
            int start = m - 1;
            while (start > 0 && tokens[start - 1].TrailingPunctuation is null && !tokens[start].BreaksLine) start--;
            return Delete(tokens, start, m + 2);
        }
        return null;
    }

    static readonly HashSet<string> StutterWords = new()
    {
        "a", "an", "the", "i", "to", "of", "in", "on", "at", "for", "and", "but", "or",
        "we", "you", "he", "she", "it", "they", "my", "our", "your", "his", "their",
        "this", "with", "will", "can", "would", "should", "could", "if", "be", "are",
        "was", "were", "me", "us", "them", "i'm", "it's", "we're", "you're", "they're",
    };

    static List<Token>? Stutter(List<Token> tokens)
    {
        for (int i = 0; i < tokens.Count; i++)
        {
            foreach (int n in new[] { 3, 2, 1 })
            {
                if (i + 2 * n > tokens.Count) continue;
                bool same = true;
                for (int k = 0; k < n; k++) if (tokens[i + k].Norm != tokens[i + n + k].Norm) { same = false; break; }
                if (!same) continue;
                if (!(n > 1 || StutterWords.Contains(tokens[i].Norm))) continue;
                // "the, the meeting" is a stutter; "Thursday. Thursday" is not.
                bool punctInside = false;
                for (int k = i; k < i + n - 1; k++) if (tokens[k].TrailingPunctuation is not null) punctInside = true;
                var lastPunct = tokens[i + n - 1].TrailingPunctuation;
                bool secondBreaks = false;
                for (int k = i + n; k < i + 2 * n; k++) if (tokens[k].BreaksLine) secondBreaks = true;
                bool firstBreaks = false;
                for (int k = i + 1; k < i + n; k++) if (tokens[k].BreaksLine) firstBreaks = true;
                if (punctInside || !(lastPunct is null || lastPunct == ',') || secondBreaks || firstBreaks) continue;
                return Delete(tokens, i, i + n);
            }
        }
        return null;
    }

    static readonly string[][] Hedges =
    {
        new[] { "you", "know" }, new[] { "i", "guess" }, new[] { "kind", "of" }, new[] { "sort", "of" }, new[] { "basically" }, new[] { "literally" },
    };

    static bool IsTrailingHedge(string[] phrase) =>
        phrase.SequenceEqual(new[] { "you", "know" }) || phrase.SequenceEqual(new[] { "i", "guess" }) || phrase.SequenceEqual(new[] { "basically" });

    /// <summary>Hedges go only where commas set them off as an aside.</summary>
    static List<Token>? Hedge(List<Token> tokens)
    {
        for (int h = 0; h < tokens.Count; h++)
        {
            foreach (var phrase in Hedges)
            {
                int upper = h + phrase.Length;
                if (upper > tokens.Count) continue;
                bool same = true;
                for (int k = 0; k < phrase.Length; k++) if (tokens[h + k].Norm != phrase[k]) { same = false; break; }
                if (!same) continue;
                bool punctInside = false;
                for (int k = h; k < upper - 1; k++) if (tokens[k].TrailingPunctuation is not null) punctInside = true;
                bool brokenInside = false;
                for (int k = h + 1; k < upper; k++) if (tokens[k].BreaksLine) brokenInside = true;
                if (punctInside || brokenInside) continue;

                var last = tokens[upper - 1].TrailingPunctuation;
                bool hasNext = upper < tokens.Count;
                bool afterComma = h > 0 && tokens[h - 1].TrailingPunctuation == ',';

                // "Basically, we need" -> "We need"
                if (IsSentenceStart(tokens, h) && last == ',' && hasNext) return Delete(tokens, h, upper);
                // "It was, you know, kind of weird" -> "It was kind of weird"
                if (afterComma && last == ',' && hasNext)
                {
                    var edited = new List<Token>(tokens);
                    var t = edited[h - 1];
                    t.Word = Chars.DropLast(t.Word);
                    edited[h - 1] = t;
                    return Delete(edited, h, upper);
                }
                // "That's the plan, I guess." -> "That's the plan."
                if (afterComma && IsTrailingHedge(phrase) && last is '.' or '!' or '?')
                {
                    var edited = new List<Token>(tokens);
                    var t = edited[h - 1];
                    t.Word = Chars.DropLast(t.Word) + last;
                    edited[h - 1] = t;
                    return Delete(edited, h, upper);
                }
            }
        }
        return null;
    }

    // MARK: - Kinds

    static readonly HashSet<string> Days = new()
    {
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "today", "tomorrow", "tonight", "yesterday",
    };

    static readonly HashSet<string> Months = new()
    {
        "january", "february", "march", "april", "may", "june", "july", "august",
        "september", "october", "november", "december",
    };

    static readonly HashSet<string> NumberWords = new()
    {
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
        "eleven", "twelve", "fifteen", "twenty", "thirty", "forty", "fifty", "hundred",
        "thousand", "noon", "midnight",
    };

    static Kind KindOf(List<Token> tokens, int index)
    {
        var token = tokens[index];
        var norm = token.Norm;
        var first = Chars.First(token.Word);
        bool capitalised = first is not null && Chars.IsUppercase(first);
        if (Days.Contains(norm)) return Kind.Day;
        // "may" and "march" are verbs far more often than months.
        if (Months.Contains(norm) && capitalised) return Kind.Month;
        if (NumberWords.Contains(norm) || IsNumeral(norm)) return Kind.Number;
        // A capital at a sentence start is grammar, not a name.
        if (capitalised && norm != "i" && !norm.StartsWith("i'", StringComparison.Ordinal) && !IsSentenceStart(tokens, index)) return Kind.Name;
        return Kind.Other;
    }

    /// <summary>"3", "3:30", "2pm", "$20", "50%".</summary>
    static bool IsNumeral(string word)
    {
        var body = word;
        if (body.StartsWith('$')) body = body[1..];
        foreach (var suffix in new[] { "am", "pm", "%", "st", "nd", "rd", "th" })
            if (body.EndsWith(suffix, StringComparison.Ordinal)) body = body[..^suffix.Length];
        if (body.Length == 0) return false;
        var g = Chars.Graphemes(body);
        if (!Chars.IsNumber(g[0])) return false;
        return g.All(c => Chars.IsNumber(c) || c is ":" or "." or ",");
    }

    // MARK: - Tokens

    /// <summary>
    /// Removes tokens [lower, upper), keeping the whitespace that stood in front
    /// of the cut. A capital that started the sentence moves to the new first word.
    /// </summary>
    static List<Token> Delete(List<Token> tokens, int lower, int upper)
    {
        var result = tokens.Take(lower).ToList();
        if (upper >= tokens.Count) return result;
        var next = tokens[upper];
        next.Leading = tokens[lower].Leading;
        var first = Chars.First(tokens[lower].Word);
        if (IsSentenceStart(tokens, lower) && first is not null && Chars.IsUppercase(first))
            next.Word = Chars.CapitalizeFirst(next.Word);
        result.Add(next);
        result.AddRange(tokens.Skip(upper + 1));
        return result;
    }

    static bool IsSentenceStart(List<Token> tokens, int index) =>
        index == 0 || tokens[index - 1].EndsSentence || tokens[index].BreaksLine;

    static int ClauseStart(List<Token> tokens, int index)
    {
        int start = Math.Max(index, 0);
        while (start > 0 && !IsSentenceStart(tokens, start)) start--;
        return start;
    }

    /// <summary>Punctuation minus ' $ %, which belong to words ("it's", "$20", "50%").</summary>
    static bool IsEdgePunctuation(char c) => char.IsPunctuation(c) && c != '\'' && c != '$' && c != '%';

    public static string Normalize(string word) => Chars.TrimWhere(Chars.Lower(word), IsEdgePunctuation);

    /// <summary>Words, each carrying the whitespace in front of it, so the text reassembles exactly.</summary>
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
