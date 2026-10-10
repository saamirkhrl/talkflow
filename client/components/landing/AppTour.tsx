"use client";

import { useCallback, useEffect, useRef, useState, type ComponentType } from "react";
import Link from "next/link";
import { cn } from "@/lib/cn";
import { GmailMock, MessagesMock, NotionMock, SlackMock, WhatsAppMock, type MockProps } from "./AppMocks";
import { APP_LOGOS } from "./brand-logos.generated";
import { BrandLogo } from "./BrandLogo";
import { ClaudeCodeMock } from "./ClaudeCodeMock";
import { DICTATIONS } from "./content";
import { useDictation, type Phase } from "./dictation";
import { RecDot, Waveform, wallpaperStyle } from "./primitives";
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

// The overlay talkflow shows at the bottom of the screen: a red dot and input
// levels while fn is held.
function Pill({ listening }: { listening: boolean }) {
  return (
    <div className="absolute bottom-[68px] left-1/2 flex h-11 min-w-[172px] -translate-x-1/2 items-center justify-center gap-3 rounded-full bg-ink px-5 text-[14px] whitespace-nowrap text-paper shadow-[0_16px_32px_-12px_rgba(31,30,34,0.5)] ring-1 ring-white/20">
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

const DOCK_ICON = "grid size-10 flex-none place-items-center rounded-[11px] bg-white/90 p-[7px] shadow-[0_1px_3px_rgba(0,0,0,0.25)] sm:size-11";

// One app's window. It waits a little smaller, and zooms in when talkflow starts listening.
function SceneView({
  scene,
  active,
  reduced,
  onPhase,
  onEnd,
}: {
  scene: Scene;
  active: boolean;
  reduced: boolean;
  onPhase: (phase: Phase) => void;
  onEnd: () => void;
}) {
  const d = useDictation(scene.text, active, reduced, scene.sends, onEnd);
  const { Mock } = scene;
  const zoomed = d.phase !== "idle";

  useEffect(() => {
    if (active) onPhase(d.phase);
  }, [active, d.phase, onPhase]);

  return (
    <div
      className={cn(
        "absolute inset-x-0 top-0 bottom-[116px] origin-[50%_60%] [transition:opacity_300ms_ease-out,scale_1100ms_cubic-bezier(.2,.8,.2,1)]",
        active ? "z-10 opacity-100" : "pointer-events-none opacity-0",
        zoomed ? "scale-100" : "scale-[0.9]",
      )}
    >
      <div className="absolute inset-0 overflow-hidden rounded-xl border border-black/15 shadow-[0_40px_80px_-24px_rgba(0,10,40,0.6)]">
        <Mock text={scene.text} d={d} />
      </div>
    </div>
  );
}

// "Say the whole thought": a looping demo, like a screen recording. talkflow's pill and a
// dock of apps sit on the Mac desktop; the pill wakes up, the app in front zooms in a
// little and the dictated words arrive. Then the next app takes over. Pauses off screen.
export function AppTour() {
  const stage = useRef<HTMLElement>(null);
  const [active, setActive] = useState(0);
  const [phase, setPhase] = useState<Phase>("idle");
  const [visible, setVisible] = useState(false);
  const reduced = useReducedMotion();

  useEffect(() => {
    const el = stage.current;
    if (!el) return;
    const observer = new IntersectionObserver(([entry]) => setVisible(entry.isIntersecting), { threshold: 0.35 });
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  const next = useCallback(() => setActive((i) => (i + 1) % SCENES.length), []);

  return (
    <div className="flex flex-col justify-center">
      <figure
        ref={stage}
        className="relative mx-auto h-[min(500px,calc(100svh-120px))] w-full max-w-[1200px] overflow-hidden rounded-3xl sm:h-[560px]"
        style={wallpaperStyle}
      >
        <figcaption className="sr-only">
          talkflow typing a dictated message into {SCENES[active].name}. The demo cycles through other apps.
        </figcaption>
        <div aria-hidden="true" className="absolute inset-3 sm:inset-8">
          {SCENES.map((s, i) => (
            <SceneView key={s.name} scene={s} active={i === active && visible} reduced={reduced} onPhase={setPhase} onEnd={next} />
          ))}
          <Pill listening={phase === "listening"} />
        </div>
        <div className="absolute bottom-3 left-1/2 flex -translate-x-1/2 gap-2 rounded-[22px] border border-white/30 bg-white/25 p-1.5 shadow-[0_10px_30px_rgba(0,10,40,0.35)] backdrop-blur-xl">
          {SCENES.map((s, i) => (
            <button
              key={s.name}
              type="button"
              onClick={() => setActive(i)}
              aria-label={`Show ${s.name}`}
              aria-current={i === active ? "true" : undefined}
              className="relative flex flex-col items-center"
            >
              <span className={cn(DOCK_ICON, "transition-transform duration-300", i === active && "-translate-y-1.5 scale-110")}>
                <BrandLogo logo={LOGOS[i]} className="size-full" />
              </span>
              <span className={cn("absolute -bottom-1 size-1 rounded-full bg-white/90 transition-opacity", i === active ? "opacity-100" : "opacity-0")} />
            </button>
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
  );
}
