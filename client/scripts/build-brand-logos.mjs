#!/usr/bin/env node
// Builds components/landing/brand-logos.generated.ts from local Iconify JSON
// icon sets (devDependencies). Run from client/: `npm run logos`.
//
// The output is deterministic: same packages in, byte-identical file out.
// Nothing here is hand-drawn; every glyph comes from one of these sets:
//   @iconify-json/logos (CC0), @iconify-json/thesvg (MIT),
//   @iconify-json/simple-icons (CC0), @iconify-json/mdi (Apache-2.0).

import { writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { getIconData, iconToSVG } from "@iconify/utils";

const require = createRequire(import.meta.url);
const CLIENT_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const OUT_FILE = path.join(CLIENT_DIR, "components/landing/brand-logos.generated.ts");

// Every internal id becomes `${ID_MARKER}<brand-slug>-<n>`. BrandLogo.tsx
// relies on this marker to make ids unique per rendered instance.
const ID_MARKER = "tfid-";

function loadSet(prefix) {
  const pkg = `@iconify-json/${prefix}`;
  const info = require(`${pkg}/info.json`);
  return {
    prefix,
    icons: require(`${pkg}/icons.json`),
    version: require(`${pkg}/package.json`).version,
    license: info.license.spdx ?? info.license.title,
    // `palette: false` means the set is single-color (currentColor).
    palette: info.palette === true,
  };
}

const SETS = Object.fromEntries(
  ["logos", "thesvg", "simple-icons", "mdi"].map((prefix) => [prefix, loadSet(prefix)]),
);

// OS glyphs: single color, inherit currentColor so they sit inside buttons.
const OS = [
  { key: "apple", candidates: ["simple-icons:apple"] },
  { key: "windows", candidates: ["mdi:microsoft-windows"] },
];

// App logos in display order. Candidates are tried in order: full-color
// `logos:*` first, then the (single-color) thesvg / simple-icons glyphs.
// A single-color glyph is filled with `tint`, the brand hex published in
// simple-icons 16.33.0 data/simple-icons.json (CC0).
const APPS = [
  { name: "Slack", candidates: ["logos:slack-icon"] },
  { name: "Notion", candidates: ["logos:notion-icon"] },
  { name: "Messages", candidates: ["thesvg:imessage", "simple-icons:imessage"], tint: "#34DA50" },
  { name: "WhatsApp", candidates: ["logos:whatsapp-icon"] },
  { name: "Gmail", candidates: ["logos:google-gmail", "logos:google-gmail-2020"] },
  { name: "Claude", candidates: ["logos:claude-icon"] },
  { name: "ChatGPT", candidates: ["logos:openai-icon"] },
  { name: "Cursor", candidates: ["logos:cursor-icon"] },
  { name: "VS Code", candidates: ["logos:visual-studio-code"] },
  { name: "Xcode", candidates: ["logos:xcode"] },
  { name: "GitHub", candidates: ["logos:github-icon"] },
  { name: "Linear", candidates: ["logos:linear-icon"] },
  { name: "Figma", candidates: ["logos:figma"] },
  { name: "Discord", candidates: ["logos:discord-icon"] },
  { name: "Telegram", candidates: ["logos:telegram"] },
  { name: "Signal", candidates: ["logos:signal"] },
  { name: "Messenger", candidates: ["logos:messenger"] },
  { name: "Zoom", candidates: ["logos:zoom-icon"] },
  { name: "Google Meet", candidates: ["logos:google-meet", "logos:google-meet-2020"] },
  { name: "Microsoft Teams", candidates: ["logos:microsoft-teams"] },
  { name: "Google Docs", candidates: ["thesvg:google-docs", "simple-icons:googledocs"], tint: "#4285F4" },
  { name: "Google Sheets", candidates: ["thesvg:google-sheets", "simple-icons:googlesheets"], tint: "#34A853" },
  { name: "Obsidian", candidates: ["logos:obsidian-icon"] },
  { name: "Evernote", candidates: ["thesvg:evernote", "simple-icons:evernote"], tint: "#00A82D" },
  { name: "Things", candidates: ["thesvg:things", "simple-icons:things"], tint: "#2473E7" },
  { name: "Todoist", candidates: ["logos:todoist-icon"] },
  { name: "Asana", candidates: ["logos:asana-icon"] },
  { name: "Trello", candidates: ["logos:trello"] },
  { name: "ClickUp", candidates: ["logos:clickup-icon"] },
  { name: "Jira", candidates: ["logos:jira"] },
  { name: "Confluence", candidates: ["logos:confluence"] },
  { name: "Airtable", candidates: ["logos:airtable"] },
  { name: "Miro", candidates: ["logos:miro-icon"] },
  { name: "Loom", candidates: ["logos:loom-icon"] },
  { name: "Perplexity", candidates: ["logos:perplexity-icon"] },
  { name: "Gemini", candidates: ["logos:google-gemini-icon"] },
  { name: "Warp", candidates: ["thesvg:warp", "simple-icons:warp"], tint: "#01A4FF" },
  { name: "iTerm2", candidates: ["thesvg:iterm2", "simple-icons:iterm2"], tint: "#000000" },
  { name: "Chrome", candidates: ["logos:chrome"] },
  { name: "Safari", candidates: ["logos:safari"] },
  { name: "Arc", candidates: ["logos:arc"] },
  { name: "Firefox", candidates: ["logos:firefox"] },
  { name: "X", candidates: ["logos:x"] },
  { name: "LinkedIn", candidates: ["logos:linkedin-icon"] },
  { name: "Reddit", candidates: ["logos:reddit-icon"] },
  { name: "Substack", candidates: ["thesvg:substack", "simple-icons:substack"], tint: "#FF6719" },
];

function slugify(name) {
  return name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-|-$/g, "");
}

