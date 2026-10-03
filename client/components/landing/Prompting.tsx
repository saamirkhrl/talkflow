import { cn } from "@/lib/cn";
import { AppTour } from "./AppTour";
import { SectionTitle } from "./primitives";

const SPEEDS = [
  { label: "Typing", wpm: 40, width: "28%", strong: false },
  { label: "Speaking", wpm: 145, width: "100%", strong: true },
];

export function Prompting() {
  return (
    <section className="mx-auto max-w-[1200px] px-gutter py-[clamp(72px,10vw,136px)]">
      <div className="grid gap-x-16 gap-y-6 lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)]">
        {/* Pinned beside the app tour on wide screens, so the copy stays put while the apps change. */}
        <div className="lg:sticky lg:top-0 lg:flex lg:h-svh lg:flex-col lg:justify-center lg:self-start lg:pt-16">
          <SectionTitle>Say the whole thought.</SectionTitle>
          <p className="mt-6 max-w-[42ch] text-[18px] text-graphite">
            Most people talk much faster than they type, so the context you would normally skip, the edge cases and the
            &quot;and also&quot;, makes it into what you write. Better prompts, emails and messages for the same effort.
          </p>
          <dl className="mt-10 flex max-w-[440px] flex-col gap-4">
            {SPEEDS.map((s) => (
              <div key={s.label} className="grid grid-cols-[80px_1fr_76px] items-center gap-4">
                <dt className={cn("text-[15px]", !s.strong && "text-graphite")}>{s.label}</dt>
                <div className="h-2 rounded-full bg-ink/8" aria-hidden="true">
                  <div className={cn("h-full rounded-full", s.strong ? "bg-ink" : "bg-ink/30")} style={{ width: s.width }} />
                </div>
                <dd className="text-right font-serif text-[22px] tabular-nums">
                  {s.wpm} <span className="font-sans text-[13px] text-graphite">wpm</span>
                </dd>
              </div>
            ))}
          </dl>
        </div>
        <AppTour />
      </div>
    </section>
  );
}
