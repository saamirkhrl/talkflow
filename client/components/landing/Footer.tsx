import Link from "next/link";
import { GUIDES } from "./content";
import { Badges } from "./FinalCta";

export function Footer() {
  return (
    <footer className="overflow-hidden pb-0">
      <div className="mx-auto max-w-[1200px] px-gutter pt-10">
        <div className="glass px-[clamp(20px,3vw,36px)] py-8">
        <nav aria-labelledby="footer-guides" className="mb-8">
          <h2 id="footer-guides" className="text-[13px] tracking-[0.01em] text-graphite">
            Guides
          </h2>
          <ul className="mt-4 grid gap-x-8 gap-y-2.5 text-[15px] text-graphite sm:grid-cols-2 lg:grid-cols-4">
            {GUIDES.map((guide) => (
              <li key={guide.path}>
                <Link href={guide.path} className="hover:text-white">
                  {guide.label}
                </Link>
              </li>
            ))}
          </ul>
        </nav>
        <div className="flex flex-wrap items-center justify-between gap-x-8 gap-y-3 text-[15px] text-graphite">
          <p>Free and open source, under the MIT License.</p>
          <div className="flex gap-6">
            <Link href="/terms" className="hover:text-white">
              Terms
            </Link>
            <Link href="/privacy" className="hover:text-white">
              Privacy
            </Link>
            <Link href="/terms#other-companies" className="hover:text-white">
              Trademarks
            </Link>
          </div>
        </div>
        <div className="mt-8">
          <Badges />
        </div>
        <p id="not-affiliated" className="mt-8 text-left text-[13px] leading-[1.5] text-white/70">
          * talkflow is an independent, open-source project. It is not affiliated with, endorsed
          by or sponsored by Wispr AI, Inc. Wispr Flow is a trademark of Wispr AI, Inc.
        </p>
        </div>
        {/* The wordmark, nearly edge to edge, glowing like the clouds and
            fading into the scene at its foot. */}
        <p
          aria-hidden="true"
          className="relative mt-[clamp(48px,8svh,120px)] -mb-[0.06em] flex justify-center font-serif text-[clamp(96px,25vw,560px)] leading-[0.8] font-normal tracking-[-0.035em] whitespace-nowrap select-none"
        >
          <span className="bg-[linear-gradient(180deg,#ffffff_0%,#ffffff_45%,rgb(255_255_255/0.55)_75%,rgb(255_255_255/0)_100%)] bg-clip-text text-transparent [filter:drop-shadow(0_0_30px_rgb(200_190_255/0.55))_drop-shadow(0_18px_40px_rgb(6_30_130/0.45))]">
            talkflow
          </span>
        </p>
      </div>
    </footer>
  );
}
