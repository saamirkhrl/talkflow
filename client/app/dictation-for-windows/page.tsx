import type { Metadata } from "next";
import Link from "next/link";
import { ContentPage } from "@/components/guides/ContentPage";
import { REPO_URL } from "@/components/landing/content";
import { pageMetadata } from "@/lib/seo";

// Checked against windows/: installer/talkflow.iss (per-user install,
// x64compatible, MinVersion 10.0.17763), Talkflow/Hotkey.cs (Ctrl + Win),
// Talkflow/Microphone.cs, Talkflow/SpeechEngine.cs, Talkflow/KeyboardWriter.cs
// (paste for longer text, clipboard restored), Talkflow/Updater.cs,
// Talkflow.Core/DevicePolicy.cs, and docs/telemetry.md. Windows ships one x64
// build; Arm PCs run it through Windows' emulation.

const PATH = "/dictation-for-windows";

export const metadata: Metadata = pageMetadata({
  title: "Free voice dictation for Windows that runs on your PC",
  description:
    "talkflow is a free, open-source dictation app for Windows 10 and 11. Hold Ctrl + Win, speak, and your words are typed into any app. Speech recognition runs on your own PC.",
  path: PATH,
});

export default function DictationForWindowsPage() {
  return (
    <ContentPage
      title="Dictation for Windows"
      path={PATH}
      intro="talkflow is a free, open-source dictation app for Windows. Hold a shortcut, speak, and your words are typed into whatever app you're using. The speech recognition runs on your own PC."
    >
      <h2 id="what-it-does">What it does</h2>
      <p>
        Hold <strong>Ctrl + Win</strong>, say what you want to write, and let go. talkflow types your
        words into the focused text field: a chat, an email, a document, a code editor, a browser.
        You can pick a different shortcut in Settings. There is no account, no trial and no word
        limit.
      </p>

      <h2 id="requirements">What you need</h2>
      <ul>
        <li>Windows 10 (version 1809) or later, or Windows 11.</li>
        <li>
          Any PC that runs those. There is one installer, for x64, and Arm-based Windows PCs run it
          through Windows&apos; built-in emulation.
        </li>
        <li>
          A microphone, and about 490 MB of disk space for the English speech model, plus about
          575 MB if the optional, more accurate final-pass model is downloaded.
        </li>
      </ul>
      <p>
        The installer puts talkflow in your own user folder, so it doesn&apos;t need administrator
        rights.
      </p>

      <h2 id="local">How it works on your PC</h2>
      <p>
        The installer includes whisper.cpp&apos;s speech engine. talkflow runs it in the background,
        listening only at 127.0.0.1 (your own computer), and loads OpenAI&apos;s open Whisper model
        into it. On first run it downloads the English model, small.en, once. Your audio goes from
        the microphone to that engine and never over the internet.
      </p>
      <p>
        talkflow measures how fast your PC is and tunes itself to match. It can use your graphics
        card through Vulkan when the driver supports it, and falls back to the processor. On a fast
        enough PC it also uses a larger model, large-v3-turbo, for the final text; on a slower PC it
        skips that model and turns off the live caption so the final text isn&apos;t delayed. More
        detail is in <Link href="/how-it-works">how talkflow works</Link>.
      </p>

      <h2 id="permissions">Microphone access</h2>
      <p>
        Windows doesn&apos;t show a permission prompt for desktop apps. Instead, Settings &gt;
        Privacy &amp; security &gt; Microphone has switches that either allow them or silently give
        them silence. talkflow checks those switches, and if one is off, it tells you which and opens
        the right Settings page.
      </p>

      <h2 id="typing">How the text is typed</h2>
      <p>
        Short dictations are typed as keystrokes. Longer ones are pasted in one go, because Windows
        apps can garble long runs of synthetic keystrokes: talkflow saves your clipboard, pastes,
        then puts your clipboard back.
      </p>

      <h2 id="what-leaves">What leaves your PC</h2>
      <p>Not your voice, and not your words. The app makes only these requests:</p>
      <ul>
        <li>
          <strong>A one-time install count</strong> from official releases: one empty request with no
          ID and nothing about you or your PC, sent once and never again.
        </li>
        <li>
          <strong>Update checks</strong> with GitHub. Updates install only when you choose to.
        </li>
        <li>
          <strong>Model downloads</strong> from Hugging Face during setup.
        </li>
        <li>
          <strong>Only if you add your own key:</strong> OpenAI for transcription, or Anthropic for
          punctuation. Off unless you add one.
        </li>
      </ul>
      <p>
        See the <Link href="/privacy">privacy policy</Link> and the install counter&apos;s{" "}
        <a href={`${REPO_URL}/blob/main/docs/telemetry.md`}>public documentation</a>.
      </p>

      <h2 id="limits">Good to know</h2>
      <ul>
        <li>It is built for English; its main model, small.en, is English-only.</li>
        <li>
          It types into the focused text field of most apps, but not every app has been tested.
        </li>
        <li>
          There is also a Mac version: see <Link href="/offline-dictation-mac">offline dictation for
          Mac</Link>.
        </li>
      </ul>
    </ContentPage>
  );
}
