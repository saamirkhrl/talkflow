"use client";

import { Check, Download } from "lucide-react";
import { useState } from "react";
import { cn } from "@/lib/cn";
import { buttonClass, Corners } from "./primitives";
import { useVisitor } from "./visitor";

const COPY = {
  hero: {
    submit: "Send me the download link",
    helper: "TalkFlow is a desktop app for Mac and Windows. We'll email you one link, nothing else.",
  },
  final: {
    submit: "Get it on your computer",
    helper: "We'll email you the link so you can install it on your desktop.",
  },
};

// Desktop visitors get a download button for their OS (with a link to swap
// OS); mobile visitors get an email form, since the app is desktop-only.
export function DownloadCta({ variant }: { variant: "hero" | "final" }) {
  const { os, mobile, swapOs } = useVisitor();
  const [email, setEmail] = useState("");
  const [sent, setSent] = useState(false);
  const hero = variant === "hero";

  if (!mobile) {
    return (
      <div className={cn("flex flex-col gap-3", hero ? "items-start" : "mt-2 items-center")}>
        <a href="#download" className={cn(buttonClass.primary, "relative gap-2.5 px-[26px] py-[15px] text-[19px] tracking-[.01em]")}>
          <Corners />
          <Download size={19} strokeWidth={1.75} aria-hidden="true" />
          {os === "mac" ? "Download for Mac" : "Download for Windows"}
        </a>
        <a
          href="#download"
          className="text-[14px] text-ink-accent underline underline-offset-3 hover:text-accent"
          onClick={(e) => {
            e.preventDefault();
            swapOs();
          }}
        >
          {os === "mac" ? "Also available for Windows" : "Also available for Mac"}
        </a>
      </div>
    );
  }

  return (
    <div className={cn("flex flex-col gap-3", !hero && "w-full max-w-[440px]")}>
      {sent ? (
        <p className="flex items-center gap-2.5 text-[16px]">
          {hero && <Check size={18} strokeWidth={2} className="text-accent" aria-hidden="true" />}
          Sent. Open it on your Mac or PC.
        </p>
      ) : (
        // Prototype only: nothing is emailed yet, the form just flips to "Sent".
        <form
          className="flex flex-wrap gap-2.5"
          onSubmit={(e) => {
            e.preventDefault();
            setSent(true);
          }}
        >
          <input
            type="email"
            required
            placeholder="you@example.com"
            aria-label="Email address"
            value={email}
            onChange={(e) => setEmail(e.target.value)}
            className="min-h-12 flex-[1_1_200px] border border-divider bg-surface px-2.5 py-1.5 text-[16px] text-ink caret-accent hover:border-ink/45 focus-visible:border-accent focus-visible:outline-offset-0"
          />
          <button type="submit" className={cn(buttonClass.primary, "min-h-12 px-5 text-[17px]", !hero && "flex-auto")}>
            {COPY[variant].submit}
          </button>
        </form>
      )}
      <p className="text-[14px] text-muted">{COPY[variant].helper}</p>
    </div>
  );
}
