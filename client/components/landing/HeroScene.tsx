"use client";

import { useEffect, useRef } from "react";

// The scene under the hero copy. Its top edge fades into the hero's sky blue,
// and it drifts a little against the pointer so the plush shapes feel close.
export function HeroScene() {
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const el = ref.current;
    if (!el || matchMedia("(prefers-reduced-motion: reduce)").matches) return;
    let raf = 0;
    let tx = 0;
    let ty = 0;
    let x = 0;
    let y = 0;
    const loop = () => {
      // Ease toward the target so the motion stays soft.
      x += (tx - x) * 0.08;
      y += (ty - y) * 0.08;
      el.style.transform = `translate3d(${x * -18}px, ${y * -10}px, 0) scale(1.05)`;
      raf = Math.abs(tx - x) + Math.abs(ty - y) > 0.001 ? requestAnimationFrame(loop) : 0;
    };
    const onMove = (e: PointerEvent) => {
      tx = (e.clientX / innerWidth) * 2 - 1;
      ty = (e.clientY / innerHeight) * 2 - 1;
      if (!raf) raf = requestAnimationFrame(loop);
    };
    addEventListener("pointermove", onMove, { passive: true });
    return () => {
      removeEventListener("pointermove", onMove);
      cancelAnimationFrame(raf);
    };
  }, []);

  return (
    <div aria-hidden="true" className="pointer-events-none relative -mt-[clamp(40px,9vw,150px)] aspect-[16/9] w-full min-h-[360px] overflow-hidden">
      <div
        ref={ref}
        className="absolute inset-0 scale-[1.05] bg-cover bg-[position:50%_100%] will-change-transform [mask-image:linear-gradient(to_bottom,transparent_0%,black_22%)]"
        style={{ backgroundImage: 'url("/hero/plush.webp")' }}
      />
    </div>
  );
}
