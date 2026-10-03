import { CloudOff, Cpu, Mic, TextCursorInput } from "lucide-react";
import { REPO_URL } from "./content";

const FACTS = [
  ["Runs on your Mac", "Speech is recognized by OpenAI's Whisper model, running through whisper.cpp on your own processor."],
  ["No cloud, no account", "No sign-in, no analytics, no crash reports and no update checks. It works the same with Wi-Fi off."],
  ["Audio is never saved", "Your voice is kept in memory only, never written to disk, and replaced by your next dictation."],
  ["Open source", "Every line is public under the MIT License, so you don't have to take our word for any of this."],
];

const NODES = [
  { icon: Mic, label: "Your voice" },
  { icon: Cpu, label: "Speech engine on your Mac" },
  { icon: TextCursorInput, label: "Text at your cursor" },
];

export function Privacy() {
  return (
    <section id="privacy" className="px-3 sm:px-4">
      <div className="mx-auto max-w-[1360px] rounded-[clamp(28px,4vw,48px)] bg-ink px-gutter py-[clamp(72px,10vw,128px)] text-paper">
        <div className="mx-auto max-w-[1072px]">
          <h2 className="max-w-[13ch] font-serif text-[clamp(40px,6vw,80px)] leading-[0.98] font-normal tracking-[-0.025em]">
            Your voice never leaves your Mac.
          </h2>
          <p className="mt-6 max-w-[50ch] text-[18px] text-fog">
            talkflow sends your audio to exactly one place: a speech engine running on your own computer. Nothing is uploaded,
            because there&apos;s nowhere to upload it to.
          </p>

          <div className="mt-14 flex flex-wrap items-center gap-6">
            <div className="relative flex flex-[1_1_560px] flex-wrap items-center justify-between gap-5 rounded-3xl border border-paper/15 px-6 pt-10 pb-7 sm:px-8">
              <span className="absolute -top-3 left-6 bg-ink px-2 text-[14px] text-fog">Your Mac</span>
              {NODES.map(({ icon: Icon, label }, i) => (
                <div key={label} className="contents">
                  {i > 0 && <span aria-hidden="true" className="h-px min-w-6 flex-[0_1_64px] bg-paper/30" />}
                  <div className="flex flex-[1_1_120px] flex-col items-center gap-3 text-center text-[15px]">
                    <span className="grid size-16 place-items-center rounded-2xl bg-paper/8">
                      <Icon size={26} strokeWidth={1.5} aria-hidden="true" />
                    </span>
                    {label}
                  </div>
                </div>
              ))}
            </div>
            <div className="flex flex-none items-center gap-4 text-fog">
              <span aria-hidden="true" className="w-10 border-t border-dashed border-paper/30" />
              <span className="flex flex-col items-center gap-2 text-[14px]">
                <CloudOff size={34} strokeWidth={1.5} aria-hidden="true" />
                No cloud
              </span>
            </div>
          </div>

          <div className="mt-16 grid gap-x-10 gap-y-9 sm:grid-cols-2">
            {FACTS.map(([title, body]) => (
              <div key={title} className="border-t border-paper/15 pt-5">
                <h3 className="text-[19px] font-semibold">{title}</h3>
                <p className="mt-2 max-w-[44ch] text-fog">{body}</p>
              </div>
            ))}
          </div>

          <p className="mt-14 text-[15px] text-fog">
            The details are in the{" "}
            <a href="/privacy" className="text-paper underline decoration-paper/40 underline-offset-4 hover:decoration-paper">
              privacy policy
            </a>
            , and the code is on{" "}
            <a href={REPO_URL} className="text-paper underline decoration-paper/40 underline-offset-4 hover:decoration-paper">
              GitHub
            </a>
            .
          </p>
        </div>
      </div>
    </section>
  );
}
