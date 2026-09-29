import Link from "next/link";
import type { ReactNode } from "react";
import { Wordmark } from "@/components/brand/Logo";

// Long-form text styles, scoped to the article so the legal pages need no
// typography plugin. Headings are sans; only the page title is serif.
const PROSE = [
  "[&_h2]:mt-14 [&_h2]:text-[22px] [&_h2]:font-semibold [&_h2]:leading-[1.3] [&_h2]:tracking-[-0.01em]",
  "[&_h3]:mt-9 [&_h3]:text-[18px] [&_h3]:font-semibold [&_h3]:leading-[1.35]",
  "[&_p]:mt-4 [&_ul]:mt-4 [&_ol]:mt-4",
  "[&_ul]:list-disc [&_ol]:list-decimal [&_ul]:pl-6 [&_ol]:pl-6 [&_li]:mt-2 [&_li]:pl-1 marker:text-graphite",
  "[&_a]:underline [&_a]:decoration-ink [&_a]:decoration-1 [&_a]:underline-offset-[3px] [&_a:hover]:decoration-2",
  "[&_strong]:font-semibold",
  "[&_code]:rounded [&_code]:bg-mist [&_code]:px-1.5 [&_code]:py-0.5 [&_code]:font-mono [&_code]:text-[0.85em] [&_code]:[overflow-wrap:anywhere]",
  "[&_hr]:my-14 [&_hr]:border-line",
].join(" ");

export const CONTACT_EMAIL = "samir.kharel66@gmail.com";
export const REPO_URL = "https://github.com/saamirkhrl/talkflow";

export function EmailLink() {
  return <a href={`mailto:${CONTACT_EMAIL}`}>{CONTACT_EMAIL}</a>;
}

const FOOTER_LINKS = [
  { href: "/terms", label: "Terms of Use" },
  { href: "/privacy", label: "Privacy Policy" },
  { href: "/", label: "Home" },
];

type LegalPageProps = {
  title: string;
  lastUpdated: string;
  children: ReactNode;
};

export function LegalPage({ title, lastUpdated, children }: LegalPageProps) {
  return (
    <div className="flex min-h-dvh flex-col">
      <header className="border-b border-line">
        <div className="mx-auto flex h-16 max-w-[1200px] items-center px-gutter">
          <Link href="/" aria-label="TalkFlow home" className="rounded-md">
            <Wordmark />
          </Link>
        </div>
      </header>

      <main className="flex-1 px-gutter py-14 sm:py-20">
        <article className={`mx-auto max-w-[68ch] text-[17px] leading-[1.7] text-ink ${PROSE}`}>
          <h1 className="font-serif text-[40px] font-normal leading-[1.1] tracking-[-0.02em] sm:text-[52px]">
            {title}
          </h1>
          {/* mt-3! beats the article's [&_p]:mt-4, which is more specific. */}
          <p className="mt-3! text-[15px] text-graphite">Last updated: {lastUpdated}</p>
          {children}
        </article>
      </main>

      <footer className="border-t border-line">
        <nav
          aria-label="Legal"
          className="mx-auto flex max-w-[1200px] flex-wrap gap-x-6 gap-y-2 px-gutter py-8 text-[14px] text-graphite"
        >
          {FOOTER_LINKS.map((link) => (
            <Link
              key={link.href}
              href={link.href}
              className="underline decoration-1 underline-offset-[3px] hover:text-ink"
            >
              {link.label}
            </Link>
          ))}
        </nav>
      </footer>
    </div>
  );
}
