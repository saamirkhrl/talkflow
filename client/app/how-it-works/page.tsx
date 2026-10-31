import type { Metadata } from "next";
import Link from "next/link";
import { ContentPage } from "@/components/guides/ContentPage";
import { REPO_URL } from "@/components/landing/content";
import { pageMetadata } from "@/lib/seo";

// Every claim is checked against the app's source: Sources/talkflowd
// (SpeechEngine.swift, Dictation.swift, Preferences.swift, Polish.swift,
// TextCommands.swift, SelfCorrection.swift, ListFormat.swift, Vocabulary.swift,
// ScreenContext.swift) and windows/ (Talkflow/SpeechEngine.cs,
// Talkflow.Core/DevicePolicy.cs). Keep it that way when editing.

const PATH = "/how-it-works";

export const metadata: Metadata = pageMetadata({
  title: "How talkflow works: local speech to text with Whisper",
  description:
    "What happens between holding the key and the text appearing: Whisper running on your own computer through whisper.cpp, then simple rules that tidy the text without rewriting it.",
  path: PATH,
});

export default function HowItWorksPage() {
  return (
    <ContentPage
      title="How talkflow works"
      path={PATH}
      intro="Hold a key, speak, let go. Your words are typed into the app you're in. Here is exactly what happens in between, and which parts run where."
    >
      <h2 id="steps">The short version</h2>
      <ol>
        <li>
          You hold the shortcut: <strong>fn</strong> on a Mac, <strong>Ctrl + Win</strong> on
          Windows. Both can be changed in Settings.
        </li>
        <li>
          talkflow records from your microphone into memory and shows a small live caption of what
          it hears.
        </li>
        <li>
          You let go. The recording is transcribed one last time, tidied by a set of fixed rules,
          and typed into the text field you were in, once. Nothing is typed while you speak, so
          nothing is deleted and retyped.
        </li>
      </ol>

      <h2 id="engine">The speech engine: Whisper, on your computer</h2>
      <p>
        Speech recognition is done by <strong>Whisper</strong>, OpenAI&apos;s open speech model,
        running through <a href="https://github.com/ggml-org/whisper.cpp">whisper.cpp</a>, an open
        source engine that runs it on an ordinary processor. talkflow ships whisper.cpp&apos;s
        server inside the app and starts it in the background. It listens only at 127.0.0.1, the
        address that always means your own computer, so your audio never crosses the network.
      </p>
      <p>Two Whisper models are used:</p>
      <ul>
        <li>
          <strong>small.en</strong>, an English-only model, is the main one. It produces the live caption while you hold
          the key, and the final text unless the larger model below is in use. On a Mac it is a
          5-bit compressed copy of about 190 MB; on Windows it is the full-size file of about
          490 MB. Setup downloads it once, from the whisper.cpp project on Hugging Face.
        </li>
        <li>
          <strong>large-v3-turbo</strong> is optional and used only for the final pass, after you let
          go, because that is the only transcript that reaches your document. It is off by default:
          it uses about 800 MB more memory for a small gain in accuracy, so it is an opt-in
          (Accurate final pass in Settings). Turned on, it downloads about 575 MB in the background.
          On a Mac it is then loaded only while you dictate and unloaded right after. On Windows,
          talkflow times it on your PC first and skips it if the PC is too slow; it can use your
          graphics card through Vulkan, and falls back to the processor.
        </li>
      </ul>
      <p>
        If the larger model is missing or slow to answer, the final pass simply uses small.en. On
        slower Windows PCs the live caption is turned off so it never delays the final text.
      </p>

      <h2 id="cleanup">The tidy-up: rules, not rewriting</h2>
      <p>
        Whisper&apos;s transcript goes through a set of plain, predictable text rules before it is
        typed. They change formatting and remove noise. They never rephrase your sentences.
      </p>
      <ul>
        <li>Filler sounds such as &quot;um&quot; and &quot;uh&quot; are removed.</li>
        <li>
          Spoken commands become text: &quot;comma&quot;, &quot;question mark&quot;, &quot;new
          line&quot;, &quot;new paragraph&quot;, and emoji names such as &quot;rocket emoji&quot;.
        </li>
        <li>
          Self-corrections collapse to what you meant: &quot;meet at 2, no wait, 3&quot; becomes
          &quot;meet at 3&quot;.
        </li>
        <li>
          &quot;Number one ... number two ...&quot; becomes a numbered list, and an email&apos;s
          greeting and sign-off get their own lines.
        </li>
        <li>
          A writing style you pick in Settings: formal (capitals and full stops), casual or all
          lowercase.
        </li>
      </ul>
      <p>
        talkflow also learns your words. When you correct a name it misheard, such as
        &quot;Shivon&quot; to &quot;Siobhan&quot;, it remembers the fix and gives it to Whisper as a
        hint next time. Names visible around your cursor, such as an email&apos;s recipient, are
        used the same way. That reading happens in memory, on your computer.
      </p>

      <h2 id="optional">Optional extras you switch on yourself</h2>
      <p>None of these are on unless you turn them on in Settings:</p>
      <ul>
        <li>
          <strong>On-device punctuation</strong> (Mac, macOS 26 or later): Apple&apos;s built-in
          model suggests punctuation. Its answer is matched word by word against yours, and only
          punctuation, capitals and line breaks are taken from it.
        </li>
        <li>
          <strong>Your own OpenAI key</strong> sends the final pass to OpenAI for transcription, and{" "}
          <strong>your own Anthropic key</strong> sends the text to Claude for punctuation, under the
          same word-for-word guarantee. With a key added, that step leaves your computer and goes to
          that provider.
        </li>
      </ul>

      <h2 id="limits">What it doesn&apos;t do</h2>
      <ul>
        <li>
          It is built for English. Its main model, small.en, is English-only: fast and accurate
          for English, but it doesn&apos;t transcribe other languages.
        </li>
        <li>It doesn&apos;t run on phones or tablets: there is a Mac app and a Windows app.</li>
        <li>It doesn&apos;t rewrite, summarize or &quot;improve&quot; what you said.</li>
      </ul>

      <h2 id="source">Check it yourself</h2>
      <p>
        talkflow is open source under the MIT License, so every step above can be read in{" "}
        <a href={REPO_URL}>the source code on GitHub</a>. What the app sends over the network is
        listed in the <Link href="/privacy">privacy policy</Link>. Platform details are in{" "}
        <Link href="/offline-dictation-mac">offline dictation for Mac</Link> and{" "}
        <Link href="/dictation-for-windows">dictation for Windows</Link>.
      </p>
    </ContentPage>
  );
}
