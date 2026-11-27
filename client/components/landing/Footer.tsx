import Link from "next/link";
import { GUIDES } from "./content";
import { Badges } from "./FinalCta";

export function Footer() {
  return (
    <footer className="overflow-hidden">
      <div className="mx-auto max-w-[1200px] px-gutter pt-10">
        <div className="glass px-[clamp(20px,3vw,36px)] py-8">
          <nav aria-labelledby="footer-guides">
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
          <p id="not-affiliated" className="mt-8 text-[13px] leading-[1.5] text-white/70">
            * talkflow is an independent, open-source project. It is not affiliated with, endorsed
            by or sponsored by Wispr AI, Inc. Wispr Flow is a trademark of Wispr AI, Inc.
          </p>
        </div>

        <div className="mt-10 flex justify-center">
          <Badges />
        </div>

        {/* The wordmark, solid white with a soft glow, resting on the scene. */}
        <p
          aria-hidden="true"
          className="mt-[clamp(40px,7svh,96px)] text-center font-serif text-[clamp(88px,22vw,480px)] leading-[0.9] font-normal tracking-[-0.03em] whitespace-nowrap text-white select-none [text-shadow:0_0_40px_rgb(200_190_255/0.6),0_14px_40px_rgb(6_30_130/0.45)]"
        >
          talkflow
        </p>

        <div className="mt-[clamp(16px,3vw,32px)] mb-8 flex flex-wrap items-center justify-between gap-x-8 gap-y-3 rounded-full bg-[#08227a]/80 px-6 py-3 text-[14px] text-white/85 backdrop-blur-md">
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
      </div>
    </footer>
  );
}
