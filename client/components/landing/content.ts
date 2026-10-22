// Copy and demo data for the landing page. Every product claim here is checked
// against the app's source; keep it that way when editing.

// The home page's title and meta description, which are also the site's
// defaults (app/layout.tsx).
export const SITE_TITLE = "talkflow: talk to your computer, for free";
export const SITE_DESCRIPTION =
  "The free, open-source Wispr Flow alternative. Hold a key, speak, and your words are typed wherever your cursor is. Runs entirely on your Mac or PC.";

export const REPO_URL = "https://github.com/saamirkhrl/talkflow";
// The newest Mac build itself, not the releases page: GitHub serves the asset
// named here from whichever release is latest, so the link never goes stale.
// release.sh publishes the disk image under exactly this name (and a zip of
// the same app, which install.sh and the in-app updater use).
export const MAC_DOWNLOAD_URL = `${REPO_URL}/releases/latest/download/talkflow-macos.dmg`;
export const RELEASES_URL = `${REPO_URL}/releases`;
// Under "macOS" in the list of builds. The release is a universal binary.
export const MAC_BUILD_DETAIL = "Apple Silicon and Intel, macOS 13+";
// Served from this site (client/public/install.sh): downloads the latest
// release, installs it to /Applications and opens it.
export const INSTALL_SCRIPT_PATH = "/install.sh";

// Apple's and Microsoft's trademark guidelines restrict use of their logos
// without permission. Set to false to show text-only download buttons.
export const SHOW_OS_LOGOS = true;

// The Windows installers are attached to every release by
// .github/workflows/windows.yml. Set this to false to offer only the Mac
// download and say Windows is coming instead.
export const WINDOWS_AVAILABLE: boolean = true;
// Windows has one build, x64. It runs on every Windows 10 (1809) and 11 PC,
// Arm PCs included, which run it through Windows' built-in emulation. There is
// no separate Arm build.

// Every build the site offers, by the path it is served from:
// talkflow.live/download/<id> redirects to that release asset (see
// app/download/[build]/route.ts). The README links to these paths too.
//
// The Mac release is one universal app (Apple Silicon and Intel in the same
// binary), so both Mac paths serve the same disk image. Give one its own
// asset name here if separate builds are ever published.
export type BuildId = "mac-apple-silicon" | "mac-intel" | "windows-x64";
// `chips` are what the Mac download page lists on each choice, so people can
// match the one in About This Mac.
export const BUILDS: Record<BuildId, { os: "mac" | "windows"; label: string; chips: string[]; asset: string; available: boolean }> = {
  "mac-apple-silicon": {
    os: "mac",
    label: "Apple Silicon",
    chips: ["M1", "M2", "M3", "M4", "M5"],
    asset: "talkflow-macos.dmg",
    available: true,
  },
  "mac-intel": {
    os: "mac",
    label: "Intel",
    chips: ["Core i3", "Core i5", "Core i7", "Core i9"],
    asset: "talkflow-macos.dmg",
    available: true,
  },
  "windows-x64": {
    os: "windows",
    label: "Windows",
    chips: [],
    asset: "talkflow-windows-x64-setup.exe",
    available: WINDOWS_AVAILABLE,
  },
};
// Where every Windows Download button points: the route downloads the installer.
export const WINDOWS_DOWNLOAD_PATH = "/download/windows-x64";
export const buildUrl = (id: BuildId) => `${REPO_URL}/releases/latest/download/${BUILDS[id].asset}`;

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

// The guide pages (components/guides/ContentPage.tsx), in the order the
// footer lists them. The sitemap lists them too.
export const GUIDES: { path: string; label: string }[] = [
  { path: "/how-it-works", label: "How talkflow works" },
  { path: "/offline-dictation-mac", label: "Offline dictation for Mac" },
  { path: "/dictation-for-windows", label: "Dictation for Windows" },
  { path: "/use-cases/coding", label: "Dictation for coding" },
  { path: "/use-cases/email-and-chat", label: "Dictation for email and chat" },
  { path: "/use-cases/writing", label: "Dictation for writing" },
  { path: "/alternatives/wispr-flow", label: "talkflow vs Wispr Flow*" },
];

