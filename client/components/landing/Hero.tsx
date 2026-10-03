import { DownloadCta } from "./DownloadCta";
import { HeroRibbon } from "./HeroRibbon";

export function Hero() {
  return (
    <section id="top" className="relative overflow-hidden pt-[clamp(96px,min(12vw,17svh),136px)]">
      <div className="mx-auto flex max-w-[1200px] flex-col items-center px-gutter text-center">
        <p className="mb-6 inline-flex items-center gap-2 rounded-full border border-line bg-white/70 py-1 pr-3.5 pl-1 text-[14px] text-graphite">
          <span className="rounded-full bg-ink px-2.5 py-0.5 text-[12.5px] font-medium text-paper">Free</span>
          The open-source Wispr Flow alternative
        </p>
        <h1 className="font-serif text-[clamp(48px,min(8.6vw,12.5svh),108px)] leading-[0.94] font-normal tracking-[-0.025em]">
          Talk to your computer,
          <br />
          <em>for free, forever.</em>
        </h1>
        <p className="mt-5 max-w-[44ch] text-[clamp(17px,1.6vw,20px)] leading-[1.5] text-graphite">
          Hold fn, speak, and your words are typed wherever your cursor is. Open source, and it never leaves your Mac.
        </p>
        <div className="mt-7">
          <DownloadCta compare />
        </div>
      </div>
      <HeroRibbon />
    </section>
  );
}
