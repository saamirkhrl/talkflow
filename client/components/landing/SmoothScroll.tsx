"use client";

import { useEffect } from "react";
import { usePathname } from "next/navigation";
import { ReactLenis, useLenis } from "lenis/react";
import "lenis/dist/lenis.css";

// Next resets the native scroll position on navigation, but Lenis keeps its
// own animated target and can drag the new page back to the old offset (or
// leave it half-scrolled). Re-sync it on every route change: jump to the
// hash target if there is one, otherwise to the top.
function ResetOnNavigate() {
  const lenis = useLenis();
  const pathname = usePathname();

  useEffect(() => {
    if (!lenis) return;
    const id = decodeURIComponent(window.location.hash.slice(1));
    const target = id ? document.getElementById(id) : null;
    lenis.scrollTo(target ?? 0, { immediate: true, force: true });
  }, [lenis, pathname]);

  return null;
}

// Momentum scrolling for the whole site. Lenis drives the real document
// scroll, so sticky sections and scroll listeners keep working. It also
// smooths in-page anchor links (honoring scroll-padding-top), leaves touch
// scrolling native, and goes 1:1 for visitors who prefer reduced motion.
export function SmoothScroll() {
  return (
    <ReactLenis root options={{ anchors: true, lerp: 0.09 }}>
      <ResetOnNavigate />
    </ReactLenis>
  );
}
