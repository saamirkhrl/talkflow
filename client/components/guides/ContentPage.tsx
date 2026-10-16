import Link from "next/link";
import type { ReactNode } from "react";
import { FinalCta } from "@/components/landing/FinalCta";
import { GUIDES } from "@/components/landing/content";
import { PROSE } from "@/components/legal/LegalPage";
import { JsonLd } from "@/components/seo/JsonLd";
import { SITE_URL } from "@/lib/seo";

// The layout every guide page shares: a breadcrumb, the article in the legal
// pages' type styles, links to the other guides, then the download section.
// Static, server-rendered, nothing fetched. Add a page to GUIDES (content.ts)
// so the footer and sitemap list it.
export function ContentPage({
  title,
  intro,
  path,
  children,
}: {
  title: string;
  intro: ReactNode;
  path: string;
  children: ReactNode;
}) {
  const breadcrumb = {
    "@context": "https://schema.org",
    "@type": "BreadcrumbList",
    itemListElement: [
      { "@type": "ListItem", position: 1, name: "talkflow", item: SITE_URL },
      { "@type": "ListItem", position: 2, name: title, item: `${SITE_URL}${path}` },
    ],
  };
  const others = GUIDES.filter((guide) => guide.path !== path);

  return (
    <>
      <JsonLd data={breadcrumb} />
      <main className="px-gutter pt-32 sm:pt-40">
        <article className={`mx-auto max-w-[68ch] text-[17px] leading-[1.7] text-ink ${PROSE}`}>
          <nav aria-label="Breadcrumb" className="text-[15px] text-graphite">
            <ol className="mt-0! flex list-none! flex-wrap gap-x-2 pl-0!">
              <li className="mt-0! pl-0!">
                <Link href="/" className="no-underline! hover:text-ink">
                  talkflow
                </Link>
              </li>
              <li aria-hidden="true" className="mt-0! pl-0!">
                /
              </li>
              <li aria-current="page" className="mt-0! pl-0!">
                {title}
              </li>
            </ol>
          </nav>
          <h1 className="mt-6 font-serif text-[40px] font-normal leading-[1.1] tracking-[-0.02em] sm:text-[52px]">
            {title}
          </h1>
          {/* mt-6! beats the article's [&_p]:mt-4, which is more specific. */}
          <p className="mt-6! text-[19px] leading-[1.6] text-graphite">{intro}</p>
          {children}
          <hr />
          <h2 id="more-guides" className="mt-0!">
            More guides
          </h2>
          <ul>
            {others.map((guide) => (
              <li key={guide.path}>
                <Link href={guide.path}>{guide.label}</Link>
              </li>
            ))}
          </ul>
        </article>
      </main>
      <FinalCta />
    </>
  );
}
