import Image from "next/image";
import { cn } from "@/lib/cn";

// Square, hairline-bordered buttons from the design system. Sizes are left to
// the call site.
export const buttonClass = {
  primary:
    "inline-flex cursor-pointer items-center justify-center border border-accent bg-accent font-heading font-semibold leading-[1.2] text-bg hover:bg-accent-600 active:bg-accent-700",
  secondary:
    "inline-flex cursor-pointer items-center justify-center border border-divider font-heading font-semibold leading-[1.2] text-ink hover:bg-ink/7 active:bg-ink/14",
};

// Small caps label used for eyebrows, stat labels and diagram captions.
export const labelClass = "text-[12px] font-semibold uppercase tracking-[.08em]";

const CORNER =
  "absolute size-[11px] text-ink/55 before:absolute before:top-0 before:left-[5px] before:h-full before:w-px before:bg-current after:absolute after:top-[5px] after:left-0 after:h-px after:w-full after:bg-current";

// Registration marks drawn just outside a blueprint frame. The parent must be
// positioned.
export function Corners() {
  return (
    <>
      <i aria-hidden="true" className={cn(CORNER, "-top-1.5 -left-1.5")} />
      <i aria-hidden="true" className={cn(CORNER, "-top-1.5 -right-1.5")} />
      <i aria-hidden="true" className={cn(CORNER, "-bottom-1.5 -left-1.5")} />
      <i aria-hidden="true" className={cn(CORNER, "-right-1.5 -bottom-1.5")} />
    </>
  );
}

export function Blueprint({ className, children }: { className?: string; children: React.ReactNode }) {
  return (
    <div className={cn("relative border border-divider", className)}>
      <Corners />
      {children}
    </div>
  );
}

export function LiveDot({ className }: { className?: string }) {
  return <span aria-hidden="true" className={cn("inline-block size-2 flex-none animate-live rounded-full bg-accent", className)} />;
}

const PEAKS = [0.55, 0.85, 1, 0.7, 0.9, 0.6, 0.8, 0.5, 0.95, 0.65, 0.75, 0.55];

// A row of voice-level bars. Idle bars (and all bars under reduced motion)
// rest at a third of their height.
export function Wave({
  count,
  height,
  color,
  active = true,
  barWidth,
}: {
  count: number;
  height: number;
  color: string;
  active?: boolean;
  barWidth?: number;
}) {
  return (
    <span aria-hidden="true" className="inline-flex items-center" style={{ gap: barWidth ? barWidth * 1.2 : 3, height }}>
      {Array.from({ length: count }, (_, i) => (
        <span
          key={i}
          className={cn("block origin-center rounded-[2px]", active ? "motion-reduce:scale-y-35" : "scale-y-35")}
          style={{
            width: barWidth ?? 2.5,
            height: Math.round(height * PEAKS[i % PEAKS.length]),
            background: color,
            animation: active ? `tfwave ${0.78 + (i % 4) * 0.16}s ease-in-out ${(i * -0.137).toFixed(2)}s infinite` : undefined,
          }}
        />
      ))}
    </span>
  );
}

// Stands in for a design "image slot": shows the image once a source is set
// in content.ts, otherwise a labelled placeholder. The parent must be
// positioned and sized.
export function ImageSlot({
  src,
  alt,
  placeholder,
  sizes,
  className,
}: {
  src: string | null;
  alt: string;
  placeholder: string;
  sizes: string;
  className?: string;
}) {
  if (src) return <Image src={src} alt={alt} fill sizes={sizes} className="object-cover" unoptimized={src.endsWith(".gif")} />;
  return (
    <div role="img" aria-label={placeholder} className={cn("absolute inset-0 grid place-items-center p-4 text-center", className)}>
      <span className="opacity-70">{placeholder}</span>
    </div>
  );
}

// A numbered page section: eyebrow ("01 / How it works"), rule, content.
export function Section({
  id,
  index,
  title,
  children,
}: {
  id?: string;
  index: string;
  title: string;
  children: React.ReactNode;
}) {
  return (
    <section id={id} data-reveal className="py-[clamp(48px,7vw,96px)]">
      <span className="mb-3 block text-[13px] font-semibold tracking-[.08em] text-ink-accent uppercase">
        {index} / {title}
      </span>
      <hr className="mb-9 h-px border-0 bg-divider" />
      {children}
    </section>
  );
}

// Column with a top rule and a small accent index, used for step and fact lists.
export function Numbered({ index, children }: { index: string; children: React.ReactNode }) {
  return (
    <div className="border-t border-divider pt-5">
      <span className="text-[13px] font-semibold tracking-[.08em] text-ink-accent">{index}</span>
      {children}
    </div>
  );
}
