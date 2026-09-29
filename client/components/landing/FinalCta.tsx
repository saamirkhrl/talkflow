import { AppIcon } from "@/components/brand/Logo";
import { DownloadCta } from "./DownloadCta";

export function FinalCta() {
  return (
    <section id="download" className="mx-auto flex max-w-[1200px] flex-col items-center px-gutter py-[clamp(96px,13vw,176px)] text-center">
      <AppIcon className="size-[88px] drop-shadow-[0_18px_28px_rgba(31,30,34,0.28)]" />
      <h2 className="mt-10 font-serif text-[clamp(48px,7.4vw,96px)] leading-[0.95] font-normal tracking-[-0.025em]">
        Talk instead of type.
      </h2>
      <p className="mt-6 max-w-[36ch] text-[19px] text-graphite">Free, open source, and private by design. Set up once and just talk.</p>
      <div className="mt-10">
        <DownloadCta />
      </div>
    </section>
  );
}
