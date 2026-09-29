"use client";

import { useState } from "react";
import { cn } from "@/lib/cn";
import { STATS, type StatsRange } from "./content";
import { Blueprint, labelClass, LiveDot, Section } from "./primitives";

const HEAT_LEVEL = ["border border-divider", "bg-accent/35", "bg-accent/65", "bg-accent"];

// Eight weeks of fake activity: nothing for the first five days, then a
// deterministic mix of light, medium and heavy days.
const HEAT = Array.from({ length: 56 }, (_, i) => {
  const level = i >= 5 ? [1, 2, 3, 2, 3, 3, 1, 2, 3, 2][(i * 7 + 3) % 10] : 0;
  return { level, title: level ? `Day ${i - 4}` : "No dictation" };
});

const RANGES: [StatsRange, string][] = [
  ["week", "This week"],
  ["all", "All time"],
];

export function Stats() {
  const [range, setRange] = useState<StatsRange>("all");

  return (
    <Section index="04" title="Your stats">
      <div className="mb-12 flex flex-wrap items-end justify-between gap-6">
        <h2 className="max-w-[15ch] font-display text-[clamp(34px,4.4vw,56px)] leading-[1.02] font-normal tracking-[-0.015em]">
          Watch the keyboard time melt away.
        </h2>
        <p className="max-w-[40ch] text-[17px] text-muted">
          A private dashboard tracks every word you speak instead of type. Computed on your machine, for your eyes only.
        </p>
      </div>

      <Blueprint className="bg-bg shadow-lg">
        <div className="flex flex-wrap items-center justify-between gap-3 border-b border-divider px-5 py-3.5">
          <span className="flex items-center gap-2.5 font-heading text-[19px] font-semibold">
            <LiveDot className="size-[9px]" />
            Your TalkFlow
          </span>
          <div role="radiogroup" aria-label="Stats range" className="inline-flex divide-x divide-divider overflow-hidden border border-divider">
            {RANGES.map(([value, label]) => (
              <label
                key={value}
                className="inline-flex cursor-pointer items-center px-3 py-[7px] text-[13px] hover:bg-ink/7 has-checked:bg-accent has-checked:text-bg has-focus-visible:outline-2 has-focus-visible:-outline-offset-2 has-focus-visible:outline-accent"
              >
                <input type="radio" name="tf-range" className="sr-only" checked={range === value} onChange={() => setRange(value)} />
                {label}
              </label>
            ))}
          </div>
        </div>

        <div className="grid grid-cols-1 min-[600px]:grid-cols-2 min-[1080px]:grid-cols-4">
          {STATS[range].map((s) => (
            <div key={s.label} className="-mr-px border-r border-b border-divider px-6 pt-7 pb-[26px]">
              <span className={cn(labelClass, "block text-muted")}>{s.label}</span>
              <div className="mt-2.5 mb-1.5 flex items-baseline gap-2">
                <span className="font-heading text-[clamp(48px,5vw,64px)] leading-none font-semibold tracking-[-0.01em] tabular-nums">
                  {s.value}
                </span>
                <span className="font-heading text-[20px] text-muted">{s.unit}</span>
              </div>
              <span className="text-[14px] text-ink-accent">{s.note}</span>
            </div>
          ))}
        </div>

        <div className="flex flex-wrap items-end justify-between gap-x-10 gap-y-5 p-6">
          <div className="flex min-w-0 flex-col gap-3">
            <span className={cn(labelClass, "text-muted")}>Last 8 weeks</span>
            <div className="grid auto-cols-[14px] grid-flow-col grid-rows-[repeat(7,14px)] gap-1">
              {HEAT.map((cell, i) => (
                <span key={i} title={cell.title} className={HEAT_LEVEL[cell.level]} />
              ))}
            </div>
          </div>
          <div className="flex items-center gap-2.5 text-[14px] text-muted">
            <span>Less</span>
            {HEAT_LEVEL.map((cls) => (
              <span key={cls} className={cn("size-3.5", cls)} />
            ))}
            <span>More</span>
          </div>
        </div>
      </Blueprint>
    </Section>
  );
}
