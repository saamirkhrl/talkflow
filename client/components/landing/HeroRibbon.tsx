"use client";

import { useEffect, useId, useMemo, useRef, useState } from "react";
import { RecDot, Waveform } from "./primitives";

// What was said, and what TalkFlow typed. The clean side is the real output of
// `talkflowd --formattest` (HANDOFF.md, "Self-test flags") for Whisper's
// transcript of the spoken side. On the spoken side, [um] is a filler the app
// drops, {question mark} a spoken command it turns into a symbol, and <first> a
// cue it formats around. " / " on the clean side is a line break; the ribbon is
// one line, so it becomes a space.
const PAIRS: { say: string; get: string; cue?: string }[] = [
  {
    say: "[um] so the checkout form is double submitting when someone taps pay twice [uh] can you add a loading state that disables the button after the first click {question mark}",
    get: "So the checkout form is double submitting when someone taps pay twice. Can you add a loading state that disables the button after the first click?",
  },
  {
    say: "[hmm] let's ship it tonight {rocket emoji}",
    get: "Let's ship it tonight 🚀",
  },
  {
    say: "okay so [uh] three things <first> fix the retry logic <second> [um] add a test for the timeout <third> update the changelog",
    get: "Okay, so, three things. / First, fix the retry logic. / Second, add a test for the timeout. / Third, update the changelog.",
    cue: "Lists formatted",
  },
  {
    say: "<hi> sam [um] thanks for the notes I'll send the draft by friday <best> samir",
    get: "Hi Sam, / Thanks for the notes. I'll send the draft by Friday. / Best, Samir.",
    cue: "Emails formatted",
  },
  {
    say: "[uh] can we push standup to tomorrow morning {question mark} I've got a dentist thing at nine",
    get: "Can we push standup to tomorrow morning? I've got a dentist thing at nine.",
  },
  {
    say: "[um] the bug only happens in safari when the tab is in the background the timer just stops {thinking face emoji}",
    get: "The bug only happens in Safari when the tab is in the background. The timer just stops 🤔",
  },
  {
    say: "[um] so the plan for tomorrow {colon} {new line} write the tests {new line} fix the flaky one {new line} ship it",
    get: "So the plan for tomorrow: / Write the tests / Fix the flaky one / Ship it",
  },
  {
    say: "grabbing lunch [uh] want anything {question mark} {taco emoji}",
    get: "Grabbing lunch, want anything? 🌮",
  },
  {
    say: "the demo went great [uh] huge thanks to everyone who stayed late {exclamation mark} {clap emoji}",
    get: "The demo went great. Huge thanks to everyone who stayed late! 👏",
  },
];

const FEATURES = [
  "Filler words removed",
  "Punctuation added",
  "Emoji by name",
  "New lines by voice",
  "Lists formatted",
  "Emails formatted",
];

const commandTag = (command: string) =>
  command.endsWith("emoji")
    ? "Emoji by name"
    : /^new (line|paragraph)$/.test(command)
      ? "New lines by voice"
      : "Punctuation added";

const SEP = " · ";
const TAU = Math.PI * 2;

// px per second. The clean text leaves about 4x faster than the spoken text
// arrives. Phones show only ~200px of each path, so both run a little slower.
const SPEED = { say: 38, get: 150 };
const SPEED_SMALL = { say: 30, get: 115 };
// A badge stays up at least this long before the next one replaces it.
const BADGE_HOLD = 1800;

// --- Script ------------------------------------------------------------------

type Tone = "plain" | "quiet" | "loud";
type Span = { text: string; tone: Tone };
type Line = { text: string; spans: Span[] };
type Run = number[];

type Script = {
  say: Line;
  get: Line;
  // Fillers, commands and cues, with the badge each one earns in the pill.
  marks: { at: number; end: number; tag: number }[];
  // Where the first spoken sentence ends, for the opening frame.
  opening: number;
};

function push(line: Line, text: string, tone: Tone) {
  const last = line.spans[line.spans.length - 1];
  if (last?.tone === tone) last.text += text;
  else line.spans.push({ text, tone });
  line.text += text;
}

