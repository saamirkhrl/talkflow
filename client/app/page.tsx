import type { Metadata } from "next";
import { Apps } from "@/components/landing/Apps";
import { FAQ, REPO_URL, SITE_DESCRIPTION, SITE_TITLE } from "@/components/landing/content";
import { Faq } from "@/components/landing/Faq";
import { FinalCta } from "@/components/landing/FinalCta";
import { Hero } from "@/components/landing/Hero";
import { HowItWorks } from "@/components/landing/HowItWorks";
import { LaunchVideo } from "@/components/landing/LaunchVideo";
import { Privacy } from "@/components/landing/Privacy";
import { Prompting } from "@/components/landing/Prompting";
import { Stats } from "@/components/landing/Stats";
import { JsonLd } from "@/components/seo/JsonLd";
import { pageMetadata, SITE_URL } from "@/lib/seo";

export const metadata: Metadata = pageMetadata({ title: SITE_TITLE, description: SITE_DESCRIPTION, path: "/", absoluteTitle: true });

// What search engines read about the app, and the FAQ section's questions.
// Typed as source code too, so codeRepository is a valid property.
const APP_JSON_LD = {
  "@context": "https://schema.org",
  "@type": ["SoftwareApplication", "SoftwareSourceCode"],
  name: "talkflow",
  description: SITE_DESCRIPTION,
  url: SITE_URL,
  image: `${SITE_URL}/icon.svg`,
  applicationCategory: "UtilitiesApplication",
  operatingSystem: "macOS",
  offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
  isAccessibleForFree: true,
  license: "https://opensource.org/license/mit",
  codeRepository: REPO_URL,
  downloadUrl: `${SITE_URL}/download/mac`,
};

const FAQ_JSON_LD = {
  "@context": "https://schema.org",
  "@type": "FAQPage",
  mainEntity: FAQ.map(([question, answer]) => ({
    "@type": "Question",
    name: question,
    acceptedAnswer: { "@type": "Answer", text: answer },
  })),
};

export default function Home() {
  return (
    <main className="overflow-x-clip">
      <JsonLd data={APP_JSON_LD} />
      <JsonLd data={FAQ_JSON_LD} />
      <Hero />
      <LaunchVideo />
      <div className="mx-auto mt-[clamp(72px,10vw,140px)] flex max-w-[1280px] flex-col gap-[clamp(40px,6vw,88px)] px-3 sm:px-4">
        <div className="glass pb-[clamp(48px,6vw,80px)]">
          <Apps />
        </div>
        <div className="glass">
          <HowItWorks />
        </div>
        <div className="glass">
          <Prompting />
        </div>
        <Privacy />
        <div className="glass">
          <Stats />
        </div>
        <div className="glass">
          <Faq />
        </div>
        <div className="glass">
          <FinalCta />
        </div>
      </div>
    </main>
  );
}
