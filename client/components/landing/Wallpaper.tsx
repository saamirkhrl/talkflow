"use client";

import { useEffect, useRef, useState } from "react";
import { cn } from "@/lib/cn";

const IMAGE = 'url("/wallpaper/tahoe.webp")';

// The macOS Tahoe desktop picture, drifting slowly the way Tahoe's own
// wallpaper flows: two oversized copies pan and scale out of step, one
// mirrored and fading in and out over the other. Only transforms and opacity
// change, so it stays on the GPU. It holds still off screen, and the global
// reduced-motion rule stops it altogether.
export function Wallpaper({ className }: { className?: string }) {
  const ref = useRef<HTMLDivElement>(null);
  const [onScreen, setOnScreen] = useState(false);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const observer = new IntersectionObserver(([entry]) => setOnScreen(entry.isIntersecting));
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  const playState = onScreen ? "running" : "paused";

  return (
    <div ref={ref} aria-hidden="true" className={cn("absolute inset-0 overflow-hidden bg-[#1b3a78]", className)}>
      <div
        className="absolute -inset-[12%] animate-drift bg-cover bg-center will-change-transform"
        style={{ backgroundImage: IMAGE, animationPlayState: playState }}
      />
      <div
        className="absolute -inset-[12%] animate-drift-alt bg-cover bg-center opacity-0 will-change-[transform,opacity]"
        style={{ backgroundImage: IMAGE, animationPlayState: playState }}
      />
    </div>
  );
}
