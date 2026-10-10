"use client";

import { useEffect, useRef, useState, type ComponentType, type RefObject } from "react";
import { useLenis } from "lenis/react";
import Image from "next/image";
import Link from "next/link";
import { cn } from "@/lib/cn";
import { GmailMock, MessagesMock, NotionMock, SlackMock, WhatsAppMock, type MockProps } from "./AppMocks";
import { APP_LOGOS } from "./brand-logos.generated";
import { BrandLogo } from "./BrandLogo";
import { ClaudeCodeMock } from "./ClaudeCodeMock";
import { DICTATIONS } from "./content";
import { useDictation, type Phase } from "./dictation";
import { Waveform } from "./primitives";
import { useReducedMotion } from "./visitor";
import { Wallpaper } from "./Wallpaper";

type Scene = {
  name: string;
  logo: string;
  Mock: ComponentType<MockProps>;
  text: string;
  // Chats and terminals send on Return, so the text leaves the field.
  sends: boolean;
};

const SCENES: Scene[] = [
  { name: "Claude Code", logo: "Claude", Mock: ClaudeCodeMock, text: DICTATIONS.claudeCode, sends: true },
  { name: "Messages", logo: "Messages", Mock: MessagesMock, text: DICTATIONS.messages, sends: true },
  { name: "Gmail", logo: "Gmail", Mock: GmailMock, text: DICTATIONS.gmail, sends: false },
  { name: "WhatsApp", logo: "WhatsApp", Mock: WhatsAppMock, text: DICTATIONS.whatsapp, sends: true },
  { name: "Slack", logo: "Slack", Mock: SlackMock, text: DICTATIONS.slack, sends: true },
  { name: "Notion", logo: "Notion", Mock: NotionMock, text: DICTATIONS.notion, sends: false },
];

const LOGOS = SCENES.map((s) => APP_LOGOS.find((logo) => logo.name === s.logo)!);

// How much page scroll each app gets, in viewport heights.
const STEP_SVH = 70;

// The stage is a little Mac screen drawn in points and scaled to fit. Windows
// are a real small window size, or a narrow one on phones, where their
// sidebars collapse. They grow taller to use any spare height.
const WIDE = { w: 720, h: 430 };
const NARROW = { w: 380, h: 450 };
const MAX_GROW = 1.25;
// The overlay is 40 pt tall (Overlay.swift), sitting just above the Dock;
// the window keeps clear of it.
const PILL_BOTTOM = 80;
const PILL_HEIGHT = 40;
const WINDOW_BOTTOM = PILL_BOTTOM + PILL_HEIGHT + 12;
const MARGIN = 12;
// dock.png is 893 x 123 at 2x.
const DOCK = { w: 446.5, h: 61.5 };

// Which scene the page is scrolled to: the track's scroll range is split
// evenly between the scenes while its sticky stage is pinned.
function useActiveScene(track: RefObject<HTMLDivElement | null>): number {
  const [active, setActive] = useState(0);

  useEffect(() => {
    const update = () => {
      const el = track.current;
      if (!el) return;
      const rect = el.getBoundingClientRect();
      const range = rect.height - innerHeight;
      const progress = range > 0 ? Math.min(Math.max(-rect.top / range, 0), 0.9999) : 0;
      setActive(Math.floor(progress * SCENES.length));
    };
    const frame = requestAnimationFrame(update);
    addEventListener("scroll", update, { passive: true });
    addEventListener("resize", update);
    return () => {
      cancelAnimationFrame(frame);
      removeEventListener("scroll", update);
      removeEventListener("resize", update);
    };
  }, [track]);

  return active;
}

type Fit = { scale: number; width: number; height: number; win: { w: number; h: number } };

