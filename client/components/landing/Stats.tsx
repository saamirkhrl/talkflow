import { AppIcon } from "@/components/brand/Logo";
import { DASHBOARD } from "./content";
import { SectionTitle } from "./primitives";

export function Stats() {
  return (
    <section className="mx-auto max-w-[1200px] px-gutter py-[clamp(72px,10vw,136px)]">
      <div className="grid items-end gap-x-16 gap-y-8 lg:grid-cols-2">
        <SectionTitle className="max-w-[14ch]">See how much you didn&apos;t type.</SectionTitle>
        <p className="max-w-[44ch] text-[18px] text-graphite lg:justify-self-end">
          Open Dashboard from the menu bar to see your words, speed, streak and the typing time you&apos;ve saved. It&apos;s
          worked out on your Mac and stays there.
        </p>
      </div>

      <figure className="mt-14">
        <div className="overflow-hidden rounded-2xl border border-line bg-paper shadow-[0_30px_60px_-34px_rgba(31,30,34,0.35)]">
          <div className="flex h-11 items-center gap-3 border-b border-line px-4">
            <div className="flex gap-[7px]">
              {[0, 1, 2].map((i) => (
                <span key={i} className="size-[11px] rounded-full bg-ink/12" />
              ))}
            </div>
            <span className="flex flex-1 items-center justify-center gap-2 text-[13px] text-graphite">
              <AppIcon className="size-4" />
              Your dictation stats
            </span>
            <span className="w-[47px]" />
          </div>
          <dl className="grid grid-cols-2 md:grid-cols-3">
            {DASHBOARD.map((s) => (
              <div key={s.label} className="-mr-px -mb-px border-r border-b border-line px-6 py-7 sm:px-8">
                <dt className="text-[14px] text-graphite">{s.label}</dt>
                <dd className="mt-2 flex items-baseline gap-1.5">
                  <span className="font-serif text-[clamp(40px,5vw,60px)] leading-none tracking-[-0.02em] tabular-nums">{s.value}</span>
                  {s.unit && <span className="text-[15px] text-graphite">{s.unit}</span>}
                </dd>
              </div>
            ))}
          </dl>
        </div>
        <figcaption className="mt-4 text-[13px] text-graphite">
          Example numbers. Time saved compares your speaking time with typing the same words at 40 wpm.
        </figcaption>
      </figure>
    </section>
  );
}
