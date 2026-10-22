import { Analytics } from "@vercel/analytics/next";
import type { Metadata } from "next";
import { Newsreader } from "next/font/google";
import { Footer } from "@/components/landing/Footer";
import { SITE_DESCRIPTION, SITE_TITLE } from "@/components/landing/content";
import { Nav } from "@/components/landing/Nav";
import { SmoothScroll } from "@/components/landing/SmoothScroll";
import { VisitorProvider } from "@/components/landing/visitor";
import { SITE_NAME, SITE_URL } from "@/lib/seo";
import "./globals.css";

const newsreader = Newsreader({
  variable: "--font-newsreader",
  subsets: ["latin"],
  style: ["normal", "italic"],
  axes: ["opsz"],
});

// The defaults every page starts from. Pages set their own title,
// description, canonical and social cards with pageMetadata (lib/seo.ts);
// the Open Graph image comes from app/opengraph-image.tsx.
export const metadata: Metadata = {
  metadataBase: new URL(SITE_URL),
  title: {
    default: SITE_TITLE,
    template: "%s | talkflow",
  },
  description: SITE_DESCRIPTION,
  openGraph: { type: "website", siteName: SITE_NAME, locale: "en_US" },
  twitter: { card: "summary_large_image" },
};


// The real star count, refreshed hourly. GitHub's API allows 60 unauthenticated
// requests an hour per IP, and Vercel's build and render IPs are shared, so it
// is often refused there; shields.io (which the README badges use) is the
// fallback. If both fail, the nav shows a plain GitHub link.
async function getStars(): Promise<number | null> {
  return (await starsFromGithub()) ?? (await starsFromShields());
}

async function starsFromGithub(): Promise<number | null> {
  try {
    const res = await fetch("https://api.github.com/repos/saamirkhrl/talkflow", {
      headers: { Accept: "application/vnd.github+json" },
      next: { revalidate: 3600 },
    });
    if (!res.ok) return null;
    const repo: { stargazers_count?: unknown } = await res.json();
    return typeof repo.stargazers_count === "number" ? repo.stargazers_count : null;
  } catch {
    return null;
  }
}

// shields.io abbreviates large counts ("1.2k"); only an exact number is used.
async function starsFromShields(): Promise<number | null> {
  try {
    const res = await fetch("https://img.shields.io/github/stars/saamirkhrl/talkflow.json", {
      next: { revalidate: 3600 },
    });
    if (!res.ok) return null;
    const badge: { value?: unknown } = await res.json();
    return typeof badge.value === "string" && /^\d+$/.test(badge.value) ? Number(badge.value) : null;
  } catch {
    return null;
  }
}

export default async function RootLayout({ children }: LayoutProps<"/">) {
  const stars = await getStars();

  return (
    <html lang="en" className={newsreader.variable}>
      <body className="font-sans">
        <SmoothScroll />
        <VisitorProvider>
          <Nav stars={stars} />
          {children}
          <Footer />
        </VisitorProvider>
        <Analytics />
      </body>
    </html>
  );
}
