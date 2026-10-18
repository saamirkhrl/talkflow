import type { Metadata } from "next";
import Link from "next/link";
import { EmailLink, LegalPage, REPO_URL } from "@/components/legal/LegalPage";
import { pageMetadata } from "@/lib/seo";

// The first app version that counts installs (docs/telemetry.md).
const COUNTED_FROM = "0.1.6";

export const metadata: Metadata = pageMetadata({
  title: "Privacy Policy",
  description:
    "What the talkflow website and app do and do not do with your information. Dictation happens on your own Mac or PC.",
  path: "/privacy",
});

export default function PrivacyPage() {
  return (
    <LegalPage title="Privacy Policy" lastUpdated="October 18, 2026">
      <h2 id="short-version">The short version</h2>
      <ul>
        <li>
          <strong>The app works on your computer.</strong> Your speech is turned into text on your
          own Mac or PC, by a speech engine running on it. Apart from that, the app asks GitHub
          whether a newer version exists (see{" "}<a href="#app-updates">Update checks</a>), tells us
          once that it was installed (see <a href="#app-receive">What we receive from the app</a>),
          and contacts OpenAI or Anthropic only if you add your own API key. We don&apos;t receive
          your audio, your text or your usage stats.
        </li>
        <li>
          <strong>Optional cloud features send your words to the company you pick.</strong> If you
          add your own OpenAI key and turn on OpenAI transcription, your recorded audio goes to
          OpenAI. If you add your own Anthropic key and turn on Claude punctuation, the text of your
          dictation goes to Anthropic. Both are off unless you turn them on (see{" "}
          <a href="#app-keys">Your own OpenAI or Anthropic key</a>).
        </li>
        <li>
          <strong>The app has no accounts and doesn&apos;t track how you use it.</strong> The first
          time it runs, it tells us once so we can count installs. talkflow puts no ID, no device
          information and no usage data in that request, and we store only a total number. It checks GitHub for
          updates, and an update installs only when you click. Audio is never saved to disk.
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
          official releases of the talkflow app for Mac and Windows, downloaded from this website or
          from{" "}
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
      <p>
        The app&apos;s one-time install request (see{" "}
        <a href="#app-receive">What we receive from the app</a>) reaches us the same way, through
        Vercel. The total it adds to is kept in a database hosted by Neon, which receives only that
        number.
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

      <p>
        talkflow has a Mac app and a Windows app. They handle your information the same way; where
        they differ, this part says so.
      </p>

      <h3 id="app-how">How dictation works</h3>
      <p>
        When you hold the talkflow shortcut (fn on a Mac and Ctrl + Win on Windows, unless you
        change it), the app:
      </p>
      <ol>
        <li>records sound from your microphone and keeps it in your computer&apos;s memory;</li>
        <li>
          sends that audio to a speech engine (whisper.cpp), which is included with talkflow and
          runs as a separate program on your own computer, at the address 127.0.0.1 (also called &quot;localhost&quot;), which always means
          your own computer;
        </li>
        <li>
          turns the speech into text using OpenAI&apos;s Whisper speech model, running on your
          computer: the English-only &quot;small.en&quot; version and, on computers fast enough
          for it, the larger &quot;large-v3-turbo&quot; version for the final text;
        </li>
        <li>types the text into the app you&apos;re using.</li>
      </ol>
      <p>
        <strong>Audio is never saved to disk.</strong> It stays in memory only, until your next
        dictation or until you quit talkflow.
      </p>
      <p>
        The speech engine is a program on your computer. It is not a cloud server, and your audio
        doesn&apos;t travel over the internet, unless you turn on OpenAI transcription with your own
        key (see <a href="#app-keys">Your own OpenAI or Anthropic key</a>).
      </p>
      <p>
        <strong>No voiceprints.</strong> talkflow uses your voice only to turn it into text. It
        doesn&apos;t create a voiceprint or any other biometric identifier, and it doesn&apos;t try
        to recognize who is speaking.
      </p>

      <h3 id="app-receive">What we receive from the app</h3>
      <p>
        One thing: the first time a newly installed copy of talkflow runs while online, it tells us
        once, so we can count how many times talkflow has been installed. This applies to versions{" "}
        {COUNTED_FROM} and later; earlier versions send us nothing.
      </p>
      <ul>
        <li>
          The app sends one empty request to our website. talkflow puts nothing in it: no ID, no
          information about your device or operating system, and no usage data, audio or text.
        </li>
        <li>
          We store only a running total. We don&apos;t store your IP address or anything else from
          the request, so we can&apos;t tell installs apart or link the count to you.
        </li>
        <li>
          Like any web request, it reaches our hosting provider (Vercel) with your IP address and the
          standard technical details your operating system adds to web requests. Vercel&apos;s
          ordinary request logs apply to it, as they do to the website (see{" "}
          <a href="#website-retention">How long it&apos;s kept</a>). The total is stored in a database
          hosted by Neon.
        </li>
        <li>
          Once our site confirms it received the request, the app remembers that (a yes/no flag on
          your computer) and doesn&apos;t send it again. If the request fails, the app tries again
          the next time it starts. Reinstalling talkflow may count again.
        </li>
        <li>
          Copies of talkflow built from the source code don&apos;t send this request at all.
        </li>
      </ul>
      <p>
        Apart from that, the app doesn&apos;t send your audio, your text, your stats or any other
        information to us. There are no accounts, no usage analytics and no crash reports sent to
        us. Besides the speech engine on your own computer and this one-time request, the app connects
        only to GitHub to check for updates (below), and to OpenAI or Anthropic if you add your own
        API key in Settings.
      </p>

      <h3 id="app-updates">Update checks</h3>
      <p>
        When it is online, the app asks GitHub whether a newer version exists: shortly after it
        starts, every few hours while it runs, and when you open the dashboard. It downloads a small
        public file listing the latest release (if that file is missing, it asks GitHub&apos;s
        release API instead). The request sends nothing about you or your dictation. Like any web
        request, it reaches GitHub with your IP address, and it names the app and its version (for
        example &quot;talkflow/0.1.5&quot;). GitHub&apos;s privacy statement covers that request; we
        don&apos;t receive it.
      </p>
      <p>
        When a newer version exists, the app says so. Nothing is downloaded or installed until you
        click to update, and the download is checked against the release&apos;s published checksum
        before it is installed. Without an internet connection, the app works the same and simply
        checks again later.
      </p>
      <p>
        Apart from the one-time install count, which can&apos;t be linked to you, we don&apos;t
        receive anything from the app, so we can&apos;t see, recover or delete anything on your
        computer for you. You are in control of it.
      </p>

      <h3 id="app-keys">Your own OpenAI or Anthropic key</h3>
      <p>
        In Settings you can add your own API key for OpenAI or Anthropic and turn on a feature that
        uses it. These features are off by default. When one is on, talkflow sends data directly from
        your computer to that company, using your key. It doesn&apos;t pass through us, and we
        don&apos;t receive it.
      </p>
      <ul>
        <li>
          <strong>OpenAI transcription.</strong> For each dictation, talkflow sends the recorded audio
          to OpenAI to be turned into text. To help spell words correctly, it also sends a short
          hint: the first name on your computer&apos;s user account, and up to 25 words talkflow has
          learned from your corrections and, on a Mac, names visible on your screen (such as an
          email&apos;s recipients). The live preview while you speak still runs on your computer.
        </li>
        <li>
          <strong>Claude punctuation.</strong> For each dictation, talkflow sends the text of your
          dictation to Anthropic, which adds punctuation and capitals. talkflow keeps your original
          words and only takes the punctuation from the reply.
        </li>
      </ul>
      <p>
        Each request carries your key and the technical details any web request has, such
        as your IP address. When you save a key, talkflow checks it by asking the company for its list
        of models, which sends no dictation.
      </p>
      <p>
        What OpenAI or Anthropic does with that data is governed by your own agreement with them,
        under the account your key belongs to, and by their policies, including how long they keep
        it. See the{" "}
        <a href="https://openai.com/policies/privacy-policy/">OpenAI privacy policy</a> and the{" "}
        <a href="https://www.anthropic.com/legal/privacy">Anthropic privacy policy</a>. We don&apos;t
        control them, and we aren&apos;t responsible for how they handle it. Don&apos;t turn these
        features on for dictation you aren&apos;t allowed to share with them, for example
        confidential work or health information. If a request fails, talkflow transcribes or
        punctuates on your computer instead.
      </p>

      <h3 id="app-setup">Setting up the app</h3>
      <p>
        The whisper.cpp speech engine comes inside the talkflow download, so nothing else needs to
        be installed. The Whisper speech models are downloaded from Hugging Face: small.en (English
        only) during setup, and large-v3-turbo in the background on computers that use it. Hugging
        Face sees your IP address when you download them and handles it under the{" "}
        <a href="https://huggingface.co/privacy">Hugging Face privacy policy</a>.
      </p>

      <h3 id="app-local">What stays on your computer</h3>
      <p>
        The app keeps a small amount of information on your own computer. On a Mac, your data is in{" "}
        <code>~/Library/Application Support/talkflow/</code>. On Windows, it is in{" "}
        <code>%APPDATA%\talkflow\</code>, and the models and logs are in{" "}
        <code>%LOCALAPPDATA%\talkflow\</code>.
      </p>
      <ul>
        <li>
          <strong>Usage stats</strong> (<code>stats.json</code>). Totals of words dictated, number
          of dictations and speaking time, and words per day. These power the stats you see in the
          app. They contain no text and no audio.
        </li>
        <li>
          <strong>Settings and learned words</strong> (<code>settings.json</code>). Your settings,
          and the words talkflow has learned from corrections you made by hand (see{" "}
          <a href="#app-reads">What the app reads while you dictate</a>).
        </li>
        <li>
          <strong>A technical log.</strong> On a Mac, at{" "}
          <code>~/Library/Logs/talkflow/talkflow.log</code>, which grows until you delete it. On
          Windows, at <code>%LOCALAPPDATA%\talkflow\logs\talkflow.log</code>, which starts over at
          2 MB. For each dictation it records technical details, such as its length and timing and
          the name of the app you dictated into. It does not record your words.
        </li>
        <li>
          <strong>Whether this copy has been counted.</strong> A yes/no flag (in the app&apos;s
          preferences on a Mac, and in <code>windows.json</code> on Windows), so the install count
          described above is sent only once.
        </li>
        <li>
          <strong>On Windows, speed measurements.</strong> How fast your PC runs each speech model,
          so talkflow can choose the right settings (<code>device.json</code>).
        </li>
        <li>
          <strong>Your own API keys</strong>, if you add any: in the macOS Keychain on a Mac, and in
          Windows Credential Manager on Windows, never in a plain file.
        </li>
        <li>
          <strong>The speech engine&apos;s own log.</strong> The speech engine may keep its own log
          next to talkflow&apos;s. Delete it with the others if you want it gone.
        </li>
      </ul>
      <p>
        talkflow doesn&apos;t encrypt these files itself. They are protected by your user account,
        and by disk encryption (FileVault on a Mac, BitLocker or device encryption on Windows) if
        you have it turned on.
      </p>
      <p>
        <strong>Deleting them.</strong> You can delete these files at any time. On a Mac, deleting
        the talkflow app may not delete them. On Windows, uninstalling removes the models and logs
        but keeps your data folder, so remove <code>%APPDATA%\talkflow\</code> too if you want it
        gone.
      </p>

      <h3 id="app-reads">What the app reads while you dictate</h3>
      <p>
        When you start a dictation, talkflow reads what is around your cursor, through macOS
        Accessibility on a Mac or UI Automation on Windows: up to 300 characters before the cursor,
        up to the last 4,000 characters of the text field, and names visible on screen, such as an
        email&apos;s recipients. It uses this to get spacing and capitals right, to spell names
        correctly and, a little later, to notice when you corrected a word it got wrong, so it can
        learn that word. It never reads password fields, and it never reads whole documents beyond
        those limits. This happens in memory. It isn&apos;t logged or sent anywhere, and it is kept
        only for that dictation, except a corrected word, which is saved to your learned words.
      </p>
      <p>
        <strong>The clipboard.</strong> On a Mac, talkflow types with keystrokes and doesn&apos;t
        use the clipboard, with one exception: if the text can&apos;t be typed (for example, because
        you switched to another app while speaking), it is put on the clipboard so your words
        aren&apos;t lost. On Windows, longer dictations are pasted: talkflow saves what is on your
        clipboard, puts the dictation there, pastes it, and then puts your clipboard back. That
        paste is kept out of Windows clipboard history and the cloud clipboard.
      </p>

      <h3 id="app-permissions">Permissions the app asks for</h3>
      <p>
        <strong>On a Mac.</strong> You can turn either of these off at any time in{" "}
        <strong>System Settings &gt; Privacy &amp; Security</strong>, but talkflow won&apos;t work
        without them.
      </p>
      <ul>
        <li>
          <strong>Microphone.</strong> macOS asks you to approve this, so talkflow can hear you.
        </li>
        <li>
          <strong>Accessibility.</strong> You grant this yourself in System Settings. talkflow uses
          it to type the text into the app you&apos;re using, to notice when you press and release
          the shortcut, and for the reading described above. While you hold the shortcut, it also
          notices whether another key is pressed (then you&apos;re using an app shortcut, such as
          Command + C, not dictating), without looking at which key it was. It doesn&apos;t record,
          store or send what you type. Because Accessibility covers this, talkflow doesn&apos;t ask
          for Input Monitoring.
        </li>
      </ul>
      <p>
        <strong>On Windows.</strong> Windows doesn&apos;t ask desktop apps for permissions. Instead:
      </p>
      <ul>
        <li>
          <strong>Microphone.</strong> The switches in Settings &gt; Privacy &amp; security &gt;
          Microphone must allow desktop apps to use it. talkflow checks them and, if one is off,
          tells you which.
        </li>
        <li>
          <strong>The shortcut.</strong> To notice when you hold the shortcut, talkflow watches key
          presses, as Windows lets any desktop app do. It keeps track only of which keys are held
          down at that moment, to tell whether the shortcut is held. It doesn&apos;t record, store
          or send what you type.
        </li>
      </ul>

      <h3 id="app-outside">Things outside talkflow&apos;s control</h3>
      <p>
        Some things that happen on your computer are up to you, your organization or other
        companies, not us:
      </p>
      <ul>
        <li>
          <strong>Backups and sync.</strong> Tools like Time Machine, OneDrive, or other backup and
          sync software you use, may copy the files listed above. Those copies are governed by the
          tool you use.
        </li>
        <li>
          <strong>Your operating system.</strong> macOS and Windows may make their own network
          connections, for example to check a newly downloaded app or installer before it first
          opens. If you have chosen to share analytics or diagnostic data with Apple or Microsoft,
          your operating system may also send them crash reports that involve talkflow.
          Apple&apos;s and Microsoft&apos;s privacy policies cover those.
        </li>
        <li>
          <strong>Work computers.</strong> If you use talkflow on a computer managed by your
          employer or school, their security and monitoring tools and policies may also apply.
        </li>
      </ul>

      <h3 id="app-future">Future versions</h3>
      <p>
        This part describes the app as of the &quot;Last updated&quot; date above. The one-time
        install count starts with version {COUNTED_FROM}. If we ever add a feature that sends any
        other information off your computer, such as crash reports, we will update this policy before
        releasing that version and describe the change in the release notes.
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

      <h2 id="retention">How long we keep information</h2>
      <p>
        We keep personal information only as long as we need it for the purposes described in this
        policy, including to meet legal obligations, resolve disputes and protect the site. To decide
        how long that is, we consider how much information there is, how sensitive it is, the risk of
        harm from misuse, and whether we can achieve our purpose another way. When we no longer need
        it, we delete it or make it anonymous. The specific periods for website logs and emails are
        described above.
      </p>

      <h2 id="sensitive">Sensitive information</h2>
      <p>
        Please don&apos;t send us sensitive personal information by email, such as health, financial
        or government ID details, or information about your race, religion, political views or sex
        life. We don&apos;t need it to answer you.
      </p>

      <h2 id="automated-decisions">No automated decisions or profiling</h2>
      <p>
        We don&apos;t make decisions about you by automated means, and we don&apos;t profile you, in
        ways that have legal or similarly significant effects on you.
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
        In practice we hold very little. We have no app data about you at all (the install count
        is a single total that can&apos;t be linked to anyone), and we don&apos;t keep copies of
        website request logs. If you contact us about website logs, we may not be
        able to find them, because they are held by our hosting provider.
      </p>
      <p>
        <strong>How to make a request.</strong> Email <EmailLink />. We&apos;ll reply within one
        month. If we need to confirm who you are, we&apos;ll ask only for what we need. Where the law
        allows, someone you authorize can make a request for you; we may ask for proof that you
        authorized them. If we turn down a request, we&apos;ll tell you why. Where the law gives you
        the right to appeal that decision, reply to our answer and say you want to appeal, and
        we&apos;ll review it again.
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
        <strong>If you live in California, Texas or another US state with a privacy law</strong>,
        you can make the same requests by email, including an appeal. We&apos;ll handle them in the
        same way, whether or not that law applies to us. If we deny your appeal, you may contact your
        state&apos;s attorney general.
      </p>

      <h2 id="security">Keeping information safe</h2>
      <ul>
        <li>The website is served over encrypted HTTPS connections.</li>
        <li>
          The app talks to its speech engine at 127.0.0.1, your own computer. talkflow starts the
          speech engine so that it listens only on your own computer, not on your network.
        </li>
        <li>
          The app&apos;s other connections (update checks, the one-time install count, and OpenAI or
          Anthropic if you add a key) use encrypted HTTPS.
        </li>
      </ul>
      <p>
        No system is perfectly secure, and we can&apos;t guarantee the security of information sent
        over the internet. We keep the information we hold to a minimum, which is itself a protection.
      </p>

      <h2 id="transfers">International transfers</h2>
      <p>
        Vercel is based in the United States and serves the site from data centers around the world,
        so website request information may be processed outside your country, including in the
        United States. Vercel says it is certified under the EU-U.S. Data Privacy Framework (and
        its UK and Swiss extensions) and also uses standard contractual clauses approved by the
        European Commission. Emails you send us are handled by Google, which also processes data in
        the United States and other countries. You can ask us for more information about these
        safeguards at <EmailLink />.
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
