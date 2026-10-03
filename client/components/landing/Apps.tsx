"use client";

import { useEffect, useState } from "react";
import { APP_LOGOS } from "./brand-logos.generated";
import { BrandLogo } from "./BrandLogo";
import { useReducedMotion } from "./visitor";

const FEATURED = ["Slack", "Messages", "Cursor", "Notion", "Claude", "WhatsApp", "Gmail", "ChatGPT", "Linear", "Obsidian", "VS Code", "Discord"];
const APPS = FEATURED.flatMap((name) => APP_LOGOS.filter((logo) => logo.name === name));

// Types an app name, holds it, backspaces it, then moves on to the next app.
function useTypedApp(reduced: boolean) {
  const [state, setState] = useState({ idx: 0, chars: APPS[0].name.length });

  useEffect(() => {
    if (reduced) return;
    let idx = 0;
    let chars = APPS[0].name.length;
    let deleting = false;
    let timer: number;
    const tick = () => {
      let delay: number;
      if (!deleting) {
        if (chars < APPS[idx].name.length) {
          chars++;
          delay = 55 + Math.random() * 65;
        } else {
          deleting = true;
          delay = 1600;
        }
      } else if (chars > 0) {
        chars--;
        delay = 32;
      } else {
        deleting = false;
        idx = (idx + 1) % APPS.length;
        delay = 240;
      }
      setState({ idx, chars });
      timer = window.setTimeout(tick, delay);
    };
    timer = window.setTimeout(tick, 1600);
    return () => window.clearTimeout(timer);
  }, [reduced]);

  const app = APPS[state.idx];
  return { app, typed: app.name.slice(0, state.chars) };
}

export function Apps() {
  const reduced = useReducedMotion();
  const { app, typed } = useTypedApp(reduced);

  return (
    <section id="features" className="pt-[clamp(88px,12vw,160px)]">
      <div className="mx-auto max-w-[1200px] px-gutter text-center">
        <h2 className="font-serif text-[clamp(38px,5.6vw,72px)] leading-[1.05] font-normal tracking-[-0.02em]">
          Speak, and it appears in
          <span className="sr-only"> any app.</span>
          <span aria-hidden="true" className="mt-1 flex items-center justify-center gap-[0.22em] sm:mt-2">
            <span key={app.name} className="inline-flex size-[0.78em] animate-[appear_300ms_ease-out]">
              <BrandLogo logo={app} className="size-full" />
            </span>
            <em className="whitespace-nowrap">
              {typed}
              <span aria-hidden="true" className="ml-1 inline-block h-[0.8em] w-[3px] translate-y-[0.08em] animate-blink bg-ink" />
            </em>
          </span>
        </h2>
        <p className="mx-auto mt-6 max-w-[44ch] text-[18px] text-graphite">
          talkflow types into whichever text field has your cursor. No copying, no pasting.
        </p>
      </div>
    </section>
  );
}
