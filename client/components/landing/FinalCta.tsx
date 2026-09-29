import { DownloadCta } from "./DownloadCta";
import { Wave } from "./primitives";

export function FinalCta() {
  return (
    <section
      id="download"
      data-reveal
      className="flex flex-col items-center gap-7 pt-[clamp(72px,10vw,140px)] pb-[clamp(64px,8vw,112px)] text-center"
    >
      <Wave count={24} height={44} color="var(--color-accent)" barWidth={3} />
      <h2 className="font-display text-[clamp(44px,7vw,92px)] leading-[.96] font-normal tracking-[-0.02em]">Talk instead of type.</h2>
      <p className="text-[19px] text-muted">Private, free, on your computer.</p>
      <DownloadCta variant="final" />
      <p className="text-[14px] tracking-[.04em] text-muted">Free · No account · Works offline</p>
    </section>
  );
}
