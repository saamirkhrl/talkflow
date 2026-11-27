"use client";

import { useEffect, useRef } from "react";

// One tall plush render behind the whole home page. It is fixed to the window
// and pans from the sky at the top to the coral and cloud bed at the bottom as
// the page scrolls, so the page reads as one long scene. Only a transform
// changes, so it stays on the GPU.
export function SkyBackdrop() {
  const ref = useRef<HTMLImageElement>(null);

  useEffect(() => {
    const img = ref.current;
    if (!img) return;
    let raf = 0;
    const update = () => {
      raf = 0;
      const max = document.documentElement.scrollHeight - innerHeight;
      const p = max > 0 ? Math.min(1, Math.max(0, scrollY / max)) : 0;
      const travel = Math.max(0, img.offsetHeight - innerHeight);
      img.style.transform = `translate3d(-50%, ${-p * travel}px, 0)`;
    };
    const kick = () => {
      if (!raf) raf = requestAnimationFrame(update);
    };
    addEventListener("scroll", kick, { passive: true });
    addEventListener("resize", kick);
    const ro = new ResizeObserver(kick);
    ro.observe(document.body);
    img.addEventListener("load", kick);
    kick();
    return () => {
      cancelAnimationFrame(raf);
      removeEventListener("scroll", kick);
      removeEventListener("resize", kick);
      ro.disconnect();
    };
  }, []);

  return (
    <div aria-hidden="true" className="pointer-events-none fixed inset-0 -z-10 overflow-hidden">
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img
        ref={ref}
        src="/hero/sky-2400.webp"
        srcSet="/hero/sky-1200.webp 1200w, /hero/sky-2400.webp 2400w"
        sizes="100vw"
        alt=""
        decoding="async"
        fetchPriority="high"
        className="absolute top-0 left-1/2 h-auto w-full min-w-[calc(100svh*0.56)] max-w-none will-change-transform"
      />
    </div>
  );
}
