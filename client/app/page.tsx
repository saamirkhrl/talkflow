import { Apps } from "@/components/landing/Apps";
import { Faq } from "@/components/landing/Faq";
import { FinalCta } from "@/components/landing/FinalCta";
import { Hero } from "@/components/landing/Hero";
import { HowItWorks } from "@/components/landing/HowItWorks";
import { Privacy } from "@/components/landing/Privacy";
import { Prompting } from "@/components/landing/Prompting";
import { Stats } from "@/components/landing/Stats";

export default function Home() {
  return (
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
  );
}
