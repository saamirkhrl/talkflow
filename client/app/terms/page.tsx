import type { Metadata } from "next";
import Link from "next/link";
import { EmailLink, LegalPage, REPO_URL } from "@/components/legal/LegalPage";

export const metadata: Metadata = {
  title: "Terms of Use",
  description:
    "The terms for using the TalkFlow website. The TalkFlow app is covered by its own open-source license.",
};

export default function TermsPage() {
  return (
    <LegalPage title="Terms of Use" lastUpdated="September 29, 2026">
      <h2 id="short-version">The short version</h2>
      <ul>
        <li>
          These terms cover this website. The TalkFlow app is covered by its own open-source
          license, the MIT License.
        </li>
        <li>
          The site and the app are free. They come &quot;as is&quot;, without promises beyond what
          the law requires.
        </li>
        <li>
          The code is open. The TalkFlow name and logo are not, so please don&apos;t use them in a
          way that makes something look official when it isn&apos;t.
        </li>
        <li>
          Other companies&apos; names and logos belong to them. TalkFlow is not affiliated with any
          of them.
        </li>
        <li>
          Questions? Email <EmailLink />.
        </li>
      </ul>
      <p>This summary is here to help. The full terms below are what count.</p>

      <h2 id="who-we-are">1. Who we are</h2>
      <p>
        This website (&quot;the site&quot;) is run by Samir Kharel, an individual developer
        (&quot;we&quot;, &quot;us&quot;, &quot;our&quot;). You can reach us at <EmailLink />.
      </p>
      <p>
        By using the site, you agree to these terms. If you don&apos;t agree, please don&apos;t use
        the site.
      </p>

      <h2 id="app-license">2. The app has its own license</h2>
      <p>
        TalkFlow is a free dictation app for macOS. A Windows version is planned. Its source code is
        published at <a href={REPO_URL}>{REPO_URL}</a> under the MIT License (see the LICENSE file
        at the root of the repository).
      </p>
      <p>
        That license, not these terms, decides what you may do with the app and its source code.
        Nothing in these terms takes away or limits any right the license gives you.
      </p>
      <p>
        If these terms and the license ever disagree about the app or its code, the license wins.
        These terms cover everything else: the site itself and the TalkFlow name and logo.
      </p>
      <p>
        TalkFlow uses whisper.cpp (MIT License) and OpenAI&apos;s Whisper speech model (MIT
        License). Each is covered by its own license, which you can find in its repository.
      </p>

      <h2 id="getting-the-app">3. Getting the app</h2>
      <p>
        Please download TalkFlow only from this site or from <a href={REPO_URL}>{REPO_URL}</a>. We
        can&apos;t vouch for copies from anywhere else, including modified versions that other
        people build and share under the license.
      </p>
      <p>
        The README and release notes in the repository describe what each version does and what it
        needs to run. If the site and the release notes disagree about a version, the release notes
        are correct for that version.
      </p>

      <h2 id="using-the-site">4. Using the site</h2>
      <p>You&apos;re welcome to read the site, link to it and share it. Please don&apos;t:</p>
      <ul>
        <li>try to break or overload the site, or get into the systems that host it without permission;</li>
        <li>use the site to spread malware or anything unlawful;</li>
        <li>copy the site to make a look-alike that people could mistake for the official TalkFlow site;</li>
        <li>pretend to be us, or suggest that you speak for the TalkFlow project when you don&apos;t.</li>
      </ul>
      <p>We may block access for anyone who does these things.</p>

      <h2 id="name-and-logo">5. The TalkFlow name and logo</h2>
      <p>
        The code is open source. The TalkFlow name and logo are not. They tell people which releases
        come from this project.
      </p>
      <p>
        The MIT License covers the code. It does not give anyone permission to use the TalkFlow name
        or logo.
      </p>
      <p>You may:</p>
      <ul>
        <li>
          use the name &quot;TalkFlow&quot; to refer to the project truthfully, for example
          &quot;works with TalkFlow&quot;, &quot;a review of TalkFlow&quot; or &quot;based on
          TalkFlow&quot;;
        </li>
        <li>link to the site or the repository.</li>
      </ul>
      <p>Please don&apos;t:</p>
      <ul>
        <li>
          use the TalkFlow name or logo for a fork, modified version or related product in a way
          that suggests it is the official TalkFlow, or that we made or endorse it. If you publish a
          fork, please give it a different name and icon;
        </li>
        <li>
          use the TalkFlow logo to suggest that we endorse you, your product or your organization.
        </li>
      </ul>
      <p>If you&apos;re not sure whether a use is fine, email us and ask.</p>

      <h2 id="other-companies">6. Other companies&apos; names and logos</h2>
      <p>
        The site shows the names and logos of other companies&apos; apps as examples of places you
        can type. TalkFlow types into the focused text field of most Mac apps. We have not tested
        every app, and apps can change how they handle typed text, so TalkFlow may not work in every
        app or in every version of an app. We use these names and logos only to describe where you
        can type.
      </p>
      <p>
        TalkFlow is an independent project. It is not affiliated with, endorsed by or sponsored by
        Apple, Microsoft or any other company whose products are named or shown on the site.
      </p>
      <p>
        Apple, Mac, macOS and the Apple logo are trademarks of Apple Inc., registered in the U.S.
        and other countries. Windows and the Windows logo are trademarks of the Microsoft group of
        companies. All other product names and logos are trademarks of their respective owners.
      </p>

      <h2 id="other-sites">7. Links to other sites</h2>
      <p>
        The site links to sites we don&apos;t run, such as GitHub. We&apos;re not responsible for
        their content or for how they handle your information. Their own terms and privacy policies
        apply.
      </p>

      <h2 id="no-warranty">8. No warranty</h2>
      <p>TalkFlow and this site are free. They are provided &quot;as is&quot; and &quot;as available&quot;.</p>
      <p>
        For the app, the warranty disclaimer in the MIT License applies. For the site, and for the
        app to the extent the license doesn&apos;t already cover it, we make no promises of any kind,
        whether express or implied, except those the law requires. That includes no promise that the
        site or the app will be accurate, reliable, available, secure or error-free, that they will
        suit your particular purpose, or that they don&apos;t infringe anyone else&apos;s rights.
      </p>
      <p>
        In plain terms: speech recognition makes mistakes. TalkFlow may mishear you, type the wrong
        words, type into the wrong place or type nothing at all. Check what it typed before you send
        it or rely on it, especially for anything important such as medical, legal, financial or
        safety-related text.
      </p>
      <p>
        This section doesn&apos;t take away any legal rights that can&apos;t be excluded. See
        section 10.
      </p>

      <h2 id="liability">9. Limits on our liability</h2>
      <p>As far as the law allows:</p>
      <ul>
        <li>
          we are not liable for any indirect, incidental, special or consequential loss, or for lost
          data, lost profits, lost business or lost opportunities, arising from your use of, or
          inability to use, the site or the app; and
        </li>
        <li>
          our total liability to you for all claims about the site and the app is limited to the
          amount you paid us to use the site or the app. Both are free, so that amount is zero.
        </li>
      </ul>
      <p>For the app, the limitation of liability in the MIT License also applies.</p>
      <p>
        <strong>What we don&apos;t limit.</strong> Nothing in these terms excludes or limits our
        liability for:
      </p>
      <ul>
        <li>death or personal injury caused by our negligence;</li>
        <li>fraud or fraudulent misrepresentation;</li>
        <li>harm we cause on purpose or through gross negligence;</li>
        <li>anything else that the law doesn&apos;t allow us to exclude or limit.</li>
      </ul>

      <h2 id="consumer-law">10. Your rights under consumer law</h2>
      <p>
        Some countries don&apos;t allow the exclusions and limits in sections 8 and 9, or allow them
        only in part. This includes many consumer protection laws in the UK and the European Union.
        If you live in one of those countries, sections 8 and 9 apply only as far as your local law
        allows, and you keep every right that your local law gives you and that can&apos;t be waived
        by contract.
      </p>

      <h2 id="changes">11. Changes to the site and to these terms</h2>
      <p>We may change the site, or stop running it, at any time.</p>
      <p>
        We may also update these terms. When we do, we&apos;ll post the new version on this page and
        change the &quot;Last updated&quot; date at the top.
      </p>
      <p>
        Changes apply from that date. They don&apos;t apply to anything that happened before it. If
        you keep using the site after a change takes effect, the updated terms apply to you.
      </p>

      <h2 id="disputes">12. Disputes</h2>
      <p>
        If you have a problem, please email us at <EmailLink /> first. Most problems can be sorted
        out that way.
      </p>
      <p>
        Nothing in these terms limits any rights that the law of the country where you live gives
        you.
      </p>

      <h2 id="children">13. Children</h2>
      <p>
        The site is for a general audience. It is not aimed at children under 13. If you are under
        18, or under the age of majority where you live, please read these terms with a parent or
        guardian.
      </p>

      <h2 id="other-terms">14. Other legal terms</h2>
      <ul>
        <li>
          <strong>If part of these terms can&apos;t be enforced.</strong> If a court decides that
          part of these terms is invalid or can&apos;t be enforced, the rest of the terms still
          apply.
        </li>
        <li>
          <strong>If we don&apos;t act straight away.</strong> If we don&apos;t enforce part of these
          terms right away, we can still enforce it later.
        </li>
        <li>
          <strong>The whole agreement.</strong> These terms, our <Link href="/privacy">Privacy Policy</Link>{" "}
          and, for the app, the MIT License are the whole agreement between you and us about the site
          and the app.
        </li>
        <li>
          <strong>Transfer.</strong> If someone else takes over the TalkFlow project, such as a new
          maintainer or organization, we may transfer these terms to them. This won&apos;t reduce
          your rights under these terms.
        </li>
      </ul>

      <h2 id="contact">15. Contact</h2>
      <p>
        Questions about these terms? Email <EmailLink />.
      </p>
    </LegalPage>
  );
}
