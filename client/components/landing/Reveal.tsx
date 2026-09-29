"use client";

import { useEffect } from "react";
import { useReducedMotion } from "./visitor";

// Fades [data-reveal] sections up as they scroll into view. Anything already
// on screen at load is left alone so the first paint never blinks.
export function Reveal() {
  const reduced = useReducedMotion();

  useEffect(() => {
    if (reduced || !("IntersectionObserver" in window)) return;
    const show = (el: HTMLElement) => {
      el.style.opacity = "1";
      el.style.transform = "none";
    };
    const io = new IntersectionObserver(
      (entries) =>
        entries.forEach((entry) => {
          if (!entry.isIntersecting) return;
          show(entry.target as HTMLElement);
          io.unobserve(entry.target);
        }),
      { threshold: 0.08 },
    );
    const hidden: HTMLElement[] = [];
    document.querySelectorAll<HTMLElement>("[data-reveal]").forEach((el) => {
      if (el.getBoundingClientRect().top < innerHeight) return;
      el.style.opacity = "0";
      el.style.transform = "translateY(18px)";
      el.style.transition = "opacity .8s cubic-bezier(.2,.7,.2,1), transform .8s cubic-bezier(.2,.7,.2,1)";
      hidden.push(el);
      io.observe(el);
    });
    return () => {
      io.disconnect();
      hidden.forEach(show);
    };
  }, [reduced]);

  return null;
}