function buildScript(order: number[]): Script {
  const say: Line = { text: "", spans: [] };
  const get: Line = { text: "", spans: [] };
  const marks: Script["marks"] = [];
  let opening = 0;

  order.forEach((index, n) => {
    const pair = PAIRS[index];
    [...pair.say.matchAll(/\[([^\]]+)\]|\{([^}]+)\}|<([^>]+)>|(\S+)/g)].forEach(([, filler, command, cue, word], i) => {
      if (i) push(say, " ", "plain");
      const at = say.text.length;
      if (filler) {
        push(say, filler, "quiet");
        marks.push({ at, end: say.text.length, tag: FEATURES.indexOf("Filler words removed") });
      } else if (command) {
        push(say, command, "loud");
        marks.push({ at, end: say.text.length, tag: FEATURES.indexOf(commandTag(command)) });
      } else if (cue) {
        push(say, cue, "loud");
        marks.push({ at, end: say.text.length, tag: FEATURES.indexOf(pair.cue ?? "") });
      } else {
        push(say, word, "plain");
      }
    });
    push(get, pair.get.replaceAll(" / ", " "), "plain");
    if (n === 0) opening = say.text.length;
    push(say, SEP, "quiet");
    push(get, SEP, "quiet");
  });

  return { say, get, marks, opening };
}

// The line repeated until it is `length` chars long.
function repeat(line: Line, length: number): Span[] {
  const out: Span[] = [];
  let left = length;
  while (left > 0) {
    for (const span of line.spans) {
      if (left <= 0) break;
      let text = span.text.slice(0, left);
      // Never end on half an emoji.
      if (/[\uD800-\uDBFF]$/.test(text)) text = text.slice(0, -1);
      out.push({ text, tone: span.tone });
      left -= span.text.length;
    }
  }
  return out;
}

function newRun(): Run {
  const order = PAIRS.map((_, i) => i);
  for (let i = order.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [order[i], order[j]] = [order[j], order[i]];
  }
  return order;
}

// --- Geometry ----------------------------------------------------------------

type Geo = { w: number; h: number; cx: number; cy: number; pw: number; ph: number; top: number };
type Pt = { x: number; y: number };

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
const mod = (v: number, m: number) => ((v % m) + m) % m;
const f = (n: number) => n.toFixed(1);

// A cubic with an arc-length table, so loops and waves can be laid along it by
// distance, using its own direction as "forward" and its left side as "up".
function curve(p0: Pt, p1: Pt, p2: Pt, p3: Pt) {
  const point = (t: number): Pt => {
    const u = 1 - t;
    return {
      x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
      y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y,
    };
  };
  const tangent = (t: number): Pt => {
    const u = 1 - t;
    const x = 3 * u * u * (p1.x - p0.x) + 6 * u * t * (p2.x - p1.x) + 3 * t * t * (p3.x - p2.x);
    const y = 3 * u * u * (p1.y - p0.y) + 6 * u * t * (p2.y - p1.y) + 3 * t * t * (p3.y - p2.y);
    const l = Math.hypot(x, y) || 1;
    return { x: x / l, y: y / l };
  };
  const N = 240;
  const lens = [0];
  for (let i = 1, prev = p0; i <= N; i++) {
    const p = point(i / N);
    lens.push(lens[i - 1] + Math.hypot(p.x - prev.x, p.y - prev.y));
    prev = p;
  }
  const param = (s: number) => {
    const d = clamp(s, 0, lens[N]);
    let lo = 0;
    let hi = N;
    while (hi - lo > 1) {
      const mid = (lo + hi) >> 1;
      if (lens[mid] <= d) lo = mid;
      else hi = mid;
    }
    return (lo + (d - lens[lo]) / (lens[hi] - lens[lo] || 1)) / N;
  };
  return { length: lens[N], at: (s: number) => point(param(s)), dir: (s: number) => tangent(param(s)) };
}

type Curve = ReturnType<typeof curve>;
// One turn of a trochoid laid along the base: a loop when b > a, a wave when
// b < a. `lift` picks the side it rises toward.
type Turn = { at: number; a: number; b: number; lift: 1 | -1; loop: boolean };

