import { Apps } from "@/components/landing/Apps";
import { Faq } from "@/components/landing/Faq";
import { FinalCta } from "@/components/landing/FinalCta";
import { Footer } from "@/components/landing/Footer";
import { Hero } from "@/components/landing/Hero";
import { HowItWorks } from "@/components/landing/HowItWorks";
import { Nav } from "@/components/landing/Nav";
import { Privacy } from "@/components/landing/Privacy";
import { Prompting } from "@/components/landing/Prompting";
import { Stats } from "@/components/landing/Stats";
import { VisitorProvider } from "@/components/landing/visitor";

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

export default async function Home() {
  const stars = await getStars();

  return (
    <VisitorProvider>
      <Nav stars={stars} />
      <main className="overflow-x-clip">
        <Hero />
        <Apps />
        <HowItWorks />
        <Prompting />
        <Privacy />
        <Stats />
        <Faq />
        <FinalCta />
      </main>
      <Footer />
    </VisitorProvider>
  );
}
