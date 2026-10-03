"use client";

import { Check, Link2 } from "lucide-react";
import { useState } from "react";
import { cn } from "@/lib/cn";
import { BrandLogo } from "./BrandLogo";
import { OS_LOGOS } from "./brand-logos.generated";
import { DOWNLOAD_URL, SHOW_OS_LOGOS, WINDOWS_AVAILABLE, WISPR_FLOW_PRICE } from "./content";
import { buttonClass } from "./primitives";
import { useVisitor } from "./visitor";

const OS = {
  mac: { label: "Mac", logo: OS_LOGOS.apple },
  windows: { label: "Windows", logo: OS_LOGOS.windows },
};

// Wispr Flow Pro's price with a red line drawn through it, then "Free".
function PriceCompare() {
  return (
    <p className="flex items-center gap-3.5 leading-none">
      <span className="sr-only">
        Wispr Flow Pro costs {WISPR_FLOW_PRICE}. talkflow is free.
      </span>
      <span aria-hidden="true" className="flex flex-col items-start gap-1.5">
        <span className="text-[12px] tracking-[0.01em] text-graphite">Wispr Flow Pro</span>
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

// Desktop visitors get a download for their OS plus a link for the other one.
// Phones can't run talkflow, so they get a way to carry the link to a computer
// instead. Nothing is collected either way. `compare` adds the Wispr Flow
// price next to the button.
export function DownloadCta({ align = "center", compare = false }: { align?: "center" | "start"; compare?: boolean }) {
  const visitor = useVisitor();
  // Until there's a Windows build, everyone is offered the Mac download.
  const os = WINDOWS_AVAILABLE ? visitor.os : "mac";
  const other = os === "mac" ? "windows" : "mac";
  const { mobile } = visitor;

  if (mobile) return <CopyLink align={align} compare={compare} />;

  return (
    <div className={cn("flex flex-col gap-4", align === "center" ? "items-center" : "items-start")}>
      <div className="flex flex-wrap items-center justify-center gap-x-7 gap-y-4">
        <a href={DOWNLOAD_URL} target="_blank" rel="noopener noreferrer" className={cn(buttonClass.primary, "h-13 px-7 text-[17px]")}>
          {SHOW_OS_LOGOS && <BrandLogo logo={OS[os].logo} className="size-[18px] -translate-y-px" />}
          Download for {OS[os].label}
        </a>
        {compare && <PriceCompare />}
      </div>
      {WINDOWS_AVAILABLE ? (
        <a
          href={DOWNLOAD_URL}
          target="_blank" rel="noopener noreferrer"
          className="inline-flex items-center gap-1.5 text-[15px] text-graphite underline decoration-line underline-offset-4 hover:text-ink hover:decoration-ink"
        >
          {SHOW_OS_LOGOS && <BrandLogo logo={OS[other].logo} className="size-3.5" />}
          Also available for {OS[other].label}
        </a>
      ) : (
        <p className="text-[15px] text-graphite">Windows version coming soon</p>
      )}
    </div>
  );
}

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
      <p className="text-[15px] text-graphite">talkflow runs on your computer, not your phone. Open this page on your Mac to download it.</p>
    </div>
  );
}