// Loops are squashed a little, which opens up their tops so the upside-down
// words there stay legible.
const SQUASH = 0.75;

// Samples the ribbon about every `step` px, and cuts it at the top of each loop
// so the way down can be drawn over the way up where they cross.
function sample(base: Curve, turns: Turn[], step: number) {
  const pts: Pt[] = [];
  const cuts: number[] = [];
  const peaks = turns.filter((t) => t.loop).map((t) => t.at + Math.PI * t.a);
  let k = 0;
  let p = 0;
  for (let s = 0; ; ) {
    while (k < turns.length && s > turns[k].at + TAU * turns[k].a) k++;
    const turn = turns[k] && s >= turns[k].at ? turns[k] : null;
    const o = base.at(s);
    const d = base.dir(s);
    let speed = 1;
    if (turn) {
      const phi = (s - turn.at) / turn.a;
      const along = turn.b * Math.sin(phi);
      const up = turn.lift * SQUASH * turn.b * (1 - Math.cos(phi));
      o.x += along * d.x + up * d.y;
      o.y += along * d.y - up * d.x;
      const r = turn.b / turn.a;
      speed = Math.hypot(1 + r * Math.cos(phi), SQUASH * r * Math.sin(phi));
    }
    pts.push(o);
    if (s === peaks[p]) {
      cuts.push(pts.length - 1);
      p++;
    }
    if (s >= base.length) break;
    let next = s + step / Math.max(speed, 0.5);
    if (p < peaks.length && next > peaks[p]) next = peaks[p];
    s = Math.min(next, base.length);
  }
  return { pts, cuts };
}

// How far along `over` it first crosses `under`, or null if it never does.
function crossing(under: Pt[], over: Pt[]) {
  let along = 0;
  for (let i = 0; i < over.length - 1; i++) {
    const [p, q] = [over[i], over[i + 1]];
    const r = { x: q.x - p.x, y: q.y - p.y };
    for (let j = 0; j < under.length - 1; j++) {
      const [a, b] = [under[j], under[j + 1]];
      const s = { x: b.x - a.x, y: b.y - a.y };
      const den = r.x * s.y - r.y * s.x;
      if (!den) continue;
      const t = ((a.x - p.x) * s.y - (a.y - p.y) * s.x) / den;
      const u = ((a.x - p.x) * r.y - (a.y - p.y) * r.x) / den;
      // Strict bounds skip the point the two pieces share at the loop's top.
      if (t > 0 && t < 1 && u > 0 && u < 1) return along + t * Math.hypot(r.x, r.y);
    }
    along += Math.hypot(r.x, r.y);
  }
  return null;
}

// Catmull-Rom through the samples, split into one path per cut. Each piece
// also notes where the next one crosses over it.
function paths(pts: Pt[], cuts: number[]) {
  const bounds = [0, ...cuts, pts.length - 1];
  return bounds.slice(1).map((end, n) => {
    const start = bounds[n];
    let d = `M${f(pts[start].x)} ${f(pts[start].y)}`;
    let length = 0;
    for (let i = start; i < end; i++) {
      const [p0, p1, p2, p3] = [pts[i - 1] ?? pts[i], pts[i], pts[i + 1], pts[i + 2] ?? pts[i + 1]];
      d += ` C${f(p1.x + (p2.x - p0.x) / 6)} ${f(p1.y + (p2.y - p0.y) / 6)} ${f(p2.x - (p3.x - p1.x) / 6)} ${f(p2.y - (p3.y - p1.y) / 6)} ${f(p2.x)} ${f(p2.y)}`;
      length += Math.hypot(p2.x - p1.x, p2.y - p1.y);
    }
    const next = bounds[n + 2];
    const crossedAt = next === undefined ? null : crossing(pts.slice(start, end + 1), pts.slice(end, next + 1));
    return { d, length, crossedAt };
  });
}

