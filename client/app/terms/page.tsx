import type { Metadata } from "next";
import Link from "next/link";
import { EmailLink, LegalPage, REPO_URL } from "@/components/legal/LegalPage";
import { pageMetadata } from "@/lib/seo";

export const metadata: Metadata = pageMetadata({
  title: "Terms of Use",
  description:
    "The terms for using the talkflow website. The talkflow app is covered by its own open-source license.",
  path: "/terms",
});

export default function TermsPage() {
  return (
    <LegalPage title="Terms of Use" lastUpdated="October 18, 2026">
      <h2 id="short-version">The short version</h2>
      <ul>
        <li>
          These terms cover this website. The talkflow app is covered by its own open-source
          license, the MIT License.
        </li>
        <li>
          The site and the app are free. They come &quot;as is&quot;, without promises beyond what
          the law requires.
        </li>
        <li>
          The code is open. The talkflow name and logo are not, so please don&apos;t use them in a
          way that makes something look official when it isn&apos;t.
        </li>
        <li>
          Other companies&apos; names and logos belong to them. talkflow is not affiliated with any
          of them.
        </li>
        <li>
          Texas law governs these terms, but you keep any rights your own local law gives you.
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
        the site. In these terms, &quot;including&quot; means &quot;including without
        limitation&quot;.
      </p>

      <h2 id="app-license">2. The app has its own license</h2>
      <p>
        talkflow is a free dictation app for Mac and Windows. Its source code is
        published at <a href={REPO_URL} target="_blank" rel="noopener noreferrer">{REPO_URL}</a> under the MIT License (see the LICENSE file
        at the root of the repository).
      </p>
      <p>
        That license, not these terms, decides what you may do with the app and its source code.
        Nothing in these terms takes away or limits any right the license gives you.
      </p>
      <p>
        If these terms and the license ever disagree about the app or its code, the license wins.
        These terms cover everything else: the site itself and the talkflow name and logo.
      </p>
      <p>
        talkflow uses whisper.cpp (MIT License) and OpenAI&apos;s Whisper speech model (MIT
        License). Each is covered by its own license, which you can find in its repository.
      </p>

      <h2 id="getting-the-app">3. Getting the app</h2>
      <p>
        Please download talkflow only from this site or from <a href={REPO_URL} target="_blank" rel="noopener noreferrer">{REPO_URL}</a>. We
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
        <li>copy the site to make a look-alike that people could mistake for the official talkflow site;</li>
        <li>pretend to be us, or suggest that you speak for the talkflow project when you don&apos;t.</li>
      </ul>
      <p>We may block access for anyone who does these things.</p>

      <h3 id="feedback">Feedback and contributions</h3>
      <p>
        If you send us ideas or suggestions about talkflow, for example by email or in a GitHub
        issue, you allow us to use them freely, without paying you or crediting you. Please
        don&apos;t send anything you consider confidential. Code you contribute to the repository is
        covered by the repository&apos;s license, not by this paragraph.
      </p>

      <h2 id="name-and-logo">5. The talkflow name and logo</h2>
      <p>
        The code is open source. The talkflow name and logo are not. They tell people which releases
        come from this project.
      </p>
      <p>
        The MIT License covers the code. It does not give anyone permission to use the talkflow name
        or logo.
      </p>
      <p>You may:</p>
      <ul>
        <li>
          use the name &quot;talkflow&quot; to refer to the project truthfully, for example
          &quot;works with talkflow&quot;, &quot;a review of talkflow&quot; or &quot;based on
          talkflow&quot;;
        </li>
        <li>link to the site or the repository.</li>
      </ul>
      <p>Please don&apos;t:</p>
      <ul>
        <li>
          use the talkflow name or logo for a fork, modified version or related product in a way
          that suggests it is the official talkflow, or that we made or endorse it. If you publish a
          fork, please give it a different name and icon;
        </li>
        <li>
          use the talkflow logo to suggest that we endorse you, your product or your organization.
        </li>
      </ul>
      <p>If you&apos;re not sure whether a use is fine, email us and ask.</p>

      <h2 id="other-companies">6. Other companies&apos; names and logos</h2>
      <p>
        The site shows the names and logos of other companies&apos; apps as examples of places you
        can type. talkflow types into the focused text field of most Mac and Windows apps. We have not tested
        every app, and apps can change how they handle typed text, so talkflow may not work in every
        app or in every version of an app. We use these names and logos only to describe where you
        can type.
      </p>
      <p>
        The app windows in the demos on the site, such as Claude Code, Messages, Gmail, WhatsApp,
        Slack and Notion, are illustrations we drew to show where talkflow types. They are not
        screenshots, and the people, messages and companies in them are made up.
      </p>
      <p>
        The site compares talkflow with Wispr Flow, including Wispr Flow&apos;s published prices.
        Those prices were taken from Wispr Flow&apos;s own pricing page on October 2, 2026, and may
        have changed since.
      </p>
      <p>
        talkflow is an independent project. It is not affiliated with, endorsed by or sponsored by
        Wispr, Apple, Microsoft, Google, Slack, Meta, Notion, Anthropic or any other company whose
        products are named or shown on the site.
      </p>
      <p>
        Apple, Mac, macOS, Messages and the Apple logo are trademarks of Apple Inc., registered in
        the U.S. and other countries. Windows and the Windows logo are trademarks of the Microsoft
        group of companies. Gmail is a trademark of Google LLC. Slack is a trademark of Slack
        Technologies, LLC. WhatsApp is a trademark of WhatsApp LLC. Notion is a trademark of Notion
        Labs, Inc. Claude and Claude Code are trademarks of Anthropic, PBC. Wispr Flow is a
        trademark of its owner. All other product names and logos are trademarks of their
        respective owners.
      </p>

      <h2 id="other-sites">7. Links to other sites</h2>
      <p>
        The site links to sites we don&apos;t run, such as GitHub. We&apos;re not responsible for
        their content or for how they handle your information. Their own terms and privacy policies
        apply.
      </p>

      <h2 id="no-warranty">8. No warranty</h2>
      <p>talkflow and this site are free. They are provided &quot;as is&quot; and &quot;as available&quot;.</p>
      <p>
        For the app, the warranty disclaimer in the MIT License applies. For the site, and for the
        app to the extent the license doesn&apos;t already cover it, we make no promises of any kind,
        whether express or implied, except those the law requires. That includes no promise that the
        site or the app will be accurate, reliable, available, secure or error-free, that they will
        suit your particular purpose, or that they don&apos;t infringe anyone else&apos;s rights.
      </p>
      <p>
        In plain terms: speech recognition makes mistakes. talkflow may mishear you, type the wrong
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
          our total liability to you for all claims about the site and the app, taken together, is
          limited to the greater of US $50 and the amount you paid us to use them in the six months
          before the claim arose. Both are free, so the limit is US $50.
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

      <p>
        <strong>If you misuse the site.</strong> As far as the law allows, if someone makes a claim
        against us because you broke these terms or the law while using the site, you agree to cover
        our reasonable costs of that claim, including reasonable legal fees. This doesn&apos;t apply
        to claims caused by our own fault, or to the extent your local consumer law doesn&apos;t
        allow it.
      </p>

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
      <p>
        If we block your access under section 4, or these terms otherwise end, the sections that by
        their nature should continue (such as sections 5, 8, 9, 12 and 15) still apply.
      </p>

      <h2 id="disputes">12. Disputes</h2>
      <p>
        If you have a problem, please email us at <EmailLink /> first. Most problems can be sorted
        out that way.
      </p>
      <p>
        <strong>Governing law.</strong> These terms, and any dispute about them or the site, are
        governed by the laws of the State of Texas, United States, without regard to its
        conflict-of-law rules. Any dispute that goes to court will be decided by the state or federal
        courts located in Texas, except that either of us may bring an individual claim in a small
        claims court where it qualifies, and either of us may ask any court with jurisdiction to
        protect intellectual property rights.
      </p>
      <p>
        Nothing in these terms limits any rights that the law of the country where you live gives
        you. If you are a consumer in the UK, the EU or another country whose law lets you bring a
        claim in your own courts, or makes its consumer protections apply whatever law the contract
        chooses, you keep those rights.
      </p>

      <h2 id="children">13. Children</h2>
      <p>
        The site is for a general audience. It is not aimed at children under 13. If you are under
        18, or under the age of majority where you live, please read these terms with a parent or
        guardian.
      </p>

      <h2 id="state-notices">14. Notices for US states</h2>
      <p>
        <strong>California.</strong> Under California Civil Code Section 1789.3, California users are
        entitled to this notice: the site is provided by Samir Kharel, who can be reached at{" "}
        <EmailLink /> to file a complaint about the site or to get more information about using it.
        You may also contact the Complaint Assistance Unit of the Division of Consumer Services of
        the California Department of Consumer Affairs in writing at 1625 North Market Blvd., Suite
        N 112, Sacramento, CA 95834, or by phone at (800) 952-5210.
      </p>
      <p>
        <strong>Privacy rights in your state.</strong> If you live in California, Texas, Colorado,
        Connecticut, Virginia, Nevada or another US state with a privacy law, you may have rights over
        your personal information, such as to access, correct or delete it, or to opt out of its
        sale. We don&apos;t sell personal information or use it for targeted advertising. See our{" "}
        <Link href="/privacy#rights">Privacy Policy</Link> for how to make a request.
      </p>

      <h2 id="other-terms">15. Other legal terms</h2>
      <ul>
        <li>
          <strong>If part of these terms can&apos;t be enforced.</strong> If a court decides that
          part of these terms is invalid or can&apos;t be enforced, that part is changed only as much
          as needed to make it enforceable, and the rest of the terms still apply.
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
          <strong>Transfer.</strong> If someone else takes over the talkflow project, such as a new
          maintainer or organization, we may transfer these terms to them. This won&apos;t reduce
          your rights under these terms. You may not transfer these terms to someone else without our
          written permission.
        </li>
        <li>
          <strong>Emails and notices.</strong> You agree that we can communicate with you
          electronically, by email or by posting notices on the site, and that this meets any legal
          requirement for written notice.
        </li>
        <li>
          <strong>Export laws.</strong> You agree to follow US and other export control laws that
          apply to you when you download or share talkflow.
        </li>
        <li>
          <strong>Accessibility.</strong> We aim for the site to meet the Web Content Accessibility
          Guidelines (WCAG) 2.1, Level AA. If something on the site is hard to use, email{" "}
          <EmailLink /> and we&apos;ll try to fix it.
        </li>
      </ul>

      <h2 id="contact">16. Contact</h2>
      <p>
        Questions about these terms? Email <EmailLink />.
      </p>
      <p>
        Parts of these terms are adapted from free templates by General Legal, PC, released under
        CC0. General Legal hasn&apos;t reviewed this page, and it isn&apos;t legal advice.
      </p>
    </LegalPage>
  );
}
