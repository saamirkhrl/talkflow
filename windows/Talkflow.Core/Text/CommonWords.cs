namespace Talkflow.Core.Text;

/// <summary>
/// Everyday English words that open sentences, used where the Mac app asks
/// NLTagger whether a capitalised word is a name. A word on this list is never
/// treated as a name; a word off it keeps its capital. Erring towards keeping a
/// capital is the safe side: a stray capital is a smaller error than "sarah".
/// </summary>
public static class CommonWords
{
    public static bool Contains(string lowercased) => Words.Contains(lowercased);

    static readonly HashSet<string> Words = new(StringComparer.Ordinal)
    {
        // Function words
        "a", "about", "above", "after", "again", "against", "all", "also", "although", "always", "am", "an", "and",
        "another", "any", "anyone", "anything", "anyway", "are", "around", "as", "at", "because", "been", "before",
        "being", "below", "between", "both", "but", "by", "can", "cannot", "could", "did", "do", "does", "doing",
        "down", "during", "each", "either", "else", "even", "ever", "every", "everyone", "everything", "few", "for",
        "from", "further", "had", "has", "have", "having", "he", "her", "here", "hers", "herself", "him", "himself",
        "his", "how", "however", "if", "in", "into", "is", "it", "its", "itself", "just", "least", "less", "let",
        "like", "many", "may", "maybe", "me", "might", "more", "most", "much", "must", "my", "myself", "neither",
        "never", "no", "nobody", "none", "nor", "not", "nothing", "now", "of", "off", "often", "on", "once", "one",
        "only", "or", "other", "others", "otherwise", "our", "ours", "ourselves", "out", "over", "own", "perhaps",
        "please", "quite", "rather", "really", "same", "she", "should", "since", "so", "some", "somebody", "someone",
        "something", "sometimes", "somewhere", "still", "such", "than", "that", "the", "their", "theirs", "them",
        "themselves", "then", "there", "therefore", "these", "they", "this", "those", "though", "through", "thus",
        "to", "together", "too", "toward", "towards", "under", "unless", "until", "up", "upon", "us", "very", "was",
        "we", "were", "what", "whatever", "when", "whenever", "where", "wherever", "whether", "which", "while", "who",
        "whoever", "whole", "whom", "whose", "why", "will", "with", "within", "without", "would", "yet", "you",
        "your", "yours", "yourself", "yourselves",
        // Contractions
        "i'm", "i've", "i'll", "i'd", "you're", "you've", "you'll", "you'd", "he's", "she's", "it's", "we're",
        "we've", "we'll", "we'd", "they're", "they've", "they'll", "they'd", "that's", "there's", "here's", "what's",
        "who's", "where's", "how's", "let's", "don't", "doesn't", "didn't", "can't", "couldn't", "won't", "wouldn't",
        "shouldn't", "isn't", "aren't", "wasn't", "weren't", "haven't", "hasn't", "hadn't", "mustn't",
        // Openers and replies
        "yes", "yeah", "yep", "nope", "okay", "ok", "sure", "thanks", "thank", "hello", "hi", "hey", "sorry", "well",
        "oh", "wow", "great", "good", "nice", "cool", "awesome", "perfect", "fine", "right", "alright", "actually",
        "basically", "honestly", "hopefully", "apparently", "anyway", "besides", "meanwhile", "finally", "first",
        "second", "third", "next", "last", "lastly", "also", "additionally", "instead", "otherwise", "overall",
        "definitely", "probably", "certainly", "absolutely", "exactly", "totally", "seriously", "literally",
        "unfortunately", "fortunately", "luckily", "obviously", "clearly", "generally", "usually", "normally",
        "recently", "currently", "today", "tomorrow", "yesterday", "tonight", "soon", "later", "already",
        // Common verbs
        "add", "agree", "allow", "answer", "ask", "be", "become", "begin", "believe", "bring", "build", "buy", "call",
        "change", "check", "choose", "close", "come", "consider", "continue", "create", "cut", "decide", "delete",
        "do", "done", "draw", "drink", "drive", "drop", "eat", "email", "end", "enjoy", "explain", "fall", "feel",
        "fill", "find", "finish", "fix", "follow", "forget", "forward", "get", "give", "go", "going", "gonna",
        "got", "grab", "guess", "happen", "hear", "help", "hold", "hope", "imagine", "include", "keep", "know",
        "learn", "leave", "lend", "let", "listen", "live", "look", "lose", "love", "make", "mean", "meet", "mention",
        "message", "mind", "miss", "move", "need", "note", "notice", "offer", "open", "order", "pay", "pick", "plan",
        "play", "post", "prefer", "prepare", "print", "pull", "push", "put", "read", "reach", "receive", "remember",
        "remind", "remove", "reply", "report", "review", "run", "save", "say", "said", "see", "seem", "sell", "send",
        "sent", "set", "share", "show", "sign", "sit", "sleep", "sorry", "speak", "spend", "stand", "start", "stay",
        "stop", "suggest", "support", "take", "talk", "teach", "tell", "text", "think", "thought", "try", "turn",
        "understand", "update", "upload", "use", "used", "visit", "wait", "walk", "want", "wanted", "was", "watch",
        "wish", "wonder", "work", "worked", "working", "write", "wrote",
        // Common nouns and adjectives
        "able", "account", "address", "afternoon", "again", "age", "ago", "anyone", "app", "apps", "area", "back",
        "bad", "best", "better", "big", "bit", "book", "budget", "business", "busy", "car", "case", "chance",
        "child", "children", "city", "class", "company", "computer", "customer", "customers", "data", "date", "day",
        "days", "deal", "deck", "different", "dinner", "doc", "document", "draft", "early", "easy", "email",
        "evening", "event", "everybody", "example", "fact", "family", "fast", "feedback", "file", "files", "folks",
        "food", "free", "friend", "friends", "full", "fun", "game", "glad", "guys", "half", "happy", "hard", "head",
        "high", "home", "hour", "hours", "house", "idea", "ideas", "important", "info", "interesting", "issue",
        "issues", "job", "kind", "large", "late", "launch", "life", "line", "list", "little", "long", "lot", "lots",
        "low", "lunch", "main", "man", "meeting", "minute", "minutes", "moment", "money", "month", "months",
        "morning", "name", "new", "news", "night", "number", "office", "old", "page", "part", "party", "people",
        "person", "phone", "photo", "place", "plans", "point", "possible", "pretty", "price", "problem", "product",
        "project", "question", "questions", "quick", "quickly", "ready", "real", "reason", "rest", "room", "sale",
        "school", "sense", "short", "side", "simple", "small", "so", "sounds", "special", "story", "student",
        "students", "stuff", "super", "sure", "system", "team", "thing", "things", "time", "times", "true", "two",
        "three", "four", "five", "six", "seven", "eight", "nine", "ten", "unit", "user", "users", "version",
        "video", "water", "way", "ways", "week", "weekend", "weeks", "welcome", "woman", "word", "words", "world",
        "year", "years", "young", "dear", "regards", "sincerely", "cheers", "congrats", "congratulations",
    };
}
