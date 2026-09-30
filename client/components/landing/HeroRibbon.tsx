"use client";

import { useEffect, useId, useMemo, useRef, useState } from "react";
import { RecDot, Waveform } from "./primitives";

// Real before/after pairs from the app's own formatter (`talkflowd --formattest`,
// see FACTS.md). "/" marks a line break in the real output; the ribbon is one
// line, so it becomes a space.
const PAIRS = [
  {
    say: "um so the checkout form is double submitting when someone taps pay twice uh can you add a loading state that disables the button after the first click question mark",
    get: "So the checkout form is double submitting when someone taps pay twice. Can you add a loading state that disables the button after the first click?",
  },
  {
    say: "hmm let's ship it tonight rocket emoji",
    get: "Let's ship it tonight 🚀",
  },
  {
    say: "okay so uh three things first fix the retry logic second um add a test for the timeout third update the changelog",
    get: "Okay so three things. / First, fix the retry logic. / Second, add a test for the timeout. / Third, update the changelog.",
  },
  {
    say: "hi sam comma new paragraph thanks for the notes um I'll send the draft by friday best comma samir",
    get: "Hi Sam, thanks for the notes. I'll send the draft by Friday. / Best, Samir",
  },
];

const FEATURES = ["Filler words removed", "Punctuation added", "Emoji by name", "Lists formatted"];

// One plain space between pairs keeps the ribbon continuous.
const GAP = " ";
const SAY = PAIRS.map((p) => p.say).join(GAP) + GAP;
const GET = PAIRS.map((p) => p.get.replaceAll(" / ", " ")).join(GAP) + GAP;
// The offset lives in [-period, 0), so the text must reach one period past the
// path end. A copy is ~3,100px (say) / ~2,800px (get) at desktop sizes, more
// than half of either path even on very wide screens, so three copies suffice.
const COPIES = 3;

// px per second along the path. The clean text leaves about 3x faster than
// the spoken text arrives. Phones show only ~200px of each path, so both run a
// little slower there to stay readable.
const SPEED = { say: 35, get: 110 };
const SPEED_SMALL = { say: 28, get: 86 };
const BADGE_MS = 2500;

type Geo = { w: number; h: number; cx: number; cy: number; pw: number; ph: number };

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
const mod = (v: number, m: number) => ((v % m) + m) % m;
const f = (n: number) => n.toFixed(1);

// Both paths are built in CSS pixels around the pill's measured box, so text
// size and speed stay true at every width.
function layout(g: Geo) {
  const small = g.w < 640;
  const inset = g.ph / 2; // joins sit at the centers of the pill's round ends
  const ex = g.cx - g.pw / 2 + inset;
  const sx = g.cx + g.pw / 2 - inset;
  const { cy, w, h } = g;

  // The spoken text runs along `left`, then continues along `tail` when there
  // is one (the tail is drawn over the way in where the loop crosses itself).
  let left: string;
  let tail: string | null = null;
  let right: string;

  if (small) {
    // A single flat swoop in from the top left, and a short gentle rise.
    const s = { x: -40, y: cy - h * 0.34 };
    const dx = ex - s.x;
    left = `M${f(s.x)} ${f(s.y)} C${f(s.x + dx * 0.55)} ${f(s.y)} ${f(ex - dx * 0.55)} ${f(cy)} ${f(ex)} ${f(cy)}`;
    const e = { x: w + 30, y: cy - h * 0.28 };
    const rx = e.x - sx;
    right = `M${f(sx)} ${f(cy)} C${f(sx + rx * 0.5)} ${f(cy)} ${f(e.x - rx * 0.35)} ${f(e.y + h * 0.05)} ${f(e.x)} ${f(e.y)}`;
  } else {
    // In from the upper left, one counter-clockwise loop, then a long descent
    // that crosses the way in almost square-on and flattens into the pill.
    const r = clamp(h * 0.22, 60, 92);
    const lx = clamp(w * 0.2, r + 110, ex - r * 3.4);
    const ly = r + h * 0.05;
    const k = r * 0.5523; // cubic circle constant
    const s = { x: -60, y: ly + r * 0.5 };
    const b = { x: lx, y: ly + r };
    const run = b.x - s.x;
    const out = ex - (lx - r);
    left = [
      `M${f(s.x)} ${f(s.y)}`,
      `C${f(s.x + run * 0.45)} ${f(s.y)} ${f(b.x - run * 0.5)} ${f(b.y)} ${f(b.x)} ${f(b.y)}`,
      `C${f(b.x + k)} ${f(b.y)} ${f(lx + r)} ${f(ly + k)} ${f(lx + r)} ${f(ly)}`,
      `C${f(lx + r)} ${f(ly - k)} ${f(lx + k)} ${f(ly - r)} ${f(lx)} ${f(ly - r)}`,
      `C${f(lx - k)} ${f(ly - r)} ${f(lx - r)} ${f(ly - k)} ${f(lx - r)} ${f(ly)}`,
    ].join(" ");
    tail = `M${f(lx - r)} ${f(ly)} C${f(lx - r)} ${f(ly + (cy - ly) * 1.05)} ${f(lx - r + out * 0.3)} ${f(cy)} ${f(ex)} ${f(cy)}`;
    const e = { x: w + 60, y: cy - clamp(h * 0.42, 110, 180) };
    const rx = e.x - sx;
    right = `M${f(sx)} ${f(cy)} C${f(sx + rx * 0.45)} ${f(cy)} ${f(e.x - rx * 0.3)} ${f(e.y + 24)} ${f(e.x)} ${f(e.y)}`;
  }

  return {
    small,
    left,
    tail,
    right,
    inset,
    sayFont: small ? 15 : 18,
    getFont: small ? 14 : 16,
    stroke: small ? 26 : 30,
    fade: small ? 36 : clamp(w * 0.12, 120, 220),
  };
}

