"use client";

import {
  ArrowUp,
  BookOpen,
  Captions,
  ChevronLeft,
  Copy,
  EllipsisVertical,
  FileText,
  Hand,
  House,
  Info,
  Lock,
  MessageSquare,
  Mic,
  MicOff,
  MonitorUp,
  PhoneOff,
  Settings,
  Shapes,
  Smile,
  Trash2,
  Users,
  Video,
} from "lucide-react";
import Image from "next/image";
import { useEffect, useRef, useState, type ReactNode } from "react";
import { AppIcon } from "@/components/brand/Logo";
import { cn } from "@/lib/cn";
import { BrandLogo } from "./BrandLogo";
import { APP_LOGOS } from "./brand-logos.generated";
import { SectionTitle } from "./primitives";
import { useReducedMotion } from "./visitor";

// The note taker, told by scrolling: a video call is on, talkflow records it,
// the notes write themselves, then Ask answers questions about the meeting.
// The words are the app's own demo meeting ("Launch planning"), so the site
// shows exactly what the Notes screens show.

// The screen is drawn at this size and scaled to fit the stage.
const W = 1120;
const H = 700;

const MEET = APP_LOGOS.find((l) => l.name === "Google Meet");

// photo: a webcam frame in public/notes/. Without one the tile shows the
// call's camera-off look: a coloured circle with the initial.
const PEOPLE: { name: string; photo?: string; color: string; speaks: number; muted?: boolean }[] = [
  { name: "Maya Chen", color: "#e8710a", speaks: 0 },
  { name: "Jordan Lee", color: "#1e8e3e", speaks: 1, muted: true },
  { name: "Priya Shah", color: "#9334e6", speaks: 2 },
  { name: "You", color: "#1a73e8", speaks: 3 },
];

type Seg = { t: string; cite?: never } | { cite: string; t?: never };

const SUMMARY: { kind: "h" | "p" | "li"; segs: Seg[] }[] = [
  { kind: "h", segs: [{ t: "Summary" }] },
  {
    kind: "p",
    segs: [
      { t: "The team agreed to ship the correction fix and the new app window together, with the note taker following once the summary part is in. The launch post will lead with privacy, and everyone checks in again on Thursday. (" },
      { cite: "0:04" },
      { t: ", " },
      { cite: "0:36" },
      { t: ", " },
      { cite: "1:01" },
      { t: ")" },
    ],
  },
  { kind: "h", segs: [{ t: "Decisions" }] },
  { kind: "li", segs: [{ t: "The correction fix and the new app window launch together. (" }, { cite: "0:04" }, { t: ")" }] },
  { kind: "li", segs: [{ t: "The launch post leads with the privacy angle. (" }, { cite: "0:36" }, { t: ")" }] },
  { kind: "li", segs: [{ t: "The note taker waits until the summary part is in. (" }, { cite: "1:01" }, { t: ")" }] },
  { kind: "h", segs: [{ t: "Open questions" }] },
  { kind: "li", segs: [{ t: "When the Settings page will be final. (" }, { cite: "0:27" }, { t: ")" }] },
];

const ASK: { q: string; a: Seg[] }[] = [
  {
    q: "What did we decide about the launch post?",
    a: [
      { t: "The post will lead with the privacy angle, since everything on your own Mac is what people repeat back " },
      { cite: "0:36" },
      { t: ". Maya is drafting it tonight and sending it for edits " },
      { cite: "0:48" },
      { t: "." },
    ],
  },
  {
    q: "What are my action items?",
    a: [
      { t: "Two: cut a proper demo video once the Settings page is final " },
      { cite: "0:27" },
      { t: ", and set up the check-in on Thursday " },
      { cite: "1:32" },
      { t: "." },
    ],
  },
];

// 0 -> 1 between a and b, eased.
function ramp(p: number, a: number, b: number) {
  const t = Math.min(1, Math.max(0, (p - a) / (b - a)));
  return t * t * (3 - 2 * t);
}

const length = (segs: Seg[]) => segs.reduce((n, s) => n + (s.t ?? s.cite).length, 0);

// Where each summary block starts in the run of revealed characters.
const SUMMARY_START = SUMMARY.map((_, i) => SUMMARY.slice(0, i).reduce((n, b) => n + length(b.segs), 0));
const SUMMARY_TOTAL = SUMMARY.reduce((n, b) => n + length(b.segs), 0);

