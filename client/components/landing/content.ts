// Copy and demo data for the landing page. Every product claim here is checked
// against the app's source; keep it that way when editing.

export const REPO_URL = "https://github.com/saamirkhrl/talkflow";
export const DOWNLOAD_URL = `${REPO_URL}/releases/latest`;

// Apple's and Microsoft's trademark guidelines restrict use of their logos
// without permission. Set to false to show text-only download buttons.
export const SHOW_OS_LOGOS = true;

// The hero demo in "Built for prompting": a request dictated into an agent.
export const PROMPTS = [
  "So the checkout form is double submitting when someone taps pay twice on a slow connection. Can you add a loading state that disables the button after the first click and shows a small spinner inside it? Also make sure it resets if the request fails, and add a test for the retry case.",
  "Let's clean up the pay button before we ship. Pull the price formatting out into a helper that handles currencies properly, keep the button label short on small screens, and write a couple of tests so we don't break it again next week.",
];

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
