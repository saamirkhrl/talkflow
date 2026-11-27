import { AppIcon } from "@/components/brand/Logo";
import { DownloadCta } from "./DownloadCta";

export function FinalCta() {
  return (
    <section id="download" className="mx-auto flex max-w-[1200px] flex-col items-center px-gutter py-[clamp(64px,9vw,120px)] text-center">
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

// Launch-directory badges, shown in the footer box.
export function Badges() {
  return (
    <div className="flex flex-wrap items-center gap-4">
      <a
        href="https://www.producthunt.com/products/talkflow-6?embed=true&utm_source=badge-featured&utm_medium=badge&utm_campaign=badge-talkflow-ea47cdaa-f4ff-4b0b-a5a4-56bd516d7179"
        target="_blank"
        rel="noopener noreferrer"
        className="inline-flex rounded-lg transition-opacity hover:opacity-80"
      >
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          alt="talkflow - 100% free, open-source, and private alternative to WisprFlow | Product Hunt"
          width={200}
          height={43}
          src="https://api.producthunt.com/widgets/embed-image/v1/featured.svg?post_id=1280918&theme=light&t=1792035925990"
        />
      </a>
      <a href="https://www.trymacapps.com" target="_blank" rel="noopener noreferrer" className="inline-flex rounded-lg bg-white px-1.5 transition-opacity hover:opacity-80">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img alt="Featured on TryMacApps" width={200} height={67} src="https://www.trymacapps.com/badge.png" />
      </a>
      <a
        href="https://usefulshelf.co/?utm_source=maker-website&utm_medium=referral&utm_campaign=badge&utm_content=lime"
        target="_blank"
        rel="nofollow noopener noreferrer"
        className="inline-flex rounded-lg transition-opacity hover:opacity-80"
      >
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img alt="Featured on UsefulShelf" width={248} height={66} src="https://usefulshelf.co/badge/usefulshelf.svg?theme=lime" />
      </a>
    </div>
  );
}
