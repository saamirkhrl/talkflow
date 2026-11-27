import type { Metadata } from "next";

// The site's public address. Relative URLs in metadata (canonical, Open
// Graph) resolve against it (metadataBase in app/layout.tsx).
export const SITE_URL = "https://talkflow.live";
export const SITE_NAME = "talkflow";

// The shared social card (app/opengraph-image.tsx). Pages that set their own
// openGraph lose the file-based image, so pageMetadata names it again.
export const OG_IMAGE_ALT = "talkflow: free, open-source dictation that runs on your own Mac";

// Next merges metadata shallowly, so a page that sets openGraph or twitter
// replaces the layout's whole object. Every page builds its metadata here so
// each one gets its own canonical, og:title and og:url instead of the home
// page's. `title` is the page's own title; the layout's template adds
// " | talkflow" to <title>, and it is added here for the social cards.
export function pageMetadata({
  title,
  description,
  path,
  absoluteTitle = false,
}: {
  title: string;
  description: string;
  path: string;
  absoluteTitle?: boolean;
}): Metadata {
  const image = { url: "/opengraph-image", width: 1200, height: 630, alt: OG_IMAGE_ALT };
  const fullTitle = absoluteTitle ? title : `${title} | ${SITE_NAME}`;
  return {
    title: absoluteTitle ? { absolute: title } : title,
    description,
    alternates: { canonical: path },
    openGraph: { type: "website", siteName: SITE_NAME, locale: "en_US", url: path, title: fullTitle, description, images: [image] },
    twitter: { card: "summary_large_image", title: fullTitle, description, images: [image] },
  };
}
