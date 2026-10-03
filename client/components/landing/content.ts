// Copy and demo data for the landing page. Every product claim here is checked
// against the app's source; keep it that way when editing.

export const REPO_URL = "https://github.com/saamirkhrl/talkflow";
export const DOWNLOAD_URL = `${REPO_URL}/releases/latest`;

// Apple's and Microsoft's trademark guidelines restrict use of their logos
// without permission. Set to false to show text-only download buttons.
export const SHOW_OS_LOGOS = true;

// What gets dictated into each app in the "Say the whole thought" scroll demo.
// "\n" marks a line break in the finished text. Like the app, the blank lines
// around an email's greeting and sign-off only appear once fn is released
// (Dictation.render runs StructurePolish on the final pass only).
export const DICTATIONS = {
  claudeCode:
    "So the checkout form is double submitting when someone taps pay twice on a slow connection. Can you add a loading state that disables the button after the first click and shows a small spinner inside it? Also make sure it resets if the request fails, and add a test for the retry case.",
  messages:
    "Yes, on my way! The train got stuck outside Canal Street for twenty minutes, so I'm running a bit late. Order me the spicy noodles if you can, and the next round is on me.",
  gmail:
    "Hi Daniel,\n\nThanks for sending the contract over. I read through it this morning and it all looks good, apart from the payment terms in section four. Could we move those to thirty days instead of fifteen? Happy to jump on a quick call this week if that's easier.\n\nBest, Alex",
  whatsapp:
    "Count me in! I'll grab a cheesecake from the bakery on the way, and I can pick up Grandma if she needs a lift. Should be there around one.",
  slack:
    "It's merged and on staging. The double submit is gone, and I added a test for the retry case. QA can start whenever they're ready, and if nothing turns up we can ship tomorrow morning.",
  notion:
    "Start with onboarding. Most people who drop off do it before day three, so let's rewrite the welcome emails and add a short checklist to the dashboard. We should also keep one person on support rotation so bug fixes don't stall.",
};

export const FAQ: [question: string, answer: string][] = [
  [
    "Is it really free?",
    "Yes. No trial, no tiers, no subscription. TalkFlow is open source under the MIT License and runs on your own Mac, so there's nothing to pay for.",
  ],
  [
    "Does anything get sent to the cloud?",
    "No. Your audio goes to one place: the speech engine running on your own Mac. The text is typed straight into the app you're using. There's no account, no analytics and no update check.",
  ],
  [
    "Which key do I hold?",
    "fn, the Globe key in the bottom-left corner of Mac keyboards. Hold it while you talk and let go when you're done.",
  ],
  [
    "Does it rewrite what I say?",
    "No. It types what you said. It removes filler sounds like \"um\" and \"uh\", and it follows spoken commands such as \"comma\", \"question mark\", \"new paragraph\" and emoji names like \"rocket emoji\". It never rephrases your sentences.",
  ],
  [
    "Which languages does it support?",
    "English. TalkFlow uses Whisper's English speech model, which is fast and accurate for English but doesn't transcribe other languages.",
  ],
  [
    "Does it work offline?",
    "Yes. Once it's set up, turn off Wi-Fi and TalkFlow works exactly the same.",
  ],
  [
    "What do I need to run it?",
    "A Mac with macOS 13 or later. It's built and tested on Apple silicon. The speech model needs about 500 MB of disk space. A Windows version is planned.",
  ],
];

// What the TalkFlow dashboard shows, with example numbers.
export const DASHBOARD = [
  { label: "Words dictated", value: "44,612", unit: "" },
  { label: "Average speed", value: "145", unit: "wpm" },
  { label: "Words today", value: "1,208", unit: "" },
  { label: "Day streak", value: "52", unit: "days" },
  { label: "Time saved", value: "13.5", unit: "hours" },
  { label: "Dictations", value: "2,316", unit: "" },
];
