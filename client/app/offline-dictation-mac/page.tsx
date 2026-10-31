import type { Metadata } from "next";
import Link from "next/link";
import { ContentPage } from "@/components/guides/ContentPage";
import { REPO_URL } from "@/components/landing/content";
import { pageMetadata } from "@/lib/seo";

// Checked against Sources/talkflowd (Permissions.swift, SpeechEngine.swift,
// Preferences.swift, Hotkey.swift, InstallCounter.swift, Updater.swift),
// Package.swift (macOS 13), README.md and docs/telemetry.md.

const PATH = "/offline-dictation-mac";

export const metadata: Metadata = pageMetadata({
  title: "Offline voice dictation for Mac, free and open source",
  description:
    "talkflow turns speech into text on your own Mac with Whisper, then types it into any app. Works with Wi-Fi off, no account, no word limit. What it needs and what leaves your Mac.",
  path: PATH,
});

export default function OfflineDictationMacPage() {
  return (
    <ContentPage
      title="Offline dictation for Mac"
      path={PATH}
      intro="talkflow is a free, open-source dictation app that turns your speech into text on your own Mac and types it into whatever app you're using. Once it's set up, it works the same with Wi-Fi off."
    >
      <h2 id="what-it-does">What it does</h2>
      <p>
        Hold <strong>fn</strong> (the Globe key in the bottom-left corner of Mac keyboards), say what
        you want to write, and let go. Your words appear in the focused text field: a chat, an
        email, a document, a terminal, a browser. You can change the key in Settings to Right
        Option, Right Command, Control + Option, or record your own combination.
      </p>
      <p>
        It runs on macOS 13 or later, on Apple silicon and Intel Macs: one universal app for both.
        It is free, with no account, no trial and no word limit.
      </p>

      <h2 id="local">How dictation stays on your Mac</h2>
      <p>
        talkflow includes a speech engine, whisper.cpp, which runs OpenAI&apos;s open Whisper model
        on your Mac&apos;s own processor. The engine listens only at 127.0.0.1, which always means
        your own computer. The app sends your recording there and gets text back, without the audio
        ever going over the internet. Audio is kept in memory only and is never written to disk.
      </p>
      <p>
        Setup downloads the English speech model once (small.en, about 190 MB). A larger, more
        accurate model for the final text (large-v3-turbo, about 575 MB) is optional: turn on
        Accurate final pass in Settings and it downloads in the background. Either way, nothing
        more needs to be downloaded to dictate. The full pipeline is described in{" "}
        <Link href="/how-it-works">how talkflow works</Link>.
      </p>

      <h2 id="permissions">Permissions, and why each one is needed</h2>
      <p>The setup window walks you through two macOS permissions:</p>
      <ul>
        <li>
          <strong>Microphone</strong>, so talkflow can hear you. macOS asks you to approve it.
        </li>
        <li>
          <strong>Accessibility</strong>, which you switch on in System Settings. talkflow uses it to
          type the text into the app you&apos;re using, to notice when you hold and release the
          shortcut, and to read a little of the text around your cursor so it can add a space when
          one is needed. It never reads password fields, and it types with keystrokes rather than
          through your clipboard (unless a dictation can&apos;t be typed, for example because you
          switched apps, in which case it&apos;s put on the clipboard so it isn&apos;t lost).
        </li>
      </ul>
      <p>
        You can turn either off at any time in System Settings &gt; Privacy &amp; Security. If
        holding fn opens the emoji picker instead, set System Settings &gt; Keyboard &gt; &quot;Press
        the globe key to&quot; to <strong>Do Nothing</strong>.
      </p>

      <h2 id="what-leaves">What leaves your Mac</h2>
      <p>Not your voice, and not your words. The app makes only these requests:</p>
      <ul>
        <li>
          <strong>A one-time install count.</strong> The first time an official release runs while
          online, it sends one empty request so installs can be counted. No ID and nothing about
          you, your Mac or your usage. Once it succeeds it never sends again, and copies built from
          source never send it.
        </li>
        <li>
          <strong>Update checks.</strong> It asks GitHub whether a newer version exists. An update
          installs only when you click it, and only if the download matches the release&apos;s
          checksum.
        </li>
        <li>
          <strong>Model downloads during setup</strong>, from Hugging Face, as described above.
        </li>
        <li>
          <strong>Only if you add your own key:</strong> OpenAI for transcription, or Anthropic for
          punctuation. That step then goes to that provider. Both are off unless you add a key.
        </li>
      </ul>
      <p>
        There is no account and no usage analytics. The details are in the{" "}
        <Link href="/privacy">privacy policy</Link>.
      </p>

      <h2 id="offline">Using it offline</h2>
      <p>
        With the model downloaded, turn off Wi-Fi and dictate as usual. The update check and the
        install count simply wait until you&apos;re online again; dictation doesn&apos;t depend on
        either.
      </p>

      <h2 id="limits">Good to know</h2>
      <ul>
        <li>It is built for English; its main model, small.en, is English-only.</li>
        <li>
          It types into the focused text field of most Mac apps, but not every app has been tested,
          and an app can change how it accepts typed text.
        </li>
        <li>
          Your stats and settings live in{" "}
          <code>~/Library/Application Support/talkflow/</code>. Uninstalling from Settings removes
          the app, engine and models and keeps that folder.
        </li>
      </ul>

      <h2 id="install">Install</h2>
      <p>
        Download it below, or see the <Link href="/download/mac">Mac download page</Link>. You can
        also build it yourself from <a href={REPO_URL}>the source on GitHub</a>. Using a PC? See{" "}
        <Link href="/dictation-for-windows">dictation for Windows</Link>.
      </p>
    </ContentPage>
  );
}