// Both paths are built in CSS pixels around the pill's measured box, so text
// size and speed stay true at every width.
function layout(g: Geo) {
  const small = g.w < 640;
  const inset = g.ph / 2; // joins sit at the centers of the pill's round ends
  const ex = g.cx - g.pw / 2 + inset;
  const sx = g.cx + g.pw / 2 - inset;
  const { cy, w, h } = g;

  // The way in: a gentle fall from the left edge into the pill, with one big
  // loop laid along it.
  const s = small ? { x: -40, y: cy - h * 0.14 } : { x: -60, y: cy - h * 0.1 };
  const run = ex - s.x;
  const base = curve(s, { x: s.x + run * 0.4, y: s.y }, { x: ex - run * 0.45, y: cy }, { x: ex, y: cy });
  // The loop stays clear of the hero copy, which reaches `top` px into the band
  // around the center.
  const a = small ? 22 : clamp(h * 0.1, 26, 38);
  const len = TAU * a;
  const at = small ? 8 : clamp(w * 0.1, 40, 200);
  const x1 = base.at(at + len).x;
  const y = base.at(at + len / 2).y;
  const b = Math.min(a * 3.4, (y - 12) / (2 * SQUASH));
  const clear = x1 < w / 2 - 150 || y - 2 * SQUASH * b - 10 > g.top + 14;
  const fits = at + len <= base.length && x1 <= ex - (small ? 40 : 90) && b >= a * 2.8 && clear;
  const way = sample(base, fits ? [{ at, a, b, lift: 1, loop: true }] : [], 5);

  // The way out: a long smooth rise to the right edge.
  const e = small ? { x: w + 30, y: cy - h * 0.28 } : { x: w + 60, y: cy - clamp(h * 0.42, 110, 180) };
  const rx = e.x - sx;
  const out = small
    ? curve({ x: sx, y: cy }, { x: sx + rx * 0.5, y: cy }, { x: e.x - rx * 0.35, y: e.y + h * 0.05 }, e)
    : curve({ x: sx, y: cy }, { x: sx + rx * 0.45, y: cy }, { x: e.x - rx * 0.3, y: e.y + 24 }, e);

  return {
    small,
    say: paths(way.pts, way.cuts),
    get: paths(sample(out, [], 6).pts, [])[0],
    inset,
    sayFont: small ? 15 : 18,
    getFont: small ? 14 : 16,
    stroke: small ? 26 : 30,
    fade: small ? 36 : clamp(w * 0.07, 70, 140),
  };
}

// --- Component ---------------------------------------------------------------

const SAY_TONE: Record<Tone, string | undefined> = { plain: undefined, quiet: "fill-graphite/45", loud: "fill-ink" };
const GET_TONE: Record<Tone, string | undefined> = { plain: undefined, quiet: "fill-paper/50", loud: undefined };

function Spans({ spans, tones }: { spans: Span[]; tones: Record<Tone, string | undefined> }) {
  return spans.map((span, i) => (
    <tspan key={i} className={tones[span.tone]}>
      {span.text}
    </tspan>
  ));
}

