// Copy and demo data for the landing page. Every product claim here is checked
// against the app's source; keep it that way when editing.

export const REPO_URL = "https://github.com/saamirkhrl/talkflow";
// The newest Mac build itself, not the releases page: GitHub serves the asset
// named here from whichever release is latest, so the link never goes stale.
// release.sh publishes the zip under exactly this name.
export const MAC_DOWNLOAD_URL = `${REPO_URL}/releases/latest/download/talkflow-macos.zip`;
export const RELEASES_URL = `${REPO_URL}/releases`;
// Under "macOS" in the list of builds. The release is a universal binary.
export const MAC_BUILD_DETAIL = "Apple Silicon and Intel, macOS 13+";
// Served from this site (client/public/install.sh): downloads the latest
// release, installs it to /Applications and opens it.
export const INSTALL_SCRIPT_PATH = "/install.sh";

// Apple's and Microsoft's trademark guidelines restrict use of their logos
// without permission. Set to false to show text-only download buttons.
export const SHOW_OS_LOGOS = true;

// There is no Windows build yet (see the FAQ). While this is false the site
// offers only the Mac download and says Windows is coming, instead of
// advertising a Windows download that doesn't exist.
export const WINDOWS_AVAILABLE: boolean = false;

// What gets dictated into each app in the "Say the whole thought" scroll demo.
// "\n" marks a line break in the finished text. Like the app, the blank lines
// around an email's greeting and sign-off only appear once fn is released
// (Dictation.render runs StructurePolish on the final pass only).
export const DICTATIONS = {
  claudeCode:
    "Okay, we're launching on Hacker News tomorrow morning and I'm worried the waitlist falls over. Can you add rate limiting per IP, move the welcome email onto a queue so it doesn't block the request, and write a quick load test so we can see where it breaks? Also make sure we're not logging anyone's email in plain text.",
  messages:
    "Yes, on my way! Parking around South Park is a nightmare, so I'm running about ten minutes late. Order me whatever you're having, and the next round is on me.",
  gmail:
    "Hi Daniel,\n\nThanks for making time on Tuesday. As promised, the deck and our latest numbers are attached. Launch week brought in about 2,400 signups, mostly from Hacker News, and we're aiming to close the round in the next three weeks. Happy to walk your partners through it whenever suits them.\n\nBest, Alex",
  whatsapp:
    "Count me in! I'll grab a cheesecake from the bakery on the way, and I can pick up Grandma if she needs a lift. Should be there around one.",
  slack:
    "We're good. Rate limiting is in, the welcome emails go through a queue now, and I load tested it to about 2,000 requests a second. I'll post at 8 a.m. Pacific, so try to be around for the first couple of hours to answer comments.",
  notion:
    "Start with onboarding. Most people who drop off do it before day three, so let's rewrite the welcome emails and add a short checklist to the dashboard. We should also reply to every Hacker News comment we missed, since that thread is still sending signups.",
};

// Wispr Flow Pro's monthly price, from wisprflow.ai/pricing (checked
// 2026-10-02: $15/user/mo billed monthly, $12 billed yearly). Shown struck
// through next to the hero download button. Re-check before changing copy.
export const WISPR_FLOW_PRICE = "$15/mo";

export const FAQ: [question: string, answer: string][] = [
  [
    "How is it different from Wispr Flow?",
    "Wispr Flow Pro costs $15 a month, or $12 a month billed yearly, and Wispr Flow's free plan stops at 2,000 words a week on desktop. talkflow is free with no word limit, it's open source, and the speech engine runs on your own Mac.",
  ],
  [
    "Is it really free?",
    "Yes. No trial, no tiers, no subscription. talkflow is open source under the MIT License and runs on your own Mac, so there's nothing to pay for.",
  ],
  [
    "Does anything get sent to the cloud?",
    "No. Your audio goes to one place: the speech engine running on your own Mac. The text is typed straight into the app you're using. There's no account and no analytics. The only other request it makes is to GitHub, to see if there's a newer version when you open the dashboard, and an update only installs when you click it.",
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
    "English. talkflow uses Whisper's English speech model, which is fast and accurate for English but doesn't transcribe other languages.",
  ],
  [
    "Does it work offline?",
    "Yes. Once it's set up, turn off Wi-Fi and talkflow works exactly the same.",
  ],
  [
    "What do I need to run it?",
    "A Mac with macOS 13 or later. It's built and tested on Apple silicon. The speech model needs about 500 MB of disk space. A Windows version is planned.",
  ],
];

// What the talkflow dashboard shows, with example numbers.
export const DASHBOARD = [
  { label: "Words dictated", value: "44,612", unit: "" },
  { label: "Average speed", value: "145", unit: "wpm" },
  { label: "Words today", value: "1,208", unit: "" },
  { label: "Day streak", value: "52", unit: "days" },
  { label: "Time saved", value: "13.5", unit: "hours" },
  { label: "Dictations", value: "2,316", unit: "" },
];
