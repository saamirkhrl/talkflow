using System.Text;
using Talkflow.Core.Text;
using Xunit;

namespace Talkflow.Core.Tests;

/// <summary>
/// StreamSelfTest.swift's pipeline cases: streaming, segments, emails, lists,
/// the release pass, insert-once, writing styles. Cases about macOS write paths
/// (Accessibility, browser bundle ids) have no Windows counterpart: Windows
/// writes by keystrokes only, so every rewrite is held to the keystroke budget.
/// </summary>
public class PipelineTests
{
    static string R(string raw, bool structure = true) => Render.Text(raw, "", structure);

    // MARK: - Streaming (runCase)

    public sealed record StreamCase(string Name, string[] Ticks, string OnRelease, string[] NeverShownLive);

    public static readonly TheoryData<StreamCase> StreamCases = new()
    {
        new StreamCase("the email that was flashing and mangling", new[]
        {
            "Dear Sarah",
            "Dear Sarah, can you",
            "Dear Sarah, can you please review",
            "Dear Sarah, can you pleased review my pitch",
            "Dear Sarah, can you please review my pitch deck for the water",
            "Dear Sarah, can you please review my pitch deck for the waterbed willow",
            "Dear Sarah, can you please review my pitch deck for the waterbed willow fish. Thank you",
        }, "Dear Sarah, can you please review my pitch deck for the waterbed willow fish. Thank you, sincerely, Samir.", new[] { "pleased" }),
        new StreamCase("a word revised after it was first emitted (to -> two)", new[]
        {
            "I need to", "I need two tickets", "I need two tickets for the", "I need two tickets for the show tonight", "I need two tickets for the show tonight.",
        }, "I need two tickets for the show tonight.", Array.Empty<string>()),
        new StreamCase("a two-word emoji command split across ticks", new[]
        {
            "Send me the", "Send me the water", "Send me the water emoji", "Send me the water emoji and the bridge", "Send me the water emoji and the bridge emoji",
        }, "Send me the water emoji and the bridge emoji", new[] { "water", "bridge", "emoji" }),
        new StreamCase("a spoken paragraph break mid-hold", new[]
        {
            "Hi Sarah new paragraph can you",
            "Hi Sarah new paragraph can you review the deck",
            "Hi Sarah new paragraph can you review the deck and tell me",
            "Hi Sarah new paragraph can you review the deck and tell me what you think.",
        }, "Hi Sarah new paragraph can you review the deck and tell me what you think.", new[] { "paragraph" }),
        new StreamCase("whisper drops tail words and then recovers", new[]
        {
            "The quick brown fox jumps over", "The quick brown fox jumps over the lazy dog", "The quick brown fox",
            "The quick brown fox jumps over the lazy dog again", "The quick brown fox jumps over the lazy dog again and again",
        }, "The quick brown fox jumps over the lazy dog again and again.", Array.Empty<string>()),
        new StreamCase("late punctuation shifting the tail", new[]
        {
            "Let me know if that works", "Let me know if that works for you", "Let me know if that works for you, otherwise",
            "Let me know if that works for you. Otherwise I can move it",
        }, "Let me know if that works for you. Otherwise I can move it.", Array.Empty<string>()),
    };

