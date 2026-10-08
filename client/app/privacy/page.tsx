import type { Metadata } from "next";
import Link from "next/link";
import { EmailLink, LegalPage, REPO_URL } from "@/components/legal/LegalPage";

export const metadata: Metadata = {
  title: "Privacy Policy",
  description:
    "What the talkflow website and app do and do not do with your information. Dictation happens on your own Mac.",
};

export default function PrivacyPage() {
  return (
    <LegalPage title="Privacy Policy" lastUpdated="October 7, 2026">
      <h2 id="short-version">The short version</h2>
      <ul>
        <li>
          <strong>The app works on your Mac.</strong> Your speech is turned into text on your own
          computer, by a speech engine running on your Mac. Apart from that, the app only asks GitHub
          whether a newer version exists (see{" "}<a href="#app-updates">Update checks</a>), and contacts
          OpenAI or Anthropic only if you add your own API key. We don&apos;t receive your audio, your
          text or your usage stats.
        </li>
        <li>
          <strong>The app has no accounts and no telemetry.</strong> It checks GitHub for updates,
          and an update installs only when you click. Audio is never saved to disk.
        </li>
        <li>
          <strong>The website has no cookies and no forms, and uses only basic, cookieless
          analytics.</strong> Like every website, it can&apos;t be delivered without your browser
          sending some technical information, such as your IP address, to our hosting provider.
        </li>
        <li>
          <strong>We don&apos;t sell or share your personal information</strong>, and we don&apos;t
          use it for advertising.
        </li>
        <li>
          <strong>Questions?</strong> Email <EmailLink />.
        </li>
      </ul>
      <p>
        This policy has two main parts: <strong>The website</strong> and <strong>The app</strong>.
        They work very differently, so we describe them separately.
      </p>

      <h2 id="who-we-are">Who we are</h2>
      <p>
        talkflow is run by Samir Kharel, an individual developer (&quot;we&quot;, &quot;us&quot;,
        &quot;our&quot;). You can contact us at <EmailLink />.
      </p>
      <p>
        For the website information described in Part 1, and for any emails you send us, we decide
        how that information is used. Under data protection laws such as the GDPR and UK GDPR, that
        makes us the &quot;controller&quot; of that information.
      </p>

      <h2 id="scope">What this policy covers, and what it doesn&apos;t</h2>
      <p>This policy covers:</p>
      <ul>
        <li>this website;</li>
        <li>
          official releases of the talkflow app downloaded from this website or from{" "}
          <a href={REPO_URL} target="_blank" rel="noopener noreferrer">{REPO_URL}</a>;
        </li>
        <li>emails you send us.</li>
      </ul>
      <p>It doesn&apos;t cover:</p>
      <ul>
        <li>
          <strong>Other websites we link to</strong>, such as GitHub. Their own privacy policies
          apply.
        </li>
        <li>
          <strong>The apps you dictate into.</strong> Once talkflow types your words into another
          app, such as a chat app, an email client or a document, that text is handled by that app
          and its provider under their own privacy policies.
        </li>
        <li>
          <strong>Modified versions of talkflow.</strong> talkflow is open source, so anyone can
          build and share their own version. Those versions may work differently, and this policy
          doesn&apos;t describe them.
        </li>
      </ul>

      <hr />

      <h2 id="website">Part 1: The website</h2>

      <h3 id="website-info">What information is collected</h3>
      <p>
        When you visit the site, your browser sends our hosting provider the technical information
        that every website needs in order to respond. This typically includes:
      </p>
      <ul>
        <li>your IP address, and the approximate location that can be worked out from it;</li>
        <li>your browser type and operating system (the &quot;user agent&quot;);</li>
        <li>
          the page you asked for, the page that linked you to us (the &quot;referrer&quot;), and the
          date and time of the request.
        </li>
      </ul>
      <p>Our hosting provider is Vercel Inc.</p>

      <h3 id="website-not">What the site doesn&apos;t do</h3>
      <ul>
        <li>It doesn&apos;t set cookies.</li>
        <li>
          It doesn&apos;t use advertising, tracking pixels or session recording. It does use Vercel
          Web Analytics to count page views and visits in aggregate (pages viewed, referrer,
          country, browser and device type). It doesn&apos;t use cookies for this, doesn&apos;t
          build a profile of you and doesn&apos;t follow you across other websites.
        </li>
        <li>
          It doesn&apos;t ask you for any personal information. There are no sign-up, contact or
          email forms.
        </li>
        <li>
          Its fonts are served from our own site, not from Google, so your browser doesn&apos;t
          contact Google Fonts.
        </li>
        <li>
          To show the right download button, the page checks in your browser which operating system
          you&apos;re using. That check happens on your device, and the result isn&apos;t sent to
          us.
        </li>
      </ul>

      <h3 id="website-github">The GitHub star count</h3>
      <p>
        The page shows how many people have starred the project on GitHub. Our server fetches this
        public number from GitHub&apos;s API, at most once an hour. Your browser does not contact
        GitHub for this, and GitHub does not receive your IP address from it.
      </p>

      <h3 id="website-basis">Why we use it, and our legal basis</h3>
      <p>
        This information is used only to deliver the site to you, keep it running, and protect it
        from abuse such as attacks and excessive traffic.
      </p>
      <p>
        Under the GDPR and UK GDPR, our legal basis is our <strong>legitimate interests</strong> in
        running a working and secure website (Article 6(1)(f)). You have the right to object to
        this. See &quot;Your rights&quot; below.
      </p>

      <h3 id="website-vercel">Who handles it for us</h3>
      <p>
        Our hosting provider (Vercel Inc.) handles this information in order to serve the site. See
        Vercel&apos;s <a href="https://vercel.com/legal/privacy-notice">Privacy Notice</a>.
      </p>
      <p>We don&apos;t share website information with anyone else, except where the law requires it.</p>

      <h3 id="website-retention">How long it&apos;s kept</h3>
      <p>
        Vercel keeps request logs for a limited time under its own policies. We don&apos;t copy or
        export them.
      </p>

      <h3 id="website-downloads">Downloads</h3>
      <p>
        If you download or view talkflow on GitHub, GitHub receives your request, including your IP
        address, and handles it under the{" "}
        <a href="https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement">
          GitHub Privacy Statement
        </a>
        .
      </p>

      <h3 id="website-dnt">&quot;Do Not Track&quot; and Global Privacy Control</h3>
      <p>
        We don&apos;t track visitors across other websites, and we don&apos;t allow other
        companies to do so through our site. Our aggregate analytics don&apos;t use cookies or
        build a profile of you. So there&apos;s nothing for a &quot;Do Not
        Track&quot; or Global Privacy Control signal to switch off. The site works the same way
        whether or not your browser sends one.
      </p>

      <hr />

      <h2 id="app">Part 2: The app</h2>

      <h3 id="app-how">How dictation works</h3>
      <p>When you hold the talkflow hotkey (the fn key), the app:</p>
      <ol>
        <li>records sound from your microphone and keeps it in your computer&apos;s memory;</li>
        <li>
          sends that audio to a speech engine (whisper.cpp) running as a separate program on your
          own Mac, at the address 127.0.0.1 (also called &quot;localhost&quot;), which always means
          your own computer;
        </li>
        <li>
          turns the speech into text using the Whisper speech model (the English-only
          &quot;small.en&quot; version), running on your Mac;
        </li>
        <li>types the text into the app you&apos;re using.</li>
      </ol>
      <p>
        <strong>Audio is never saved to disk.</strong> It stays in memory only, until your next
        dictation or until you quit talkflow.
      </p>
      <p>
        The speech engine is a program on your computer. It is not a cloud server, and your audio
        doesn&apos;t travel over the internet.
      </p>

      <h3 id="app-receive">What we receive from the app</h3>
      <p>
        Nothing. The app doesn&apos;t send your audio, your text, your stats or any other
        information to us. There are no accounts, no telemetry, no analytics and no crash reports
        sent to us. Apart from the speech engine on your own Mac, the app connects only to GitHub to
        check for updates (below), and to OpenAI or Anthropic if you add your own API key in Settings.
      </p>

      <h3 id="app-updates">Update checks</h3>
      <p>
        When it is online, the app asks GitHub whether a newer version exists: shortly after it
        starts, every few hours while it runs, and when you open the dashboard. It downloads a small
        public file listing the latest release (if that file is missing, it asks GitHub&apos;s
        release API instead). The request sends nothing about you or your dictation. Like any web
        request, it reaches GitHub with your IP address, and it names the app and its version (for
        example &quot;talkflow/0.1.4&quot;). GitHub&apos;s privacy statement covers that request; we
        don&apos;t receive it.
      </p>
      <p>
        When a newer version exists, the app says so. Nothing is downloaded or installed until you
        click to update, and the download is checked against the release&apos;s published checksum
        before it is installed. Without an internet connection, the app works the same and simply
        checks again later.
      </p>
      <p>
        Because we don&apos;t receive anything from the app, we can&apos;t see, recover or delete
        anything on your Mac for you. You are in control of it.
      </p>

      <h3 id="app-setup">Setting up the app</h3>
      <p>
        When you set talkflow up, you download other software. Those services see your IP address
        when you download, and handle it under their own privacy policies:
      </p>
      <ul>
        <li>
          The Whisper model (small.en, English only) is downloaded from Hugging Face. See the{" "}
          <a href="https://huggingface.co/privacy">Hugging Face privacy policy</a>.
        </li>
        <li>
          The whisper.cpp speech engine is typically installed with Homebrew. See{" "}
          <a href="https://docs.brew.sh/Analytics">Homebrew&apos;s analytics documentation</a>.
        </li>
      </ul>

      <h3 id="app-local">What stays on your Mac</h3>
      <p>The app keeps a small amount of information on your own computer:</p>
      <ul>
        <li>
          <strong>Usage stats.</strong> Totals of words dictated, number of dictations and speaking
          time, and words per day. These power the stats you see in the app. They contain no text
          and no audio. They are stored in a file at{" "}
          <code>~/Library/Application Support/talkflow/stats.json</code>.
        </li>
        <li>
          <strong>A technical log.</strong> The app writes a log at{" "}
          <code>~/Library/Logs/talkflow/talkflow.log</code>. It grows until you delete it. For each
          dictation it records technical details, such as its length and timing and the name of the
          app you dictated into. It does not record your words.
        </li>
        <li>
          <strong>The speech engine&apos;s own log.</strong> Depending on how the speech engine is
          set up on your Mac, it may keep its own log. Check the speech engine&apos;s settings if you
          want to turn that off or delete it.
        </li>
      </ul>
      <p>
        These files are not encrypted by talkflow. They are protected by your macOS user account,
        and by FileVault disk encryption if you have it turned on.
      </p>
      <p>
        <strong>Deleting them.</strong> You can delete these files at any time. Deleting the
        talkflow app may not delete them, so remove the files above if you want them gone.
      </p>

      <h3 id="app-reads">What the app reads while you dictate</h3>
      <p>
        Through macOS Accessibility, talkflow reads the one character before your cursor, so it can
        add a space when needed, and the text it typed itself. It never reads whole documents. This
        happens in memory, and that text isn&apos;t saved or sent anywhere. talkflow never uses the
        clipboard.
      </p>

      <h3 id="app-permissions">Permissions the app asks for</h3>
      <p>
        You can turn any of these off at any time in <strong>System Settings &gt; Privacy &amp;
        Security</strong>, but talkflow won&apos;t work without them.
      </p>
      <ul>
        <li>
          <strong>Microphone.</strong> macOS asks you to approve this, so talkflow can hear you.
        </li>
        <li>
          <strong>Accessibility.</strong> You grant this yourself in System Settings. talkflow uses
          it to type the text into the app you&apos;re using, and for the reading described above.
        </li>
        <li>
          <strong>Input Monitoring.</strong> You grant this yourself in System Settings. talkflow
          uses it listen-only, to notice when you press and release the fn key. It sees only
          modifier keys, never the characters you type.
        </li>
      </ul>

      <h3 id="app-outside">Things outside talkflow&apos;s control</h3>
      <p>
        Some things that happen on your Mac are up to you, your organization or other companies, not
        us:
      </p>
      <ul>
        <li>
          <strong>Backups and sync.</strong> Tools like Time Machine, or other backup and sync
          software you use, may copy the files listed above. Those copies are governed by the tool
          you use.
        </li>
        <li>
          <strong>Your operating system.</strong> macOS may make its own network connections, for
          example when it checks a newly downloaded app before first opening it. If you have chosen
          to share Mac analytics with Apple, macOS may also send Apple crash reports that involve
          talkflow. Apple&apos;s privacy policy covers those.
        </li>
        <li>
          <strong>Work computers.</strong> If you use talkflow on a computer managed by your
          employer or school, their security and monitoring tools and policies may also apply.
        </li>
      </ul>

      <h3 id="app-future">Future versions</h3>
      <p>
        This part describes the app as of the &quot;Last updated&quot; date above. If we ever add a
        feature that sends any other information off your Mac, such as crash reports, we
        will update this policy before releasing that version and describe the change in the release
        notes.
      </p>

      <hr />

      <h2 id="email">Emails you send us</h2>
      <p>
        If you email us, we receive your email address, your name if you include it, and whatever
        you write. We use it only to reply and to deal with your request. Our legal basis is our
        legitimate interest in answering you.
      </p>
      <p>
        Our address forwards to a Gmail inbox. Google, and the email service that forwards the
        messages, process them on our behalf. We keep emails only as long as needed to handle your
        request.
      </p>

      <h2 id="selling">Selling and sharing</h2>
      <p>
        We don&apos;t sell your personal information. We don&apos;t &quot;share&quot; it for
        cross-context behavioral advertising, as California law defines those terms, and we
        don&apos;t use it for targeted advertising. We haven&apos;t done any of these things in the
        past 12 months.
      </p>

      <h2 id="children">Children</h2>
      <p>
        The site and the app are not aimed at children under 13, and we don&apos;t knowingly collect
        personal information from children under 13. If you believe a child under 13 has sent us
        personal information, for example by email, contact us and we&apos;ll delete it.
      </p>

      <h2 id="rights">Your rights</h2>
      <p>Depending on where you live, you may have the right to:</p>
      <ul>
        <li>ask for a copy of the personal information we hold about you (access);</li>
        <li>ask us to correct it (rectification);</li>
        <li>ask us to delete it (erasure);</li>
        <li>ask us to limit how we use it (restriction);</li>
        <li>object to our use of it based on our legitimate interests (objection);</li>
        <li>receive it in a portable format (portability);</li>
        <li>not be treated differently for using any of these rights.</li>
      </ul>
      <p>
        In practice we hold very little. We have no app data about you at all, and we don&apos;t
        keep copies of website request logs. If you contact us about website logs, we may not be
        able to find them, because they are held by our hosting provider.
      </p>
      <p>
        <strong>How to make a request.</strong> Email <EmailLink />. We&apos;ll reply within one
        month. If we need to confirm who you are, we&apos;ll ask only for what we need.
      </p>
      <p>
        <strong>Complaints.</strong> If you have a concern about how we handle your information,
        please tell us first at <EmailLink />. You also have the right to complain to a data
        protection authority:
      </p>
      <ul>
        <li>
          in the UK, the{" "}
          <a href="https://ico.org.uk/make-a-complaint/">Information Commissioner&apos;s Office (ICO)</a>;
        </li>
        <li>
          in the EU or EEA, the data protection authority in your country (
          <a href="https://www.edpb.europa.eu/about-edpb/about-edpb/members_en">
            list of EU authorities
          </a>
          ).
        </li>
      </ul>
      <p>
        <strong>If you live in California or another US state with a privacy law</strong>, you can
        make the same requests by email. We&apos;ll handle them in the same way, whether or not that
        law applies to us.
      </p>

      <h2 id="security">Keeping information safe</h2>
      <ul>
        <li>The website is served over encrypted HTTPS connections.</li>
        <li>
          The app only ever connects to 127.0.0.1, your own computer. When the speech engine is set up
          as described in the README, it listens only on your own computer, not on your network.
        </li>
      </ul>
      <p>
        No system is perfectly secure, but we keep the information we hold to a minimum, which is
        itself a protection.
      </p>

      <h2 id="transfers">International transfers</h2>
      <p>
        Vercel is based in the United States and serves the site from data centers around the world,
        so website request information may be processed outside your country, including in the
        United States. Vercel handles this under its own policies.
      </p>

      <h2 id="changes">Changes to this policy</h2>
      <p>
        We may update this policy. When we do, we&apos;ll post the new version on this page and
        change the &quot;Last updated&quot; date at the top. Significant changes to the app&apos;s
        data handling are also noted in the release notes.
      </p>
      <p>
        The app tells you when a new version is available, but not when this policy changes. Please
        check this page or the release notes when you update. See also our{" "}
        <Link href="/terms">Terms of Use</Link>.
      </p>

      <h2 id="contact">Contact</h2>
      <p>
        Samir Kharel
        <br />
        Email: <EmailLink />
      </p>
    </LegalPage>
  );
}
