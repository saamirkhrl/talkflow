import Link from "next/link";
import { FEATURED_ON, GUIDES } from "./content";

export function Footer() {
  return (
    <footer className="overflow-hidden">
      <div className="mx-auto max-w-[1200px] px-gutter pt-10">
        <nav aria-labelledby="footer-guides" className="mb-10 border-b border-line pb-10">
          <h2 id="footer-guides" className="text-[13px] tracking-[0.01em] text-graphite">
            Guides
          </h2>
          <ul className="mt-4 grid gap-x-8 gap-y-2.5 text-[15px] text-graphite sm:grid-cols-2 lg:grid-cols-4">
            {GUIDES.map((guide) => (
              <li key={guide.path}>
                <Link href={guide.path} className="hover:text-ink">
                  {guide.label}
                </Link>
              </li>
            ))}
          </ul>
        </nav>
        <nav aria-labelledby="footer-featured" className="mb-10 border-b border-line pb-10">
          <h2 id="footer-featured" className="text-[13px] tracking-[0.01em] text-graphite">
            Featured on
          </h2>
          <ul className="mt-4 flex flex-wrap gap-x-4 gap-y-1.5 text-[13px] text-graphite">
            {FEATURED_ON.map((site) => (
              <li key={site.url}>
                <a href={site.url} target="_blank" rel="noopener" className="hover:text-ink">
                  {site.name}
                </a>
              </li>
            ))}
          </ul>
        </nav>
        <div className="flex flex-wrap items-center justify-between gap-x-8 gap-y-3 text-[15px] text-graphite">
          <p>Free and open source, under the MIT License.</p>
          <div className="flex gap-6">
            <Link href="/terms" className="hover:text-ink">
              Terms
            </Link>
            <Link href="/privacy" className="hover:text-ink">
              Privacy
            </Link>
            <Link href="/terms#other-companies" className="hover:text-ink">
              Trademarks
            </Link>
          </div>
        </div>
        <p aria-hidden="true" className="mt-16 pb-6 text-center font-serif text-[clamp(72px,22.5vw,290px)] leading-[0.8] tracking-[-0.04em] whitespace-nowrap select-none">
          talkflow
        </p>
        <p id="not-affiliated" className="mx-auto max-w-[70ch] pb-8 text-center text-[13px] leading-[1.5] text-graphite">
          * talkflow is an independent, open-source project. It is not affiliated with, endorsed
          by or sponsored by Wispr AI, Inc. Wispr Flow is a trademark of Wispr AI, Inc.
        </p>
      </div>
    </footer>
  );
}
