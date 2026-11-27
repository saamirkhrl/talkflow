import { DownloadCta } from "./DownloadCta";
import { HeroRibbon } from "./HeroRibbon";
import { ForOs } from "./visitor";

// The copy sits in the open sky of the plush scene (SkyBackdrop, behind the page).
export function Hero() {
  return (
    <section id="top" className="relative overflow-x-clip">
      {/* A haze of sky blue behind the copy, so white text reads over the clouds. */}
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 top-0 h-[880px] bg-[radial-gradient(ellipse_52%_46%_at_50%_34%,rgb(10_55_190/0.78),rgb(10_55_190/0.42)_55%,transparent_78%)]"
      />
      <div className="relative z-10 mx-auto flex max-w-[1200px] flex-col items-center px-gutter pt-[clamp(108px,min(13vw,16svh),148px)] text-center">
        <p className="mb-6 inline-flex items-center gap-2 rounded-full bg-white/12 py-1 pr-3.5 pl-1 text-[14px] text-white/90 ring-1 ring-white/20 backdrop-blur-sm">
          <span className="rounded-full bg-coral px-2.5 py-0.5 text-[12.5px] font-medium text-white">Free</span>
          The open-source Wispr Flow alternative
        </p>
        <h1 className="font-serif text-[clamp(48px,min(8.4vw,11.5svh),104px)] leading-[0.94] font-normal tracking-[-0.025em] text-white">
          Talk to your computer,
          <br />
          <em>for free, forever.</em>
        </h1>
        <p className="mt-5 max-w-[44ch] text-[clamp(17px,1.6vw,20px)] leading-[1.5] text-white/85">
          Hold <ForOs mac="fn" windows="Ctrl + Win" />, speak, and your words are typed wherever your cursor is. Open source, and it
          never leaves your <ForOs mac="Mac" windows="computer" />.
        </p>
        <div className="relative z-10 mt-7">
          <DownloadCta compare />
        </div>
      </div>
      <HeroRibbon />
    </section>
  );
}
