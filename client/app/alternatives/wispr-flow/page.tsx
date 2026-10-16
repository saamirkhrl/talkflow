import type { Metadata } from "next";
import Link from "next/link";
import { ContentPage } from "@/components/guides/ContentPage";
import { REPO_URL } from "@/components/landing/content";
import { pageMetadata } from "@/lib/seo";

// Wispr Flow facts are taken only from Wispr's own public pages, checked in
// October 2026: wisprflow.ai/pricing (plans, prices, free-plan word limits,
// platforms), wisprflow.ai/privacy ("Transcription always happens in the
// cloud", audio deletion, training setting), wisprflow.ai/terms-of-service
// (account required, no decompiling or derivative works) and wisprflow.ai
// (100+ languages, automatic formatting). Re-check them before editing, and
// update CHECKED. talkflow facts are checked against the app's source.
const CHECKED = "October 2026";

const PATH = "/alternatives/wispr-flow";

export const metadata: Metadata = pageMetadata({
  title: "talkflow vs Wispr Flow: an open-source, offline alternative",
  description:
    "An honest comparison of talkflow and Wispr Flow: price, open source, where your audio is processed, platforms, languages and accounts. Including what talkflow doesn't do.",
  path: PATH,
});

const ROWS: [label: string, talkflow: string, wispr: string][] = [
  ["Price", "Free, no paid tier", "Free plan; Pro is $15 per user a month, or $12 billed yearly"],
  ["Word limit", "None", "Free plan: 2,000 words a week on desktop, 1,000 on mobile"],
  ["Source code", "Open source (MIT License)", "Proprietary; its terms don't allow decompiling or derivative works"],
  ["Where speech is transcribed", "On your own computer, with Whisper", "In Wispr's cloud (its privacy page: \"Transcription always happens in the cloud\")"],
  ["Works offline", "Yes, once set up", "No, transcription needs its servers"],
  ["Account", "None", "Required by its terms of service"],
  ["Platforms", "Mac and Windows", "Mac, Windows, iPhone and Android"],
  ["Languages", "English", "100+ languages, per its website"],
  ["Text editing", "Fixed rules: filler removal, spoken punctuation, lists. Never rephrases", "Automatic formatting and edits of what you said"],
];

export default function WisprFlowAlternativePage() {
  return (
    <ContentPage
      title="talkflow vs Wispr Flow"
      path={PATH}
      intro={
        <>
          Wispr Flow<a href="#not-affiliated">*</a> and talkflow both let you hold a key, speak, and
          have your words typed into any app. They make different trade-offs. Here is a plain
          comparison, including where talkflow does less.
        </>
      }
    >
      <h2 id="table">Side by side</h2>
      <div className="mt-6 overflow-x-auto">
        <table className="w-full min-w-[560px] border-collapse text-left text-[15px] leading-[1.5]">
          <thead>
            <tr className="border-b border-line">
              <th scope="col" className="w-[24%] py-3 pr-4 font-semibold"></th>
              <th scope="col" className="w-[34%] py-3 pr-4 font-semibold">talkflow</th>
              <th scope="col" className="py-3 font-semibold">Wispr Flow*</th>
            </tr>
          </thead>
          <tbody>
            {ROWS.map(([label, ours, theirs]) => (
              <tr key={label} className="border-b border-line align-top">
                <th scope="row" className="py-3 pr-4 font-medium">{label}</th>
                <td className="py-3 pr-4">{ours}</td>
                <td className="py-3 text-graphite">{theirs}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      <p className="text-[15px] text-graphite">
        Wispr Flow details are from its own pricing, privacy and terms pages and its website, last
        checked {CHECKED}. Plans and features change, so check{" "}
        <a href="https://wisprflow.ai/pricing">wisprflow.ai</a> for the current details.
      </p>

      <h2 id="price">Price and limits</h2>
      <p>
        talkflow costs nothing and has no paid tier, trial or word limit. Wispr Flow has a free plan
        limited to 2,000 words a week on desktop, and a Pro plan at $15 per user a month, or $12 a
        month billed yearly. It also lists team and enterprise plans.
      </p>

      <h2 id="processing">Where your audio goes</h2>
      <p>
        This is the biggest difference. talkflow runs Whisper on your own Mac or PC through
        whisper.cpp; your audio never leaves the computer, and dictation works with Wi-Fi off. Wispr
        Flow sends audio to its servers for transcription. Its privacy page says the audio is deleted
        once it is transcribed unless you turn on its cloud storage, and that a setting controls
        whether your audio, transcripts and edits can be used to improve its models.
      </p>
      <p>
        The trade-off is that a cloud service can run larger models than a laptop. talkflow uses
        Whisper&apos;s small.en model, plus the larger large-v3-turbo for the final text on
        computers that can run it quickly. See <Link href="/how-it-works">how talkflow works</Link>.
      </p>

      <h2 id="open-source">Open source and accounts</h2>
      <p>
        talkflow&apos;s code is public under the MIT License, so you can read exactly what it does,
        build it yourself, or change it. It has no account and no sign-in. Wispr Flow is proprietary
        software and requires an account.
      </p>

      <h2 id="where-wispr-does-more">Where Wispr Flow does more</h2>
      <ul>
        <li>
          <strong>Phones.</strong> Wispr Flow has iPhone and Android apps. talkflow is only for Mac
          and Windows.
        </li>
        <li>
          <strong>Languages.</strong> Wispr Flow says it supports more than 100 languages. talkflow is
          built for English.
        </li>
        <li>
          <strong>AI editing.</strong> Wispr Flow formats and edits what you say. talkflow
          deliberately types your own words: it removes filler sounds and follows spoken commands,
          but never rephrases.
        </li>
        <li>
          <strong>Teams.</strong> Wispr Flow offers team and enterprise plans. talkflow has no admin
          features.
        </li>
      </ul>

      <h2 id="which">Which one fits</h2>
      <p>
        talkflow is a good fit if you dictate in English on a Mac or PC and want it free, private and
        working offline, with code you can inspect. If you need phone apps, other languages or
        AI rewriting, Wispr Flow covers those.
      </p>
      <p>
        Read about <Link href="/offline-dictation-mac">offline dictation on Mac</Link> or{" "}
        <Link href="/dictation-for-windows">dictation on Windows</Link>, or browse{" "}
        <a href={REPO_URL}>the source on GitHub</a>.
      </p>

      <p className="text-[15px] text-graphite">
        * talkflow is an independent, open-source project. It is not affiliated with, endorsed by or
        sponsored by Wispr AI, Inc. Wispr Flow is a trademark of Wispr AI, Inc., and is named here
        only to identify it.
      </p>
    </ContentPage>
  );
}
