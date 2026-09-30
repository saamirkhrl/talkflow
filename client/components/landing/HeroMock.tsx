"use client";

import { useEffect, useState } from "react";
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
        later(() => step(pi, words, 0), 650);
      }, 1600);
    };

    const step = (pi: number, words: string[], i: number) => {
      if (i >= words.length) {
        later(() => {
          setDictation((d) => ({ ...d, phase: "done" }));
          later(() => {
            const next = (pi + 1) % PROMPTS.length;
            setDictation({ ...START, pi: next });
            listen(next);
          }, 2800);
        }, 700);
        return;
      }
      const burst = Math.random() < 0.35 && i + 1 < words.length ? 2 : 1;
      const n = Math.min(words.length, i + burst);
      setDictation((d) => ({ ...d, words: n }));
      const word = words[n - 1];
      let delay = 110 + Math.random() * 150;
      if (/[,;]$/.test(word)) delay += 280 + Math.random() * 220;
      if (/[.?!]$/.test(word)) delay += 620 + Math.random() * 420;
      if (Math.random() < 0.05) delay += 450;
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

        <div className="flex min-h-[420px] flex-col gap-4 p-4 font-mono text-[12px] leading-[1.55] text-[#e8e6e1] sm:p-5 sm:text-[13px]">
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

          <div>
            <div>
              <span className="text-[#4eba65]">⏺ </span>
              <span className="font-bold">Bash</span>(npm test)
            </div>
            <div className={`flex ${DIM}`}>
              <span className="w-[5ch] shrink-0 whitespace-pre">{"  ⎿  "}</span>
              <span className="whitespace-pre">{"Tests:  48 passed, 48 total\nTime:   2.4 s"}</span>
            </div>
          </div>

          <div>
            <span>⏺ </span>All 48 tests pass on main. What should we work on next?
          </div>

          <div className="flex-1" />

          <div>
            <div
              className={`rounded-lg border px-3 py-2 transition-colors duration-300 ${listening ? "border-[#b4b1aa]" : "border-[#5a5855]"}`}
            >
              <div aria-live="off" className="flex min-h-[220px] gap-2 break-words sm:min-h-[124px]">
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
            <div className={`mt-1.5 px-1 ${DIM}`}>? for shortcuts</div>
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
