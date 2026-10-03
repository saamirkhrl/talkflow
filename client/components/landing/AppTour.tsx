"use client";

import { useEffect, useRef, useState, type ComponentType, type RefObject } from "react";
import { useLenis } from "lenis/react";
import Link from "next/link";
import { cn } from "@/lib/cn";
import { GmailMock, MessagesMock, NotionMock, SlackMock, WhatsAppMock, type MockProps } from "./AppMocks";
import { APP_LOGOS } from "./brand-logos.generated";
import { BrandLogo } from "./BrandLogo";
import { ClaudeCodeMock } from "./ClaudeCodeMock";
import { DICTATIONS } from "./content";
import { useDictation } from "./dictation";
import { RecDot, Waveform } from "./primitives";
import { useReducedMotion } from "./visitor";

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

// The overlay talkflow shows at the bottom of the screen: a red dot and input
// levels while fn is held.
function Pill({ listening }: { listening: boolean }) {
  return (
    <div className="absolute bottom-0 left-1/2 flex h-11 min-w-[172px] -translate-x-1/2 items-center justify-center gap-3 rounded-full bg-ink px-5 text-[14px] whitespace-nowrap text-paper shadow-[0_16px_32px_-12px_rgba(31,30,34,0.5)] ring-1 ring-white/20">
      {listening ? (
        <>
          <RecDot />
          <Waveform bars={12} height={20} />
        </>
      ) : (
        <span className="flex items-center gap-2 text-paper/80">
          Hold <kbd className="rounded-md border border-paper/25 px-1.5 py-px font-sans text-[12px] text-paper">fn</kbd> to
          talk
        </span>
      )}
    </div>
  );
}

// Where a scene sits relative to the one on show: the next ones wait just
// below, the ones already passed sink back behind it.
type Place = "before" | "active" | "after";

const PLACE = {
  // On top, turns opaque fast so the window underneath never shows through.
  active:
    "z-10 opacity-100 [transition:opacity_180ms_ease-out,translate_700ms_cubic-bezier(.2,.8,.2,1),scale_700ms_cubic-bezier(.2,.8,.2,1)]",
  before:
    "pointer-events-none -translate-y-3 scale-[0.95] opacity-0 [transition:opacity_380ms_ease-in_140ms,translate_700ms_cubic-bezier(.2,.8,.2,1),scale_700ms_cubic-bezier(.2,.8,.2,1)]",
  after:
    "pointer-events-none translate-y-10 opacity-0 [transition:opacity_380ms_ease-in_140ms,translate_700ms_cubic-bezier(.2,.8,.2,1),scale_700ms_cubic-bezier(.2,.8,.2,1)]",
};

function SceneView({ scene, place, reduced }: { scene: Scene; place: Place; reduced: boolean }) {
  const d = useDictation(scene.text, place === "active", reduced, scene.sends);
  const { Mock } = scene;

  return (
    <div className={cn("absolute inset-0", PLACE[place])}>
      <div className="absolute inset-x-0 top-0 bottom-9 overflow-hidden rounded-xl border border-black/12 shadow-[0_30px_60px_-30px_rgba(31,30,34,0.5)]">
        <Mock text={scene.text} d={d} />
      </div>
      <Pill listening={d.phase === "listening"} />
    </div>
  );
}

// The right-hand column of "Say the whole thought": a tall scroll track with a
// pinned stage. Scrolling through the track walks the stage from Claude Code
// through the apps listed in "Speak, and it appears in", each with something
// being dictated into it.
export function AppTour() {
  const track = useRef<HTMLDivElement>(null);
  const active = useActiveScene(track);
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
                  "flex h-9 items-center rounded-full px-2.5 text-[14px] transition-[background-color,box-shadow,color] duration-300",
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

        <figure className="relative h-[min(470px,calc(100svh-185px))] sm:h-[min(530px,calc(100svh-185px))]">
          <figcaption className="sr-only">
            talkflow typing a dictated message into {SCENES[active].name}. Scroll to see it in other apps.
          </figcaption>
          <div aria-hidden="true">
            {SCENES.map((s, i) => (
              <SceneView key={s.name} scene={s} place={i < active ? "before" : i > active ? "after" : "active"} reduced={reduced} />
            ))}
          </div>
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
