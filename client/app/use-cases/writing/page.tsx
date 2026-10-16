import type { Metadata } from "next";
import Link from "next/link";
import { ContentPage } from "@/components/guides/ContentPage";
import { pageMetadata } from "@/lib/seo";

// Feature claims are checked against Sources/talkflowd (Cleanup.swift,
// TextCommands.swift, ListFormat.swift, SelfCorrection.swift,
// WritingStyle.swift, Dictation.swift) and the README ("How it works").

const PATH = "/use-cases/writing";

export const metadata: Metadata = pageMetadata({
  title: "Dictation for writing: drafts, notes and documents",
  description:
    "Write first drafts, notes and documents by speaking. talkflow types your words into Notion, Google Docs, Word or any editor, without rewriting them. Free, open source and offline.",
  path: PATH,
});

export default function WritingPage() {
  return (
    <ContentPage
      title="Dictation for writing"
      path={PATH}
      intro="For many people, speaking is quicker than typing. talkflow lets you get a first draft, a note or a long paragraph down by saying it, straight into the editor you already use."
    >
      <h2 id="drafts">Get the first draft out</h2>
      <p>
        The hardest part of writing is often getting the first version down. Talking through an idea
        is quicker and looser than typing it, and you can shape the text afterwards with your
        keyboard as usual. Hold the key, say a paragraph, let go, and it&apos;s in your document.
        Then say the next one.
      </p>
      <p>
        talkflow types into the focused field of most apps, so it works in Notion, in Google Docs and
        other browser editors, in desktop word processors and in plain text editors. Not every app
        has been tested, and apps can change how they accept typed text.
      </p>

      <h2 id="voice">It keeps your voice</h2>
      <p>
        Many tools now &quot;improve&quot; dictated text with AI. talkflow deliberately doesn&apos;t.
        It types what you said. The only changes are mechanical:
      </p>
      <ul>
        <li>filler sounds like &quot;um&quot; and &quot;uh&quot; are removed;</li>
        <li>
          when you correct yourself mid-sentence (&quot;on Friday, wait no, Thursday&quot;), only
          the correction is kept, and a repeated word (&quot;the the&quot;) is typed once;
        </li>
        <li>spoken punctuation and layout commands are followed.</li>
      </ul>

      <h2 id="structure">Structure by voice</h2>
      <ul>
        <li>
          Say &quot;comma&quot;, &quot;period&quot;, &quot;question mark&quot; and so on when you
          want exact punctuation. Whisper also punctuates natural speech on its own.
        </li>
        <li>Say &quot;new line&quot; or &quot;new paragraph&quot; to break the text.</li>
        <li>
          Say &quot;number one ... number two ... number three ...&quot; and the items become a
          numbered list.
        </li>
        <li>
          Pick a writing style in Settings: formal (capitals and full stops), casual, or all
          lowercase.
        </li>
      </ul>

      <h2 id="flow">Nothing jumps around while you talk</h2>
      <p>
        A small live caption shows what talkflow is hearing while you hold the key (on slower
        Windows PCs it is turned off). The text goes
        into your document once, when you let go, so the words already on the page are never
        deleted and retyped under your cursor.
      </p>

      <h2 id="tips">Tips for longer pieces</h2>
      <ul>
        <li>
          Dictate a paragraph per hold. Short holds are easy to check, and a fresh hold after
          &quot;new paragraph&quot; keeps the structure clear.
        </li>
        <li>
          Talk first, edit later. Get the whole draft down by voice, then switch to the keyboard
          to tighten it.
        </li>
        <li>
          Correct names and terms by hand once. talkflow learns them, which helps with characters,
          places or jargon that come up again.
        </li>
      </ul>

      <h2 id="private">Drafts stay on your computer</h2>
      <p>
        Speech recognition runs on your own Mac or PC with Whisper, and works with Wi-Fi off.
        Unfinished drafts, journals and private notes aren&apos;t sent to a transcription service.
        Read <Link href="/how-it-works">how talkflow works</Link> for the details.
      </p>

      <h2 id="limits">Good to know</h2>
      <ul>
        <li>It is built for English.</li>
        <li>
          It&apos;s free with no word limit, so long sessions cost nothing. There is no account to
          create.
        </li>
        <li>
          It runs on Mac and Windows. See <Link href="/offline-dictation-mac">Mac</Link> and{" "}
          <Link href="/dictation-for-windows">Windows</Link>.
        </li>
      </ul>
    </ContentPage>
  );
}
