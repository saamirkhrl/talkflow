"use client";

import { useEffect, useState } from "react";
import { APPS, CLEAN, HOTKEYS, RAW } from "./content";
import { Blueprint, LiveDot, Numbered, Section, Wave } from "./primitives";
import { useReducedMotion } from "./visitor";

// Types an app name, holds it, backspaces it, then moves to the next one.
function useTypedAppName(reduced: boolean): string {
  const [app, setApp] = useState({ idx: 0, chars: APPS[0].length });

  useEffect(() => {
    if (reduced) return;
    let idx = 0;
    let chars = APPS[0].length;
    let deleting = false;
    let timer: number;
    const tick = () => {
      let delay: number;
      if (!deleting) {
        if (chars < APPS[idx].length) {
          chars++;
          delay = 60 + Math.random() * 70;
        } else {
          deleting = true;
          delay = 1500;
        }
      } else if (chars > 0) {
        chars--;
        delay = 38;
      } else {
        deleting = false;
        idx = (idx + 1) % APPS.length;
        delay = 280;
      }
      setApp({ idx, chars });
      timer = window.setTimeout(tick, delay);
    };
    timer = window.setTimeout(tick, 1400);
    return () => window.clearTimeout(timer);
  }, [reduced]);

  return APPS[app.idx].slice(0, app.chars);
}

function useCycle(length: number, ms: number, reduced: boolean): number {
  const [i, setI] = useState(0);
  useEffect(() => {
    if (reduced) return;
    const id = window.setInterval(() => setI((n) => (n + 1) % length), ms);
    return () => window.clearInterval(id);
  }, [length, ms, reduced]);
  return i;
}

const RAW_OFFSETS = [-24, 16, -6, 26, -16, 8, -28, 20, -4, 22, -12];

// An endless marquee: the list is rendered twice and the track drifts by
// half its width, so the loop point is seamless.
function Flow({ side }: { side: "left" | "right" }) {
  const left = side === "left";
  return (
    <div className="flex h-full w-max animate-drift items-center" style={{ animationDuration: left ? "40s" : "14s" }}>
      {["a", "b"].flatMap((copy) =>
        left
          ? RAW.map((text, i) => (
              <span
                key={copy + i}
                className="mr-[34px] inline-block text-muted italic whitespace-nowrap opacity-75"
                style={{ fontSize: 15 + (i % 3), transform: `translateY(${RAW_OFFSETS[i % RAW_OFFSETS.length]}px)` }}
              >
                {text}
              </span>
            ))
          : CLEAN.map((text, i) => (
              <span
                key={copy + i}
                className="mr-16 inline-block text-[21px] whitespace-nowrap"
                style={{ animation: `tfbob ${2.6 + i * 0.5}s ease-in-out ${-i * 0.8}s infinite alternate` }}
              >
                {text}
              </span>
            )),
      )}
    </div>
  );
}

const FLOW_LABEL = "absolute top-3.5 text-[12px] font-semibold tracking-[.08em] uppercase";
const STEP_TITLE = "mt-1.5 mb-2.5 flex min-h-9 flex-wrap items-center gap-3 text-[26px]";

export function HowItWorks() {
  const reduced = useReducedMotion();
  const appName = useTypedAppName(reduced);
  const hotkey = HOTKEYS[useCycle(HOTKEYS.length, 1700, reduced)];

  return (
    <Section id="features" index="01" title="How it works">
      <h2 className="mb-12 font-display text-[clamp(36px,5vw,64px)] leading-[1.04] font-normal tracking-[-0.02em]">
        Speak, and it appears in{" "}
        <em className="whitespace-nowrap">
          {appName}
          <span aria-hidden="true" className="ml-1 inline-block h-[.82em] w-[3px] animate-[tfblink_1s_steps(1)_infinite] bg-accent align-[-0.04em]" />
        </em>
      </h2>

      <Blueprint className="mb-12 h-[clamp(180px,20vw,220px)]">
        <div
          aria-hidden="true"
          className="absolute inset-y-0 right-1/2 left-0 overflow-hidden [mask-image:linear-gradient(to_right,transparent,#000_20%,#000_90%,transparent)]"
        >
          <Flow side="left" />
        </div>
        <div
          aria-hidden="true"
          className="absolute inset-y-0 right-0 left-1/2 overflow-hidden [mask-image:linear-gradient(to_right,transparent,#000_8%,#000_78%,transparent)]"
        >
          <Flow side="right" />
        </div>
        <span className={`${FLOW_LABEL} left-[18px] text-muted`}>What you say</span>
        <span className={`${FLOW_LABEL} right-[18px] text-ink-accent`}>What you get</span>
        <div className="absolute top-1/2 left-1/2 z-2 flex h-[52px] -translate-1/2 items-center gap-3 rounded-full border border-neutral-100/14 bg-neutral-900 pr-5 pl-4 shadow-lg">
          <LiveDot />
          <Wave count={9} height={18} color="var(--color-accent-400)" />
        </div>
      </Blueprint>

      <div className="grid grid-cols-1 gap-x-[clamp(24px,3vw,44px)] gap-y-8 min-[900px]:grid-cols-3">
        <Numbered index="01">
          <h3 className={STEP_TITLE}>
            Hold{" "}
            <span className="inline-grid h-9 min-w-12 place-items-center border border-b-3 border-divider px-3 text-[18px] tracking-[.02em] text-ink-accent">
              {hotkey}
            </span>
          </h3>
          <p className="text-muted">Or any shortcut you like. It works anywhere you can type.</p>
        </Numbered>
        <Numbered index="02">
          <h3 className={STEP_TITLE}>Speak naturally</h3>
          <p className="text-muted">
            Talk the way you think. The &quot;um&quot;s, pauses and restarts get cleaned up as your words pass through.
          </p>
        </Numbered>
        <Numbered index="03">
          <h3 className={STEP_TITLE}>Text flows in</h3>
          <p className="text-muted">Polished, punctuated text lands right at your cursor. No copy, no paste.</p>
        </Numbered>
      </div>
    </Section>
  );
}