// The first `count` characters of a run of text and time links.
function Reveal({ segs, count }: { segs: Seg[]; count: number }) {
  let left = count;
  const out: ReactNode[] = [];
  segs.forEach((s, i) => {
    if (left <= 0) return;
    const text = s.t ?? s.cite;
    const shown = text.slice(0, left);
    left -= text.length;
    out.push(
      s.cite ? (
        <span key={i} className="text-[#55545a] underline decoration-[#9a999e] underline-offset-2">
          {shown}
        </span>
      ) : (
        <span key={i}>{shown}</span>
      ),
    );
  });
  return <>{out}</>;
}

// How far the page has scrolled through the track, 0 to 1. Only listens
// while the section is near the screen.
function useTrackProgress(track: React.RefObject<HTMLDivElement | null>) {
  const [p, setP] = useState(0);
  useEffect(() => {
    const el = track.current;
    if (!el) return;
    let raf = 0;
    const update = () => {
      raf = 0;
      const r = el.getBoundingClientRect();
      const range = r.height - innerHeight;
      const next = range > 0 ? Math.min(1, Math.max(0, -r.top / range)) : 0;
      setP((prev) => (Math.abs(prev - next) < 0.001 ? prev : next));
    };
    const kick = () => {
      if (!raf) raf = requestAnimationFrame(update);
    };
    const io = new IntersectionObserver(([e]) => {
      if (e.isIntersecting) {
        addEventListener("scroll", kick, { passive: true });
        addEventListener("resize", kick);
        kick();
      } else {
        removeEventListener("scroll", kick);
        removeEventListener("resize", kick);
      }
    });
    io.observe(el);
    return () => {
      io.disconnect();
      cancelAnimationFrame(raf);
      removeEventListener("scroll", kick);
      removeEventListener("resize", kick);
    };
  }, [track]);
  return p;
}

// Scale the drawn screen to whatever width the stage has.
function useScale(box: React.RefObject<HTMLDivElement | null>) {
  const [s, setS] = useState(0);
  useEffect(() => {
    const el = box.current;
    if (!el) return;
    const ro = new ResizeObserver(([e]) => setS(Math.min(e.contentRect.width / W, e.contentRect.height / H)));
    ro.observe(el);
    return () => ro.disconnect();
  }, [box]);
  return s;
}

const STEPS = ["Record", "Write", "Ask"];

export function NoteTaker() {
  const track = useRef<HTMLDivElement>(null);
  const box = useRef<HTMLDivElement>(null);
  const reduced = useReducedMotion();
  const raw = useTrackProgress(track);
  // Reduced motion: show the finished notes, no scrubbing.
  const p = reduced ? 0.76 : raw;
  const scale = useScale(box);

  const appIn = ramp(p, 0.2, 0.34);
  const writing = p >= 0.4 && p < 0.47;
  const detail = p >= 0.47;
  const askTab = p >= 0.72;
  const step = p < 0.42 ? 0 : p < 0.72 ? 1 : 2;

  return (
    <section id="notes" aria-labelledby="notes-title" className="px-gutter">
      <div ref={track} className={cn("relative", reduced ? "h-auto" : "h-[420svh]")}>
        <div
          className={cn(
            "flex flex-col items-center gap-[clamp(14px,2.2svh,24px)] pt-[clamp(80px,11svh,104px)] pb-[clamp(16px,3svh,32px)]",
            !reduced && "sticky top-0 h-svh",
          )}
        >
          <div className="text-center">
            <SectionTitle className="text-[clamp(34px,4.4vw,56px)]">
              <span id="notes-title">Every meeting, written up.</span>
            </SectionTitle>
            <p className="mx-auto mt-3 max-w-[56ch] text-[clamp(15px,1.3vw,17px)] text-white/75">
              Record any call. talkflow transcribes it on your Mac, then writes the notes and answers your questions
              with your own AI key.
            </p>
          </div>

          <Steps step={step} progress={p} />

          <div ref={box} className="relative min-h-0 w-full max-w-[1120px] flex-1">
            {scale > 0 && (
              <div
                aria-hidden="true"
                className="absolute top-1/2 left-1/2 origin-center"
                style={{ width: W, height: H, transform: `translate(-50%, -50%) scale(${scale})` }}
              >
                <MeetWindow dim={appIn} />
                <div
                  className="absolute inset-[28px_70px_20px]"
                  style={{
                    opacity: ramp(p, 0.2, 0.25),
                    transform: `translateY(${(1 - appIn) * 40}px) scale(${0.92 + appIn * 0.08})`,
                    pointerEvents: "none",
                  }}
                >
                  <AppWindow>{!detail ? <Recording writing={writing} /> : <NoteDetail p={p} askTab={askTab} />}</AppWindow>
                </div>
              </div>
            )}
          </div>
          <p className="sr-only">
            A video call with four people. talkflow records it, writes a summary with decisions and open questions,
            then answers questions about the meeting with links to the moment each answer came from.
          </p>
        </div>
      </div>
    </section>
  );
}

