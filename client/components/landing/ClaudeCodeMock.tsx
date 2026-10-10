"use client";

import { useEffect, useState, type ReactNode } from "react";
import { cn } from "@/lib/cn";
import { typedText, type Dictation } from "./dictation";
import { Lights } from "./primitives";

// Claude Code's dark theme.
const DIM = "text-[#999999]";
const CLAUDE = "text-[#d77757]";
const GREEN = "text-[#4eba65]";
const USER_BG = "bg-[#373737]";
const ADDED = "bg-[#225c2b]";
const REMOVED = "bg-[#7a2936]";
const ADDED_WORD = "bg-[#38a660]";

// One blank terminal row.
function Gap() {
  return <div className="h-(--lh)" />;
}

// Claude Code's mascot, the block-character crab it prints in its header,
// drawn as the quadrant pixels those characters cover so it lines up in any
// monospace font. Each cell is 1ch x 1 row, split into 2 x 2.
const MASCOT = ["  ▐▛███▜▌ ", " ▝▜█████▛▘", "   ▘▘ ▝▝  "];
const QUADRANTS: Record<string, string> = { "▐": "0101", "▛": "1110", "█": "1111", "▜": "1101", "▌": "1010", "▝": "0100", "▘": "1000" };

function Mascot() {
  const cols = MASCOT[0].length;
  const rects = MASCOT.flatMap((row, y) =>
    [...row].flatMap((ch, x) =>
      [...(QUADRANTS[ch] ?? "0000")].flatMap((on, q) =>
        on === "1" ? [<rect key={`${x}-${y}-${q}`} x={x * 2 + (q % 2)} y={y * 2 + (q >> 1)} width={1.02} height={1.02} />] : [],
      ),
    ),
  );
  return (
    <svg
      aria-hidden="true"
      viewBox={`0 0 ${cols * 2} ${MASCOT.length * 2}`}
      preserveAspectRatio="none"
      className={cn("absolute top-0 left-0 h-[calc(3*var(--lh))] w-[10ch] fill-current", CLAUDE)}
    >
      {rects}
    </svg>
  );
}

// "⏺ " with a hanging indent, the way Claude Code prints replies and tool calls.
function Bullet({ dot, children }: { dot?: string; children: ReactNode }) {
  return (
    <div className="flex">
      <span className={cn("w-[2ch] shrink-0", dot)}>⏺</span>
      <div className="min-w-0">{children}</div>
    </div>
  );
}

// A tool call, with its result hanging off "  ⎿  ".
function Tool({ name, arg, children }: { name: string; arg: string; children: ReactNode }) {
  return (
    <div>
      <Bullet dot={GREEN}>
        <span className="font-bold">{name}</span>({arg})
      </Bullet>
      <div className="flex">
        <span className={cn("w-[5ch] shrink-0 whitespace-pre", DIM)}>{"  ⎿  "}</span>
        <div className="min-w-0 flex-1">{children}</div>
      </div>
    </div>
  );
}

function DiffRow({ n, sign, children }: { n: number; sign?: "+" | "-"; children: ReactNode }) {
  return (
    <div className={cn("flex", sign === "+" && ADDED, sign === "-" && REMOVED)}>
      <span className={cn("w-[4ch] shrink-0 text-right", sign ? "text-[#e8e6e3]/70" : DIM)}>{n}</span>
      <span className="w-[3ch] shrink-0 text-center">{sign}</span>
      <span className="min-w-0 whitespace-pre-wrap">{children}</span>
    </div>
  );
}

function UserMessage({ children }: { children: ReactNode }) {
  return (
    <div className={cn("flex pr-[1ch]", USER_BG)}>
      <span className={cn("w-[2ch] shrink-0", DIM)}>&gt;</span>
      <div className="min-w-0 break-words">{children}</div>
    </div>
  );
}

// The rule above and below the prompt is a row of "─", drawn through the
// middle of its row the way a terminal draws box characters.
function Rule() {
  return <div aria-hidden="true" className="flex h-(--lh) items-center before:h-px before:flex-1 before:bg-[#888888]" />;
}

const FRAMES = ["·", "✢", "✳", "✶", "✻", "✽", "✻", "✶", "✳", "✢"];

