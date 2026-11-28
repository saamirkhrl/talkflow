"use client";

import { Check } from "lucide-react";
import { useEffect, useState } from "react";
import { APP_LOGOS } from "./brand-logos.generated";
import { BrandLogo } from "./BrandLogo";
import { useReducedMotion } from "./visitor";

// Step 3: what is waiting in the app when you let go. The sentences are real
// talkflow output (the same pairs as the hero ribbon).
const RESULTS = [
  { app: "Slack", text: "Let's ship it tonight 🚀" },
  { app: "Gmail", text: "Hi Sam, thanks for the notes. I'll send the draft by Friday." },
  { app: "Notion", text: "First, fix the retry logic. Second, add a test for the timeout." },
];
const LOGOS = RESULTS.map((r) => APP_LOGOS.find((l) => l.name === r.app));

export function LetGoDemo() {
  const reduced = useReducedMotion();
  const [i, setI] = useState(0);

  useEffect(() => {
    if (reduced) return;
    const t = window.setInterval(() => setI((n) => (n + 1) % RESULTS.length), 3000);
    return () => window.clearInterval(t);
  }, [reduced]);

  const logo = LOGOS[i];
  return (
    <div key={i} className="w-full max-w-[280px] animate-[pop-in_400ms_ease-out] rounded-2xl bg-white p-3 text-left text-[#0b1f66] shadow-[0_14px_30px_-16px_rgb(4_16_80/0.6)]">
      <div className="flex items-center gap-2">
        {logo && <BrandLogo logo={logo} className="size-5" />}
        <span className="text-[13px] font-semibold">{RESULTS[i].app}</span>
        <span className="ml-auto inline-flex items-center gap-1 rounded-full bg-[#e7ecfb] px-2 py-0.5 text-[11px] font-medium">
          <Check className="size-3" strokeWidth={3} aria-hidden="true" />
          Typed
        </span>
      </div>
      <p className="mt-2 text-[14px] leading-snug">{RESULTS[i].text}</p>
    </div>
  );
}