// How much to scale the screen so a whole window, the overlay and the Dock fit
// the stage. Measured, so it is unknown until the first layout.
function useFit(stage: RefObject<HTMLElement | null>): Fit | null {
  const [fit, setFit] = useState<Fit | null>(null);

  useEffect(() => {
    const el = stage.current;
    if (!el) return;
    const observer = new ResizeObserver(([entry]) => {
      const { width, height } = entry.contentRect;
      const base = width < 560 ? NARROW : WIDE;
      const scale = Math.min(width / (base.w + 2 * MARGIN), height / (base.h + MARGIN + WINDOW_BOTTOM), 1.1);
      const room = height / scale - MARGIN - WINDOW_BOTTOM;
      const win = { w: base.w, h: Math.round(Math.min(Math.max(room, base.h), base.h * MAX_GROW)) };
      setFit({ scale, width: width / scale, height: height / scale, win });
    });
    observer.observe(el);
    return () => observer.disconnect();
  }, [stage]);

  return fit;
}

// talkflow's overlay, at its real size: a black capsule with the red recording
// dot and nine level bars while fn is held. Between dictations it shows the hint.
function Pill({ listening }: { listening: boolean }) {
  return (
    <div
      className="absolute left-1/2 flex -translate-x-1/2 items-center justify-center rounded-full bg-black/88 text-[13px] whitespace-nowrap text-white shadow-[0_6px_16px_rgba(0,0,0,0.35)] transition-[width] duration-300"
      style={{ bottom: PILL_BOTTOM, height: PILL_HEIGHT, width: listening ? 150 : 168 }}
    >
      {listening ? (
        <span className="flex w-full items-center px-4">
          <span className="size-2.5 flex-none animate-dot-pulse rounded-full bg-rec" />
          <span className="flex flex-1 justify-center pl-3.5">
            <Waveform bars={9} height={28} barWidth={2.5} gap={3.5} />
          </span>
        </span>
      ) : (
        <span className="flex items-center gap-2 text-white/80">
          Hold <kbd className="rounded-md border border-white/25 px-1.5 py-px font-sans text-[12px] text-white">fn</kbd> to
          talk
        </span>
      )}
    </div>
  );
}

// Where a scene sits relative to the one on show: the next ones wait just
// below, the ones already passed sink back behind it.
type Place = "before" | "active" | "after";

const EASE = "cubic-bezier(.2,.8,.2,1)";
const PLACE = {
  // On top, turns opaque fast so the window underneath never shows through.
  active: { className: "z-10 opacity-100", transition: `opacity 180ms ease-out, translate 700ms ${EASE}` },
  before: { className: "pointer-events-none -translate-y-3 opacity-0", transition: `opacity 380ms ease-in 140ms, translate 700ms ${EASE}` },
  after: { className: "pointer-events-none translate-y-10 opacity-0", transition: `opacity 380ms ease-in 140ms, translate 700ms ${EASE}` },
};

// One app's window, centred above the overlay. It waits a little smaller and
// zooms in when talkflow starts listening.
function SceneView({
  scene,
  place,
  reduced,
  win,
  onPhase,
}: {
  scene: Scene;
  place: Place;
  reduced: boolean;
  win: { w: number; h: number };
  onPhase: (phase: Phase) => void;
}) {
  const d = useDictation(scene.text, place === "active", reduced, scene.sends);
  const { Mock } = scene;

  useEffect(() => {
    if (place === "active") onPhase(d.phase);
  }, [place, d.phase, onPhase]);

  return (
    <div
      className={cn("absolute inset-x-0 grid place-items-center", PLACE[place].className)}
      style={{ top: MARGIN, bottom: WINDOW_BOTTOM, transition: PLACE[place].transition }}
    >
      <div
        className={cn(
          "@container relative overflow-hidden rounded-[12px] shadow-[0_0_0_0.5px_rgba(0,0,0,0.35),0_22px_56px_-6px_rgba(0,0,0,0.5),0_8px_18px_-4px_rgba(0,0,0,0.22)] [transition:scale_900ms_cubic-bezier(.2,.8,.2,1)]",
          d.phase === "idle" ? "scale-[0.95]" : "scale-100",
        )}
        style={{ width: win.w, height: win.h }}
      >
        <Mock text={scene.text} d={d} />
      </div>
    </div>
  );
}

