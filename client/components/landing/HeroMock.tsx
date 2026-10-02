"use client";

import { useEffect, useState, type ReactNode } from "react";
import { PROMPTS } from "./content";
import { RecDot, Waveform } from "./primitives";
import { useReducedMotion } from "./visitor";

type Phase = "idle" | "listening" | "done";
type Dictation = { pi: number; words: number; phase: Phase };

const START: Dictation = { pi: 0, words: 0, phase: "idle" };

// Plays each prompt into the chat box word by word, with human-ish pauses
// after commas and sentence ends, then moves on to the next prompt.
function useDictation(reduced: boolean): Dictation {
  const [dictation, setDictation] = useState(START);

  useEffect(() => {
    if (reduced) return;
    let timer: number;
    const later = (fn: () => void, ms: number) => {
      timer = window.setTimeout(fn, ms);
    };

    const listen = (pi: number) => {
      const words = PROMPTS[pi].split(" ");
      later(() => {
        setDictation({ ...START, pi, phase: "listening" });
        later(() => step(pi, words, 0), 350);
      }, 700);
    };

    const step = (pi: number, words: string[], i: number) => {
      if (i >= words.length) {
        later(() => {
          setDictation((d) => ({ ...d, phase: "done" }));
          later(() => {
            const next = (pi + 1) % PROMPTS.length;
            setDictation({ ...START, pi: next });
            listen(next);
          }, 1300);
        }, 300);
        return;
      }
      const burst = Math.random() < 0.35 && i + 1 < words.length ? 2 : 1;
      const n = Math.min(words.length, i + burst);
      setDictation((d) => ({ ...d, words: n }));
      const word = words[n - 1];
      let delay = 70 + Math.random() * 110;
      if (/[,;]$/.test(word)) delay += 110 + Math.random() * 120;
      if (/[.?!]$/.test(word)) delay += 180 + Math.random() * 200;
      if (Math.random() < 0.05) delay += 200;
      later(() => step(pi, words, n), delay);
    };

    listen(0);
    return () => window.clearTimeout(timer);
  }, [reduced]);

  return reduced ? { ...START, words: PROMPTS[0].split(" ").length, phase: "done" } : dictation;
}

const CORAL = "text-[#d77757]";
const DIM = "text-[#8d8b86]";

// The mascot and welcome lines Claude Code prints when it starts.
const BANNER = [
  [" ▐▛███▜▌ ", "Claude Code"],
  ["▝▜█████▛▘", "Sonnet 5.5 · Claude Max"],
  ["  ▘▘ ▝▝  ", "~/checkout-app"],
];

// One tool call: a green bullet, the call, then its output hanging off a bracket.
function Tool({ name, arg, children }: { name: string; arg: string; children: ReactNode }) {
  return (
    <div>
      <div>
        <span className="text-[#4eba65]">⏺ </span>
        <span className="font-bold">{name}</span>({arg})
      </div>
      <div className={`flex ${DIM}`}>
        <span className="w-[5ch] shrink-0 whitespace-pre">{"  ⎿  "}</span>
        <span className="min-w-0 whitespace-pre-wrap">{children}</span>
      </div>
    </div>
  );
}

function Diff({ n, sign, text }: { n: number; sign: "+" | "-"; text: string }) {
  const add = sign === "+";
  return (
    <span className={`block whitespace-pre text-[#e8e6e1] ${add ? "bg-[#1d3b27]" : "bg-[#472126]"}`}>
      <span className={DIM}>{String(n).padStart(3)} </span>
      {sign}
      {text}
    </span>
  );
}

