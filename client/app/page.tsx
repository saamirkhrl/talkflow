import { Faq } from "@/components/landing/Faq";
import { FinalCta } from "@/components/landing/FinalCta";
import { Footer } from "@/components/landing/Footer";
import { FounderNote } from "@/components/landing/FounderNote";
import { Hero } from "@/components/landing/Hero";
import { HowItWorks } from "@/components/landing/HowItWorks";
import { Nav } from "@/components/landing/Nav";
import { Privacy } from "@/components/landing/Privacy";
import { Prompting } from "@/components/landing/Prompting";
import { Reveal } from "@/components/landing/Reveal";
import { Stats } from "@/components/landing/Stats";
import { VisitorProvider } from "@/components/landing/visitor";

export default function Home() {
  return (
    <VisitorProvider>
      <div className="overflow-x-clip">
        <Nav />
        <main id="top" className="mx-auto max-w-[1200px] px-gutter">
          <Hero />
          <HowItWorks />
          <Prompting />
          <Privacy />
          <Stats />
          <FounderNote />
          <Faq />
          <FinalCta />
        </main>
        <Footer />
      </div>
      <Reveal />
    </VisitorProvider>
  );
}