// Record, Write, Ask: a white pill slides to the current step, and a thin
// line under it fills as the story plays.
function Steps({ step, progress }: { step: number; progress: number }) {
  return (
    <div className="relative">
      <ol className="relative grid grid-cols-3 rounded-full bg-white/10 p-1 text-[14px] font-medium ring-1 ring-white/20 backdrop-blur-md">
        <span
          aria-hidden="true"
          className="absolute inset-y-1 left-1 w-[calc((100%-8px)/3)] rounded-full bg-white shadow-[0_6px_18px_-6px_rgb(3_12_60/0.6)] transition-transform duration-500 ease-[cubic-bezier(.2,.8,.2,1)]"
          style={{ transform: `translateX(${step * 100}%)` }}
        />
        {STEPS.map((label, i) => (
          <li
            key={label}
            className={cn(
              "relative z-10 flex items-center justify-center gap-2 px-5 py-1.5 transition-colors duration-300",
              i === step ? "text-[#0b1f66]" : "text-white/70",
            )}
          >
            <span
              className={cn(
                "grid size-[18px] place-items-center rounded-full text-[11px] tabular-nums transition-colors duration-300",
                i === step ? "bg-[#0b1f66] text-white" : "bg-white/15 text-white/80",
              )}
            >
              {i + 1}
            </span>
            {label}
          </li>
        ))}
      </ol>
      <div aria-hidden="true" className="mx-auto mt-2 h-[2px] w-[70%] overflow-hidden rounded-full bg-white/15">
        <div className="h-full origin-left rounded-full bg-white/80" style={{ transform: `scaleX(${progress})` }} />
      </div>
    </div>
  );
}

// ---- The call ---------------------------------------------------------------

function MeetWindow({ dim }: { dim: number }) {
  return (
    <div
      className="absolute inset-0 overflow-hidden rounded-[14px] bg-[#202124] shadow-[0_40px_90px_-30px_rgb(0_0_0/0.7)] ring-1 ring-black/40"
      style={{ transform: `scale(${1 - dim * 0.05})`, filter: `brightness(${1 - dim * 0.45}) blur(${dim * 2}px)` }}
    >
      {/* Browser chrome */}
      <div className="flex h-[38px] items-end gap-2 bg-[#35363a] pl-4">
        <div className="mb-[13px] flex gap-2">
          <span className="size-3 rounded-full bg-[#ff5f57]" />
          <span className="size-3 rounded-full bg-[#febc2e]" />
          <span className="size-3 rounded-full bg-[#28c840]" />
        </div>
        <div className="ml-4 flex h-[30px] w-[230px] items-center gap-2 rounded-t-[10px] bg-[#202124] px-3 text-[12px] text-white/85">
          {MEET && <BrandLogo logo={MEET} className="size-4" />}
          <span className="truncate">Meet - Launch planning</span>
        </div>
      </div>
      <div className="flex h-[34px] items-center gap-3 bg-[#202124] px-4 text-[12.5px] text-white/70">
        <Lock size={12} />
        <span>meet.google.com/kfp-rtxa-wnq</span>
      </div>

      {/* Tiles */}
      <div className="grid h-[548px] grid-cols-2 gap-2.5 px-4 pt-1">
        {PEOPLE.map((person) => (
          <div key={person.name} className="relative overflow-hidden rounded-[12px] bg-[#3c4043]">
            {person.photo ? (
              <Image src={person.photo} alt="" fill sizes="560px" className="object-cover" />
            ) : (
              <span className="absolute inset-0 grid place-items-center">
                <span
                  className="grid size-[104px] place-items-center rounded-full text-[44px] text-white"
                  style={{ background: person.color }}
                >
                  {person.name[0]}
                </span>
              </span>
            )}
            {/* Speaking: a blue frame and bars, in turn */}
            <span
              className="absolute inset-0 rounded-[12px] opacity-0 ring-[3px] ring-[#8ab4f8] ring-inset"
              style={{ animation: `meet-speak 8s ${person.speaks * 2}s infinite` }}
            />
            <span className="absolute top-3 right-3 grid size-7 place-items-center rounded-full bg-[#1a73e8]/90">
              {person.muted ? (
                <MicOff size={14} className="text-white" />
              ) : (
                <span className="flex h-3 items-center gap-[2px]">
                  {[0, 1, 2].map((b) => (
                    <span
                      key={b}
                      className="w-[3px] origin-center rounded-full bg-white"
                      style={{ height: 12, animation: `level 0.9s ${b * 0.15 + person.speaks * 0.3}s ease-in-out infinite` }}
                    />
                  ))}
                </span>
              )}
            </span>
            <span className="absolute bottom-2.5 left-3 text-[13px] font-medium text-white [text-shadow:0_1px_3px_rgb(0_0_0/0.8)]">
              {person.name}
            </span>
          </div>
        ))}
      </div>

      {/* Controls */}
      <div className="flex h-[80px] items-center justify-between px-6 text-white">
        <span className="w-[260px] text-[14px] text-white/90">
          2:12 PM <span className="mx-2 text-white/40">|</span> kfp-rtxa-wnq
        </span>
        <div className="flex items-center gap-2.5">
          {[Mic, Video, Captions, Smile, MonitorUp, Hand, EllipsisVertical].map((Icon, i) => (
            <span key={i} className="grid size-10 place-items-center rounded-full bg-[#3c4043]">
              <Icon size={18} />
            </span>
          ))}
          <span className="grid h-10 w-14 place-items-center rounded-full bg-[#ea4335]">
            <PhoneOff size={18} />
          </span>
        </div>
        <div className="flex w-[260px] justify-end gap-5 text-white/90">
          <Info size={20} />
          <span className="relative">
            <Users size={20} />
            <span className="absolute -top-1.5 -right-2 grid size-4 place-items-center rounded-full bg-[#8ab4f8] text-[10px] font-semibold text-[#202124]">
              4
            </span>
          </span>
          <MessageSquare size={20} />
          <Shapes size={20} />
        </div>
      </div>
    </div>
  );
}

