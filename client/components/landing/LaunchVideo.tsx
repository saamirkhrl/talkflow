"use client";

import { Pause, Play, Volume2, VolumeX } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { useReducedMotion } from "./visitor";

const controlClass =
  "inline-flex items-center gap-1.5 rounded-full bg-ink/80 px-3 py-1.5 text-[13px] font-medium text-paper backdrop-blur transition-colors hover:bg-ink";

// The launch reel. It plays muted while it's on screen and pauses when it
// isn't; with reduced motion it waits for a click. The reel's background is
// the page's paper, so it sits in the page rather than in a black box.
export function LaunchVideo() {
  const reduced = useReducedMotion();
  const ref = useRef<HTMLVideoElement>(null);
  const [playing, setPlaying] = useState(false);
  const [muted, setMuted] = useState(true);

  useEffect(() => {
    const video = ref.current;
    if (!video || reduced) return;
    const observer = new IntersectionObserver(
      ([entry]) => {
        if (entry.isIntersecting) video.play().catch(() => {});
        else video.pause();
      },
      { threshold: 0.4 },
    );
    observer.observe(video);
    return () => observer.disconnect();
  }, [reduced]);

  const toggle = () => {
    const video = ref.current;
    if (!video) return;
    if (video.paused) video.play().catch(() => {});
    else video.pause();
  };

  const toggleSound = () => {
    const video = ref.current;
    if (!video) return;
    video.muted = !video.muted;
    setMuted(video.muted);
    // Turning the sound on starts the reel over, so the music lines up with the cuts.
    if (!video.muted) {
      video.currentTime = 0;
      video.play().catch(() => {});
    }
  };

  return (
    <section id="watch" aria-label="talkflow in 36 seconds" className="pt-[clamp(72px,9vw,128px)]">
      <div className="mx-auto max-w-[1080px] px-gutter">
        <div className="group relative overflow-hidden rounded-[clamp(14px,2vw,24px)] border border-line bg-paper shadow-[0_30px_80px_-30px_rgb(31_30_34/0.25)]">
          <video
            ref={ref}
            className="block aspect-video w-full cursor-pointer"
            src="/video/launch.mp4"
            poster="/video/launch-poster.webp"
            muted
            loop
            playsInline
            preload="none"
            onClick={toggle}
            onPlay={() => setPlaying(true)}
            onPause={() => setPlaying(false)}
          />
          {!playing && (
            <button
              type="button"
              onClick={toggle}
              aria-label="Play the talkflow launch video"
              className="absolute inset-0 grid place-items-center bg-ink/5 transition-colors hover:bg-ink/10"
            >
              <span className="grid size-16 place-items-center rounded-full bg-ink text-paper shadow-lg sm:size-20">
                <Play className="size-7 translate-x-0.5 fill-current sm:size-8" />
              </span>
            </button>
          )}
          <div className="absolute right-3 bottom-3 flex gap-2 opacity-100 transition-opacity sm:opacity-0 sm:group-focus-within:opacity-100 sm:group-hover:opacity-100">
            {playing && (
              <button type="button" onClick={toggle} aria-label="Pause" className={controlClass}>
                <Pause className="size-3.5 fill-current" />
              </button>
            )}
            <button type="button" onClick={toggleSound} aria-pressed={!muted} className={controlClass}>
              {muted ? <VolumeX className="size-3.5" /> : <Volume2 className="size-3.5" />}
              {muted ? "Sound on" : "Mute"}
            </button>
          </div>
        </div>
      </div>
    </section>
  );
}
