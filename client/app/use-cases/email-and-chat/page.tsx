import type { Metadata } from "next";
import Link from "next/link";
import { ContentPage } from "@/components/guides/ContentPage";
import { pageMetadata } from "@/lib/seo";

// Feature claims are checked against Sources/talkflowd (StructurePolish.swift,
// TextCommands.swift, WritingStyle.swift, ScreenContext.swift,
// SelfCorrection.swift) and their windows/Talkflow.Core/Text counterparts.

const PATH = "/use-cases/email-and-chat";

export const metadata: Metadata = pageMetadata({
  title: "Voice typing for email and chat in any app",
  description:
    "Dictate emails and chat messages into Gmail, Slack, WhatsApp, Messages or any other app with talkflow. Greetings get their own lines, emoji by name, casual or formal style. Free and private.",
  path: PATH,
});

export default function EmailAndChatPage() {
  return (
    <ContentPage
      title="Dictation for email and chat"
      path={PATH}
      intro="Replies are where typing time goes. With talkflow you hold a key, say the message the way you'd say it to the person, and it's typed into whatever app you're in: your email client, Slack, WhatsApp, Messages or a browser tab."
    >
      <h2 id="any-app">Works where you already write</h2>
      <p>
        talkflow isn&apos;t a separate editor you copy from. It types straight into the focused text
        field, so there&apos;s nothing to paste and no new app to learn. It works in most Mac and
        Windows apps, from desktop email clients to web apps in your browser. Not every app has
        been tested, and apps can change how they accept typed text.
      </p>

      <h2 id="email">For email</h2>
      <ul>
        <li>
          <strong>Greeting, body and sign-off on their own lines.</strong> Say &quot;Hi Daniel,
          thanks for making time on Tuesday ... Best, Alex&quot; and the greeting and sign-off are
          set apart with blank lines, the way an email is laid out.
        </li>
        <li>
          <strong>Names spelled right.</strong> Names visible around your cursor, such as the
          person you&apos;re replying to, are given to the speech model as a hint, so an unusual name
          is more likely to come out spelled the way it&apos;s shown. Correct one by hand and
          talkflow remembers it.
        </li>
        <li>
          <strong>Paragraphs and lists.</strong> Say &quot;new paragraph&quot;, or &quot;number one
          ... number two ...&quot; for a numbered list.
        </li>
      </ul>

      <h2 id="chat">For chat</h2>
      <ul>
        <li>
          <strong>Casual style.</strong> Pick &quot;casual&quot; in Settings for lowercase with no
          closing full stop, the way most people text, or &quot;all lowercase&quot;. &quot;I&quot;
          stays capitalized in casual.
        </li>
        <li>
          <strong>Emoji by name.</strong> Say &quot;rocket emoji&quot; or &quot;thumbs up
          emoji&quot;.
        </li>
        <li>
          <strong>Change your mind mid-sentence.</strong> &quot;Let&apos;s meet Friday, wait no,
          Thursday&quot; comes out as &quot;Let&apos;s meet Thursday&quot;.
        </li>
      </ul>

      <h2 id="routine">A quick routine</h2>
      <ol>
        <li>Click into the reply box, as you would to type.</li>
        <li>
          Hold the key and say the message, including the greeting and sign-off if it&apos;s an
          email. Pause as long as you need; nothing is typed until you let go.
        </li>
        <li>Let go, read it over, and fix anything by hand before you send it.</li>
      </ol>
      <p>
        The text is typed into the reply box, not sent, so you get to check it first. Line breaks
        are typed as line breaks rather than a plain Return key, which in chat apps like Slack would
        send the message.
      </p>

      <h2 id="your-words">Your words, not a rewrite</h2>
      <p>
        talkflow removes filler sounds like &quot;um&quot; and &quot;uh&quot; and follows the spoken
        commands above. It never rephrases your sentences, so a message still sounds like you wrote
        it.
      </p>

      <h2 id="private">Private messages stay private</h2>
      <p>
        Speech recognition runs on your own computer. talkflow doesn&apos;t send your audio or your
        text to a transcription service, and it has no account. Once the text is typed into an app,
        that app handles it as usual. Details are in the <Link href="/privacy">privacy policy</Link>
        .
      </p>

      <h2 id="limits">Good to know</h2>
      <ul>
        <li>It is built for English.</li>
        <li>It runs on Mac and Windows computers, not on phones.</li>
        <li>
          The default shortcut is fn on a Mac and Ctrl + Win on Windows. See{" "}
          <Link href="/offline-dictation-mac">Mac</Link> and{" "}
          <Link href="/dictation-for-windows">Windows</Link> setup.
        </li>
      </ul>
    </ContentPage>
  );
}
