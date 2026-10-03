"use client";

import { ReactLenis } from "lenis/react";
import "lenis/dist/lenis.css";

// Momentum scrolling for the whole site. Lenis drives the real document
// scroll, so sticky sections and scroll listeners keep working. It also
// smooths in-page anchor links (honoring scroll-padding-top), leaves touch
// scrolling native, and goes 1:1 for visitors who prefer reduced motion.
export function SmoothScroll() {
  return <ReactLenis root options={{ anchors: true, lerp: 0.09 }} />;
}