// ---- talkflow ---------------------------------------------------------------

function AppWindow({ children }: { children: ReactNode }) {
  return (
    <div className="flex h-full overflow-hidden rounded-[14px] bg-[#f5f5f3] text-[#1f1e22] shadow-[0_50px_100px_-30px_rgb(0_0_0/0.75)] ring-1 ring-black/10">
      <aside className="flex w-[210px] flex-none flex-col bg-[#eeeeeb] px-3.5 pt-4 pb-5">
        <div className="flex gap-2">
          <span className="size-3 rounded-full bg-[#ff5f57]" />
          <span className="size-3 rounded-full bg-[#febc2e]" />
          <span className="size-3 rounded-full bg-[#28c840]" />
        </div>
        <div className="mt-7 flex items-center gap-2 pl-1.5 font-serif text-[22px] leading-none">
          <AppIcon className="size-[26px]" />
          talkflow
        </div>
        <nav className="mt-6 flex flex-col gap-1 text-[14.5px]">
          {[
            [House, "Home"],
            [FileText, "Notes"],
            [BookOpen, "Dictionary"],
            [Settings, "Settings"],
          ].map(([Icon, label]) => {
            const I = Icon as typeof House;
            const on = label === "Notes";
            return (
              <span
                key={label as string}
                className={cn("flex items-center gap-3 rounded-[10px] px-3 py-2.5", on && "bg-[#1f1e22] text-white")}
              >
                <I size={17} strokeWidth={1.75} />
                {label as string}
              </span>
            );
          })}
        </nav>
      </aside>
      <div className="relative min-w-0 flex-1 px-10 pt-7">{children}</div>
    </div>
  );
}

