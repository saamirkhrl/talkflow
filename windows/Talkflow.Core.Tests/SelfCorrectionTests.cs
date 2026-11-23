using Talkflow.Core.Text;
using Xunit;

namespace Talkflow.Core.Tests;

/// <summary>StreamSelfTest.runSelfCorrectionCases, pair for pair.</summary>
public class SelfCorrectionTests
{
    public static readonly TheoryData<string, string> Pure = new()
    {
        // corrections: marker plus a replacement of the same kind
        { "let's change that to Friday, wait no, Thursday", "let's change that to Thursday" },
        { "let's change that to Friday wait no Thursday", "let's change that to Thursday" },
        { "Meet at 2, no wait, 3.", "Meet at 3." },
        { "Meet at 2 pm, no wait, 3 pm.", "Meet at 3 pm." },
        { "Meet at 2. No wait, 3.", "Meet at 3." },
        { "Send it to Sarah, sorry, Sam.", "Send it to Sam." },
        { "We met on Monday, actually, Tuesday.", "We met on Tuesday." },
        { "Let's do it tomorrow, scratch that, let's do it Monday.", "Let's do it Monday." },
        { "We'll go. Scratch that, we'll stay.", "We'll stay." },
        { "I went home, I mean I went to the office.", "I went to the office." },
        // From a Gmail dictation: markers people chain, and a time said as
        // two numbers.
        { "Let's have a meeting on Thursday, wait actually Saturday at 3 p.m.", "Let's have a meeting on Saturday at 3 p.m." },
        { "Let's meet at 3 p.m. Wait actually no 7 30 p.m. where we can talk.", "Let's meet at 7 30 p.m. where we can talk." },
        { "Let's actually have a meeting on Thursday, wait actually Saturday at 3 p.m. Wait actually no 7 30 p.m. where we can talk about your product.", "Let's actually have a meeting on Saturday at 7 30 p.m. where we can talk about your product." },
        { "Meet at 2 30, no wait, 3.", "Meet at 3." },
        { "I'll be there Friday, wait, Saturday.", "I'll be there Saturday." },
        { "We meet Friday, actually no, Saturday.", "We meet Saturday." },
        // The replacement restates the sentence: "let's make that 4pm".
        { "Let's meet tomorrow at 7pm. Wait, actually let's make that 4pm.", "Let's meet tomorrow at 4pm." },
        { "Meet at 2, no wait, make that 3.", "Meet at 3." },
        { "Let's do Friday, wait no, let's do Thursday.", "Let's do Thursday." },
        // Times and numbers, every marker and lead-in people use.
        { "Let's meet at 7pm. Wait, make that 4pm.", "Let's meet at 4pm." },
        { "Let's meet at 7pm. Actually, 4pm.", "Let's meet at 4pm." },
        { "Let's meet at 7pm. Actually, let's make it 4pm.", "Let's meet at 4pm." },
        { "Let's meet at 7pm. Actually let's say 4pm.", "Let's meet at 4pm." },
        { "Let's meet at 7pm. Sorry, I meant 4pm.", "Let's meet at 4pm." },
        { "Let's meet at 7pm, I mean 4pm.", "Let's meet at 4pm." },
        { "Let's meet at 7pm, or rather 4pm.", "Let's meet at 4pm." },
        { "Let's meet at 7pm, correction, 4pm.", "Let's meet at 4pm." },
        { "Let's meet at 7pm. Wait, no, let's make that 4pm.", "Let's meet at 4pm." },
        { "Let's meet at 7pm. Oh wait, actually 4pm.", "Let's meet at 4pm." },
        { "Let's meet at 7pm, no wait, 4pm works better.", "Let's meet at 4pm works better." },
        { "The meeting is at three, no, four o'clock.", "The meeting is at three, no, four o'clock." },
        { "The meeting is at three, no wait, four o'clock.", "The meeting is at four o'clock." },
        { "It costs $20, no wait, $30.", "It costs $30." },
        { "Call me at 3:30, I mean 4:30.", "Call me at 4:30." },
        { "We need 50 units, sorry, 500 units.", "We need 500 units." },
        { "Let's meet at 7pm tomorrow. Wait, actually let's make that 4pm tomorrow.", "Let's meet at 4pm tomorrow." },
        // Compound replacements: the new value is several parts (day, "at",
        // time) and replaces the whole old phrase, not one token.
        { "Hey, let's meet tomorrow at 3pm. Actually, let's make that Tuesday at 2pm.", "Hey, let's meet Tuesday at 2pm." },
        { "Hey, let's meet tomorrow at 3pm actually, let's make that Tuesday at 2pm.", "Hey, let's meet Tuesday at 2pm." },
        { "Let's meet tomorrow at 3pm, wait no, Tuesday at 2pm.", "Let's meet Tuesday at 2pm." },
        { "Let's meet tomorrow at 3pm wait no Tuesday at 2pm", "Let's meet Tuesday at 2pm" },
        { "Let's meet tomorrow at 3pm. No wait, Tuesday at 2pm.", "Let's meet Tuesday at 2pm." },
        { "Let's meet tomorrow at 3pm. Oh wait, Tuesday at 2pm.", "Let's meet Tuesday at 2pm." },
        { "Let's meet tomorrow at 3pm, sorry, Tuesday at 2pm.", "Let's meet Tuesday at 2pm." },
        { "Let's meet tomorrow at 3pm, I mean Tuesday at 2pm.", "Let's meet Tuesday at 2pm." },
        { "Let's meet tomorrow at 3pm, or rather Tuesday at 2pm.", "Let's meet Tuesday at 2pm." },
        { "Let's meet tomorrow at 3pm. Correction, Tuesday at 2pm.", "Let's meet Tuesday at 2pm." },
        { "Let's meet tomorrow at 3pm. Make that Tuesday at 2pm.", "Let's meet Tuesday at 2pm." },
        { "Let's meet tomorrow at 3pm. Actually, let's say Tuesday at 2pm.", "Let's meet Tuesday at 2pm." },
        { "Let's meet tomorrow at 3pm. Sorry, I meant Tuesday at 2pm.", "Let's meet Tuesday at 2pm." },
        { "Let's meet tomorrow at 3pm. Actually, how about Tuesday at 2pm?", "Let's meet Tuesday at 2pm?" },
        { "Let's meet tomorrow at 3 p.m. Wait, Tuesday at 2 p.m.", "Let's meet Tuesday at 2 p.m." },
        { "The deadline is Monday the 5th, no wait, Tuesday the 6th.", "The deadline is Tuesday the 6th." },
        { "The deadline is Monday the 5th no wait Tuesday the 6th", "The deadline is Tuesday the 6th" },
        { "Let's meet at 3 in the park, no wait, at 4 in the park.", "Let's meet at 4 in the park." },
        { "Her birthday is June 3rd, sorry, July 3rd.", "Her birthday is July 3rd." },
        { "Her birthday is June 3rd, I mean July 4th.", "Her birthday is July 4th." },
        { "The flight leaves Friday at 6 am, wait no, Saturday at 7 am.", "The flight leaves Saturday at 7 am." },
        { "Send it to Sarah from sales, sorry, Tom from marketing.", "Send it to Tom from marketing." },
        { "Book a table for 4 at 7, actually, for 6 at 8.", "Book a table for 6 at 8." },
        // Every marker on a plain value, with and without commas.
        { "Call me at 5, wait, 6.", "Call me at 6." },
        { "Call me at 5 no wait 6", "Call me at 6" },
        { "Call me at 5 wait no 6", "Call me at 6" },
        { "Call me at 5. Oh wait, 6.", "Call me at 6." },
        { "Call me at 5. Sorry, 6.", "Call me at 6." },
        { "Call me at 5, or rather 6.", "Call me at 6." },
        { "Call me at 5. Correction, 6.", "Call me at 6." },
        { "Call me at 5, make that 6.", "Call me at 6." },
        { "Call me at 5, I mean 6.", "Call me at 6." },
        { "Call me at 5. Actually, it's 6.", "Call me at 6." },
        { "The budget is $500, wait no, $700.", "The budget is $700." },
        { "The budget is 500 dollars, sorry, 700 dollars.", "The budget is 700 dollars." },
        { "We grew 20%, I mean 25%.", "We grew 25%." },
        { "The meeting is on Wednesday. Wait, no, Thursday.", "The meeting is on Thursday." },
        { "The launch is in September, actually, October.", "The launch is in October." },
        { "Ask Priya, I mean Maria.", "Ask Maria." },
        { "We're flying to Denver, no wait, Boston.", "We're flying to Boston." },
        { "Meet me at Starbucks, sorry, Peet's.", "Meet me at Peet's." },
        // Plain words: only after an unmistakable marker, or "or rather".
        { "Bring the red folder, wait no, the blue folder.", "Bring the blue folder." },
        { "I'll take the train, no wait, the bus.", "I'll take the bus." },
        { "It was good, or rather great.", "It was great." },
        { "Meet me in the lobby, wait no, in the garden.", "Meet me in the garden." },
        // Chained twice, and two corrections in one dictation.
        { "Meet at 3, no wait, 4, no wait, 5.", "Meet at 5." },
        { "Let's do Monday, actually, Tuesday, no wait, Wednesday.", "Let's do Wednesday." },
        { "Meet at 3, wait, 4. Bring Tom, sorry, Sam.", "Meet at 4. Bring Sam." },
        { "Lunch on Friday, wait no, Thursday. Dinner at 7, I mean 8.", "Lunch on Thursday. Dinner at 8." },
        { "Fly out Monday at 9, no wait, Tuesday at 10, and back Friday, sorry, Saturday.", "Fly out Tuesday at 10, and back Saturday." },
        // Lowercase, unpunctuated speech-to-text.
        { "lets meet at 3 wait no 4", "lets meet at 4" },
        { "send it to sarah wait no john", "send it to sarah wait no john" },
        // Compound negatives: an answer, a list, a new thought.
        { "Is it Monday at 3? No, Tuesday at 4.", "Is it Monday at 3? No, Tuesday at 4." },
        { "I'm free Monday, actually Tuesday too.", "I'm free Monday, actually Tuesday too." },
        { "I'll pay 20 dollars, actually, 30 is fine.", "I'll pay 20 dollars, actually, 30 is fine." },
        { "I'll pay 20 dollars, no wait, 30 is fine.", "I'll pay 20 dollars, no wait, 30 is fine." },
        { "We met on Monday, sorry, Tuesday was busy.", "We met on Monday, sorry, Tuesday was busy." },
        { "I like Monday at 3, I mean it, Tuesday at 4 is worse.", "I like Monday at 3, I mean it, Tuesday at 4 is worse." },
        { "Call Sarah, actually Tom is out today.", "Call Sarah, actually Tom is out today." },
        { "It's the red one, I mean the one by the door.", "It's the red one, I mean the one by the door." },
        { "Sorry, I meant to call you at 5.", "Sorry, I meant to call you at 5." },
        { "Actually, let's make that work on Tuesday.", "Actually, let's make that work on Tuesday." },
        { "Make that happen by Friday.", "Make that happen by Friday." },
        { "Correction fluid is on the desk.", "Correction fluid is on the desk." },
        { "I'd rather go on Monday.", "I'd rather go on Monday." },
        { "Wait no longer than 5 minutes.", "Wait no longer than 5 minutes." },
        { "Sorry Tom, Sarah is out until Monday.", "Sorry Tom, Sarah is out until Monday." },
        { "It was good, I mean really good.", "It was good, I mean really good." },
        { "I'm sorry, Monday doesn't work.", "I'm sorry, Monday doesn't work." },
        { "No, Friday works.", "No, Friday works." },
        { "Oh wait, I forgot the keys.", "Oh wait, I forgot the keys." },
        { "Never mind, it's fine.", "Never mind, it's fine." },
        { "The train is red, no wait, it's the bus that's red.", "The train is red, no wait, it's the bus that's red." },
        { "I said Monday, actually.", "I said Monday, actually." },
        { "He scored 3, then 4, then 5.", "He scored 3, then 4, then 5." },
        { "Monday, Tuesday, or Wednesday all work.", "Monday, Tuesday, or Wednesday all work." },
        // A lead-in sets off a weak marker, but "actually make that" is
        // still not one; a changed plain word needs a full replacement.
        { "We could actually make that work by Friday.", "We could actually make that work by Friday." },
        { "I actually make it 5 times a week.", "I actually make it 5 times a week." },
        { "I'd actually say Monday at 3 works.", "I'd actually say Monday at 3 works." },
        { "Bring the red folder, wait no, the blue folder is better.", "Bring the red folder, wait no, the blue folder is better." },
        { "Bring the red folder wait no the blue folder", "Bring the red folder wait no the blue folder" },
        { "Pick the big red box, wait no, the small blue box.", "Pick the big red box, wait no, the small blue box." },
        // Days, months, names.
        { "Let's meet on Monday. Actually, let's make it Tuesday.", "Let's meet on Tuesday." },
        { "Let's meet Monday. Wait, I meant Tuesday.", "Let's meet Tuesday." },
        { "It is due on March 5th, no wait, March 6th.", "It is due on March 6th." },
        { "The party is in June, sorry, July.", "The party is in July." },
        { "Tell John, actually tell Mike.", "Tell Mike." },
        { "Send it to Sarah, no wait, send it to Sam.", "Send it to Sam." },
        { "Email Sarah, wait, I mean Sam, about the report.", "Email Sam, about the report." },
        { "Invite Priya, no wait, Priyanka.", "Invite Priyanka." },
        // Plain words, only after an unmistakable marker.
        { "I like cats, wait no, dogs.", "I like dogs." },
        // Unpunctuated, so "is" below could just as well be a swap: left alone.
        { "There is no wait, fine.", "There is no wait, fine." },
        { "He said yes, wait no, it's fine.", "He said yes, wait no, it's fine." },
        // New rules must not reach too far.
        { "I'll call at 5, actually it's raining, so no.", "I'll call at 5, actually it's raining, so no." },
        { "He told me to ignore that. Fine.", "He told me to ignore that. Fine." },
        { "Please strike that chord again.", "Please strike that chord again." },
        { "It is the 5th, I mean it, we are late.", "It is the 5th, I mean it, we are late." },
        { "Oh, that is great news.", "Oh, that is great news." },
        // Whole-clause retractions.
        { "Let's go to the park. Strike that. Let's go home.", "Let's go home." },
        { "Order pizza, scratch that, order sushi.", "Order sushi." },
        { "We should leave now, ignore that, we should wait.", "We should wait." },
        // "scratch that" after a filler word or without commas, and a value
        // swap that keeps the words around it.
        { "it'll be like 10 to 20, actually scratch that, it'll be like 10 to 30 seconds long and it's just going to be a short and punchy reel", "it'll be like 10 to 30 seconds long and it's just going to be a short and punchy reel" },
        { "it'll be like 10 to 20 actually scratch that it'll be like 10 to 30 seconds long", "it'll be like 10 to 30 seconds long" },
        { "It'll be like 10 to 20, actually, scratch that, it'll be like 10 to 30 seconds.", "It'll be like 10 to 30 seconds." },
        { "It'll be like 10 to 20, wait, scratch that, 10 to 30 seconds.", "It'll be like 10 to 30 seconds." },
        { "it's gonna be 4 p.m., scratch that, 5 p.m. that works", "it's gonna be 5 p.m. that works" },
        { "Let's meet at 4 p.m., scratch that, 5 p.m.", "Let's meet at 5 p.m." },
        { "Let's meet at 4 p.m. Scratch that. 5 p.m. works.", "Let's meet at 5 p.m. works." },
        { "Let's meet at 4 pm, scratch that, 5 pm works for me.", "Let's meet at 5 pm works for me." },
        { "It starts at 4, actually scratch that, 5.", "It starts at 5." },
        { "Meet on Friday, oh scratch that, Thursday.", "Meet on Thursday." },
        { "Okay scratch that, the budget is 20 dollars.", "Okay scratch that, the budget is 20 dollars." },
        { "Send it to Sarah, scratch that, send it to Sam.", "Send it to Sam." },
        { "I'll call him tomorrow, scratch that, I'll text him instead.", "I'll text him instead." },
        { "Buy milk. Actually scratch that. Buy eggs.", "Buy eggs." },
        { "Let's go to the park, actually scratch that, let's go home.", "Let's go home." },
        { "Let's go to the park, um, scratch that, let's go home.", "Let's go home." },
        { "First line.\nActually scratch that, second line.", "Second line." },
        { "Call Sam at 3, scratch that, scratch that, call Sam at 4.", "Call Sam at 4." },
        { "Pay 20 dollars, strike that, pay 30 dollars.", "Pay 30 dollars." },
        { "Ship it Monday, disregard that, ship it Friday.", "Ship it Friday." },
        { "Let's meet at 4, scratch that", "Let's meet at 4, scratch that" },
        { "We'll go at 6 am, scratch that, 7 am, and then eat.", "We'll go at 7 am, and then eat." },
        // "actually no not a short, <restart>": the negated phrase is skipped
        { "let's make the demo video 45 minutes and then we'll just add a short, actually no not a short, we'll just add a long youtube video", "let's make the demo video 45 minutes and then we'll just add a long youtube video" },
        { "We'll add a short, no wait not a short, we'll add a long video.", "We'll add a long video." },
        { "I want a red one, actually not a red one, I want a blue one.", "I want a blue one." },
        { "It is not a short, it is long.", "It is not a short, it is long." },
        { "I like it, actually not bad, I mean good.", "I like it, actually not bad, I mean good." },
        // not commands
        { "Please, scratch that itch.", "Please, scratch that itch." },
        { "You can scratch that itch later, actually.", "You can scratch that itch later, actually." },
        { "I need to scratch that itch.", "I need to scratch that itch." },
        { "Actually scratch that.", "Actually scratch that." },
        { "The cat will scratch that couch, probably.", "The cat will scratch that couch, probably." },
        { "He told me to strike that chord, actually.", "He told me to strike that chord, actually." },
        // stutters and restarts
        { "the the meeting is at noon", "the meeting is at noon" },
        { "The the meeting is at noon.", "The meeting is at noon." },
        { "I I think so.", "I think so." },
        { "we should we should go now", "we should go now" },
        // hedges, only where commas set them off
        { "Basically, we need more users.", "We need more users." },
        { "It was, you know, kind of weird.", "It was kind of weird." },
        { "That's the plan, I guess.", "That's the plan." },
        // negatives: must come back untouched
        { "No, I don't think so.", "No, I don't think so." },
        // An answer, not a correction: a lone "no" is never a marker.
        { "Is it Friday? No, Thursday.", "Is it Friday? No, Thursday." },
        { "I'll be there at 5, wait for me.", "I'll be there at 5, wait for me." },
        { "Wait, let me check.", "Wait, let me check." },
        { "I actually liked it.", "I actually liked it." },
        { "Is Friday or Thursday better?", "Is Friday or Thursday better?" },
        // Decided: emphasis, not a correction. Nothing precedes the
        // marker, so there is nothing for it to replace.
        { "no no no I love it", "no no no I love it" },
        { "I like both, I mean really both.", "I like both, I mean really both." },
        { "I'm sorry, Sarah, I can't make it.", "I'm sorry, Sarah, I can't make it." },
        { "I can't make it to Paris, sorry, Tom will go instead.", "I can't make it to Paris, sorry, Tom will go instead." },
        { "I'll pay 20, actually, 30 is fine.", "I'll pay 20, actually, 30 is fine." },
        { "There is no wait time on Friday.", "There is no wait time on Friday." },
        { "I know that that is true.", "I know that that is true." },
        { "I gave her her book.", "I gave her her book." },
        { "It was very very good.", "It was very very good." },
        { "I guess so.", "I guess so." },
        { "I kind of like it.", "I kind of like it." },
        { "You know the answer.", "You know the answer." },
        { "It was good, kind of.", "It was good, kind of." },
        { "Please scratch that itch.", "Please scratch that itch." },
        // Collapsing would need "three coffees", an insertion; "Order
        // three." would drop a word the user meant. Left alone.
        { "Order two coffees, make that three.", "Order two coffees, make that three." },
        { "I would like a coffee.", "I would like a coffee." },
        // Widened rules: plain swaps, sentence-start names, commands, restarts, false starts.
        { "Make the button blue, I mean green.", "Make the button green." },
        { "Put the logo on the left, sorry, the right.", "Put the logo on the right." },
        { "Use a dropdown, actually no, a toggle.", "Use a toggle." },
        { "Tell John. Wait, no. Mike.", "Tell Mike." },
        { "I want you to refactor the whole file. Actually, just refactor the render function.", "I want you to just refactor the render function." },
        { "Can you rewrite this in Rust? Actually, never mind, keep it in Swift.", "Keep it in Swift." },
        { "First fix the tests. Wait, no, first pull the latest changes.", "First pull the latest changes." },
        { "Delete the old migration. Wait, don't delete it, just rename it.", "Just rename it." },
        { "Can you make the, can you change the font size?", "Can you change the font size?" },
        { "Let's ship today, start over, let's ship tomorrow.", "Let's ship tomorrow." },
        { "Turn left, I mean right.", "Turn right." },
        { "Make it bigger, sorry, smaller.", "Make it smaller." },
        { "I'll have the soup, actually, the salad.", "I'll have the salad." },
        { "Order the pasta, I meant the pizza.", "Order the pizza." },
        { "Tell John. Wait, no. Tell Mike.", "Tell Mike." },
        { "I'll go, wait no, I'll stay.", "I'll stay." },
        { "Delete it. Actually, don't delete it, archive it.", "Archive it." },
        { "Can you rewrite this in Rust? Never mind, keep it in Swift.", "Keep it in Swift." },
        { "Make it blue, undo that, make it green.", "Make it green." },
        { "So, can you make the, can you change the font size?", "So, can you change the font size?" },
        { "We should go, I mean soon.", "We should go, I mean soon." },
        { "Great job, I mean that.", "Great job, I mean that." },
        { "It's not red, I mean blue.", "It's not red, I mean blue." },
        { "Tell John. Sorry. Mike.", "Tell John. Sorry. Mike." },
        { "Ask John. Wait, no. Thanks.", "Ask John. Wait, no. Thanks." },
        { "I'm tired. Actually, I'm going to bed.", "I'm tired. Actually, I'm going to bed." },
        { "What are you looking at, what are you doing?", "What are you looking at, what are you doing?" },
        { "Look at the last commit, undo that, and rerun the tests.", "Look at the last commit, undo that, and rerun the tests." },
        { "If it fails, start over, then check the logs.", "If it fails, start over, then check the logs." },
        { "Oh, never mind, it's fine.", "Oh, never mind, it's fine." },
        { "Okay, actually never mind, it's fine.", "Okay, actually never mind, it's fine." },
        { "I'll call him, never mind.", "I'll call him, never mind." },
        { "It's raining, never mind, we'll go anyway.", "It's raining, never mind, we'll go anyway." },
        { "We need to start over from scratch.", "We need to start over from scratch." },
        { "Please delete that file.", "Please delete that file." },
        { "Thanks for the gift, sorry, the late reply.", "Thanks for the gift, sorry, the late reply." },
    };

    [Theory]
    [MemberData(nameof(Pure))]
    public void CollapsesOnlyWhatWasMeant(string raw, string want) => Assert.Equal(want, SelfCorrection.Apply(raw));

    [Fact]
    public void TheDeletionOnlyGuard()
    {
        Assert.True(SelfCorrection.IsDeletionOnly("meet at 2, no wait, 3", "meet at 3"));
        Assert.False(SelfCorrection.IsDeletionOnly("meet at 2", "meet at 3"));
        Assert.False(SelfCorrection.IsDeletionOnly("meet at 2", "at meet 2"));
        Assert.False(SelfCorrection.IsDeletionOnly("meet at 2", "meet me at 2"));
    }

    [Fact]
    public void HasMarkerSeesWhatTheRulesLeftStanding()
    {
        Assert.True(SelfCorrection.HasMarker("It was good, I mean really good."));
        Assert.True(SelfCorrection.HasMarker("Let's ship today, start over, let's ship tomorrow."));
        Assert.False(SelfCorrection.HasMarker("Make the button green."));
        Assert.False(SelfCorrection.HasMarker("Never mind, it's fine."));
    }
}