const escapeRegExp = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");

// Deterministic replacement for @iconify/utils `replaceIDs`: in v3 that
// function no longer takes a prefix and keeps the original ids, so it cannot
// give each brand its own namespace. Same reference rule as upstream: an id
// is rewritten where it follows `#`, `;` or `"` and precedes `"`, `)` or
// `.event` (SMIL begin/end values).
function prefixIds(body, prefix) {
  const ids = [...new Set([...body.matchAll(/\sid="([^"]+)"/g)].map((m) => m[1]))];
  if (ids.length === 0) return body;
  const renamed = new Map(ids.map((id, i) => [id, `${prefix}${i}`]));
  const pattern = new RegExp(
    `([#;"])(${ids.map(escapeRegExp).join("|")})(?=["')]|\\.[a-z])`,
    "g",
  );
  return body.replace(pattern, (_, lead, id) => lead + renamed.get(id));
}

function resolve(candidates) {
  for (const full of candidates) {
    const [prefix, name] = full.split(":");
    const set = SETS[prefix];
    if (!set) throw new Error(`Unknown icon set "${prefix}" in ${full}`);
    const data = getIconData(set.icons, name);
    if (data) return { full, set, data };
  }
  return null;
}

function build(entry, slug, { mono }) {
  const hit = resolve(entry.candidates);
  if (!hit) return null;

  const { attributes, body: rawBody } = iconToSVG(hit.data);
  if (rawBody.includes(ID_MARKER)) {
    throw new Error(`${hit.full} already contains "${ID_MARKER}"; pick another marker`);
  }
  let body = prefixIds(rawBody, `${ID_MARKER}${slug}-`);
  const isMono = !hit.set.palette;
  let note = `${hit.full} (${hit.set.license})`;

  if (mono) {
    if (!isMono || !body.includes("currentColor")) {
      throw new Error(`${hit.full} must be a single-color currentColor glyph`);
    }
  } else if (isMono) {
    if (!entry.tint) throw new Error(`${hit.full} is single-color; give ${entry.name} a tint`);
    if (!body.includes("currentColor")) throw new Error(`${hit.full} has no currentColor to tint`);
    body = body.replaceAll("currentColor", entry.tint);
    note += `, filled ${entry.tint} (simple-icons brand hex)`;
  }

  return { svg: { viewBox: attributes.viewBox, body }, note };
}

const skipped = [];
const credits = [];

const osLogos = {};
for (const entry of OS) {
  const built = build(entry, `os-${entry.key}`, { mono: true });
  if (!built) throw new Error(`OS logo "${entry.key}" not found in ${entry.candidates.join(", ")}`);
  osLogos[entry.key] = built.svg;
  credits.push(`OS ${entry.key}: ${built.note}`);
}

const appLogos = [];
for (const entry of APPS) {
  const built = build(entry, slugify(entry.name), { mono: false });
  if (!built) {
    skipped.push(entry.name);
    continue;
  }
  appLogos.push({ name: entry.name, ...built.svg });
  credits.push(`${entry.name}: ${built.note}`);
}

const q = JSON.stringify;
const setVersions = Object.values(SETS)
  .map((s) => `@iconify-json/${s.prefix}@${s.version} (${s.license})`)
  .join(", ");

const out = `// GENERATED FILE. Do not edit by hand.
// Regenerate from client/: npm run logos (scripts/build-brand-logos.mjs)
// Icon sets: ${setVersions}
//
// Sources and licenses:
${credits.map((c) => `//   ${c}`).join("\n")}
${skipped.length ? `//\n// Skipped (not found in any set): ${skipped.join(", ")}\n` : ""}
export type BrandSvg = { viewBox: string; body: string };

export const OS_LOGOS: { apple: BrandSvg; windows: BrandSvg } = {
  apple: { viewBox: ${q(osLogos.apple.viewBox)}, body: ${q(osLogos.apple.body)} },
  windows: { viewBox: ${q(osLogos.windows.viewBox)}, body: ${q(osLogos.windows.body)} },
};

export const APP_LOGOS: ({ name: string } & BrandSvg)[] = [
${appLogos
  .map(
    (l) => `  {
    name: ${q(l.name)},
    viewBox: ${q(l.viewBox)},
    body: ${q(l.body)},
  },`,
  )
  .join("\n")}
];
`;

writeFileSync(OUT_FILE, out);
console.log(
  `Wrote ${path.relative(CLIENT_DIR, OUT_FILE)}: ${appLogos.length} app logos, 2 OS logos` +
    (skipped.length ? `; skipped ${skipped.join(", ")}` : ""),
);
