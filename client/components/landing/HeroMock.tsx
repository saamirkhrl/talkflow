"use client";

import { Check } from "lucide-react";
import { useEffect, useState } from "react";
import { cn } from "@/lib/cn";
import { CODE, PROMPTS } from "./content";
import { Blueprint, LiveDot, Wave } from "./primitives";
import { useReducedMotion, useVisitor } from "./visitor";

type Phase = "idle" | "listening" | "done";
type Dictation = { pi: number; words: number; phase: Phase; startedAt: number; now: number };

const START: Dictation = { pi: 0, words: 0, phase: "idle", startedAt: 0, now: 0 };

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
        const t0 = Date.now();
        setDictation({ ...START, pi, phase: "listening", startedAt: t0, now: t0 });
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
      setDictation((d) => ({ ...d, words: n, now: Date.now() }));
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

export function HeroMock() {
  const { os, mobile } = useVisitor();
  const reduced = useReducedMotion();
  const { pi, words: shown, phase, startedAt, now } = useDictation(reduced);

  const words = PROMPTS[pi].split(" ");
  const listening = phase === "listening";
  const secs = Math.max(0, Math.floor((now - startedAt) / 1000));

  return (
    <div data-reveal className="relative mt-[clamp(56px,7vw,88px)] pb-7">
      <Blueprint className="bg-bg shadow-lg">
        <div className="flex h-[42px] items-center gap-3.5 border-b border-divider px-4">
          <div className="flex gap-[7px]">
            {[0, 1, 2].map((i) => (
              <span key={i} className="size-[11px] rounded-full border border-divider" />
            ))}
          </div>
          <span className="flex-1 text-center text-[13px] text-muted">checkout-app — Assistant</span>
          <span className="border border-accent px-2.5 py-[3px] text-[11px] tracking-[.02em] text-accent">main</span>
        </div>

        <div className="grid min-h-[420px] grid-cols-[repeat(auto-fit,minmax(min(100%,340px),1fr))]">
          {!mobile && (
            <div className="overflow-hidden border-r border-divider bg-surface py-[22px] font-mono text-[13px] leading-[1.85]">
              <div className="px-5 pb-3.5 font-sans text-[12px] tracking-[.08em] text-muted uppercase">PayButton.tsx</div>
              {CODE.map((line, i) => (
                <div key={i} className="flex gap-[18px] px-5 whitespace-pre">
                  <span className="w-[18px] text-right text-ink/38">{i + 1}</span>
                  <span className="text-muted">{line}</span>
                </div>
              ))}
            </div>
          )}

          <div className="flex flex-col gap-[18px] px-[clamp(18px,2.4vw,28px)] pt-[22px] pb-[26px]">
            <div className="flex items-start gap-3">
              <span className="grid size-[26px] flex-none place-items-center border border-divider font-heading text-[13px] text-muted">
                AI
              </span>
              <p className="max-w-[44ch] text-[15px] text-muted">All 48 tests pass on main. What should we work on next?</p>
            </div>
            <div className="flex-1" />
            <div
              className={cn(
                "border bg-bg px-[18px] pt-4 pb-3 transition-colors duration-250",
                listening ? "border-accent ring-3 ring-accent/18" : "border-divider",
              )}
            >
              <div aria-live="off" className="min-h-[124px] text-[16px] leading-[1.6]">
                <span>{words.slice(0, shown).join(" ")}</span>
                <span aria-hidden="true" className="ml-0.5 inline-block h-[1.15em] w-0.5 animate-blink bg-accent align-[-3px]" />
                {shown === 0 && <span className="text-ink/42">Ask anything…</span>}
              </div>
              <div className="mt-2.5 flex items-center justify-between text-[12px] text-muted">
                <span>{shown ? `${shown} words` : ""}</span>
                <span>Enter to send</span>
              </div>
            </div>
          </div>
        </div>
      </Blueprint>

      <div
        role="status"
        aria-label="TalkFlow listening indicator"
        className="absolute bottom-0 left-1/2 flex h-12 min-w-[228px] -translate-x-1/2 items-center justify-center rounded-full border border-neutral-100/14 bg-neutral-900 pr-5 pl-4 text-[14px] whitespace-nowrap text-neutral-100 shadow-lg"
      >
        {phase === "idle" && (
          <span className="flex items-center gap-2.5">
            <span className="size-2 rounded-full bg-neutral-500" />
            Hold <span className="border border-neutral-100/30 px-[7px] py-px text-[12px] tracking-[.04em]">{os === "mac" ? "fn" : "Ctrl + Win"}</span> to talk
          </span>
        )}
        {listening && (
          <span className="flex items-center gap-3">
            <LiveDot />
            <Wave count={12} height={20} color="var(--color-accent-400)" />
            <span className="text-neutral-300 tabular-nums">0:{String(secs).padStart(2, "0")}</span>
          </span>
        )}
        {phase === "done" && (
          <span className="flex items-center gap-[9px]">
            <Check size={16} strokeWidth={2} className="text-accent-400" aria-hidden="true" />
            Inserted {words.length} words
          </span>
        )}
      </div>
    </div>
  );
}
