import { cn } from "@/lib/cn";
import { MEDIA } from "./content";
import { ImageSlot, Section } from "./primitives";

const SPEEDS = [
  { label: "Typing", wpm: 45, width: "31%", accent: false },
  { label: "Speaking", wpm: 145, width: "100%", accent: true },
];

export function Prompting() {
  return (
    <Section index="02" title="Built for prompting">
      <div className="grid grid-cols-[repeat(auto-fit,minmax(min(100%,400px),1fr))] items-center gap-x-[clamp(32px,6vw,88px)] gap-y-12">
        <div className="flex flex-col gap-6">
          <h2 className="font-display text-[clamp(34px,4.4vw,56px)] leading-[1.02] font-normal tracking-[-0.015em]">
            Say the whole thought.
          </h2>
          <p className="max-w-[46ch] text-[18px] text-muted">
            Speaking is roughly three times faster than typing. So the context you&apos;d normally skip, the edge cases, the
            &quot;and also&quot;, makes it into the prompt. Better prompts, same effort.
          </p>
          <div className="mt-2 flex flex-col gap-4">
            {SPEEDS.map((s) => (
              <div key={s.label} className="grid grid-cols-[84px_1fr_72px] items-center gap-3.5">
                <span className={cn("text-[14px]", !s.accent && "text-muted")}>{s.label}</span>
                <div className={cn("h-3 border", s.accent ? "border-accent" : "border-divider")}>
                  <div className={cn("h-full", s.accent ? "bg-accent" : "bg-neutral-400")} style={{ width: s.width }} />
                </div>
                <span className="text-right font-heading text-[20px] tabular-nums">
                  ~{s.wpm} <span className="text-[13px] text-muted">wpm</span>
                </span>
              </div>
            ))}
          </div>
        </div>

        <div className="rounded-3xl bg-[radial-gradient(120%_90%_at_15%_0%,var(--color-accent-700),var(--color-accent-900)_70%)] p-[clamp(20px,4vw,52px)] shadow-lg">
          <div className="relative aspect-[4/3] w-full overflow-hidden rounded-[14px] bg-neutral-900/70 shadow-[0_24px_60px_rgba(0,0,0,.35)]">
            <ImageSlot
              src={MEDIA.promptTerminal}
              alt="A long, detailed prompt dictated into a terminal coding agent"
              placeholder="Drop your terminal screenshot (PNG)"
              sizes="(max-width: 900px) 100vw, 500px"
              className="text-[14px] text-neutral-300"
            />
          </div>
        </div>
      </div>
    </Section>
  );
}