    [Theory]
    [MemberData(nameof(StreamCases))]
    public void LiveUpdatesOnlyEverAppend(StreamCase testCase)
    {
        var stream = new StreamCommit();
        var screen = "";
        int liveDeletions = 0;
        var lastShown = "";
        var shownLive = new List<string>();
        foreach (var tick in testCase.Ticks)
        {
            var rendered = R(tick, structure: false);
            if (stream.Advance(rendered) is not { } settled) continue;
            Assert.StartsWith(lastShown, settled);
            lastShown = settled;
            liveDeletions += FieldEdit.Edit(screen, settled).Deleting;
            screen = settled;
            shownLive.Add(settled);
            int renderedWords = rendered.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
            int shownWords = screen.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries).Length;
            Assert.True(shownWords < renderedWords, "holds back the trailing word");
        }
        Assert.Equal(0, liveDeletions);
        foreach (var forbidden in testCase.NeverShownLive)
            Assert.DoesNotContain(shownLive, shown => ContainsWord(forbidden, shown));
        var final = R(testCase.OnRelease);
        var (deleting, inserting) = FieldEdit.Edit(screen, final);
        var applied = string.Concat(Chars.Graphemes(screen).Take(Chars.Count(screen) - deleting)) + inserting;
        Assert.Equal(final, applied);
    }

    static bool ContainsWord(string word, string text)
    {
        var words = new List<string>();
        var current = new StringBuilder();
        foreach (var g in Chars.Graphemes(text))
        {
            if (Chars.IsLetter(g) || Chars.IsNumber(g)) current.Append(g);
            else if (current.Length > 0) { words.Add(current.ToString()); current.Clear(); }
        }
        if (current.Length > 0) words.Add(current.ToString());
        return words.Any(w => string.Equals(w, word, StringComparison.OrdinalIgnoreCase));
    }

    // MARK: - Segments (runPlaceholderSegmentCases)

    [Theory]
    [InlineData("and that was the last thing I wanted to go over\n [BLANK_AUDIO]", "and that was the last thing I wanted to go over")]
    [InlineData("first part of what I said\n [BLANK_AUDIO]\n second part of what I said", "first part of what I said second part of what I said")]
    [InlineData("the first segment of a long dictation\n and the second segment of it", "the first segment of a long dictation and the second segment of it")]
    [InlineData("the community that formed around the product.\n over the last year.", "the community that formed around the product over the last year.")]
    [InlineData("that is all for today.\n Next week we start.", "that is all for today. Next week we start.")]
    [InlineData("I spoke to Dr.\n smith about it", "I spoke to Dr. smith about it")]
    [InlineData("[BLANK_AUDIO]", "")]
    public void JoinsSegments(string raw, string want) => Assert.Equal(want, Transcript.JoinSegments(raw));

    [Fact]
    public void NoPlaceholderSurvivesAndSegmentCutsJoinCleanly()
    {
        Assert.DoesNotContain("BLANK_AUDIO", R(Transcript.JoinSegments("and that was the last thing I wanted to go over\n [BLANK_AUDIO]")));
        Assert.Equal("So post about your work wins, post about your losses", R(Transcript.JoinSegments("so post about your work\n wins, post about your losses")));
    }

    // MARK: - Emails and lists (runEmailAndListCases)

    [Theory]
    [InlineData("Good morning, Mr. Johnson. I would like to ask you to update my grade in the grade book from a 97 to a 98 so my average will go to a 99. I would really appreciate it if you did that since this semester is about to end. Sincerely, Samira.",
        "Good morning, Mr. Johnson.\n\nI would like to ask you to update my grade in the grade book from a 97 to a 98 so my average will go to a 99. I would really appreciate it if you did that since this semester is about to end.\n\nSincerely, Samira.", true)]
    [InlineData("Good morning, Emily. The three things that I really like about talkflow is number one. It's free. Number two, it's available anywhere. And number three, it's completely open source under the MIT license. So you can use it whenever you want. Best, Samir.",
        "Good morning, Emily.\n\nThe three things that I really like about talkflow is:\n1. It's free.\n2. It's available anywhere.\n3. It's completely open source under the MIT license. So you can use it whenever you want.\n\nBest, Samir.", false)]
    public void EmailsReachTheScreenFormatted(string raw, string want, bool fitsBudget)
    {
        var screen = LiveScreen(raw, out var appendOnly);
        Assert.True(appendOnly, "every live step is an append");
        var final = R(raw);
        Assert.Equal(want, final);
        if (fitsBudget)
        {
            var (deleting, inserting) = FieldEdit.Edit(screen, final);
            Assert.True(Render.CorrectionIsAffordable(deleting, inserting), "the release rewrite fits the keystroke budget");
        }
    }

    [Theory]
    [InlineData("My grocery list is first, milk. Second, eggs. Third, bread.", "My grocery list is:\n1. Milk.\n2. Eggs.\n3. Bread.")]
    [InlineData("Three things, first, talk to 50 customers. Second, build in public and third of all you could submit your product to Product Hunt.",
        "Three things:\n1. Talk to 50 customers.\n2. Build in public\n3. You could submit your product to Product Hunt.")]
    [InlineData("First of all, thanks for coming to the meeting today.", "First of all, thanks for coming to the meeting today.")]
    [InlineData("I think talkflow is number one in my book.", "I think talkflow is number one in my book.")]
    [InlineData("Good morning Emily. Three things I really like about it are fast. Thank you so much for using it. Best, Samir.",
        "Good morning Emily.\n\nThree things I really like about it are fast. Thank you so much for using it.\n\nBest, Samir.")]
    [InlineData("Hey, what's up with the build today.", "Hey, what's up with the build today.")]
    [InlineData("Good morning Emily. Thank you so much again for using talkflow best Samira", "Good morning Emily.\n\nThank you so much again for using talkflow\n\nBest, Samira")]
    [InlineData("Good morning Emily. I looked at all three vendors and this is the best option we have right now.",
        "Good morning Emily.\n\nI looked at all three vendors and this is the best option we have right now.")]
    [InlineData("Can you send me the file before the meeting today please thanks Sam", "Can you send me the file before the meeting today please thanks Sam")]
    [InlineData("I asked everyone on the team who did the launch video best Sam", "I asked everyone on the team who did the launch video best Sam")]
    [InlineData("Let's meet at 3 p.m. where we can talk, or at 9 a.m. if that works.", "Let's meet at 3 p.m. where we can talk, or at 9 a.m. if that works.")]
    [InlineData("Bring snacks, e.g. chips, i.e. anything salty.", "Bring snacks, e.g. chips, i.e. anything salty.")]
    [InlineData("that is all period see you tomorrow", "That is all. See you tomorrow")]
    [InlineData("Hi Sarah new paragraph can you review the deck and tell me what you think. Thanks, Samir.", "Hi Sarah\n\nCan you review the deck and tell me what you think.\n\nThanks, Samir.")]
    public void Renders(string raw, string want) => Assert.Equal(want, R(raw));

    [Fact]
    public void ThePromptIsACasedSentenceAndItsOwnFormField()
    {
        Assert.Equal("I'm Samir, and I use talkflow, a dictation app.", Transcript.Prompt("Samir Kharel"));
        Assert.Equal("I'm Jo, and I use talkflow, a dictation app.", Transcript.Prompt("jo"));
        Assert.Equal("I use talkflow, a dictation app.", Transcript.Prompt(""));
        Assert.Equal("I use talkflow, a dictation app.", Transcript.Prompt("admin2"));
        var prompt = Transcript.Prompt("Samir Kharel");
        Assert.Contains("talkflow", prompt);
        var body = Encoding.UTF8.GetString(Transcript.MultipartBody(Array.Empty<byte>(), "b", prompt));
        Assert.Contains($"name=\"prompt\"\r\n\r\n{prompt}\r\n", body);
    }

    // MARK: - Dictations through the pipeline (runSelfCorrectionCases, second half)

    [Theory]
    [InlineData("Let's change the meeting to Friday, wait no, Thursday.", "Let's change the meeting to Thursday.")]
    [InlineData("Hey, let's meet tomorrow at 3pm. Actually, let's make that Tuesday at 2pm.", "Hey, let's meet Tuesday at 2pm.")]
    [InlineData("Fly out Monday at 9, no wait, Tuesday at 10, and back Friday, sorry, Saturday.", "Fly out Tuesday at 10, and back Saturday.")]
    [InlineData("Hi Sarah, the the deck is ready for review. Thanks, Samir.", "Hi Sarah,\n\nThe deck is ready for review.\n\nThanks, Samir.")]
    public void CorrectionsInRealDictations(string raw, string want)
    {
        var screen = LiveScreen(raw, out var appendOnly);
        Assert.True(appendOnly, "every live step is an append");
        var final = R(raw);
        Assert.Equal(want, final);
        var verbatim = Render.Text(raw, "", structure: true, corrections: false);
        Assert.Equal(final, Render.CorrectionTarget(screen, final, verbatim).Target);
    }

    [Fact]
    public void AShortHoldTypesOnlyTheCorrectedText()
    {
        var shortText = R("Meet at 2, no wait, 3.");
        Assert.Equal(shortText, Render.CorrectionTarget("", shortText, "Meet at 2, no wait, 3.").Target);
    }

    const string Long = "Let's move the review to Friday, wait no, Thursday, and then we can go over the launch plan, the pricing page, the onboarding emails, the support docs and everything else the team has been working on for the last month so that nothing is left for the week after";

    [Fact]
    public void AnEarlyCorrectionInALongLiveDictationIsRefusedSafely()
    {
        var liveScreen = R(Long, structure: false);
        var longVerbatim = Render.Text(Long, "", structure: true, corrections: false);
        var longFinal = R(Long);
        Assert.StartsWith("Let's move the review to Thursday, and then", longFinal);
        var keys = Render.CorrectionTarget(liveScreen, longFinal, longVerbatim);
        Assert.NotEqual(longFinal, keys.Target);
        Assert.Contains("self-correction", keys.Note);

        var partial = R("Let's move the review to Friday, wait no, Thursday, and then we", structure: false);
        var appended = FieldEdit.AppendOnlyTarget(partial, longVerbatim) ?? partial;
        Assert.Equal(longVerbatim, appended);
    }

    static string LiveScreen(string raw, out bool appendOnly)
    {
        var words = raw.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var screen = "";
        appendOnly = true;
        for (int count = 1; count <= words.Length; count++)
        {
            var next = R(string.Join(" ", words.Take(count)), structure: false);
            if (FieldEdit.Edit(screen, next).Deleting > 0) appendOnly = false;
            screen = next;
        }
        return screen;
    }

    // MARK: - Insert once (runInsertOnceCases)

    [Fact]
    public void InsertOnceAndTheCaption()
    {
        var final = R(Long);
        var insert = FieldEdit.Edit("", final);
        Assert.True(insert.Deleting == 0 && insert.Inserting == final && final.StartsWith("Let's move the review to Thursday,", StringComparison.Ordinal));

        Assert.Equal(("Let's meet", " at 3"), Render.CaptionParts(" Let's meet", " Let's meet at 3"));
        Assert.Equal(("", "Let's meet two"), Render.CaptionParts(" Let's meet to", " Let's meet two"));
    }

    [Fact]
    public void ContinuingASentence()
    {
        Assert.True(ScreenText.ContinuesSentence("Thanks for the notes and"));
        Assert.False(ScreenText.ContinuesSentence("Thanks for the notes. "));
        Assert.False(ScreenText.ContinuesSentence("Hi Sarah,\n"));
        Assert.False(ScreenText.ContinuesSentence(""));
        Assert.False(ScreenText.ContinuesSentence(null));
    }

    [Theory]
    [InlineData(" Great work on the deck.", " great work on the deck.")]
    [InlineData(" I think so.", " I think so.")]
    [InlineData(" NASA called.", " NASA called.")]
    [InlineData(" Samantha said yes.", " Samantha said yes.")]
    [InlineData(" I'm in.", " I'm in.")]
    public void LowercasingTheStart(string raw, string want) => Assert.Equal(want, ScreenText.LowercasingStart(raw, new[] { "Samantha" }));

    [Theory]
    [InlineData("Sounds good, see you at 5.", "Sounds good, see you at 5")]
    [InlineData("See you at 3 p.m.", "See you at 3 p.m.")]
    [InlineData("Are you coming?", "Are you coming?")]
    [InlineData("Thanks. See you soon.", "Thanks. See you soon.")]
    [InlineData("Wait...", "Wait...")]
    [InlineData("Hi,\n\nSee you.", "Hi,\n\nSee you.")]
    public void ChatStyle(string raw, string want) => Assert.Equal(want, ScreenText.ChatStyled(raw));

    [Fact]
    public void ChatAppsByProcess()
    {
        Assert.True(ScreenText.IsChat("Slack"));
        Assert.True(ScreenText.IsChat("Discord"));
        Assert.False(ScreenText.IsChat("notepad"));
        Assert.False(ScreenText.IsChat(null));
    }

    [Fact]
    public void PromptWithNamesAndLearnedWords()
    {
        const string vocabulary = "I use talkflow, a dictation app.";
        Assert.Equal(vocabulary, ScreenText.Prompt(vocabulary, Array.Empty<string>(), Array.Empty<string>()));
        Assert.Equal(vocabulary + " Names and words here: Siobhan, Acme, Kubernetes.",
            ScreenText.Prompt(vocabulary, new[] { "Siobhan", "Acme" }, new[] { "Kubernetes", "siobhan" }));
    }

    [Fact]
    public void ListsWithoutCommasAndTheSignOffComma()
    {
        Assert.Equal("Hey Samantha,\n\nThank you for getting back with me in the email. I guess three things that I need you to do is:\n1. Pick up the water\n2. Upload your resume to our app\n3. Tell other people about our app. And let's also have a meeting tomorrow at 8 p.m. and have your resume ready by that time.\n\nBest, Samir.",
            R("Hey Samantha, thank you for getting back with me in the email. I guess three things that I need you to do is first pick up the water, second upload your resume to our app, and then third tell other people about our app. And let's also have a meeting tomorrow at 8 p.m. and have your resume ready by that time. Best Samir."));
        foreach (var prose in new[]
                 {
                     "At first I hated it, but the second time was great.",
                     "Wait a second, the first thing is the budget.",
                     "I came first and my sister came second.",
                     "The first draft was fine and the second one was better.",
                     "Thanks Sam.",
                 })
            Assert.Equal(prose, R(prose));
        Assert.Equal("I need three things.\n1. Pick up the water\n2. Upload your resume\n3. Tell people about our app.",
            R("I need three things. First pick up the water, second upload your resume, third tell people about our app."));
        Assert.Equal("Body.\n\nThanks, Sarah", StructurePolish.PunctuateSignOff("Body.\n\nThanks Sarah"));
        Assert.Equal("Body.\n\nBest, Samir.", StructurePolish.PunctuateSignOff("Body.\n\nBest, Samir."));
        Assert.Equal("We should thank Sarah", StructurePolish.PunctuateSignOff("We should thank Sarah"));
    }

    [Fact]
    public void AiPunctuationOnlyTakesPunctuation()
    {
        const string original = "I guess three things that I need you to do is first pick up the water, second upload your resume. Best Samir.";
        const string suggestion = "I guess three things that I need you to do are: first, pick up the water; second, upload your resume. Best, Samir.";
        var merged = PolishMerge.Merge(original, suggestion, new[] { "Samir" });
        Assert.Equal("I guess three things that I need you to do is first, pick up the water; second, upload your resume. Best, Samir.", merged);
        Assert.True(SelfCorrection.IsDeletionOnly(original, merged) && SelfCorrection.IsDeletionOnly(merged, original));
        Assert.Equal("meet at 3 tomorrow!", PolishMerge.Merge("meet at 3 tomorrow", "Let's meet at 3 PM tomorrow!"));
        Assert.Equal("thanks Samir, and I will call.", PolishMerge.Merge("Thanks Samir and I will call", "thanks samir, and i will call.", new[] { "Samir" }));
        Assert.Equal("Hi Sarah,\n\nThe deck is ready.", PolishMerge.Merge("Hi Sarah, the deck is ready.", "Hi Sarah,\n\nThe deck is ready."));
        Assert.Equal("keep this", PolishMerge.Merge("keep this", ""));
    }

    [Fact]
    public void LearnedWords()
    {
        bool Known(string w) => w != "Shivon";
        Assert.Equal(new[] { "Siobhan" }, Vocabulary.Fixes("Thanks Shivon for the notes.", "Thanks Siobhan for the notes.", Known));
        Assert.Empty(Vocabulary.Fixes("Let's meet on Friday at noon.", "Let's meet on Thursday at noon.", Known));
        Assert.Empty(Vocabulary.Fixes("Thanks Shivon for the notes.", "Thanks Shivon for the notes.", Known));
        Assert.Equal(3, Vocabulary.Distance("kitten", "sitting"));
        Assert.Equal(3, Vocabulary.Distance("", "abc"));
        Assert.Equal(new[] { "Siobhan", "Acme" }, Vocabulary.Remember(new[] { "acme", "siobhan" }, new[] { "Siobhan", "Acme" }));
    }

    // MARK: - Release split (runReleaseSplitCases)

    [Theory]
    [InlineData("I need two tickets", "I need two tickets for the show tonight.", "I need two tickets for the show tonight.")]
    [InlineData("I need to tickets", "I need two tickets for the show tonight.", "I need to tickets for the show tonight.")]
    [InlineData("Dear Sarah,", "Dear Sarah,\n\nCan you take a look", "Dear Sarah,\n\nCan you take a look")]
    [InlineData("the whole thing was already typed", "the whole thing was already typed", null)]
    [InlineData("more words on screen than in the transcript", "fewer words", null)]
    public void TheReleaseAppendDeletesNothing(string current, string final, string? want)
    {
        var got = FieldEdit.AppendOnlyTarget(current, final);
        Assert.Equal(want, got);
        if (got is not null) Assert.Equal(0, FieldEdit.Edit(current, got).Deleting);
    }

    [Fact]
    public void ACorrectionIsOnlyAttemptedWhenItCanBeDelivered()
    {
        Assert.False(Render.CorrectionIsAffordable(422, new string('x', 471)));
        Assert.False(Render.CorrectionIsAffordable(263, new string('x', 287)));
        Assert.True(Render.CorrectionIsAffordable(31, new string('x', 37)));
    }

    [Fact]
    public void ChunksNeverSplitACharacterAndNewlinesGoAlone()
    {
        Assert.Equal(new[] { "Dear Sarah,", "\n", "\n", "Can you" }, FieldEdit.Chunked("Dear Sarah,\n\nCan you"));
        Assert.Equal(new[] { new string('a', 16), "a" }, FieldEdit.Chunked(new string('a', 17)));
        var emoji = string.Concat(Enumerable.Repeat("\U0001F680", 9));
        Assert.All(FieldEdit.Chunked(emoji), chunk => Assert.True(chunk.Length <= FieldEdit.MaxUnitsPerEvent && chunk.Length % 2 == 0));
    }

    // MARK: - Writing style (runWritingStyleCases)

    [Fact]
    public void WritingStylesChangeOnlyCaseAndTheClosingStop()
    {
        const string text = "Hi Sarah. I'm sure I'll send it, and I think it's fine.";
        Assert.Equal(text, WritingStyle.Formal.Apply(text));
        Assert.Equal("hi sarah. i'm sure i'll send it, and i think it's fine.", WritingStyle.Lowercase.Apply(text));
        Assert.Equal("hi sarah. I'm sure I'll send it, and I think it's fine", WritingStyle.Casual.Apply(text));
        Assert.Equal("wait for it...", WritingStyle.Casual.Apply("Wait for it..."));
        Assert.Equal("is it in the inbox? yes ", WritingStyle.Casual.Apply("Is it in the inbox? Yes. "));
        Assert.Equal("ice is nice", WritingStyle.Casual.Apply("ice is nice"));
        Assert.Equal(" can you check the deck. thanks",
            Render.Text("can you check the deck period thanks", " ", structure: true, style: WritingStyle.Lowercase));
        foreach (var style in WritingStyles.All)
        {
            const string raw = "Dear Sarah, can you send the file. Thanks, Samir.";
            Assert.Equal(SelfCorrection.Tokenize(raw).Select(t => t.Norm), SelfCorrection.Tokenize(style.Apply(raw)).Select(t => t.Norm));
        }
    }
}
