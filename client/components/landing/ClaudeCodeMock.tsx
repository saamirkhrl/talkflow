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

function Expand() {
  return <span className={DIM}> (ctrl+o to expand)</span>;
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

// The tail of a real Claude Code session in a Mac terminal: an earlier bug
// hunt in the scrollback, then a new prompt being dictated into the input.
// The scrollback is pinned to the bottom like a terminal's, so as the prompt
// grows the older rows scroll off the top.
export function ClaudeCodeMock({ text, d }: { text: string; d: Dictation }) {
  const typed = typedText(text, d);
  const sent = d.phase === "sent";

  return (
    <div className="flex h-full flex-col bg-[#1a1a1a] font-mono text-[11.5px] text-[#e8e6e3] [--lh:16px] sm:text-[12.5px] sm:[--lh:18px]">
      <div className="flex h-[34px] shrink-0 items-center border-b border-black/50 bg-[#2a2a2a] px-3.5 font-sans">
        <Lights />
        <span className="flex-1 truncate px-3 text-center text-[12.5px] text-[#a8a8a8]">✳ Waitlist signups fix</span>
        <span className="w-[52px]" />
      </div>

      <div className="flex min-h-0 flex-1 flex-col justify-end overflow-hidden px-3 pt-2 pb-2.5 leading-(--lh) *:shrink-0 sm:px-3.5">
        <UserMessage>signups from the landing page stopped showing up in the dashboard, can you look?</UserMessage>
        <Gap />
        <Tool name="Search" arg='pattern: "waitlist", path: "src"'>
          Found <span className="font-bold">4</span> files
          <Expand />
        </Tool>
        <Gap />
        <Tool name="Read" arg="src/app/api/waitlist/route.ts">
          Read <span className="font-bold">38</span> lines
          <Expand />
        </Tool>
        <Gap />
        <Bullet>
          The route responds before the insert finishes, and the function is frozen as soon as it responds, so most
          writes never land. I&apos;ll await the insert.
        </Bullet>
        <Gap />
        <Tool name="Update" arg="src/app/api/waitlist/route.ts">
          <div>
            Updated <span className="font-bold">src/app/api/waitlist/route.ts</span> with{" "}
            <span className="font-bold">1</span> addition and <span className="font-bold">1</span> removal
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
        <Tool name="Bash" arg="npm test -- waitlist">
          <div>
            <span className="bg-[#4eba65] px-[1ch] font-bold text-[#1a1a1a]">PASS</span> src/app/api/waitlist/route.test.ts
          </div>
          <div className="whitespace-pre">
            {"  "}
            <span className={GREEN}>✓</span> saves the email before responding <span className={DIM}>(14 ms)</span>
          </div>
          <div className="whitespace-pre">
            {"  "}
            <span className={GREEN}>✓</span> rejects a malformed email <span className={DIM}>(3 ms)</span>
          </div>
          <div className={DIM}>… +4 lines (ctrl+o to expand)</div>
        </Tool>
        <Gap />
        <Bullet>
          Fixed. The insert is awaited now, so every signup is saved before the response goes out. All 6 waitlist tests
          pass.
        </Bullet>
        <Gap />
        <div className={DIM}>✻ Worked for 1m 12s</div>
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
  );
}
