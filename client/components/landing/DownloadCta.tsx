"use client";

import { Check, Copy, Download, ExternalLink, Layers, Link2 } from "lucide-react";
import Link from "next/link";
import { useEffect, useRef, useState, useSyncExternalStore } from "react";
import { cn } from "@/lib/cn";
import { BrandLogo } from "./BrandLogo";
import { OS_LOGOS } from "./brand-logos.generated";
import { INSTALL_SCRIPT_PATH, MAC_BUILD_DETAIL, RELEASES_URL, SHOW_OS_LOGOS, WINDOWS_AVAILABLE, WINDOWS_DOWNLOAD_PATH, WISPR_FLOW_PRICE } from "./content";
import { buttonClass } from "./primitives";
import { useVisitor } from "./visitor";

const OS = {
  mac: { label: "Mac", logo: OS_LOGOS.apple },
  windows: { label: "Windows", logo: OS_LOGOS.windows },
};

// Wispr Flow Pro's price with a red line drawn through it, then "Free". The
// asterisk points to the non-affiliation note at the bottom of the footer.
function PriceCompare() {
  return (
    <p className="flex items-center gap-3.5 leading-none">
      <span className="sr-only">
        Wispr Flow Pro costs {WISPR_FLOW_PRICE}. talkflow is free. talkflow is not affiliated with Wispr.
      </span>
      <span aria-hidden="true" className="flex flex-col items-start gap-1.5">
        <span className="text-[12px] tracking-[0.01em] text-graphite">Wispr Flow Pro*</span>
        <span className="relative font-serif text-[28px] text-ink/55">
          {WISPR_FLOW_PRICE}
          <svg
            viewBox="0 0 100 40"
            preserveAspectRatio="none"
            className="pointer-events-none absolute -inset-x-2.5 -inset-y-0.5 h-[calc(100%+4px)] w-[calc(100%+20px)] overflow-visible"
          >
            <path
              d="M2 36 C 28 28, 60 16, 98 4"
              pathLength={1}
              fill="none"
              stroke="var(--color-rec)"
              strokeWidth={5.5}
              strokeLinecap="round"
              vectorEffect="non-scaling-stroke"
              className="[stroke-dasharray:1] animate-[strike_550ms_cubic-bezier(.6,0,.3,1)_700ms_both]"
            />
          </svg>
        </span>
      </span>
      <span aria-hidden="true" className="self-end font-serif text-[36px] italic">
        Free
      </span>
    </p>
  );
}

// Desktop visitors get the button for their own OS: on a Mac it opens the
// Apple Silicon / Intel page, on Windows it downloads the one installer
// (while WINDOWS_AVAILABLE is off, Windows says it is coming).
// Under it, the one-line Terminal install and a menu of every build. Phones
// can't run talkflow, so they get a way to carry the link to a computer
// instead. Nothing is collected either way. `compare` adds the Wispr Flow
// price next to the button.
export function DownloadCta({ align = "center", compare = false }: { align?: "center" | "start"; compare?: boolean }) {
  const { os, mobile } = useVisitor();

  if (mobile) return <CopyLink align={align} compare={compare} />;

  return (
    <div className={cn("flex flex-col gap-4", align === "center" ? "items-center" : "items-start")}>
      <div className="flex flex-wrap items-center justify-center gap-x-7 gap-y-4">
        {os === "mac" ? (
          <Link href="/download/mac" className={cn(buttonClass.primary, "h-13 px-7 text-[17px]")}>
            {SHOW_OS_LOGOS && <BrandLogo logo={OS.mac.logo} className="size-[18px] -translate-y-px" />}
            Download for Mac
          </Link>
        ) : WINDOWS_AVAILABLE ? (
          // A plain link: the route redirects to the installer, which downloads.
          <a href={WINDOWS_DOWNLOAD_PATH} className={cn(buttonClass.primary, "h-13 px-7 text-[17px]")}>
            {SHOW_OS_LOGOS && <BrandLogo logo={OS.windows.logo} className="size-[18px] -translate-y-px" />}
            Download for Windows
          </a>
        ) : (
          <span aria-disabled="true" className={cn(buttonClass.secondary, "h-13 cursor-default px-7 text-[17px] text-graphite hover:bg-transparent")}>
            {SHOW_OS_LOGOS && <BrandLogo logo={OS.windows.logo} className="size-[18px] -translate-y-px" />}
            Windows version coming soon
          </span>
        )}
        {compare && <PriceCompare />}
      </div>
      <InstallCommand />
    </div>
  );
}

// "https://<this site>" while the page is open; empty while rendering on the
// server, where there is no address yet.
function useOrigin(): string {
  return useSyncExternalStore(noopSubscribe, () => location.origin, () => "");
}
const noopSubscribe = () => () => {};

