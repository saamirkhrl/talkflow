import Link from "next/link";
import { Wordmark } from "@/components/brand/Logo";

export function Footer() {
  return (
    <footer className="border-t border-line">
      <div className="mx-auto flex max-w-[1200px] flex-col gap-8 px-gutter py-10">
        <div className="flex flex-wrap items-center justify-between gap-6">
          <Wordmark />
          <div className="flex gap-6 text-[15px] text-graphite">
            <Link href="/terms" className="hover:text-ink">
              Terms
            </Link>
            <Link href="/privacy" className="hover:text-ink">
              Privacy
            </Link>
          </div>
        </div>
        <p className="max-w-[90ch] text-[13px] leading-relaxed text-graphite">
          TalkFlow is free, open-source software released under the MIT License. It is an independent project and is not
          affiliated with, endorsed by or sponsored by any company whose products are shown on this site. Apple, Mac and macOS are
          trademarks of Apple Inc. Windows is a trademark of the Microsoft group of companies. All other product names and logos
          belong to their owners.
        </p>
      </div>
    </footer>
  );
}