// The right-hand column of "Say the whole thought": a tall scroll track with a
// pinned stage. Scrolling through the track walks the stage from Claude Code
// through the apps listed in "Speak, and it appears in", each with something
// being dictated into it. The stage is a Mac desktop: the window in front,
// talkflow's overlay and the Dock below it.
export function AppTour() {
  const track = useRef<HTMLDivElement>(null);
  const stage = useRef<HTMLElement>(null);
  const active = useActiveScene(track);
  const fit = useFit(stage);
  const [phase, setPhase] = useState<Phase>("idle");
  const reduced = useReducedMotion();

  const lenis = useLenis();

  // Scrolls to the middle of a scene's share of the track.
  const show = (i: number) => {
    const el = track.current;
    if (!el) return;
    const top = el.getBoundingClientRect().top + scrollY;
    const range = el.offsetHeight - innerHeight;
    const target = top + (range * (i + 0.5)) / SCENES.length;
    if (lenis) lenis.scrollTo(target, { duration: 1.1 });
    else scrollTo({ top: target, behavior: reduced ? "auto" : "smooth" });
  };

  return (
    <div ref={track} className="relative" style={{ height: `calc(100svh + ${(SCENES.length - 1) * STEP_SVH}svh)` }}>
      <div className="sticky top-0 flex h-svh flex-col justify-center pt-16 pb-4">
        <div className="mb-5 flex justify-center">
          <div className="flex items-center gap-0.5 rounded-full border border-line bg-paper p-1">
            {SCENES.map((s, i) => (
              <button
                key={s.name}
                type="button"
                onClick={() => show(i)}
                aria-label={`Show ${s.name}`}
                aria-current={i === active ? "true" : undefined}
                className={cn(
                  "flex h-9 items-center rounded-full px-2 text-[13.5px] transition-[background-color,box-shadow,color] duration-300 sm:px-2.5 sm:text-[14px]",
                  i === active ? "bg-white text-ink shadow-[0_1px_3px_rgba(31,30,34,0.14)]" : "text-graphite hover:bg-ink/5",
                )}
              >
                <BrandLogo logo={LOGOS[i]} className="size-[18px]" />
                <span
                  className={cn(
                    "grid transition-[grid-template-columns] duration-300 ease-[cubic-bezier(.2,.8,.2,1)]",
                    i === active ? "grid-cols-[1fr]" : "grid-cols-[0fr]",
                  )}
                >
                  <span className="overflow-hidden pl-2 whitespace-nowrap">{s.name}</span>
                </span>
              </button>
            ))}
          </div>
        </div>

        <figure
          ref={stage}
          className="relative isolate h-[min(580px,calc(100svh-190px))] overflow-hidden rounded-3xl"
        >
          <figcaption className="sr-only">
            talkflow typing a dictated message into {SCENES[active].name}. Scroll to see it in other apps.
          </figcaption>
          <Wallpaper className="-z-10" />
          {fit && (
            <div
              aria-hidden="true"
              className="absolute top-0 left-0 origin-top-left"
              style={{ width: fit.width, height: fit.height, scale: fit.scale }}
            >
              {SCENES.map((s, i) => (
                <SceneView
                  key={s.name}
                  scene={s}
                  place={i < active ? "before" : i > active ? "after" : "active"}
                  reduced={reduced}
                  win={fit.win}
                  onPhase={setPhase}
                />
              ))}
              <Pill listening={phase === "listening"} />
              {/* The real Tahoe Dock: its glass, captured, with the apps' own icons. The glass blurs what is behind it. */}
              <div
                className="absolute bottom-[3px] left-1/2 -translate-x-1/2"
                style={{ width: `min(${DOCK.w}px, 100% - 16px)`, aspectRatio: `${DOCK.w} / ${DOCK.h}` }}
              >
                <span className="absolute inset-x-[0.5%] top-[5%] bottom-[2.5%] rounded-[30%/50%] backdrop-blur-xl backdrop-saturate-150" />
                <Image src="/app/dock.png" alt="" fill unoptimized className="relative" />
              </div>
            </div>
          )}
        </figure>
        <p className="mt-4 text-center text-[12.5px] text-graphite/80">
          talkflow isn&apos;t affiliated with these apps.{" "}
          <Link href="/terms#other-companies" className="underline decoration-line underline-offset-2 hover:text-ink">
            Trademarks
          </Link>
        </p>
      </div>
    </div>
  );
}
