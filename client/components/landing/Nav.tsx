"use client";

import { useSyncExternalStore } from "react";
import { Wordmark } from "@/components/brand/Logo";
import { cn } from "@/lib/cn";
import { BrandLogo } from "./BrandLogo";
import { OS_LOGOS } from "./brand-logos.generated";
import { DOWNLOAD_URL, REPO_URL, SHOW_OS_LOGOS } from "./content";
import { GithubIcon } from "./GithubIcon";
import { buttonClass } from "./primitives";
import { useVisitor } from "./visitor";

function subscribeScroll(onChange: () => void) {
  addEventListener("scroll", onChange, { passive: true });
  return () => removeEventListener("scroll", onChange);
}

const LINKS = [
  ["Features", "#features"],
  ["Privacy", "#privacy"],
  ["FAQs", "#faq"],
];

// A floating pill that tightens and turns to frosted glass once the page moves.
export function Nav({ stars }: { stars: number | null }) {
  const { os, mobile } = useVisitor();
  const scrolled = useSyncExternalStore(subscribeScroll, () => scrollY > 24, () => false);

  return (
    <header className="pointer-events-none fixed inset-x-0 top-3 z-50 flex justify-center px-3 sm:top-4">
      <nav
        aria-label="Main"
        className={cn(
          "pointer-events-auto flex w-full items-center gap-1 rounded-full border border-line pr-3 pl-3 transition-[max-width,height,background-color,box-shadow] duration-500 ease-[cubic-bezier(.2,.8,.2,1)] sm:pl-4",
          scrolled
            ? "h-12 max-w-[700px] bg-mist/75 shadow-[0_12px_32px_-14px_rgba(31,30,34,0.3)] backdrop-blur-xl backdrop-saturate-150"
            : "h-14 max-w-[820px] bg-paper/90 shadow-[0_1px_2px_rgba(31,30,34,0.06)]",
        )}
      >
        <a href="#top" aria-label="TalkFlow home" className="mr-auto inline-flex items-center rounded-full">
          <Wordmark className={cn("transition-[font-size] duration-500", scrolled ? "text-[19px]" : "text-[21px]")} />
        </a>

        {!mobile && (
          <div className="flex items-center text-[15px] text-graphite">
            {LINKS.map(([label, href]) => (
              <a key={href} href={href} className="rounded-full px-3 py-1.5 transition-colors hover:bg-ink/5 hover:text-ink">
                {label}
              </a>
            ))}
          </div>
        )}

        <a
          href={mobile ? "#download" : DOWNLOAD_URL}
          className={cn(buttonClass.secondary, "mr-1 px-4 text-[15px] transition-[height] duration-500", scrolled ? "h-9" : "h-10")}
        >
          {SHOW_OS_LOGOS && !mobile && (
            <BrandLogo logo={os === "mac" ? OS_LOGOS.apple : OS_LOGOS.windows} className="size-[15px] -translate-y-px" />
          )}
          Download
        </a>

        <a
          href={REPO_URL}
          aria-label={stars === null ? "TalkFlow on GitHub" : `Star TalkFlow on GitHub (${stars} stars)`}
          className={cn(buttonClass.primary, "px-4 text-[15px] transition-[height] duration-500", scrolled ? "h-9" : "h-10")}
        >
          <GithubIcon size={17} />
          {!mobile && <span>GitHub</span>}
          {!mobile && stars !== null && (
            <span className="border-l border-paper/25 pl-2 tabular-nums">{stars.toLocaleString("en-US")}</span>
          )}
        </a>
      </nav>
    </header>
  );
}