function Recording({ writing }: { writing: boolean }) {
  return (
    <div>
      <span className="flex items-center gap-1 text-[16px]">
        <ChevronLeft size={18} /> Notes
      </span>
      <p className="mt-6 text-[13px] text-[#6b6a6f]">Meeting name</p>
      <div className="mt-2 rounded-[10px] border border-[#d6d5d2] bg-white px-4 py-2.5 font-serif text-[26px]">
        Launch planning
      </div>
      <div className="mt-5 rounded-[16px] border border-[#e2e1de] bg-white px-7 py-6">
        <div className="flex items-center justify-between">
          <div>
            <p className="pl-7 text-[13px] text-[#6b6a6f]">Recording</p>
            <p className="flex items-center gap-3 font-serif text-[54px] leading-none tabular-nums">
              <span className={cn("size-3.5 rounded-full", writing ? "bg-[#9a999e]" : "animate-dot-pulse bg-[#e0352b]")} />
              12:34
            </p>
          </div>
          <span
            className={cn(
              "rounded-full px-5 py-3 text-[15px] font-semibold text-white transition-[background-color,transform] duration-300",
              writing ? "scale-95 bg-[#55545a]" : "bg-[#1f1e22]",
            )}
          >
            Stop and write notes
          </span>
        </div>
        <div className="mt-7 grid grid-cols-[180px_1fr] items-center gap-x-6 gap-y-5">
          {[
            ["You", "MacBook Pro Microphone", "1.1s"],
            ["Everyone else", "Sound from this Mac", "0.8s"],
          ].map(([who, src, speed]) => (
            <div key={who} className="contents">
              <div>
                <p className="text-[15px] font-semibold">{who}</p>
                <p className="text-[13px] text-[#6b6a6f]">{src}</p>
              </div>
              <div className="h-2 overflow-hidden rounded-full bg-[#e8e7e4]">
                <div
                  className="h-full origin-left rounded-full bg-[#1f1e22]"
                  style={{ animation: writing ? "none" : `meet-level ${speed} ease-in-out infinite alternate`, width: writing ? "0%" : "100%" }}
                />
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

function NoteDetail({ p, askTab }: { p: number; askTab: boolean }) {
  const tabs = ["Summary", "Ask", "Transcript"];
  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center justify-between">
        <span className="flex items-center gap-1 text-[16px]">
          <ChevronLeft size={18} /> Notes
        </span>
        <span className="flex gap-4 text-[#55545a]">
          <Copy size={17} strokeWidth={1.6} />
          <Trash2 size={17} strokeWidth={1.6} />
        </span>
      </div>
      <h3 className="mt-3 font-serif text-[30px] leading-tight">Launch planning</h3>
      <p className="text-[13px] text-[#6b6a6f]">Today, 2:00 PM · 42 min</p>
      <div className="mt-4 flex gap-6 border-b border-[#dcdbd8] text-[14.5px]">
        {tabs.map((t) => {
          const on = (t === "Ask") === askTab && t !== "Transcript";
          return (
            <span key={t} className={cn("-mb-px pb-2", on ? "border-b-2 border-[#1f1e22]" : "text-[#6b6a6f]")}>
              {t}
            </span>
          );
        })}
      </div>
      {askTab ? <AskTab p={p} /> : <SummaryTab p={p} />}
    </div>
  );
}

function SummaryTab({ p }: { p: number }) {
  // The document writes itself between 0.48 and 0.7.
  const shown = Math.round(ramp(p, 0.48, 0.7) * SUMMARY_TOTAL);
  return (
    <div className="mt-5 text-[14.5px] leading-[1.6]">
      {SUMMARY.map((block, i) => {
        const count = Math.min(length(block.segs), shown - SUMMARY_START[i]);
        if (count <= 0) return null;
        if (block.kind === "h")
          return (
            <p key={i} className="mt-4 text-[19px] font-semibold first:mt-0">
              <Reveal segs={block.segs} count={count} />
            </p>
          );
        if (block.kind === "li")
          return (
            <p key={i} className="mt-1.5 flex gap-3 pl-1">
              <span className="mt-[9px] size-[5px] flex-none rounded-full bg-[#1f1e22]" />
              <span>
                <Reveal segs={block.segs} count={count} />
              </span>
            </p>
          );
        return (
          <p key={i} className="mt-1.5">
            <Reveal segs={block.segs} count={count} />
          </p>
        );
      })}
    </div>
  );
}

function AskTab({ p }: { p: number }) {
  // Each question appears, then its answer streams in as you scroll.
  const windows = [
    [0.74, 0.77, 0.86],
    [0.88, 0.9, 0.98],
  ];
  return (
    <div className="relative flex min-h-0 flex-1 flex-col">
      <div className="flex flex-1 flex-col gap-4 pt-5 text-[14.5px] leading-[1.55]">
        {ASK.map((turn, i) => {
          const [qAt, aFrom, aTo] = windows[i];
          if (p < qAt) return null;
          const count = Math.round(ramp(p, aFrom, aTo) * length(turn.a));
          return (
            <div key={i} className="flex flex-col gap-3">
              <span className="self-end rounded-full border border-[#e2e1de] bg-white px-4 py-2 animate-[pop-in_300ms_ease-out]">
                {turn.q}
              </span>
              {count > 0 && (
                <p>
                  <Reveal segs={turn.a} count={count} />
                  {count < length(turn.a) && <span className="ml-0.5 inline-block h-[1em] w-[2px] translate-y-[3px] animate-blink bg-[#1f1e22]" />}
                </p>
              )}
            </div>
          );
        })}
      </div>
      <div className="mb-6 flex items-center justify-between rounded-full border border-[#d6d5d2] bg-white py-1.5 pr-1.5 pl-5 text-[14.5px] text-[#9a999e]">
        Ask about this meeting
        <span className="grid size-8 place-items-center rounded-full bg-[#efefec] text-[#6b6a6f]">
          <ArrowUp size={16} />
        </span>
      </div>
    </div>
  );
}
