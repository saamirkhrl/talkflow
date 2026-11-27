import { CloudOff, Cpu, Mic, TextCursorInput, Unlink } from "lucide-react";
import { ForOs } from "./visitor";

const YOUR_COMPUTER = <ForOs mac="Mac" windows="computer" />;

const FACTS: [React.ReactNode, string][] = [
  [<>Runs on your {YOUR_COMPUTER}</>, "Whisper recognizes your speech on your own processor."],
  ["No cloud, no account", "No sign-in or analytics, and it works offline. Online, it only checks for updates and counts installs, anonymously."],
  ["Audio is never saved", "Held in memory, never written to disk."],
  ["Open source", "Every line is public, MIT licensed."],
];

const STEPS: { icon: typeof Mic; label: React.ReactNode }[] = [
  { icon: Mic, label: "Your voice" },
  { icon: Cpu, label: <>Speech engine on your {YOUR_COMPUTER}</> },
  { icon: TextCursorInput, label: "Text at your cursor" },
];

export function Privacy() {
  return (
    <section id="privacy" className="px-3 sm:px-4">
      <div className="mx-auto max-w-[1360px] rounded-[clamp(28px,4vw,48px)] bg-ink px-gutter py-[clamp(56px,7vw,96px)] text-paper">
        <h2 className="max-w-[13ch] font-serif text-[clamp(40px,6vw,80px)] leading-[0.98] font-normal tracking-[-0.025em]">
          Your voice never leaves your {YOUR_COMPUTER}.
        </h2>

        {/* Where your audio goes: voice, engine and cursor boxed together, and a broken line out to the cloud it never reaches. */}
        <div className="mt-[clamp(32px,4vw,56px)] flex flex-col items-center [--pad:32px] [--tile:64px] md:flex-row md:items-start md:[--pad:48px] md:[--tile:76px] lg:[--tile:96px]">
          <div className="grid w-full grid-cols-3 gap-x-2 rounded-[clamp(20px,2.5vw,32px)] border border-paper/15 px-3 py-(--pad) md:flex-1 md:px-4">
            {STEPS.map(({ icon: Icon, label }, i) => (
              <div key={i} className="relative flex flex-col items-center gap-4 text-center">
                {i > 0 && (
                  <span
                    aria-hidden="true"
                    className="absolute top-[calc(var(--tile)/2)] right-[calc(50%+var(--tile)/2+20px)] left-[calc(-50%+var(--tile)/2+20px)] hidden h-px bg-paper/25 md:block"
                  />
                )}
                <span className="grid size-(--tile) place-items-center rounded-[28%] bg-paper/8 ring-1 ring-paper/10">
                  <Icon className="size-[42%]" strokeWidth={1.25} aria-hidden="true" />
                </span>
                <span className="max-w-[18ch] text-[13px] leading-snug text-paper/85 md:text-[14px] lg:max-w-none lg:whitespace-nowrap">
                  {label}
                </span>
              </div>
            ))}
          </div>

          {/* A snapped cable: two solid ends that stop short, with a broken link where they would meet. */}
          <span
            aria-hidden="true"
            className="flex h-24 flex-col items-center justify-center gap-2 text-fog md:mt-[calc(var(--pad)+1px+var(--tile)/2)] md:h-0 md:w-[clamp(96px,10vw,160px)] md:flex-row md:px-3"
          >
            <span className="w-px flex-1 bg-linear-to-b from-paper/40 to-paper/10 md:h-px md:w-auto md:bg-linear-to-r" />
            <Unlink className="size-6 flex-none rotate-90 md:rotate-0" strokeWidth={1.5} />
            <span className="w-px flex-1 bg-linear-to-t from-paper/40 to-paper/10 md:h-px md:w-auto md:bg-linear-to-l" />
          </span>

          <div className="flex flex-col items-center gap-4 text-center text-fog md:pt-[calc(var(--pad)+1px)]">
            <span className="grid size-(--tile) place-items-center rounded-[28%] border border-dashed border-paper/25">
              <CloudOff className="size-[42%]" strokeWidth={1.25} aria-hidden="true" />
            </span>
            <span className="text-[13px] leading-snug md:text-[14px]">No cloud</span>
          </div>
        </div>

        <div className="mt-[clamp(32px,4vw,56px)] grid gap-x-10 gap-y-6 sm:grid-cols-2 lg:grid-cols-4">
          {FACTS.map(([title, body]) => (
            <div key={body} className="border-t border-paper/15 pt-4">
              <h3 className="text-[17px] font-semibold">{title}</h3>
              <p className="mt-1.5 text-[15px] text-fog">{body}</p>
            </div>
          ))}
        </div>
      </div>
    </section>
  );
}