// A Claude Code session in a Mac terminal, with a prompt being dictated into
// it. The pill mirrors the app's real overlay: a red dot and input levels
// while fn is held.
export function HeroMock() {
  const reduced = useReducedMotion();
  const { pi, words: shown, phase } = useDictation(reduced);

  const words = PROMPTS[pi].split(" ");
  const listening = phase === "listening";

  return (
    <div className="relative pb-7">
      <div className="overflow-hidden rounded-xl border border-white/10 bg-[#1c1b1a] shadow-[0_30px_60px_-30px_rgba(31,30,34,0.55)]">
        <div className="flex h-[38px] items-center gap-3 border-b border-black/40 bg-[#2a2928] px-3.5">
          <div className="flex gap-2" aria-hidden="true">
            <span className="size-3 rounded-full bg-[#ff5f57]" />
            <span className="size-3 rounded-full bg-[#febc2e]" />
            <span className="size-3 rounded-full bg-[#28c840]" />
          </div>
          <span className="flex-1 truncate text-center text-[13px] text-[#a3a19c]">checkout-app — claude</span>
          <span className="w-[52px]" />
        </div>

        <div className="flex h-[470px] flex-col justify-end gap-3.5 overflow-hidden p-4 font-mono text-[12px] leading-[1.5] text-[#e8e6e1] sm:h-[540px] sm:p-5 sm:text-[13px]">
          <pre className="m-0 font-mono leading-[1.05] whitespace-pre">
            {BANNER.map(([mascot, text], i) => (
              <div key={i}>
                <span className={CORAL}>{mascot}</span>
                {"  "}
                <span className={i === 0 ? "font-bold" : DIM}>{text}</span>
              </div>
            ))}
          </pre>

          <div className="bg-[#2f2e2c] px-2.5 py-1">
            <span className={DIM}>&gt; </span>run the tests
          </div>

          <Tool name="Bash" arg="npm test">
            <span className="text-[#4eba65]">PASS</span> src/cart.test.ts{"\n"}
            <span className="text-[#4eba65]">PASS</span> src/checkout.test.ts{"\n"}
            <span className="text-[#f0616d]">FAIL</span> src/PayButton.test.tsx{"\n"}
            {"  "}● PayButton › ignores a double click{"\n"}
            {"    "}expected 1 call, received 2{"\n"}
            Tests: <span className="text-[#f0616d]">1 failed</span>, 47 passed, 48 total
          </Tool>

          <Tool name="Read" arg="src/components/PayButton.tsx">
            Read 64 lines
          </Tool>

          <Tool name="Update" arg="src/components/PayButton.tsx">
            Updated with 3 additions and 1 removal
            <span className="mt-1 block">
              <Diff n={18} sign="-" text="  <button onClick={() => submit(cart)}>" />
              <Diff n={18} sign="+" text="  <button disabled={pending} onClick={() => {" />
              <Diff n={19} sign="+" text="    if (!pending) submit(cart);" />
              <Diff n={20} sign="+" text="  }}>" />
            </span>
          </Tool>

          <Tool name="Bash" arg="npm test">
            Tests: <span className="text-[#4eba65]">48 passed</span>, 48 total{"\n"}
            Time:  2.1 s
          </Tool>

          <div>
            <span>⏺ </span>Fixed the double submit in PayButton, and all 48 tests pass. What should we work on next?
          </div>

          <div>
            <div className="border-y border-[#5a5855] py-1.5">
              <div aria-live="off" className="flex min-h-[92px] gap-2 break-words sm:min-h-[44px]">
                <span aria-hidden="true">&gt;</span>
                <div className="min-w-0 flex-1">
                  {shown === 0 ? (
                    <span className={DIM}>
                      <span aria-hidden="true" className="animate-blink bg-[#e8e6e1] text-[#1c1b1a]">
                        T
                      </span>
                      ry &quot;fix the double submit in PayButton&quot;
                    </span>
                  ) : (
                    <>
                      <span>{words.slice(0, shown).join(" ")}</span>
                      <span aria-hidden="true" className="ml-px inline-block h-[1.2em] w-[0.6em] translate-y-[3px] animate-blink bg-[#e8e6e1]" />
                    </>
                  )}
                </div>
              </div>
            </div>
            <div className={`mt-1 flex justify-between px-1 ${DIM}`}>
              <span>? for shortcuts</span>
              <span className="hidden sm:inline">◐ medium · /effort</span>
            </div>
          </div>
        </div>
      </div>

      <div
        role="status"
        aria-label={listening ? "TalkFlow is listening" : "Hold fn to talk"}
        className="absolute bottom-0 left-1/2 flex h-12 min-w-[180px] -translate-x-1/2 items-center justify-center gap-3 rounded-full bg-ink px-5 text-[14px] whitespace-nowrap text-paper shadow-[0_16px_32px_-12px_rgba(31,30,34,0.5)] ring-1 ring-white/20"
      >
        {listening ? (
          <>
            <RecDot />
            <Waveform bars={12} height={20} />
          </>
        ) : (
          <span className="flex items-center gap-2 text-paper/80">
            Hold <kbd className="rounded-md border border-paper/25 px-1.5 py-px font-sans text-[12px] text-paper">fn</kbd> to talk
          </span>
        )}
      </div>
    </div>
  );
}
