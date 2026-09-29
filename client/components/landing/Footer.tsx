import { LiveDot } from "./primitives";

const LINKS = ["GitHub", "Twitter", "Instagram", "YouTube", "Privacy policy"];

export function Footer() {
  return (
    <footer className="border-t border-divider">
      <div className="mx-auto flex max-w-[1200px] flex-wrap items-center justify-between gap-x-8 gap-y-5 px-gutter py-8 text-[14px] text-muted">
        <span className="flex items-center gap-2.5 font-heading text-[20px] font-semibold text-ink">
          <LiveDot className="size-[9px]" />
          TalkFlow
        </span>
        <div className="flex flex-wrap gap-x-[22px] gap-y-2">
          {LINKS.map((label) => (
            <a key={label} href="#" className="underline underline-offset-3 hover:text-accent">
              {label}
            </a>
          ))}
        </div>
        <span>Made by Samir Kharel.</span>
      </div>
    </footer>
  );
}
