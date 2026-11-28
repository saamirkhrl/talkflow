import { AppTour } from "./AppTour";
import { SectionTitle } from "./primitives";

// Words written over one minute at each speed. One unit is one px: the plot
// runs from y=180 (0 words) up to y=20 (160 words), and x=36..400 is 0..60 s.
const X0 = 36;
const X1 = 400;
const Y0 = 180;
const TYPING = 40;
const SPEAKING = 145;

function SpeedChart() {
  return (
    <figure className="mt-10 max-w-[460px]">
      <svg viewBox="0 0 440 214" className="w-full overflow-visible" role="img" aria-labelledby="speed-chart-title">
        <title id="speed-chart-title">{`Words written in one minute: about ${TYPING} typing, about ${SPEAKING} speaking.`}</title>
        <defs>
          <linearGradient id="speak-fill" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stopColor="#fff" stopOpacity="0.22" />
            <stop offset="1" stopColor="#fff" stopOpacity="0" />
          </linearGradient>
        </defs>
        {[0, 50, 100, 150].map((v) => (
          <g key={v}>
            <line x1={X0} x2={X1} y1={Y0 - v} y2={Y0 - v} stroke="#fff" strokeOpacity={v === 0 ? 0.35 : 0.1} />
            <text x={X0 - 10} y={Y0 - v + 4} textAnchor="end" className="fill-white/50 text-[11px]">
              {v}
            </text>
          </g>
        ))}
        <path d={`M${X0} ${Y0} L${X1} ${Y0 - SPEAKING} L${X1} ${Y0} Z`} fill="url(#speak-fill)" />
        <line x1={X0} y1={Y0} x2={X1} y2={Y0 - TYPING} stroke="#fff" strokeOpacity="0.45" strokeWidth="2.5" strokeLinecap="round" strokeDasharray="1 6" />
        <line x1={X0} y1={Y0} x2={X1} y2={Y0 - SPEAKING} stroke="#fff" strokeWidth="3" strokeLinecap="round" />
        <circle cx={X1} cy={Y0 - TYPING} r="4" className="fill-white/60" />
        <circle cx={X1} cy={Y0 - SPEAKING} r="5" fill="#fff" />
        <text x={X1 - 8} y={Y0 - SPEAKING - 14} textAnchor="end" className="fill-white text-[14px] font-medium">
          Speaking <tspan className="font-serif text-[20px]">{SPEAKING}</tspan> wpm
        </text>
        <text x={X1 - 8} y={Y0 - TYPING - 14} textAnchor="end" className="fill-white/60 text-[14px]">
          Typing <tspan className="font-serif text-[20px]">{TYPING}</tspan> wpm
        </text>
        <text x={X0} y="206" className="fill-white/50 text-[11px]">0s</text>
        <text x={(X0 + X1) / 2} y="206" textAnchor="middle" className="fill-white/50 text-[11px]">30s</text>
        <text x={X1} y="206" textAnchor="end" className="fill-white/50 text-[11px]">1 min</text>
      </svg>
      <figcaption className="mt-2 text-[13px] text-white/60">Words written in one minute</figcaption>
    </figure>
  );
}

export function Prompting() {
  return (
    <section className="mx-auto max-w-[1200px] px-gutter pt-[clamp(40px,5vw,64px)] pb-[clamp(56px,7vw,96px)]">
      <div className="grid gap-x-16 gap-y-6 lg:grid-cols-[minmax(0,5fr)_minmax(0,7fr)]">
        {/* Pinned beside the app tour on wide screens, so the copy stays put while the apps change. */}
        <div className="lg:sticky lg:top-24 lg:self-start lg:pt-12">
          <SectionTitle>Say the whole thought.</SectionTitle>
          <p className="mt-6 max-w-[42ch] text-[18px] text-graphite">
            Most people talk much faster than they type, so the context you would normally skip, the edge cases and the
            &quot;and also&quot;, makes it into what you write. Better prompts, emails and messages for the same effort.
          </p>
          <SpeedChart />
        </div>
        <AppTour />
      </div>
    </section>
  );
}
