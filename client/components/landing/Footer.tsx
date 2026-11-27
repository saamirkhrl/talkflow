import Link from "next/link";
import { GUIDES } from "./content";

export function Footer() {
  return (
    <footer className="overflow-hidden">
      <div className="mx-auto max-w-[1200px] px-gutter pt-10">
        <div className="rounded-[28px] bg-white/10 px-[clamp(20px,3vw,36px)] py-8 ring-1 ring-white/20 backdrop-blur-md">
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
        {/* The plush "talkflow" in the scene shows through here. */}
        <div aria-hidden="true" className="h-[clamp(300px,52svh,560px)]" />
      </div>
    </footer>
  );
}
