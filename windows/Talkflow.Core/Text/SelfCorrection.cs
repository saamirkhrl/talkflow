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
            // TypedRepair first: it also handles "scratch that" when only a
            // value changed, so "at 4 p.m., scratch that, 5 p.m." keeps the
            // words around the value. ScratchThat drops the clause otherwise.
            var next = TypedRepair(tokens) ?? ScratchThat(tokens) ?? Restart(tokens)
                ?? NegatedRestart(tokens) ?? FalseStart(tokens) ?? Stutter(tokens) ?? Hedge(tokens);
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

    /// <summary>
    /// Whether a correction marker, set off the way a correction is, still stands
    /// in <paramref name="text"/>. After <see cref="Apply"/>, true means the rules saw a marker and left it.
    /// </summary>
    public static bool HasMarker(string text)
    {
        var tokens = Tokenize(text);
        for (int i = 1; i < tokens.Count; i++)
            if (MarkersAt(i, tokens).Count > 0 || Command(i, tokens) is not null) return true;
        return false;
    }

    // MARK: - Markers

    sealed record Marker(string[] Words, bool Strong, bool NeedsClauseEnd, bool PlainAtClauseEnd = false)
    {
        public bool TrustsPlainWords => Strong || Words.SequenceEqual(new[] { "or", "rather" }) || Words.SequenceEqual(new[] { "correction" });

        /// <summary>Firm enough for a restart that repeats only the sentence's first word.</summary>
        public bool Firm => Strong || (Words.Contains("no") && Words.Contains("actually"));

        /// <summary>May be followed by a name that the sentence break capitalised: "Tell John. Wait, no. Mike."</summary>
        public bool AllowsSentenceStartName => Strong;

        /// <summary>
        /// A marker that takes something back ("actually", "wait", "no", "I mean"), as
        /// opposed to an apology ("sorry") or an exclamation ("oh no").
        /// </summary>
        public bool Retracts
        {
            get
            {
                if (Words.Contains("oh") && !Words.Contains("wait")) return false;
                return Strong || Words.Contains("actually") || Words.Contains("wait") || Words.Contains("no")
                    || Words.SequenceEqual(new[] { "i", "mean" }) || Words.SequenceEqual(new[] { "i", "meant" })
                    || Words.SequenceEqual(new[] { "or", "rather" }) || Words.SequenceEqual(new[] { "correction" });
            }
        }
    }

    static readonly Marker[] FixedMarkers =
    {
        new(new[] { "or", "rather" }, false, false),
        new(new[] { "make", "that" }, false, false),
        new(new[] { "i", "meant" }, false, false, true),
        new(new[] { "i", "mean" }, false, false, true),
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
        return new Marker(words.ToArray(), hasWait && words.Count >= 2, !hasWait && !words.Contains("no"), hasWait || !words.Contains("oh"));
    }

    /// <summary>Words that may lead into "scratch that": "10 to 20, actually scratch that, 10 to 30".</summary>
    static readonly HashSet<string> RetractLeads = new(RunWords) { "okay", "ok", "um", "uh", "hmm", "so", "well" };

    /// <summary>
    /// "scratch that" (or strike / ignore / disregard that), with any filler
    /// words in front of it, starting at <paramref name="index"/>. Always a strong
    /// marker, but only when it is plainly a command: after a filler ("actually
    /// scratch that"), or set off by punctuation on both sides. "Please scratch
    /// that itch" is neither.
    /// </summary>
    static Marker? Scratch(int index, List<Token> tokens)
    {
        var words = new List<string>();
        int i = index;
        while (i < tokens.Count && words.Count < 3 && RetractLeads.Contains(tokens[i].Norm) && (i == index || !tokens[i].BreaksLine))
        {
            words.Add(tokens[i].Norm);
            i++;
        }
        if (!(i + 1 < tokens.Count && RetractVerbs.Contains(tokens[i].Norm) && tokens[i + 1].Norm == "that"
              && (!tokens[i].BreaksLine || i == index) && !tokens[i + 1].BreaksLine)) return null;
        bool setOff = words.Count > 0
            || (index > 0 && tokens[index - 1].TrailingPunctuation is not null && tokens[i + 1].TrailingPunctuation is not null);
        if (!setOff) return null;
        words.Add(tokens[i].Norm);
        words.Add("that");
        return new Marker(words.ToArray(), true, false);
    }

    static List<(Marker Marker, int End)> MarkersAt(int index, List<Token> tokens)
    {
        var found = new List<(Marker, int)>();
        if (index <= 0) return found; // nothing before it to replace
        var candidates = new List<Marker>(FixedMarkers);
        if (Run(index, tokens) is { } run) candidates.Add(run);
        if (Scratch(index, tokens) is { } scratch) candidates.Add(scratch);
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
                    // "not a short" negates the old phrase; it is no replacement.
                    if (tokens[after].Norm == "not") continue;
                    var old = UnitsBackward(m, tokens);
                    var @new = UnitsForward(after, tokens);
                    for (int n = 1; n <= MaxUnits; n++)
                    {
                        if (n > old.Count || n > @new.Count) continue;
                        var olds = old.Take(n).Reverse().ToList();
                        var news = @new.Take(n).ToList();
                        if (n == 1 && olds[0].Kind == Kind.Name && news[0].Kind == Kind.Other
                            && SentenceStartName(news[0].Lower, olds[0].Lower, marker, lead, tokens))
                            news[0] = new Unit(news[0].Lower, news[0].Upper, Kind.Name, news[0].Norm);
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
            if (!(changedWords.Count == 1 && lead == 0
                  && tokens[old[^1].Upper - 1].TrailingPunctuation is not null)) return false;
            if (!marker.TrustsPlainWords)
            {
                if (!(marker.PlainAtClauseEnd && PlainSwapAllowed(old, @new, changedWords[0], marker, tokens))) return false;
            }
        }
        if (marker.NeedsClauseEnd || changedName || changedWords.Count > 0)
        {
            int end = @new[^1].Upper;
            if (!(end == tokens.Count || tokens[end - 1].TrailingPunctuation is not null)) return false;
        }
        return true;
    }

    /// <summary>
    /// A swap of one ordinary word after a marker that also opens new thoughts.
    /// Deliberately narrow, since nothing here knows parts of speech:
    /// the changed word is the LAST unit; one unit on each side only when both
    /// words are in one closed class; two or three units only when every unit
    /// before the changed one is an article, possessive or preposition said
    /// again; neither word is a filler; the old phrase is not negated.
    /// </summary>
    static bool PlainSwapAllowed(List<Unit> old, List<Unit> @new, int index, Marker marker, List<Token> tokens)
    {
        int n = old.Count;
        if (!(index == n - 1 && n <= 3)) return false;
        // "Did you read the book? Actually, the movie." must not become a statement: the old
        // phrase ends in a comma, or in the same mark the replacement ends in.
        var oldEnd = tokens[old[n - 1].Upper - 1].TrailingPunctuation;
        var newEnd = tokens[@new[n - 1].Upper - 1].TrailingPunctuation;
        if (!(oldEnd == ',' || oldEnd == newEnd)) return false;
        var o = old[index].Norm;
        var r = @new[index].Norm;
        if (PlainSwapStop.Contains(o) || PlainSwapStop.Contains(r)) return false;
        // "sorry" alone is just as often an apology ("Thanks for the gift. Sorry, the delay."):
        // after it, only a swap inside one closed class counts ("the left, sorry, the right").
        if (!marker.Retracts)
        {
            if (!PlainClasses.Any(c => c.Contains(o) && c.Contains(r))) return false;
        }
        if (n == 1)
        {
            if (!PlainClasses.Any(c => c.Contains(o) && c.Contains(r))) return false;
        }
        else
        {
            for (int k = 0; k < index; k++)
                if (!(old[k].Kind == Kind.Other && AnchorWords.Contains(old[k].Norm))) return false;
        }
        int before = old[0].Lower - 1;
        if (before >= 0 && IsNegation(tokens[before].Norm)) return false;
        return true;
    }

    static bool IsNegation(string word) =>
        word is "not" or "never" or "no" || word.EndsWith("n't", StringComparison.Ordinal) || word.EndsWith("n\u2019t", StringComparison.Ordinal);

    static readonly HashSet<string>[] PlainClasses =
    {
        new() { "red", "orange", "yellow", "green", "blue", "purple", "pink", "black", "white", "gray", "grey", "brown", "gold", "silver" },
        new() { "left", "right", "top", "bottom", "up", "down", "front", "back", "above", "below", "inside", "outside",
                "north", "south", "east", "west" },
        new() { "big", "bigger", "small", "smaller", "large", "larger", "tiny", "huge", "short", "shorter", "long", "longer",
                "wide", "wider", "narrow", "narrower", "tall", "taller", "high", "higher", "low", "lower" },
        new() { "first", "second", "third", "last", "next", "previous" },
        new() { "more", "less", "fewer" },
    };

    static readonly HashSet<string> AnchorWords = new()
    {
        "a", "an", "the", "my", "our", "your", "their", "his", "its", "this", "these", "those",
        "on", "in", "at", "to", "for", "with", "from", "into", "onto",
    };

    static readonly HashSet<string> PlainSwapStop = new()
    {
        "that", "this", "it", "so", "too", "yes", "yeah", "no", "okay", "ok", "sure", "well", "really", "very",
        "just", "again", "though", "anyway", "either", "now", "then", "here", "there", "please", "thanks",
        "same", "other", "one", "ones", "rest", "thing", "things", "stuff", "whole", "lot",
    };

    /// <summary>
    /// "Tell John. Wait, no. Mike.": the marker ended a sentence, so the name
    /// after it starts one and its capital looks like grammar. Only a single word
    /// standing for a name, only after a marker that is plainly a correction,
    /// never a common reply.
    /// </summary>
    static bool SentenceStartName(int index, int old, Marker marker, int lead, List<Token> tokens)
    {
        var token = tokens[index];
        // Positive evidence, not a stop list: both are given names from one closed list
        // ("Tell John. Wait, no. Mike."). "Phew", "Lunch" or "Congrats" never are.
        if (!(GivenNames.Contains(token.Norm) && GivenNames.Contains(tokens[old].Norm))) return false;
        // The old name is one capitalised word, not the end of a longer one ("Main Street").
        if (old > 0 && !IsSentenceStart(tokens, old - 1) && tokens[old - 1].Word.Length > 0 && char.IsUpper(tokens[old - 1].Word[0])) return false;
        // Not a greeting, thanks or sign-off: "Hi Tom.", "Thanks, Kevin.", "Love you, Mom."
        if (SocialOpeners.Contains(tokens[ClauseStart(tokens, old)].Norm)) return false;
        // Both end their sentence with a full stop, or the new one ends the text.
        if (!(tokens[old].TrailingPunctuation == '.'
              && (token.TrailingPunctuation == '.' || (token.TrailingPunctuation is null && index == tokens.Count - 1)))) return false;
        return lead == 0 && marker.AllowsSentenceStartName && IsSentenceStart(tokens, index)
            && !token.BreaksLine && token.Word.Length > 0 && char.IsUpper(token.Word[0]);
    }

    static readonly HashSet<string> SocialOpeners = new()
    {
        "hi", "hey", "hello", "dear", "thanks", "thank", "bye", "goodbye",
        "love", "good", "cheers", "congrats", "congratulations", "welcome", "sorry", "morning",
        "night", "yo",
    };

    /// <summary>
    /// Unambiguous given names: none is also an everyday word (no Will, Mark, Rose, Grace,
    /// May, Hope, Jack, Frank, Bill, Ray, Joy, June, April, Ivy, Holly, Penny, Dawn, Chase).
    /// One list for Mac and Windows; keep them identical.
    /// </summary>
    static readonly HashSet<string> GivenNames = new()
    {
        "aaron", "abigail", "adam", "ahmed", "aiden", "aisha", "alan", "albert",
        "alex", "alexander", "ali", "alice", "amanda", "amelia", "amit", "amy",
        "ana", "ananya", "andrea", "andrew", "andy", "angela", "anna", "anne",
        "anthony", "arjun", "ashley", "ava", "barbara", "beth", "ben", "benjamin",
        "betty", "bob", "brad", "brandon", "brenda", "brian", "bruce", "bryan",
        "caleb", "carlos", "carmen", "carol", "carolyn", "catherine", "charles", "charlotte",
        "chen", "cheryl", "chloe", "chris", "christina", "christine", "claire", "cynthia",
        "dan", "daniel", "dave", "david", "deborah", "dennis", "derek", "diana",
        "diane", "diego", "donna", "doris", "dylan", "edward", "elena", "elijah",
        "elizabeth", "ella", "ellie", "emily", "emma", "eric", "erica", "erin",
        "ethan", "eva", "evelyn", "ezra", "fatima", "gabriel", "gary", "george",
        "gloria", "greg", "gregory", "hannah", "harold", "heather", "helen", "henry",
        "hiroshi", "ian", "isaac", "isabella", "jacob", "jake", "james", "jane",
        "janet", "janice", "jason", "jeff", "jeffrey", "jennifer", "jenny", "jeremy",
        "jerry", "jessica", "jill", "jim", "joan", "joe", "john", "jonathan",
        "jordan", "jose", "joseph", "josh", "joshua", "joyce", "juan", "judith",
        "julia", "julian", "julie", "justin", "karen", "kate", "katherine", "kathleen",
        "katie", "keith", "kelly", "kenji", "kevin", "kim", "kimberly", "kyle",
        "larry", "laura", "lauren", "lawrence", "leah", "leo", "liam", "linda",
        "lisa", "logan", "lucas", "lucia", "lucy", "luis", "madison", "marcus",
        "margaret", "maria", "marie", "martha", "mary", "mateo", "matt", "matthew",
        "maya", "megan", "mei", "melissa", "mia", "michael", "michelle", "miguel",
        "mike", "mohammed", "monica", "muhammad", "nancy", "natalie", "nathan", "neil",
        "nicholas", "nick", "nicole", "nina", "noah", "nora", "oliver", "olivia",
        "omar", "owen", "pamela", "patricia", "patrick", "paul", "paula", "peter",
        "priya", "priyanka", "rachel", "rahul", "raj", "ravi", "raymond", "rebecca",
        "richard", "robert", "roger", "ronald", "ruth", "ryan", "samantha", "samuel",
        "sam", "sandra", "sanjay", "sara", "sarah", "scott", "sean", "sebastian",
        "sharon", "shirley", "sofia", "sophia", "sophie", "stephanie", "stephen", "steve",
        "steven", "susan", "tara", "teresa", "thomas", "tim", "timothy", "tina",
        "todd", "tom", "tony", "trevor", "tyler", "vanessa", "victoria", "vikram",
        "vincent", "walter", "wei", "wendy", "william", "yuki", "zachary", "zoe",
    };

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

    static readonly HashSet<string> ObjectPronouns = new() { "it", "that", "this", "them", "these", "those", "him", "her", "us", "me" };
    static readonly HashSet<string> NegationTails = new() { "yet", "now", "anymore", "again", "today" };

    /// <summary>Words after which a verb is an instruction: "I want you to refactor", "please send", "let's ship".</summary>
    static readonly HashSet<string> InstructionSlots = new() { "to", "please", "let's", "lets", "i'll", "we'll", "should", "must" };

    static readonly HashSet<string> RestartSkips = new() { "just", "only" };

    /// <summary>"I went home, I mean I went to the office": the clause restarts.</summary>
    static List<Token>? Restart(List<Token> tokens)
    {
        for (int m = 0; m < tokens.Count; m++)
        {
            foreach (var (marker, markerEnd) in MarkersAt(m, tokens))
            {
                int after = SkipNegation(markerEnd, m, tokens);
                int start = Math.Max(ClauseStart(tokens, m - 1), m - 12);
                // 1. Unchanged: the first two words after the marker were said earlier in the sentence.
                if (Repeated(after, start, m, tokens) is { } p) return Delete(tokens, p, after);
                // 2. "the whole file. Actually, just refactor the render function": the
                //    restart is one "just"/"only" in; that word is kept.
                if (marker.Retracts && after + 1 < tokens.Count && RestartSkips.Contains(tokens[after].Norm)
                    && tokens[m - 1].TrailingPunctuation != '?'
                    && !AnchorWords.Contains(tokens[after + 1].Norm) && !StutterWords.Contains(tokens[after + 1].Norm)
                    && Repeated(after + 1, start, m, tokens) is { } p2
                    && tokens[p2 + 1].TrailingPunctuation is null && p2 + 2 < m
                    && (IsSentenceStart(tokens, p2) || InstructionSlots.Contains(tokens[p2 - 1].Norm))) return Delete(tokens, p2, after);
                // 3. "First fix the tests. Wait, no, first pull the latest changes": after
                //    a firm marker, the new clause opens with the old sentence's first word.
                int s = ClauseStart(tokens, m - 1);
                if (marker.Firm && after + 1 < tokens.Count && !tokens[after + 1].BreaksLine
                    && m - s >= 2 && m - s <= 12 && tokens[m - 1].TrailingPunctuation is not null
                    && tokens[after].Norm == tokens[s].Norm && !RunWords.Contains(tokens[s].Norm))
                    return Delete(tokens, s, after);
            }
        }
        return null;
    }

    /// <summary>
    /// Where the two words at <paramref name="index"/> were first said: between
    /// <paramref name="start"/> and the marker at <paramref name="m"/>, not across punctuation after the first of them.
    /// </summary>
    static int? Repeated(int index, int start, int m, List<Token> tokens)
    {
        if (!(index + 1 < tokens.Count && !tokens[index + 1].BreaksLine)) return null;
        for (int p = m - 2; p >= start; p--)
        {
            if (tokens[p].Norm == tokens[index].Norm && tokens[p + 1].Norm == tokens[index + 1].Norm
                && tokens[p].TrailingPunctuation is null) return p;
        }
        return null;
    }

    /// <summary>
    /// "Delete the old migration. Wait, don't delete it, just rename it.": the user
    /// negates the verb that opened the sentence before the marker, then says what
    /// to do instead. The old sentence and the short negated clause go; the rest stays.
    /// </summary>
    static List<Token>? NegatedRestart(List<Token> tokens)
    {
        for (int m = 0; m < tokens.Count; m++)
        {
            foreach (var (_, markerEnd) in MarkersAt(m, tokens))
            {
                if (tokens[m - 1].TrailingPunctuation is null) continue;
                int s = ClauseStart(tokens, m - 1);
                if (!(m - s >= 2 && m - s <= 12)) continue;
                int verb = tokens[s].Norm is "let's" or "lets" or "please" ? s + 1 : s;
                if (verb >= m) continue;
                int v = markerEnd;
                if (v < tokens.Count && tokens[v].Norm is "don't" or "dont" or "don\u2019t")
                {
                    v += 1;
                }
                else if (v + 1 < tokens.Count && tokens[v].Norm == "do" && tokens[v + 1].Norm == "not")
                {
                    v += 2;
                }
                else continue;
                if (!(v < tokens.Count && tokens[v].Norm == tokens[verb].Norm)) continue;
                // Positive evidence that the old instruction itself is negated: the same object again,
                // as a pronoun ("don't delete it") or the same two words ("don't bring the charger").
                // "Go ahead and explore. Actually, don't go too far" only qualifies it.
                int o = v + 1;
                if (o < tokens.Count && ObjectPronouns.Contains(tokens[o].Norm))
                {
                    o += 1;
                }
                else if (o + 1 < tokens.Count && verb + 2 < m
                         && tokens[o].Norm == tokens[verb + 1].Norm && tokens[o + 1].Norm == tokens[verb + 2].Norm
                         && tokens[o].TrailingPunctuation is null)
                {
                    o += 2;
                }
                else continue;
                // At most one more word ("yet"), then the clause ends: "don't have it too strong" qualifies.
                int k = o - 1;
                if (tokens[k].TrailingPunctuation is null && o < tokens.Count && NegationTails.Contains(tokens[o].Norm)) k = o;
                if (!(tokens[k].TrailingPunctuation is { } p && ",;.!".Contains(p))) continue;
                bool broken = false;
                for (int j = markerEnd + 1; j <= k; j++) if (tokens[j].BreaksLine) broken = true;
                if (broken) continue;
                // Only the old sentence and the marker go; "Don't delete it, just rename it." stays.
                return Delete(tokens, s, markerEnd);
            }
        }
        return null;
    }

    /// <summary>
    /// "a short, actually no not a short, we'll add a long one": after the
    /// marker, "not" plus the very words just before it (ending in
    /// punctuation) only negates them, so the restart begins after it.
    /// </summary>
    static int SkipNegation(int index, int m, List<Token> tokens)
    {
        if (!(index < tokens.Count && tokens[index].Norm == "not")) return index;
        for (int k = 1; k <= 4; k++)
        {
            if (!(index + k < tokens.Count && m - k >= 0)) continue;
            if (tokens[index + k].TrailingPunctuation is null) continue;
            bool punctInside = false;
            for (int j = index + 1; j < index + k; j++) if (tokens[j].TrailingPunctuation is not null) punctInside = true;
            if (punctInside) continue;
            bool same = true;
            for (int j = 0; j < k; j++) if (tokens[index + 1 + j].Norm != tokens[m - k + j].Norm) { same = false; break; }
            if (!same) continue;
            return index + k + 1;
        }
        return index;
    }

    static readonly HashSet<string> RetractVerbs = new() { "scratch", "strike", "ignore", "disregard" };

    /// <summary>"..., scratch that, ..." drops the clause before it.</summary>
    static List<Token>? ScratchThat(List<Token> tokens)
    {
        for (int m = 1; m < tokens.Count; m++)
        {
            if (Scratch(m, tokens) is { } marker)
            {
                int end = m + marker.Words.Length;
                // "scratch that, scratch that" is one command said twice.
                while (end + 2 < tokens.Count && RetractVerbs.Contains(tokens[end].Norm) && tokens[end + 1].Norm == "that"
                       && !tokens[end].BreaksLine) end += 2;
                if (end >= tokens.Count || tokens[end].BreaksLine) continue;
                int start = RetractStart(tokens, m);
                if (!HasContent(tokens, start, m)) continue;
                return Delete(tokens, start, end);
            }
            if (Command(m, tokens) is { } cmd)
            {
                int end = m + cmd.Count;
                if (end >= tokens.Count || tokens[end].BreaksLine) continue;
                int start = RetractStart(tokens, m);
                if (!(cmd.RetractLead && HasContent(tokens, start, m) && !Subordinators.Contains(tokens[start].Norm))) continue;
                var phrase = string.Join(" ", cmd.Phrase);
                if (phrase is "never mind" or "nevermind")
                {
                    // Only a question or a request is taken back ("Rust? Actually, never mind, keep it
                    // in Swift."); a greeting or thanks is not ("Hi team. Actually, never mind, ...").
                    if (!(tokens[m - 1].TrailingPunctuation == '?' || RequestOpeners.Contains(tokens[start].Norm))) continue;
                    return Delete(tokens, start, end);
                }
                if (phrase == "start over")
                {
                    // "Let's ship today, wait, start over, let's ship tomorrow": the clause is said
                    // again, opening with the same two words but not repeated word for word.
                    int length = m - start;
                    if (!(length >= 2 && end + 1 < tokens.Count && !tokens[end + 1].BreaksLine
                          && tokens[end].Norm == tokens[start].Norm && tokens[end + 1].Norm == tokens[start + 1].Norm)) continue;
                    bool repeatsAll = end + length <= tokens.Count;
                    if (repeatsAll)
                        for (int k = 0; k < length; k++)
                            if (tokens[end + k].Norm != tokens[start + k].Norm) { repeatsAll = false; break; }
                    if (repeatsAll) continue;
                    return Delete(tokens, start, end);
                }
                // "delete that", "undo that": everyday editor instructions ("Select the first row,
                // delete that, select the next row"). Detected for the model step, never applied here.
                continue;
            }
        }
        return null;
    }

    /// <summary>The first token of the clause that ends right before <paramref name="m"/>.</summary>
    static int RetractStart(List<Token> tokens, int m)
    {
        int start = m - 1;
        while (start > 0 && tokens[start - 1].TrailingPunctuation is null && !tokens[start].BreaksLine) start--;
        return start;
    }

    /// <summary>
    /// Newer retract commands. Unlike scratch that they are everyday instructions
    /// ("look at the last commit, undo that, and rerun the tests"), so they only drop
    /// a clause, never act as markers for the other rules, and need more than
    /// punctuation: see <see cref="ScratchThat"/>.
    /// </summary>
    static readonly string[][] CommandRetracts =
    {
        new[] { "never", "mind" }, new[] { "nevermind" }, new[] { "start", "over" }, new[] { "delete", "that" }, new[] { "undo", "that" },
    };

    static readonly HashSet<string> RequestOpeners = new() { "please", "let's", "lets", "i'll", "we'll", "i'd", "we'd" };

    /// <summary>"actually" and "wait" mark a retraction; "oh", "so", "okay" do not ("Oh, never mind, it's fine").</summary>
    static readonly HashSet<string> RetractSignals = new() { "actually", "wait" };

    /// <summary>Words that open a subordinate clause: "If it fails, start over" is an instruction.</summary>
    static readonly HashSet<string> Subordinators = new()
    {
        "if", "when", "whenever", "once", "unless", "until", "till", "while", "after", "before", "because",
        "since", "as", "though", "although", "where", "wherever", "whether",
    };

    /// <summary>
    /// A command at <paramref name="index"/>, with optional filler leads, set off the way
    /// <see cref="Scratch"/> requires and followed at once by punctuation. Returns the number of
    /// tokens it spans, the phrase, and whether a lead was "actually" or "wait".
    /// </summary>
    static (int Count, string[] Phrase, bool RetractLead)? Command(int index, List<Token> tokens)
    {
        if (index <= 0) return null;
        var leadWords = new List<string>();
        int i = index;
        while (i < tokens.Count && leadWords.Count < 3 && RetractLeads.Contains(tokens[i].Norm) && (i == index || !tokens[i].BreaksLine))
        {
            leadWords.Add(tokens[i].Norm);
            i++;
        }
        foreach (var phrase in CommandRetracts)
        {
            if (!(i + phrase.Length <= tokens.Count)) continue;
            bool same = true;
            for (int k = 0; k < phrase.Length; k++) if (tokens[i + k].Norm != phrase[k]) { same = false; break; }
            if (!same) continue;
            if (!(i == index || !tokens[i].BreaksLine)) continue;
            bool brokenInside = false;
            for (int k = i + 1; k < i + phrase.Length; k++) if (tokens[k].BreaksLine) brokenInside = true;
            if (brokenInside) continue;
            if (tokens[i + phrase.Length - 1].TrailingPunctuation is null) continue;
            bool setOff = leadWords.Count > 0 || tokens[index - 1].TrailingPunctuation is not null;
            if (!setOff) return null;
            return (leadWords.Count + phrase.Length, phrase, leadWords.Any(w => RetractSignals.Contains(w)));
        }
        return null;
    }

    /// <summary>Whether [lower, upper) holds a word that is not just a filler lead ("Oh, never mind").</summary>
    static bool HasContent(List<Token> tokens, int lower, int upper)
    {
        for (int k = lower; k < upper; k++) if (!RetractLeads.Contains(tokens[k].Norm)) return true;
        return false;
    }

    /// <summary>Articles and possessives never end a phrase, so a comma right after one is a broken-off clause.</summary>
    static readonly HashSet<string> Danglers = new() { "an", "the", "my", "our", "your", "their", "its" };

    /// <summary>
    /// "Can you make the, can you change the font size?": a clause broken off after
    /// an article or possessive, then begun again with its first two words.
    /// </summary>
    static List<Token>? FalseStart(List<Token> tokens)
    {
        for (int d = 0; d < tokens.Count; d++)
        {
            if (!(tokens[d].TrailingPunctuation == ',' && Danglers.Contains(tokens[d].Norm)
                  && tokens[d].Word.Length > 0 && char.IsLower(tokens[d].Word[0]))) continue;
            int f = d;
            while (f > 0 && tokens[f - 1].TrailingPunctuation is null && !tokens[f].BreaksLine) f--;
            if (!(d - f >= 2 && d - f <= 7 && d + 2 < tokens.Count
                  && !tokens[d + 1].BreaksLine && !tokens[d + 2].BreaksLine
                  && tokens[d + 1].Norm == tokens[f].Norm && tokens[d + 2].Norm == tokens[f + 1].Norm)) continue;
            // "Search for the, search for an": the same words again with another article is a
            // list of words, not a restart. A real restart changes something before the slot.
            int len = d - f;
            if (d + 1 + len <= tokens.Count)
            {
                bool identical = true;
                for (int k = 0; k < len; k++) if (tokens[d + 1 + k].Norm != tokens[f + k].Norm) { identical = false; break; }
                if (identical) continue;
            }
            return Delete(tokens, f, d + 1);
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
