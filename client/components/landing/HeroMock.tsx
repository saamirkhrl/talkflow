"use client";

import { useEffect, useState } from "react";
import { cn } from "@/lib/cn";
import { CODE, PROMPTS } from "./content";
import { RecDot, Waveform } from "./primitives";
import { useReducedMotion, useVisitor } from "./visitor";

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

// An agent chat with a prompt being dictated into it. The pill mirrors the
// app's real overlay: a red dot and input levels while fn is held.
export function HeroMock() {
  const { mobile } = useVisitor();
  const reduced = useReducedMotion();
  const { pi, words: shown, phase } = useDictation(reduced);

  const words = PROMPTS[pi].split(" ");
  const listening = phase === "listening";

  return (
    <div className="relative pb-7">
      <div className="overflow-hidden rounded-2xl border border-line bg-paper shadow-[0_30px_60px_-30px_rgba(31,30,34,0.35)]">
        <div className="flex h-11 items-center gap-3 border-b border-line px-4">
          <div className="flex gap-[7px]">
            {[0, 1, 2].map((i) => (
              <span key={i} className="size-[11px] rounded-full bg-ink/12" />
            ))}
          </div>
          <span className="flex-1 text-center text-[13px] text-graphite">checkout-app</span>
          <span className="w-[47px]" />
        </div>

        <div className="grid min-h-[380px] grid-cols-[repeat(auto-fit,minmax(min(100%,300px),1fr))]">
          {!mobile && (
            <div className="overflow-hidden border-r border-line bg-mist py-5 font-mono text-[12.5px] leading-[1.85]">
              <div className="px-5 pb-3 font-sans text-[13px] text-graphite">PayButton.tsx</div>
              {CODE.map((line, i) => (
                <div key={i} className="flex gap-4 px-5 whitespace-pre">
                  <span className="w-4 text-right text-ink/35">{i + 1}</span>
                  <span className="text-ink/75">{line}</span>
                </div>
              ))}
            </div>
          )}

          <div className="flex flex-col gap-4 p-5">
            <p className="max-w-[40ch] rounded-2xl bg-mist px-4 py-3 text-[15px] text-graphite">
              All 48 tests pass on main. What should we work on next?
            </p>
            <div className="flex-1" />
            <div
              className={cn(
                "rounded-2xl border bg-paper px-4 pt-3.5 pb-3 transition-[border-color,box-shadow] duration-300",
                listening ? "border-ink/40 shadow-[0_0_0_4px_rgba(31,30,34,0.06)]" : "border-line",
              )}
            >
              <div aria-live="off" className="min-h-[118px] text-[15.5px] leading-[1.6]">
                <span>{words.slice(0, shown).join(" ")}</span>
                <span aria-hidden="true" className="ml-0.5 inline-block h-[1.15em] w-0.5 translate-y-[3px] animate-blink bg-ink" />
                {shown === 0 && <span className="text-ink/40">Ask anything</span>}
              </div>
              <div className="mt-2 flex items-center justify-between text-[12px] text-graphite">
                <span>{shown ? `${shown} words` : ""}</span>
                <span>Enter to send</span>
              </div>
            </div>
          </div>
        </div>
      </div>

      <div
        role="status"
        aria-label={listening ? "TalkFlow is listening" : "Hold fn to talk"}
        className="absolute bottom-0 left-1/2 flex h-12 min-w-[180px] -translate-x-1/2 items-center justify-center gap-3 rounded-full bg-ink px-5 text-[14px] whitespace-nowrap text-paper shadow-[0_16px_32px_-12px_rgba(31,30,34,0.5)]"
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