export function HeroRibbon() {
  const uid = useId();
  const getId = `${uid}get`;

  const rootRef = useRef<HTMLDivElement>(null);
  const bandRef = useRef<HTMLDivElement>(null);
  const pillRef = useRef<HTMLDivElement>(null);
  const badgesRef = useRef<HTMLDivElement>(null);
  const sayPathRefs = useRef<(SVGPathElement | null)[]>([]);
  const sayTextRefs = useRef<(SVGTextElement | null)[]>([]);
  const getTextRef = useRef<SVGTextElement>(null);
  const sayMeasureRef = useRef<SVGTextElement>(null);
  const getMeasureRef = useRef<SVGTextElement>(null);
  const leftSvgRef = useRef<SVGSVGElement>(null);
  const rightSvgRef = useRef<SVGSVGElement>(null);

  const [geo, setGeo] = useState<Geo | null>(null);
  const [run, setRun] = useState<Run | null>(null);
  const script = useMemo(() => (run ? buildScript(run) : null), [run]);
  const shape = useMemo(() => (geo ? layout(geo) : null), [geo]);

  // Each text must reach one period past the end of its path (its offset lives
  // in [-period, 0)). Glyphs run at least ~5px wide, so this many chars covers
  // the path with room to spare.
  const content = useMemo(() => {
    if (!shape || !script) return null;
    const sayLen = script.say.text.length;
    const getLen = script.get.text.length;
    return {
      say: shape.say.map((seg) => repeat(script.say, sayLen + Math.ceil((seg.length + 200) / 5))),
      get: repeat(script.get, getLen + Math.ceil((shape.get.length + 200) / 5)),
      sayMeasure: repeat(script.say, sayLen * 2),
      getMeasure: repeat(script.get, getLen * 2),
    };
  }, [shape, script]);

  // Measure the band and the pill (CSS owns their size and position), and roll
  // this visit's ribbon once.
  useEffect(() => {
    const root = rootRef.current;
    const band = bandRef.current;
    const pill = pillRef.current;
    if (!root || !band || !pill) return;
    const fresh = newRun();
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
        top: Math.max(0, -parseFloat(getComputedStyle(root).marginTop) || 0),
      };
      setRun((prev) => prev ?? fresh);
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
    const getText = getTextRef.current;
    const sayMeasure = sayMeasureRef.current;
    const getMeasure = getMeasureRef.current;
    const svgs = [leftSvgRef.current, rightSvgRef.current];
    if (!geo || !shape || !script || !band || !badges || !getText || !sayMeasure || !getMeasure) return;
    const sayPaths = sayPathRefs.current.slice(0, shape.say.length);
    const sayTexts = sayTextRefs.current.slice(0, shape.say.length);
    if (sayPaths.some((p) => !p) || sayTexts.some((t) => !t)) return;

    const speed = shape.small ? SPEED_SMALL : SPEED;
    // Where each piece of the way in starts, and the point on it that sits at
    // the pill's edge.
    const starts: number[] = [];
    let total = 0;
    for (const path of sayPaths) {
      starts.push(total);
      total += path!.getTotalLength();
    }
    const pillAt = total - shape.inset;
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)");

    // Both in px along the text: `pos` is the spoken position at the pill's left
    // edge (it falls as the text slides in), `out` the clean text's offset.
    let sayPeriod = 0;
    let getPeriod = 0;
    let markAt: number[] = [];
    let pos = 0;
    let out = 0;
    let badge = -1;
    let pending = -1;
    let shownAt = 0;
    let clock = 0;
    let raf = 0;
    let last = 0;
    let ready = false;
    let onScreen = true;
    let cancelled = false;

    const measure = () => {
      const sayPx = (i: number) => (i > 0 ? sayMeasure.getSubStringLength(0, i) : 0);
      const getPx = (i: number) => (i > 0 ? getMeasure.getSubStringLength(0, i) : 0);
      sayPeriod = sayPx(script.say.text.length);
      getPeriod = getPx(script.get.text.length);
      markAt = script.marks.map((m) => (sayPx(m.at) + sayPx(m.end)) / 2);
    };

    const apply = () => {
      const offset = pillAt - pos;
      sayTexts.forEach((text, j) => text!.setAttribute("x", (mod(offset - starts[j], sayPeriod) - sayPeriod).toFixed(2)));
      getText.setAttribute("x", (mod(out, getPeriod) - getPeriod).toFixed(2));
    };

    const showBadge = (i: number) => {
      badge = i;
      shownAt = clock;
      Array.from(badges.children).forEach((el, j) => {
        (el as HTMLElement).style.opacity = j === i ? "1" : "0";
      });
    };

    // The opening frame: the first spoken sentence ends at the pill and its
    // clean version starts just outside it.
    const compose = () => {
      measure();
      pos = sayMeasure.getSubStringLength(0, script.opening) + 10;
      out = shape.inset + 12;
      let recent = 0;
      markAt.forEach((at, i) => {
        if (mod(at - pos, sayPeriod) < mod(markAt[recent] - pos, sayPeriod)) recent = i;
      });
      pending = -1;
      showBadge(script.marks[recent]?.tag ?? 0);
      apply();
    };

    const frame = (t: number) => {
      const dt = last ? Math.min(t - last, 100) / 1000 : 0;
      last = t;
      clock += dt * 1000;
      const before = pos;
      pos -= speed.say * dt;
      const wrapped = pos < 0;
      if (wrapped) pos += sayPeriod;
      out = (out + speed.get * dt) % getPeriod;
      apply();

      // The newest filler or command to slip into the pill gets the badge.
      let age = Infinity;
      markAt.forEach((at, i) => {
        const crossed = wrapped ? at <= before || at > pos : at <= before && at > pos;
        if (crossed && mod(at - pos, sayPeriod) < age) {
          age = mod(at - pos, sayPeriod);
          pending = script.marks[i].tag;
        }
      });
      if (pending >= 0 && clock - shownAt >= BADGE_HOLD) {
        if (pending !== badge) showBadge(pending);
        pending = -1;
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
      const sayPhase = pos / sayPeriod;
      const getPhase = out / getPeriod;
      measure();
      pos = sayPhase * sayPeriod;
      out = getPhase * getPeriod;
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
  }, [geo, shape, script]);

  return (
    <div ref={rootRef} className="pointer-events-none relative mt-auto sm:-mt-[clamp(40px,min(9vw,18svh),136px)]">
      <p className="sr-only">Spoken words go into TalkFlow and come out as clean, punctuated text.</p>
      <div
        ref={bandRef}
        aria-hidden="true"
        className="relative h-[210px] w-full overflow-hidden select-none sm:h-[clamp(240px,min(27vw,42svh),400px)]"
      >
        {geo && shape && content && (
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
              {shape.say.map((seg, j) => (
                <g key={j}>
                  <path
                    ref={(el) => {
                      sayPathRefs.current[j] = el;
                    }}
                    id={`${uid}say${j}`}
                    d={seg.d}
                    fill="none"
                  />
                  {/* Where the way down a loop crosses the way up, the way up
                      breaks for it, like a ribbon passing over itself. */}
                  {seg.crossedAt !== null && (
                    <mask id={`${uid}gap${j}`} maskUnits="userSpaceOnUse" x="0" y="0" width={geo.w} height={geo.h}>
                      <rect width={geo.w} height={geo.h} fill="white" />
                      <path
                        d={shape.say[j + 1].d}
                        fill="none"
                        stroke="black"
                        strokeWidth={shape.sayFont * 1.5}
                        strokeDasharray={`0 ${f(Math.max(0, seg.crossedAt - 40))} 80 100000`}
                      />
                    </mask>
                  )}
                  <text
                    ref={(el) => {
                      sayTextRefs.current[j] = el;
                    }}
                    className="fill-graphite font-serif italic"
                    fontSize={shape.sayFont}
                    dominantBaseline="central"
                    xmlSpace="preserve"
                    mask={seg.crossedAt !== null ? `url(#${uid}gap${j})` : undefined}
                  >
                    <textPath href={`#${uid}say${j}`}>
                      <Spans spans={content.say[j]} tones={SAY_TONE} />
                    </textPath>
                  </text>
                </g>
              ))}
              <text
                ref={sayMeasureRef}
                className="font-serif italic"
                fontSize={shape.sayFont}
                xmlSpace="preserve"
                x="0"
                y="-200"
                visibility="hidden"
              >
                <Spans spans={content.sayMeasure} tones={SAY_TONE} />
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
                d={shape.get.d}
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
                xmlSpace="preserve"
              >
                <textPath href={`#${getId}`}>
                  <Spans spans={content.get} tones={GET_TONE} />
                </textPath>
              </text>
              <text
                ref={getMeasureRef}
                className="font-sans"
                fontSize={shape.getFont}
                xmlSpace="preserve"
                x="0"
                y="-200"
                visibility="hidden"
              >
                <Spans spans={content.getMeasure} tones={GET_TONE} />
              </text>
            </svg>
          </>
        )}

        <div
          ref={badgesRef}
          className="absolute bottom-[84px] left-1/2 grid -translate-x-1/2 sm:bottom-[104px]"
        >
          {FEATURES.map((label) => (
            <span
              key={label}
              className="col-start-1 row-start-1 justify-self-center rounded-full bg-mist px-3 py-1 text-[12px] leading-[18px] font-medium whitespace-nowrap text-ink opacity-0 transition-opacity duration-500 sm:text-[13px]"
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