// The one-line Terminal install, copyable, and the button that lists every
// build. The command names this site, so it is right on whatever domain the
// page is served from.
function InstallCommand() {
  const origin = useOrigin();
  const [copied, setCopied] = useState(false);
  const command = `curl -fsSL ${origin}${INSTALL_SCRIPT_PATH} | bash`;

  return (
    <div className="flex items-center gap-2">
      <div className="flex h-11 min-w-0 items-center gap-3 rounded-full border border-line pl-4 pr-1.5 font-mono text-[13px]">
        <span aria-hidden="true" className="select-none text-graphite">$</span>
        <code className="truncate text-ink">{command}</code>
        <button
          type="button"
          aria-label={copied ? "Copied" : "Copy install command"}
          onClick={async () => {
            try {
              await navigator.clipboard.writeText(command);
              setCopied(true);
              setTimeout(() => setCopied(false), 1600);
            } catch {
              setCopied(false);
            }
          }}
          className="inline-flex size-8 flex-none items-center justify-center rounded-full text-graphite transition-colors hover:bg-ink/5 hover:text-ink"
        >
          {copied ? <Check size={16} aria-hidden="true" /> : <Copy size={16} aria-hidden="true" />}
        </button>
      </div>
      <OtherBuilds />
    </div>
  );
}

// A small menu of every build, for anyone who wants the other OS or the
// GitHub release page.
function OtherBuilds() {
  const [open, setOpen] = useState(false);
  const ref = useRef<HTMLDivElement>(null);

  useEffect(() => {
    if (!open) return;
    const close = (event: Event) => {
      if (event instanceof KeyboardEvent ? event.key === "Escape" : !ref.current?.contains(event.target as Node)) setOpen(false);
    };
    document.addEventListener("pointerdown", close);
    document.addEventListener("keydown", close);
    return () => {
      document.removeEventListener("pointerdown", close);
      document.removeEventListener("keydown", close);
    };
  }, [open]);

  return (
    <div ref={ref} className="relative">
      <button
        type="button"
        aria-label="Other builds"
        aria-haspopup="menu"
        aria-expanded={open}
        title="Other builds"
        onClick={() => setOpen((value) => !value)}
        className={cn(buttonClass.secondary, "size-11", open && "bg-ink/5")}
      >
        <Layers size={17} aria-hidden="true" />
      </button>
      {open && (
        <div
          role="menu"
          className="absolute right-0 top-full z-20 mt-2 w-80 rounded-2xl border border-line bg-paper p-1.5 text-left shadow-[0_12px_40px_rgb(0_0_0/0.12)]"
        >
          <p className="px-3 pb-1 pt-2 text-[12px] tracking-[0.01em] text-graphite">All builds</p>
          <Link role="menuitem" href="/download/mac" onClick={() => setOpen(false)} className={menuItem}>
            {SHOW_OS_LOGOS && <BrandLogo logo={OS.mac.logo} className="size-4 flex-none" />}
            <span className="flex flex-col">
              <span className="text-[15px] text-ink">macOS</span>
              <span className="text-[12px] text-graphite">{MAC_BUILD_DETAIL}</span>
            </span>
            <Download size={16} aria-hidden="true" className="ml-auto text-graphite" />
          </Link>
          {WINDOWS_AVAILABLE ? (
            <a role="menuitem" href={WINDOWS_DOWNLOAD_PATH} onClick={() => setOpen(false)} className={menuItem}>
              {SHOW_OS_LOGOS && <BrandLogo logo={OS.windows.logo} className="size-4 flex-none" />}
              <span className="flex flex-col">
                <span className="text-[15px] text-ink">Windows</span>
                <span className="text-[12px] text-graphite">Any PC with Windows 10 or 11</span>
              </span>
              <Download size={16} aria-hidden="true" className="ml-auto text-graphite" />
            </a>
          ) : (
            <div role="menuitem" aria-disabled="true" className={cn(menuItem, "cursor-default hover:bg-transparent")}>
              {SHOW_OS_LOGOS && <BrandLogo logo={OS.windows.logo} className="size-4 flex-none opacity-60" />}
              <span className="flex flex-col">
                <span className="text-[15px] text-graphite">Windows</span>
                <span className="text-[12px] text-graphite">Coming soon</span>
              </span>
            </div>
          )}
          <a role="menuitem" href={RELEASES_URL} target="_blank" rel="noopener noreferrer" onClick={() => setOpen(false)} className={cn(menuItem, "border-t border-line rounded-t-none mt-1 pt-3")}>
            <span className="text-[14px] text-graphite">All releases on GitHub</span>
            <ExternalLink size={14} aria-hidden="true" className="ml-auto text-graphite" />
          </a>
        </div>
      )}
    </div>
  );
}

const menuItem = "flex w-full items-center gap-3 rounded-xl px-3 py-2.5 transition-colors hover:bg-ink/5";

function CopyLink({ align, compare }: { align: "center" | "start"; compare: boolean }) {
  const [copied, setCopied] = useState(false);

  return (
    <div className={cn("flex max-w-[34ch] flex-col gap-3", align === "center" ? "items-center text-center" : "items-start")}>
      {compare && (
        <div className="mb-2">
          <PriceCompare />
        </div>
      )}
      <button
        type="button"
        onClick={async () => {
          try {
            await navigator.clipboard.writeText(location.href.split("#")[0]);
            setCopied(true);
          } catch {
            setCopied(false);
          }
        }}
        className={cn(buttonClass.primary, "h-13 px-7 text-[17px]")}
      >
        {copied ? <Check size={18} aria-hidden="true" /> : <Link2 size={18} aria-hidden="true" />}
        {copied ? "Link copied" : "Copy link for your computer"}
      </button>
      <p className="text-[15px] text-graphite">talkflow runs on your computer, not your phone. Open this page on your Mac or PC to download it.</p>
    </div>
  );
}
