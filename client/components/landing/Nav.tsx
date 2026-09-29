"use client";

import { Download } from "lucide-react";
import { cn } from "@/lib/cn";
import { GITHUB_STARS, GITHUB_URL } from "./content";
import { GithubIcon } from "./GithubIcon";
import { buttonClass, LiveDot } from "./primitives";
import { useVisitor } from "./visitor";

export function Nav() {
  const { mobile } = useVisitor();

  return (
    <nav className="sticky top-0 z-20 flex items-center gap-7 border-b border-divider bg-bg/88 px-gutter py-3.5 backdrop-blur-[10px]">
      <a href="#top" className="mr-auto flex items-center gap-2.5 font-heading text-[22px] font-semibold">
        <LiveDot className="size-[9px]" />
        TalkFlow
      </a>
      {!mobile && (
        <div className="flex gap-7 text-[15px]">
          <a href="#features" className="hover:text-accent">Features</a>
          <a href="#privacy" className="hover:text-accent">Privacy</a>
          <a href="#faq" className="hover:text-accent">FAQ</a>
        </div>
      )}
      <div className="flex items-center gap-2.5">
        <a href={GITHUB_URL} aria-label="Star TalkFlow on GitHub" className={cn(buttonClass.secondary, "gap-2 px-3 py-2 text-[15px]")}>
          <GithubIcon size={16} />
          <span>Star</span>
          <span className="border-l border-divider pl-2 text-muted tabular-nums">{GITHUB_STARS}</span>
        </a>
        <a href="#download" className={cn(buttonClass.primary, "gap-2 px-3.5 py-2 text-[15px]")}>
          <Download size={15} strokeWidth={1.75} aria-hidden="true" />
          {mobile ? "Get it" : "Download"}
        </a>
      </div>
    </nav>
  );
}