function Spinner() {
  const [frame, setFrame] = useState(0);
  useEffect(() => {
    const id = window.setInterval(() => setFrame((f) => (f + 1) % FRAMES.length), 120);
    return () => window.clearInterval(id);
  }, []);
  return (
    <div className={CLAUDE}>
      <span className="inline-block w-[2ch]">{FRAMES[frame]}</span>
      Pondering… <span className={DIM}>(esc to interrupt)</span>
    </div>
  );
}

function BlockCaret() {
  return <span aria-hidden="true" className="inline-block h-(--lh) w-[1ch] animate-blink bg-[#e8e6e3] align-top" />;
}

// Claude Code running in macOS Terminal (the Basic profile, dark): the shell
// prompt that started it, its header, an earlier bug fix in the scrollback,
// then a new prompt being dictated into the input. The scrollback is pinned to
// the bottom like a terminal's, so as the prompt grows the oldest rows scroll
// off the top.
export function ClaudeCodeMock({ text, d }: { text: string; d: Dictation }) {
  const typed = typedText(text, d);
  const sent = d.phase === "sent";

  return (
    <div className="flex h-full flex-col bg-[#1e1e1e] font-mono text-[12px] text-[#e8e6e3] [--lh:16px]">
      {/* Terminal's title bar: the title Claude Code sets, the process and the window size in rows and columns. */}
      <div className="relative flex h-7 shrink-0 items-center border-b border-black bg-[#2c2c2c] px-[9px] font-sans">
        <Lights />
        <span className="absolute inset-x-[76px] truncate text-center text-[13px] font-semibold text-white/80">
          ✳ Waitlist signups fix — claude — <span className="@min-[520px]:hidden">50×24</span>
          <span className="hidden @min-[520px]:inline">88×25</span>
        </span>
      </div>

      {/* Whole rows only: a terminal scrolls a row at a time, so the top row is never cut in half. */}
      <div className="min-h-0 flex-1 px-[7px] pt-1">
        <div className="flex h-[round(down,100%,var(--lh))] flex-col justify-end overflow-hidden leading-(--lh) *:shrink-0">
          <div className="truncate">alex@MacBook-Pro waitlist % claude</div>
          <Gap />
          <div className="relative pl-[11ch]">
            <Mascot />
            <div className="truncate">
              <span className="font-bold">Claude Code</span> <span className={DIM}>v2.1.4</span>
            </div>
            <div className={cn("truncate", DIM)}>Opus 5.5 · Claude Max</div>
            <div className={cn("truncate", DIM)}>~/code/waitlist</div>
          </div>
          <Gap />
          <UserMessage>signups from the landing page stopped showing up in the dashboard, can you look?</UserMessage>
          <Gap />
          <Bullet>
            The route responds before the insert finishes, and the function is frozen as soon as it responds, so most
            writes never land. I&apos;ll await the insert.
          </Bullet>
          <Gap />
          <Tool name="Update" arg="src/app/api/waitlist/route.ts">
            <div>
              Updated <span className="font-bold">route.ts</span> with <span className="font-bold">1</span> addition and{" "}
              <span className="font-bold">1</span> removal
            </div>
            <DiffRow n={14}>{"  const { email } = await req.json();"}</DiffRow>
            <DiffRow n={15} sign="-">
              {"  db.insert(waitlist).values({ email });"}
            </DiffRow>
            <DiffRow n={15} sign="+">
              {"  "}
              <span className={ADDED_WORD}>await </span>
              {"db.insert(waitlist).values({ email });"}
            </DiffRow>
            <DiffRow n={16}>{"  return Response.json({ ok: true });"}</DiffRow>
          </Tool>
          <Gap />
          <Bullet>Fixed. Every signup is saved before the response goes out, and all 6 waitlist tests pass.</Bullet>
          <Gap />

          {sent && (
            <>
              <UserMessage>{text}</UserMessage>
              <Gap />
              <Spinner />
              <Gap />
            </>
          )}

          <Rule />
          <div aria-live="off" className="flex">
            <span className="w-[2ch] shrink-0">&gt;</span>
            <div className="min-w-0 flex-1 break-words">
              {typed}
              <BlockCaret />
            </div>
          </div>
          <Rule />
          <div className="truncate pl-[2ch]">
            <span className="text-[#af87ff]">⏵⏵ accept edits on</span>
            <span className={DIM}> (shift+tab to cycle)</span>
          </div>
        </div>
      </div>
    </div>
  );
}
