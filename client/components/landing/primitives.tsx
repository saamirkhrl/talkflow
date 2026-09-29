import { cn } from "@/lib/cn";

export const buttonClass = {
  primary:
    "inline-flex items-center justify-center gap-2 rounded-full bg-ink font-medium text-paper transition-colors hover:bg-ink/85 active:bg-ink/75",
  secondary:
    "inline-flex items-center justify-center gap-2 rounded-full border border-line font-medium text-ink transition-colors hover:bg-ink/5 active:bg-ink/10",
};

// The red "listening" dot, the same red the menu bar icon turns while recording.
export function RecDot({ className }: { className?: string }) {
  return <span aria-hidden="true" className={cn("inline-block size-2 flex-none animate-rec rounded-full bg-rec", className)} />;
}

const PEAKS = [0.45, 0.8, 1, 0.65, 0.9, 0.55, 0.75, 0.4, 0.95, 0.6, 0.85, 0.5];

// Live input level bars, like the overlay the app shows while you hold fn.
export function Waveform({
  bars,
  height,
  active = true,
  className,
}: {
  bars: number;
  height: number;
  active?: boolean;
  className?: string;
}) {
  return (
    <span aria-hidden="true" className={cn("inline-flex items-center gap-[3px]", className)} style={{ height }}>
      {Array.from({ length: bars }, (_, i) => (
        <span
          key={i}
          className={cn("block w-[3px] origin-center rounded-full bg-current", active ? "motion-reduce:scale-y-40" : "scale-y-30")}
          style={{
            height: Math.round(height * PEAKS[i % PEAKS.length]),
            animation: active ? `level ${0.7 + (i % 5) * 0.13}s ease-in-out ${(i * -0.11).toFixed(2)}s infinite` : undefined,
          }}
        />
      ))}
    </span>
  );
}

export function SectionTitle({ children, className }: { children: React.ReactNode; className?: string }) {
  return (
    <h2 className={cn("font-serif text-[clamp(38px,5.2vw,64px)] leading-[1.02] font-normal tracking-[-0.02em]", className)}>
      {children}
    </h2>
  );
}
