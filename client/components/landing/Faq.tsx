"use client";

import { Plus } from "lucide-react";
import { useState } from "react";
import { cn } from "@/lib/cn";
import { FAQ } from "./content";
import { Section } from "./primitives";

export function Faq() {
  const [open, setOpen] = useState(0);

  return (
    <Section id="faq" index="05" title="FAQ">
      <div className="grid grid-cols-[repeat(auto-fit,minmax(min(100%,300px),1fr))] gap-x-[clamp(32px,6vw,88px)] gap-y-8">
        <h2 className="font-display text-[clamp(34px,4.4vw,56px)] leading-[1.02] font-normal tracking-[-0.015em]">
          Questions, answered.
        </h2>
        <div className="col-span-full min-w-0 border-t border-divider min-[720px]:col-span-2">
          {FAQ.map(([question, answer], i) => {
            const isOpen = open === i;
            return (
              <div key={question} className="border-b border-divider">
                <h3>
                  <button
                    type="button"
                    id={`faq-b${i}`}
                    aria-expanded={isOpen}
                    aria-controls={`faq-p${i}`}
                    onClick={() => setOpen(isOpen ? -1 : i)}
                    className="flex w-full cursor-pointer items-center justify-between gap-5 px-1 py-[22px] text-left font-heading text-[22px] leading-[1.25] font-semibold hover:text-ink-accent"
                  >
                    <span>{question}</span>
                    <Plus
                      size={20}
                      strokeWidth={1.5}
                      aria-hidden="true"
                      className={cn("flex-none transition-transform duration-250", isOpen && "rotate-45")}
                    />
                  </button>
                </h3>
                {isOpen && (
                  <div id={`faq-p${i}`} role="region" aria-labelledby={`faq-b${i}`} className="max-w-[62ch] pr-12 pb-6 pl-1 text-[16px] text-muted">
                    {answer}
                  </div>
                )}
              </div>
            );
          })}
        </div>
      </div>
    </Section>
  );
}
