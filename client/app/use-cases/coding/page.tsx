import type { Metadata } from "next";
import Link from "next/link";
import { ContentPage } from "@/components/guides/ContentPage";
import { pageMetadata } from "@/lib/seo";

// Feature claims are checked against Sources/talkflowd (TextCommands.swift,
// ListFormat.swift, SelfCorrection.swift, Vocabulary.swift, FieldSync.swift)
// and their windows/Talkflow.Core/Text counterparts.

const PATH = "/use-cases/coding";

export const metadata: Metadata = pageMetadata({
  title: "Voice dictation for coding: prompts, commits and reviews",
  description:
    "Use talkflow to talk to AI coding agents and write commit messages, pull request descriptions and code review comments by voice. Free, open source, runs on your own computer.",
  path: PATH,
});

export default function CodingPage() {
  return (
    <ContentPage
      title="Dictation for coding"
      path={PATH}
      intro="Most of the typing around code isn't code. It's prompts for AI coding agents, commit messages, pull request descriptions, review comments and bug reports. That's ordinary English, and talkflow lets you say it instead of typing it."
    >
      <h2 id="where">Where it helps</h2>
      <ul>
        <li>
          <strong>Prompts for AI coding agents.</strong> Explaining what you want, with the context
          and the constraints, is far quicker out loud than typed. Hold the key in your agent&apos;s
          chat box or terminal prompt and say the whole thought in one go.
        </li>
        <li>
          <strong>Commit messages and pull request descriptions.</strong> Say what changed and why,
          and let go.
        </li>
        <li>
          <strong>Code review and issues.</strong> Review comments, bug reports with steps to
          reproduce, and replies in a team chat.
        </li>
        <li>
          <strong>Docs and comments in plain English</strong>, such as a README section or a
          design note.
        </li>
      </ul>
      <p>
        talkflow types into the focused text field, so it works in terminals, code editors,
        browser-based tools and chat apps alike. On a Mac it handles apps that don&apos;t support
        macOS&apos; text editing interface, such as many Electron apps, by typing keystrokes instead.
        Not every app has been tested, and apps can change how they accept text.
      </p>

      <h2 id="features">Features that matter for technical writing</h2>
      <ul>
        <li>
          <strong>It types what you said.</strong> No rewriting, no summarizing, no &quot;helpful&quot;
          rephrasing of a precise instruction. Filler sounds like &quot;um&quot; are removed, and
          that&apos;s it.
        </li>
        <li>
          <strong>Spoken punctuation and layout.</strong> Say &quot;comma&quot;, &quot;question
          mark&quot;, &quot;new line&quot; or &quot;new paragraph&quot;.
        </li>
        <li>
          <strong>Numbered lists.</strong> &quot;Number one, add rate limiting. Number two, move the
          email onto a queue&quot; becomes a numbered list, which is handy for step-by-step
          instructions.
        </li>
        <li>
          <strong>Self-corrections.</strong> &quot;Run it on port 8080, no wait, 3000&quot; comes
          out as &quot;Run it on port 3000&quot;.
        </li>
        <li>
          <strong>It learns your vocabulary.</strong> Correct a library or product name it misheard,
          and it remembers the fix for next time.
        </li>
        <li>
          <strong>Your shortcut.</strong> fn on a Mac and Ctrl + Win on Windows by default, or any
          modifier combination you record, so it stays out of your editor&apos;s keybindings.
        </li>
      </ul>

      <h2 id="limits">What it isn&apos;t</h2>
      <p>
        talkflow is not a voice-coding tool. It doesn&apos;t turn speech into code syntax, and it
        doesn&apos;t control your editor. Dictating{" "}
        <code>const user = await getUser(id)</code> word by word is slower than typing it. Use it for
        the English around your code, and keep typing the code itself. It is also built for English
        only.
      </p>

      <h2 id="tips">Tips</h2>
      <ul>
        <li>
          Say the whole request in one hold. talkflow types once, when you let go, so a long prompt
          lands as one clean block rather than in pieces.
        </li>
        <li>
          Think out loud. The constraints you&apos;d skip when typing (&quot;don&apos;t touch the
          public API&quot;, &quot;keep the old behavior behind a flag&quot;) are easy to say, and
          they make an agent&apos;s answer better.
        </li>
        <li>
          The first time a project or library name comes out wrong, fix it by hand. talkflow notices
          the correction and spells it your way from then on.
        </li>
        <li>
          Pick a shortcut that doesn&apos;t clash with your editor or terminal, such as Right
          Option on a Mac.
        </li>
      </ul>

      <h2 id="private">Your code stays on your machine</h2>
      <p>
        Speech recognition runs on your own Mac or PC. Your words go only into the app you dictate
        into, so what you say about unreleased code isn&apos;t sent to a transcription service.
        (If you choose to add your own OpenAI or Anthropic key in Settings, that step goes to that
        provider instead.) See <Link href="/how-it-works">how talkflow works</Link> and the{" "}
        <Link href="/privacy">privacy policy</Link>.
      </p>
    </ContentPage>
  );
}
