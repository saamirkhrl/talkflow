"use client";

import { Check, Link2 } from "lucide-react";
import { useState } from "react";
import { cn } from "@/lib/cn";
import { BrandLogo } from "./BrandLogo";
import { OS_LOGOS } from "./brand-logos.generated";
import { DOWNLOAD_URL, SHOW_OS_LOGOS } from "./content";
import { buttonClass } from "./primitives";
import { useVisitor } from "./visitor";

const OS = {
  mac: { label: "Mac", logo: OS_LOGOS.apple },
  windows: { label: "Windows", logo: OS_LOGOS.windows },
};

// Desktop visitors get a download for their OS plus a link for the other one.
// Phones can't run TalkFlow, so they get a way to carry the link to a computer
// instead. Nothing is collected either way.
export function DownloadCta({ align = "center" }: { align?: "center" | "start" }) {
  const { os, mobile } = useVisitor();
  const other = os === "mac" ? "windows" : "mac";

  if (mobile) return <CopyLink align={align} />;

  return (
    <div className={cn("flex flex-col gap-4", align === "center" ? "items-center" : "items-start")}>
      <a href={DOWNLOAD_URL} className={cn(buttonClass.primary, "h-13 px-7 text-[17px]")}>
        {SHOW_OS_LOGOS && <BrandLogo logo={OS[os].logo} className="size-[18px] -translate-y-px" />}
        Download for {OS[os].label}
      </a>
      <a
        href={DOWNLOAD_URL}
        className="inline-flex items-center gap-1.5 text-[15px] text-graphite underline decoration-line underline-offset-4 hover:text-ink hover:decoration-ink"
      >
        {SHOW_OS_LOGOS && <BrandLogo logo={OS[other].logo} className="size-3.5" />}
        Also available for {OS[other].label}
      </a>
    </div>
  );
}

function CopyLink({ align }: { align: "center" | "start" }) {
  const [copied, setCopied] = useState(false);

  return (
    <div className={cn("flex max-w-[34ch] flex-col gap-3", align === "center" ? "items-center text-center" : "items-start")}>
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
      <p className="text-[15px] text-graphite">TalkFlow runs on your computer, not your phone. Open this page on your Mac to download it.</p>
    </div>
  );
}
