"use client";

import { Plus } from "lucide-react";
import { useState } from "react";
import { cn } from "@/lib/cn";
import { FAQ } from "./content";
import { SectionTitle } from "./primitives";

export function Faq() {
  const [open, setOpen] = useState(0);

  return (
    <section id="faq" className="mx-auto max-w-[1200px] px-gutter py-[clamp(72px,10vw,136px)]">
      <div className="grid gap-x-16 gap-y-10 lg:grid-cols-[minmax(0,4fr)_minmax(0,8fr)]">
        <SectionTitle>FAQs</SectionTitle>
        <div className="border-t border-line">
          {FAQ.map(([question, answer], i) => {
            const isOpen = open === i;
            return (
              <div key={question} className="border-b border-line">
                <h3>
                  <button
                    type="button"
                    id={`faq-b${i}`}
                    aria-expanded={isOpen}
                    aria-controls={`faq-p${i}`}
                    onClick={() => setOpen(isOpen ? -1 : i)}
                    className="flex w-full cursor-pointer items-center justify-between gap-6 py-6 text-left text-[20px] leading-snug font-medium transition-colors hover:text-graphite"
                  >
                    {question}
                    <Plus
                      size={20}
                      strokeWidth={1.75}
                      aria-hidden="true"
                      className={cn("flex-none transition-transform duration-300", isOpen && "rotate-45")}
                    />
                  </button>
                </h3>
                {isOpen && (
                  <p id={`faq-p${i}`} role="region" aria-labelledby={`faq-b${i}`} className="max-w-[60ch] pr-10 pb-7 text-[17px] text-graphite">
                    {answer}
                  </p>
                )}
              </div>
            );
          })}
        </div>
      </div>
    </section>
  );
}
