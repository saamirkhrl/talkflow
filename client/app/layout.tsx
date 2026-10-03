import type { Metadata } from "next";
import { Newsreader } from "next/font/google";
import { Footer } from "@/components/landing/Footer";
import { Nav } from "@/components/landing/Nav";
import { SmoothScroll } from "@/components/landing/SmoothScroll";
import { VisitorProvider } from "@/components/landing/visitor";
import "./globals.css";

const newsreader = Newsreader({
  variable: "--font-newsreader",
  subsets: ["latin"],
  style: ["normal", "italic"],
  axes: ["opsz"],
});

export const metadata: Metadata = {
  title: {
    default: "TalkFlow: talk to your computer, for free",
    template: "%s | TalkFlow",
  },
  description:
    "The free, open-source Wispr Flow alternative. Hold fn, speak, and your words are typed wherever your cursor is. Runs entirely on your Mac.",
};


// The real star count, refreshed hourly. While the repo is private (or GitHub
// is unreachable) there is no count, and the nav shows a plain GitHub link.
async function getStars(): Promise<number | null> {
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
      </body>
    </html>
  );
}
