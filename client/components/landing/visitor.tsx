"use client";

import { createContext, useCallback, useContext, useSyncExternalStore } from "react";

type Os = "mac" | "windows";

type Visitor = {
  os: Os;
  // Phones and narrow windows can't install talkflow, so they get a
  // "copy link" button instead of a download.
  mobile: boolean;
};

const noopSubscribe = () => () => {};

function detectOs(): Os {
  const nav = navigator as Navigator & { userAgentData?: { platform?: string } };
  const platform = nav.userAgentData?.platform || navigator.platform || "";
  return /win/i.test(platform) || /Windows/.test(navigator.userAgent) ? "windows" : "mac";
}

function detectMobileUa(): boolean {
  return /iPhone|iPad|iPod|Android|Mobile/i.test(navigator.userAgent);
}

export function useMediaQuery(query: string): boolean {
  const subscribe = useCallback(
    (onChange: () => void) => {
      const mq = matchMedia(query);
      mq.addEventListener("change", onChange);
      return () => mq.removeEventListener("change", onChange);
    },
    [query],
  );
  return useSyncExternalStore(subscribe, () => matchMedia(query).matches, () => false);
}

export function useReducedMotion(): boolean {
  return useMediaQuery("(prefers-reduced-motion: reduce)");
}

const VisitorContext = createContext<Visitor | null>(null);

export function VisitorProvider({ children }: { children: React.ReactNode }) {
  const os = useSyncExternalStore(noopSubscribe, detectOs, () => "mac" as Os);
  const mobileUa = useSyncExternalStore(noopSubscribe, detectMobileUa, () => false);
  const narrow = useMediaQuery("(max-width: 639px)");

  return <VisitorContext.Provider value={{ os, mobile: mobileUa || narrow }}>{children}</VisitorContext.Provider>;
}

export function useVisitor(): Visitor {
  const visitor = useContext(VisitorContext);
  if (!visitor) throw new Error("useVisitor must be used inside <VisitorProvider>");
  return visitor;
}
