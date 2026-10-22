import type { Metadata } from "next";
import { Apps } from "@/components/landing/Apps";
import { FAQ, REPO_URL, SITE_DESCRIPTION, SITE_TITLE, WINDOWS_DOWNLOAD_PATH } from "@/components/landing/content";
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
  operatingSystem: "macOS, Windows",
  offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
  isAccessibleForFree: true,
  license: "https://opensource.org/license/mit",
  codeRepository: REPO_URL,
  downloadUrl: [`${SITE_URL}/download/mac`, `${SITE_URL}${WINDOWS_DOWNLOAD_PATH}`],
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