// Directories and launch sites that list talkflow, linked from the footer.
// Many of them only list a free product that links back to them, so these
// stay plain links (no rel="nofollow"). Product Hunt has its own badge in the
// hero and is not repeated here.
export const FEATURED_ON: { name: string; url: string }[] = [
  { name: "AlternativeTo", url: "https://alternativeto.net" },
  { name: "SaaSHub", url: "https://www.saashub.com" },
  { name: "Indie Hackers", url: "https://www.indiehackers.com" },
  { name: "Peerlist", url: "https://peerlist.io" },
  { name: "Fazier", url: "https://fazier.com" },
  { name: "Twelve Tools", url: "https://twelve.tools" },
  { name: "Findly Tools", url: "https://findly.tools" },
  { name: "Uneed", url: "https://www.uneed.best" },
  { name: "TinyLaunch", url: "https://www.tinylaunch.com" },
  { name: "PeerPush", url: "https://peerpush.com" },
  { name: "SideProjectors", url: "https://www.sideprojectors.com" },
  { name: "Product Watch", url: "https://productwatch.io" },
  { name: "Neeed", url: "https://neeed.directory" },
  { name: "FoundrList", url: "https://www.foundrlist.com" },
  { name: "Tech Directory", url: "https://www.techdirectory.io" },
  { name: "Startup Ranking", url: "https://www.startupranking.com" },
  { name: "Startup Fast", url: "https://www.startupfa.st" },
  { name: "PitchWall", url: "https://pitchwall.co" },
  { name: "SaaS Browser", url: "https://saasbrowser.com" },
  { name: "What Launched Today", url: "https://whatlaunched.today" },
  { name: "Hot100.ai", url: "https://www.hot100.ai" },
  { name: "DailyPings", url: "https://dailypings.com" },
  { name: "Launch Vault", url: "https://www.launchvault.dev" },
  { name: "ramen.tools", url: "https://ramen.tools" },
  { name: "IndieHunt", url: "https://indiehunt.io" },
  { name: "LaunchitX", url: "https://launchitx.com" },
  { name: "BestofAI", url: "https://bestofai.com" },
  { name: "Promote Project", url: "https://www.promoteproject.com" },
  { name: "ufind.best", url: "https://ufind.best" },
  { name: "Scout Forge", url: "https://scoutforge.net" },
  { name: "EarlyHunt", url: "https://earlyhunt.com" },
  { name: "Startup Tracker", url: "https://startuptracker.io" },
  { name: "CoderLegion", url: "https://coderlegion.com" },
  { name: "BuiltByMe", url: "https://builtbyme.io" },
  { name: "VibeRank", url: "https://viberank.dev" },
  { name: "StartupFound", url: "https://startupfound.com" },
  { name: "CurateClick", url: "https://curateclick.com" },
  { name: "ShipYardHQ", url: "https://shipyardhq.com" },
  { name: "Find Your SaaS", url: "https://findyoursaas.com" },
  { name: "MicroSaaS Directory", url: "https://microsaasdirectory.com" },
  { name: "IndieHacker Stacks", url: "https://indiehackerstacks.com" },
  { name: "Launch", url: "https://trylaunch.ai" },
  { name: "ProofStories", url: "https://proofstories.io" },
  { name: "TechTrending", url: "https://techtrending.com" },
  { name: "DevHub", url: "https://devhub.best" },
  { name: "NAVS", url: "https://navs.site" },
  { name: "VentureRadar", url: "https://www.ventureradar.com" },
];

export const FAQ: [question: string, answer: string][] = [
  [
    "How is it different from Wispr Flow?",
    "Wispr Flow Pro costs $15 a month, or $12 a month billed yearly, and Wispr Flow's free plan stops at 2,000 words a week on desktop. talkflow is free with no word limit, it's open source, and the speech engine runs on your own Mac or PC.",
  ],
  [
    "Is it really free?",
    "Yes. No trial, no tiers, no subscription. talkflow is open source under the MIT License and runs on your own Mac or PC, so there's nothing to pay for.",
  ],
  [
    "Does anything get sent to the cloud?",
    "Not your voice or your words. Your audio goes to one place: the speech engine running on your own computer. The text is typed straight into the app you're using. There's no account and no usage analytics. It makes two other requests: once, after you install it, it tells us so we can count installs (no ID, nothing about you or how you use it), and it asks GitHub whether there's a newer version (shortly after it starts, every few hours, and when you open the dashboard). An update only installs when you click it.",
  ],
  [
    "Which key do I hold?",
    "On a Mac, fn, the Globe key in the bottom-left corner of Mac keyboards. On Windows, Ctrl + Win (you can change it in Settings). Hold it while you talk and let go when you're done.",
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
    "A Mac with macOS 13 or later (built and tested on Apple silicon), or a PC with Windows 10 (version 1809) or later, including Arm PCs. The English speech model needs about 190 MB of disk space on a Mac and about 490 MB on Windows, plus about 575 MB for the optional, more accurate final-pass model.",
  ],
];