export function HeroRibbon() {
  const uid = useId();
  const sayId = `${uid}say`;
  const tailId = `${uid}tail`;
  const getId = `${uid}get`;

  const bandRef = useRef<HTMLDivElement>(null);
  const pillRef = useRef<HTMLDivElement>(null);
  const badgesRef = useRef<HTMLDivElement>(null);
  const sayPathRef = useRef<SVGPathElement>(null);
  const sayTextRef = useRef<SVGTextElement>(null);
  const tailPathRef = useRef<SVGPathElement>(null);
  const tailTextRef = useRef<SVGTextElement>(null);
  const getTextRef = useRef<SVGTextElement>(null);
  const sayMeasureRef = useRef<SVGTextElement>(null);
  const getMeasureRef = useRef<SVGTextElement>(null);
  const leftSvgRef = useRef<SVGSVGElement>(null);
  const rightSvgRef = useRef<SVGSVGElement>(null);

  const [geo, setGeo] = useState<Geo | null>(null);
  const shape = useMemo(() => (geo ? layout(geo) : null), [geo]);

  // Measure the band and the pill (CSS owns their size and position).
  useEffect(() => {
    const band = bandRef.current;
    const pill = pillRef.current;
    if (!band || !pill) return;
    const ro = new ResizeObserver(() => {
      const b = band.getBoundingClientRect();
      const p = pill.getBoundingClientRect();
      const next: Geo = {
        w: Math.round(b.width),
        h: Math.round(b.height),
        cx: p.left - b.left + p.width / 2,
        cy: p.top - b.top + p.height / 2,
        pw: p.width,
        ph: p.height,
      };
      setGeo((prev) =>
        prev && (Object.keys(next) as (keyof Geo)[]).every((key) => Math.abs(prev[key] - next[key]) < 0.5) ? prev : next,
      );
    });
    ro.observe(band);
    ro.observe(pill);
    return () => ro.disconnect();
  }, []);

  // Drive both texts and the badge from one rAF loop, writing to the DOM directly.
  useEffect(() => {
    const band = bandRef.current;
    const badges = badgesRef.current;
    const sayPath = sayPathRef.current;
    const sayText = sayTextRef.current;
    const tailPath = tailPathRef.current;
    const tailText = tailTextRef.current;
    const getText = getTextRef.current;
    const sayMeasure = sayMeasureRef.current;
    const getMeasure = getMeasureRef.current;
    const svgs = [leftSvgRef.current, rightSvgRef.current];
    if (!geo || !shape || !band || !badges || !sayPath || !sayText || !getText || !sayMeasure || !getMeasure) return;

    const speed = shape.small ? SPEED_SMALL : SPEED;
    // Offsets are measured along the whole spoken path (way in, then tail).
    const inLength = sayPath.getTotalLength();
    const sayLength = inLength + (tailPath?.getTotalLength() ?? 0);
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)");
    let sayPeriod = 0;
    let getPeriod = 0;
    let sayOffset = 0;
    let getOffset = 0;
    let badge = 0;
    let badgeClock = 0;
    let raf = 0;
    let last = 0;
    let ready = false;
    let onScreen = true;
    let cancelled = false;

    const apply = () => {
      sayText.setAttribute("x", sayOffset.toFixed(2));
      tailText?.setAttribute("x", (sayOffset - inLength).toFixed(2));
      getText.setAttribute("x", getOffset.toFixed(2));
    };

    const showBadge = (i: number) => {
      Array.from(badges.children).forEach((el, j) => {
        (el as HTMLElement).style.opacity = j === i ? "1" : "0";
      });
    };

    const measure = () => {
      sayPeriod = sayMeasure.getSubStringLength(0, SAY.length);
      getPeriod = getMeasure.getSubStringLength(0, GET.length);
    };

    // The resting frame: the first spoken sentence ends at the pill and its
    // clean version starts just outside it.
    const compose = () => {
      measure();
      const firstSay = sayMeasure.getSubStringLength(0, PAIRS[0].say.length);
      const sayEnd = sayLength - shape.inset - 10;
      sayOffset = mod(sayEnd - firstSay, sayPeriod) - sayPeriod;
      getOffset = mod(shape.inset + 12, getPeriod) - getPeriod;
      badge = 0;
      badgeClock = 0;
      showBadge(0);
      apply();
    };

    const frame = (t: number) => {
      const dt = last ? Math.min(t - last, 100) / 1000 : 0;
      last = t;
      sayOffset += speed.say * dt;
      if (sayOffset >= 0) sayOffset -= sayPeriod;
      getOffset += speed.get * dt;
      if (getOffset >= 0) getOffset -= getPeriod;
      apply();
      badgeClock += dt * 1000;
      if (badgeClock >= BADGE_MS) {
        badgeClock -= BADGE_MS;
        badge = (badge + 1) % FEATURES.length;
        showBadge(badge);
      }
      raf = requestAnimationFrame(frame);
    };

    const sync = () => {
      const go = ready && onScreen && !document.hidden && !reduce.matches;
      if (go && !raf) {
        last = 0;
        raf = requestAnimationFrame(frame);
      } else if (!go && raf) {
        cancelAnimationFrame(raf);
        raf = 0;
      }
    };

    const onReduce = () => {
      if (reduce.matches && ready) compose();
      sync();
    };

    // A late font swap changes glyph widths: re-measure and keep the phase.
    const onFonts = () => {
      if (!ready) return;
      const sayPhase = (sayOffset + sayPeriod) / sayPeriod;
      const getPhase = (getOffset + getPeriod) / getPeriod;
      measure();
      sayOffset = sayPhase * sayPeriod - sayPeriod;
      getOffset = getPhase * getPeriod - getPeriod;
      apply();
    };

    const io = new IntersectionObserver(([entry]) => {
      onScreen = entry.isIntersecting;
      sync();
    });
    io.observe(band);
    document.addEventListener("visibilitychange", sync);
    reduce.addEventListener("change", onReduce);
    document.fonts.addEventListener("loadingdone", onFonts);

    document.fonts.ready.then(() => {
      if (cancelled) return;
      compose();
      ready = true;
      svgs.forEach((svg) => svg?.style.setProperty("opacity", "1"));
      sync();
    });

    return () => {
      cancelled = true;
      cancelAnimationFrame(raf);
      io.disconnect();
      document.removeEventListener("visibilitychange", sync);
      reduce.removeEventListener("change", onReduce);
      document.fonts.removeEventListener("loadingdone", onFonts);
    };
  }, [geo, shape]);

  return (
    <div className="pointer-events-none relative mt-auto sm:-mt-[clamp(40px,min(9vw,18svh),136px)]">
      <p className="sr-only">Spoken words go into TalkFlow and come out as clean, punctuated text.</p>
      <div
        ref={bandRef}
        aria-hidden="true"
        className="relative h-[210px] w-full overflow-hidden select-none sm:h-[clamp(240px,min(27vw,42svh),400px)]"
      >
        {geo && shape && (
          <>
            <svg
              ref={leftSvgRef}
              width={geo.w}
              height={geo.h}
              viewBox={`0 0 ${geo.w} ${geo.h}`}
              className="absolute inset-0 opacity-0 transition-opacity duration-700"
              style={{
                maskImage: `linear-gradient(90deg, transparent, #000 ${shape.fade}px)`,
                WebkitMaskImage: `linear-gradient(90deg, transparent, #000 ${shape.fade}px)`,
              }}
            >
              <path ref={sayPathRef} id={sayId} d={shape.left} fill="none" />
              <text
                ref={sayTextRef}
                className="fill-graphite font-serif italic"
                fontSize={shape.sayFont}
                dominantBaseline="central"
              >
                <textPath href={`#${sayId}`}>{SAY.repeat(COPIES)}</textPath>
              </text>
              {shape.tail && (
                <>
                  <path ref={tailPathRef} id={tailId} d={shape.tail} fill="none" />
                  {/* A paper halo on the tail's own glyphs clears the way in only
                      under the letters, so no word is wiped out at the crossing. */}
                  <text
                    ref={tailTextRef}
                    className="fill-graphite stroke-paper font-serif italic"
                    fontSize={shape.sayFont}
                    dominantBaseline="central"
                    strokeWidth={4}
                    strokeLinejoin="round"
                    style={{ paintOrder: "stroke" }}
                  >
                    <textPath href={`#${tailId}`}>{SAY.repeat(COPIES)}</textPath>
                  </text>
                </>
              )}
              <text ref={sayMeasureRef} className="font-serif italic" fontSize={shape.sayFont} x="0" y="-200" visibility="hidden">
                {SAY + SAY}
              </text>
            </svg>
            <svg
              ref={rightSvgRef}
              width={geo.w}
              height={geo.h}
              viewBox={`0 0 ${geo.w} ${geo.h}`}
              className="absolute inset-0 opacity-0 transition-opacity duration-700"
            >
              <path
                id={getId}
                d={shape.right}
                fill="none"
                className="stroke-ink"
                strokeWidth={shape.stroke}
                strokeLinecap="round"
              />
              <text
                ref={getTextRef}
                className="fill-paper font-sans"
                fontSize={shape.getFont}
                dominantBaseline="central"
              >
                <textPath href={`#${getId}`}>{GET.repeat(COPIES)}</textPath>
              </text>
              <text ref={getMeasureRef} className="font-sans" fontSize={shape.getFont} x="0" y="-200" visibility="hidden">
                {GET + GET}
              </text>
            </svg>
          </>
        )}

        <div
          ref={badgesRef}
          className="absolute bottom-[84px] left-1/2 grid -translate-x-1/2 sm:bottom-[104px]"
        >
          {FEATURES.map((label, i) => (
            <span
              key={label}
              className={`col-start-1 row-start-1 justify-self-center rounded-full bg-mist px-3 py-1 text-[12px] leading-[18px] font-medium whitespace-nowrap text-ink transition-opacity duration-500 sm:text-[13px] ${i === 0 ? "opacity-100" : "opacity-0"}`}
            >
              {label}
            </span>
          ))}
        </div>

        <div
          ref={pillRef}
          className="absolute bottom-8 left-1/2 flex h-[44px] w-[112px] -translate-x-1/2 items-center justify-center gap-2.5 rounded-full bg-ink text-paper sm:bottom-10 sm:h-[56px] sm:w-[144px] sm:gap-3"
        >
          <RecDot className="sm:size-2.5" />
          <span className="sm:hidden">
            <Waveform bars={11} height={22} />
          </span>
          <span className="hidden sm:block">
            <Waveform bars={14} height={24} />
          </span>
        </div>
      </div>
    </div>
  );
}
