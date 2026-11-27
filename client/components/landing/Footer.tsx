import Link from "next/link";
import { GUIDES } from "./content";

export function Footer() {
  return (
    <footer className="overflow-hidden">
      <div className="mx-auto max-w-[1200px] px-gutter pt-10">
        <div className="glass px-[clamp(20px,3vw,36px)] py-8">
        <nav aria-labelledby="footer-guides" className="mb-10 border-b border-line pb-10">
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
        </div>
        <p id="not-affiliated" className="mx-auto max-w-[70ch] pt-6 text-center text-[13px] leading-[1.5] text-white/80">
          * talkflow is an independent, open-source project. It is not affiliated with, endorsed
          by or sponsored by Wispr AI, Inc. Wispr Flow is a trademark of Wispr AI, Inc.
        </p>
        {/* The wordmark rests on the coral and cloud bed at the foot of the scene. */}
        <p aria-hidden="true" className="mt-[clamp(80px,14svh,180px)] pb-[clamp(120px,22svh,260px)] text-center font-serif text-[clamp(72px,22.5vw,290px)] leading-[0.8] tracking-[-0.04em] whitespace-nowrap text-white select-none [text-shadow:0_10px_40px_rgb(10_40_150/0.45),0_2px_0_rgb(190_180_240/0.9)]">
          talkflow
        </p>
      </div>
    </footer>
  );
}
