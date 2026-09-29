import { cn } from "@/lib/cn";

// The five-bar mark from the app icon and menu bar (Packaging/AppIcon.icns,
// Sources/talkflowd/StatusBar.swift), measured on the icon's 1024 grid.
const BARS = [
  { x: 159, y: 348, h: 328 },
  { x: 312, y: 231, h: 562 },
  { x: 466, y: 77, h: 870 },
  { x: 620, y: 231, h: 562 },
  { x: 773, y: 348, h: 328 },
];

// Bars only, in currentColor, for use next to the wordmark or inside the ink pill.
export function BrandMark({ className }: { className?: string }) {
  return (
    <svg viewBox="159 77 706 870" aria-hidden="true" className={cn("fill-current", className)}>
      {BARS.map((b) => (
        <rect key={b.x} x={b.x} y={b.y} width="92" height={b.h} rx="46" />
      ))}
    </svg>
  );
}

// The full app icon: white bars on the ink rounded square.
export function AppIcon({ className }: { className?: string }) {
  return (
    <svg viewBox="0 0 1024 1024" aria-hidden="true" className={className}>
      <rect width="1024" height="1024" rx="230" fill="#1f1e22" />
      <g fill="#fff">
        {BARS.map((b) => (
          <rect key={b.x} x={b.x} y={b.y} width="92" height={b.h} rx="46" />
        ))}
      </g>
    </svg>
  );
}

export function Wordmark({ className }: { className?: string }) {
  return (
    <span className={cn("inline-flex items-center gap-2.5 font-serif text-[22px] leading-none tracking-[-0.01em]", className)}>
      <AppIcon className="size-7" />
      TalkFlow
    </span>
  );
}
