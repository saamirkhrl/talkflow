// Copy and demo data for the landing page, lifted verbatim from the
// "TalkFlow Landing" design export.

// Drop real assets into /public and point these at them. While a value is
// null the page shows the design's placeholder frame; for the hero, the
// animated dictation mock stands in until a recording exists.
export const MEDIA = {
  heroRecording: null as string | null,
  promptTerminal: null as string | null,
  founderAvatar: null as string | null,
};

export const GITHUB_URL = "https://github.com/";
export const GITHUB_STARS = "1.2k";

export const PROMPTS = [
  "Okay, so the checkout form is double-submitting when someone taps pay twice on a slow connection. Can you add a loading state that disables the button after the first click, and show a small spinner inside it? Also make sure it resets if the request fails, and add a test for the retry case.",
  "Let's clean up the pay button before we ship. Pull the price formatting out into a helper that handles currencies properly, keep the button label short on small screens, and write a couple of tests so we don't break it again next week.",
];

export const CODE = [
  "export function PayButton({ total, onPay }) {",
  "  const label = `Pay ${total}`;",
  "",
  "  return (",
  "    <button",
  '      className="pay"',
  "      onClick={onPay}",
  "    >",
  "      {label}",
  "    </button>",
  "  );",
  "}",
];

export const FAQ: [question: string, answer: string][] = [
  ["Is it really free?", "Yes. No trial, no tiers, no subscription. TalkFlow runs on your computer, so there are no servers to pay for and nothing to upsell."],
  ["Does anything get sent to the cloud?", "No. Speech recognition happens entirely on your device. Audio is processed in memory and discarded the moment your text is inserted. There's no account and no server on the other end."],
  ["Which languages does it support?", "English works best today, with support for many other major languages, including Spanish, French, German, Portuguese and Hindi. You can pick a language or let TalkFlow detect it."],
  ["Does it work offline?", "Completely. Once it's installed, turn off Wi-Fi and TalkFlow works exactly the same, on a plane or anywhere else."],
  ["What are the system requirements?", "macOS 13 or later on Apple silicon or Intel, or Windows 10/11 (64-bit). 8 GB of RAM is recommended, and the speech model needs about 1.5 GB of disk space."],
  ["Mac vs. Windows?", "Same app, same features, same price (free). The only difference is the default hotkey: fn on Mac, Ctrl + Win on Windows. Change it to ⌥ Space, Right ⌘, Caps Lock or any shortcut you like."],
];

export type StatsRange = "week" | "all";
export type Stat = { label: string; value: string; unit: string; note: string };

export const STATS: Record<StatsRange, Stat[]> = {
  all: [
    { label: "Words dictated", value: "45,212", unit: "", note: "≈ 90 pages of text" },
    { label: "Daily streak", value: "51", unit: "days", note: "Longest yet" },
    { label: "Time saved", value: "13.4", unit: "hrs", note: "vs. typing at 45 wpm" },
    { label: "Speaking speed", value: "142", unit: "wpm", note: "3.2× your typing" },
  ],
  week: [
    { label: "Words dictated", value: "6,480", unit: "", note: "+18% vs. last week" },
    { label: "Daily streak", value: "51", unit: "days", note: "7 of 7 days this week" },
    { label: "Time saved", value: "1.9", unit: "hrs", note: "vs. typing at 45 wpm" },
    { label: "Speaking speed", value: "147", unit: "wpm", note: "Your fastest week" },
  ],
};

export const APPS = ["Cursor", "Claude Code", "Notes", "Slack", "Gmail", "Notion", "VS Code", "Terminal", "Messages"];
export const HOTKEYS = ["fn", "⌥ Space", "Right ⌘", "Ctrl Space", "Caps Lock", "F5"];
export const RAW = ["um, so", "can we maybe", "move the standup", "to like…", "ten thirty", "tomorrow", "so Priya can,", "uh, join?", "and also", "ship the fix", "after lunch"];
export const CLEAN = ["Can we move standup to 10:30 tomorrow so Priya can join?", "Also, let's ship the fix after lunch.", "Switch the retry logic to exponential backoff."];
