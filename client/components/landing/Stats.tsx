import { ChevronDown } from "lucide-react";
import { AppIcon } from "@/components/brand/Logo";
import { DASHBOARD } from "./content";
import { SectionTitle, wallpaperStyle } from "./primitives";
import { ForOs } from "./visitor";

const WEEKS = 26;
const MONTHS = ["Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct"];
// Grey of each activity level, lightest day first; level 0 is a day with nothing dictated.
const LEVELS = ["bg-paper/9", "bg-paper/25", "bg-paper/40", "bg-paper/60", "bg-paper/80", "bg-paper/95"];

// Example activity: quiet for the first months, then a daily habit. Fixed numbers, so the
// server and the browser draw the same grid.
const CELLS = Array.from({ length: WEEKS * 7 }, (_, i) => {
  const week = Math.floor(i / 7);
  if (week < 17) return 0;
  const n = (i * 2654435761) >>> 0;
  return 1 + ((n >>> 7) % 5);
});

function Heatmap() {
  return (
    <div className="mt-7">
      <div className="flex items-center justify-between text-[12px] text-fog">
        <span>Last {WEEKS} weeks</span>
        <span className="flex items-center gap-1 text-paper">
          <ChevronDown size={13} aria-hidden="true" />
          Grid
        </span>
      </div>
      <div className="mt-3 grid grid-cols-[24px_1fr] gap-x-2 text-[11px] text-fog">
        <span />
        <div className="flex justify-between pr-2">
          {MONTHS.map((m) => (
            <span key={m}>{m}</span>
          ))}
        </div>
        <div className="grid grid-rows-7 items-center py-px">
          {["", "Mon", "", "Wed", "", "Fri", ""].map((d, i) => (
            <span key={i} className="leading-none">
              {d}
            </span>
          ))}
        </div>
        <div aria-hidden="true" className="grid grid-flow-col grid-rows-7 gap-[3px]">
          {CELLS.map((level, i) => (
            <span key={i} className={`aspect-square rounded-[3px] ${LEVELS[level]}`} />
          ))}
        </div>
      </div>
    </div>
  );
}

export function Stats() {
  const [total, ...rest] = DASHBOARD;

  return (
    <section className="mx-auto max-w-[1200px] px-gutter py-[clamp(72px,10vw,136px)]">
      <div className="grid items-end gap-x-16 gap-y-8 lg:grid-cols-2">
        <SectionTitle className="max-w-[14ch]">See how much you didn&apos;t type.</SectionTitle>
        <p className="max-w-[44ch] text-[18px] text-graphite lg:justify-self-end">
          <ForOs mac="Open Dashboard from the menu bar" windows="Open talkflow from the tray" /> to see your words, speed, streak
          and the typing time you&apos;ve saved. It&apos;s worked out on your <ForOs mac="Mac" windows="computer" /> and stays
          there.
        </p>
      </div>

      <figure className="mt-14">
        <div className="grid place-items-center rounded-3xl px-4 py-10 sm:py-14" style={wallpaperStyle}>
          <div className="w-full max-w-[560px] overflow-hidden rounded-xl border border-white/15 bg-ink text-paper shadow-[0_40px_80px_-24px_rgba(0,10,40,0.6)]">
            <div aria-hidden="true" className="flex gap-2 px-4 pt-3.5">
              {["#ff5f57", "#febc2e", "#28c840"].map((c) => (
                <span key={c} className="size-3 rounded-full" style={{ backgroundColor: c }} />
              ))}
            </div>
            <div className="px-6 pt-5 pb-7 sm:px-7">
              <div className="flex items-start justify-between gap-4">
                <div className="mt-2 flex items-center gap-3 sm:gap-4">
                  <AppIcon className="size-9 rounded-lg ring-1 ring-white/20 sm:size-11" />
                  <span className="font-serif text-[26px] tracking-[-0.01em] sm:text-[32px]">talkflow</span>
                </div>
                <div className="flex flex-col items-end gap-2.5 text-[12px] text-fog">
                  <span>
                    v0.1.7 <span className="ml-1.5 text-paper underline underline-offset-2">Up to date</span>
                  </span>
                  <span className="flex rounded-full bg-paper/10 p-0.5 text-[13px]">
                    <span className="rounded-full bg-paper px-3 py-1 font-medium text-ink">Dashboard</span>
                    <span className="px-3 py-1 text-paper">Settings</span>
                  </span>
                </div>
              </div>

              <p className="mt-7 text-[13px] text-fog">Total words dictated</p>
              <p className="mt-1 font-serif text-[clamp(56px,10vw,84px)] leading-none tracking-[-0.02em] tabular-nums">{total.value}</p>

              <dl className="mt-7 grid grid-cols-2 rounded-xl border border-paper/15 sm:grid-cols-4">
                {rest.map((s, i) => (
                  <div key={s.label} className={`px-4 py-3.5 ${i > 0 ? "sm:border-l sm:border-paper/15" : ""} ${i % 2 ? "border-l border-paper/15 sm:border-l" : ""}`}>
                    <dt className="text-[12px] text-fog">{s.label}</dt>
                    <dd className="mt-1 flex items-baseline gap-1">
                      <span className="font-serif text-[24px] leading-none tabular-nums">{s.value}</span>
                      {s.unit && <span className="text-[12px] text-fog">{s.unit}</span>}
                    </dd>
                  </div>
                ))}
              </dl>

              <Heatmap />
            </div>
          </div>
        </div>
        <figcaption className="mt-4 text-[13px] text-graphite">
          Example numbers. Time saved compares your speaking time with typing the same words at 40 wpm.
        </figcaption>
      </figure>
    </section>
  );
}
