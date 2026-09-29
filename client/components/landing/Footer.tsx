import Link from "next/link";

export function Footer() {
  return (
    <footer className="overflow-hidden border-t border-line">
      <div className="mx-auto max-w-[1200px] px-gutter pt-10">
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
        <p aria-hidden="true" className="mt-10 text-center font-serif text-[clamp(72px,22.5vw,290px)] leading-[0.8] tracking-[-0.04em] whitespace-nowrap select-none">
          TalkFlow
        </p>
      </div>
    </footer>
  );
}
