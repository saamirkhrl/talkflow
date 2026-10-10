import { CloudOff, Cpu, Mic, TextCursorInput } from "lucide-react";
import { REPO_URL } from "./content";
import { ForOs } from "./visitor";

const YOUR_COMPUTER = <ForOs mac="Mac" windows="computer" />;

const FACTS: [React.ReactNode, string][] = [
  [<>Runs on your {YOUR_COMPUTER}</>, "Speech is recognized by Whisper, running on your own processor."],
  ["No cloud, no account", "No sign-in, analytics or crash reports. It works with Wi-Fi off. Online, it only checks GitHub for updates and counts your install once, with no ID."],
  ["Audio is never saved", "Your voice stays in memory, never on disk, and is replaced by your next dictation."],
  ["Open source", "Every line is public under the MIT License."],
];

const NODES: { icon: typeof Mic; label: React.ReactNode }[] = [
  { icon: Mic, label: "Your voice" },
  { icon: Cpu, label: <>Speech engine on your {YOUR_COMPUTER}</> },
  { icon: TextCursorInput, label: "Text at your cursor" },
];

export function Privacy() {
  return (
    <section id="privacy" className="px-3 sm:px-4">
      <div className="mx-auto max-w-[1360px] rounded-[clamp(28px,4vw,48px)] bg-ink px-gutter py-[clamp(56px,7vw,96px)] text-paper">
        <div className="mx-auto max-w-[1072px]">
          <h2 className="max-w-[13ch] font-serif text-[clamp(40px,6vw,80px)] leading-[0.98] font-normal tracking-[-0.025em]">
            Your voice never leaves your {YOUR_COMPUTER}.
          </h2>
          <p className="mt-6 max-w-[50ch] text-[18px] text-fog">
            talkflow sends your audio to exactly one place: a speech engine running on your own computer. Nothing is uploaded,
            because there&apos;s nowhere to upload it to.
          </p>

          <div className="mx-auto mt-8 flex w-fit max-w-full flex-wrap items-center justify-center gap-x-4 gap-y-3 rounded-2xl border border-paper/15 px-5 py-3 text-[14px]">
            {NODES.map(({ icon: Icon, label }, i) => (
              <div key={i} className="contents">
                {i > 0 && <span aria-hidden="true" className="hidden h-px w-6 bg-paper/30 sm:block" />}
                <span className="flex items-center gap-2.5">
                  <span className="grid size-9 place-items-center rounded-xl bg-paper/8">
                    <Icon size={18} strokeWidth={1.5} aria-hidden="true" />
                  </span>
                  {label}
                </span>
              </div>
            ))}
            <span aria-hidden="true" className="hidden h-6 w-px bg-paper/20 sm:block" />
            <span className="flex items-center gap-2 text-fog">
              <CloudOff size={18} strokeWidth={1.5} aria-hidden="true" />
              No cloud
            </span>
          </div>

          <div className="mt-8 grid gap-x-10 gap-y-6 sm:grid-cols-2 lg:grid-cols-4">
            {FACTS.map(([title, body]) => (
              <div key={body} className="border-t border-paper/15 pt-4">
                <h3 className="text-[17px] font-semibold">{title}</h3>
                <p className="mt-1.5 text-[15px] text-fog">{body}</p>
              </div>
            ))}
          </div>

          <p className="mt-8 text-[15px] text-fog">
            The details are in the{" "}
            <a href="/privacy" className="text-paper underline decoration-paper/40 underline-offset-4 hover:decoration-paper">
              privacy policy
            </a>
            , and the code is on{" "}
            <a href={REPO_URL} target="_blank" rel="noopener noreferrer" className="text-paper underline decoration-paper/40 underline-offset-4 hover:decoration-paper">
              GitHub
            </a>
            .
          </p>
        </div>
      </div>
    </section>
  );
}
