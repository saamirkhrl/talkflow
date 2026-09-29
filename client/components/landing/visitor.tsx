"use client";

import { createContext, useCallback, useContext, useState, useSyncExternalStore } from "react";

type Os = "mac" | "windows";

type Visitor = {
  os: Os;
  // Phones and narrow windows get the "email me the link" flow instead of a
  // download button, since TalkFlow is a desktop app.
  mobile: boolean;
  swapOs: () => void;
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
  const detectedOs = useSyncExternalStore(noopSubscribe, detectOs, () => "mac" as Os);
  const mobileUa = useSyncExternalStore(noopSubscribe, detectMobileUa, () => false);
  const narrow = useMediaQuery("(max-width: 639px)");
  const [swapped, setSwapped] = useState(false);

  const os = swapped ? (detectedOs === "mac" ? "windows" : "mac") : detectedOs;
  const swapOs = useCallback(() => setSwapped((s) => !s), []);

  return (
    <VisitorContext.Provider value={{ os, mobile: mobileUa || narrow, swapOs }}>
      {children}
    </VisitorContext.Provider>
  );
}

export function useVisitor(): Visitor {
  const visitor = useContext(VisitorContext);
  if (!visitor) throw new Error("useVisitor must be used inside <VisitorProvider>");
  return visitor;
}
