import { CloudOff, Cpu, Mic, TextCursorInput } from "lucide-react";
import { ForOs } from "./visitor";

const YOUR_COMPUTER = <ForOs mac="Mac" windows="computer" />;

const FACTS: [React.ReactNode, string][] = [
  [<>Runs on your {YOUR_COMPUTER}</>, "Whisper recognizes your speech on your own processor."],
  ["No cloud, no account", "No sign-in or analytics, and it works offline. Online, it only checks for updates and counts installs, anonymously."],
  ["Audio is never saved", "Held in memory, never written to disk."],
  ["Open source", "Every line is public, MIT licensed."],
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
        </div>

        {/* Where your audio goes, edge to edge: voice, the engine on your computer, your cursor, and no cloud anywhere. */}
        <div className="mt-[clamp(32px,4vw,56px)] flex flex-col gap-5 rounded-[clamp(20px,2.5vw,32px)] border border-paper/15 px-[clamp(20px,3vw,44px)] py-[clamp(20px,3vw,40px)] text-[clamp(17px,1.9vw,26px)] md:flex-row md:items-center md:gap-[clamp(16px,2vw,32px)]">
          {NODES.map(({ icon: Icon, label }, i) => (
            <div key={i} className="contents">
              {i > 0 && <span aria-hidden="true" className="hidden h-px min-w-6 flex-1 bg-paper/30 md:block" />}
              <span className="flex items-center gap-[clamp(12px,1.4vw,20px)]">
                <span className="grid size-[clamp(48px,5vw,72px)] flex-none place-items-center rounded-[clamp(14px,1.4vw,20px)] bg-paper/8">
                  <Icon className="size-[45%]" strokeWidth={1.5} aria-hidden="true" />
                </span>
                {label}
              </span>
            </div>
          ))}
          <span aria-hidden="true" className="hidden h-[clamp(32px,4vw,56px)] w-px flex-none bg-paper/20 md:block" />
          <span className="flex items-center gap-[clamp(12px,1.4vw,20px)] text-fog">
            <span className="grid size-[clamp(48px,5vw,72px)] flex-none place-items-center md:size-auto">
              <CloudOff className="size-[clamp(22px,2.2vw,32px)]" strokeWidth={1.5} aria-hidden="true" />
            </span>
            No cloud
          </span>
        </div>

        <div className="mx-auto max-w-[1072px]">
          <div className="mt-[clamp(32px,4vw,56px)] grid gap-x-10 gap-y-6 sm:grid-cols-2 lg:grid-cols-4">
            {FACTS.map(([title, body]) => (
              <div key={body} className="border-t border-paper/15 pt-4">
                <h3 className="text-[17px] font-semibold">{title}</h3>
                <p className="mt-1.5 text-[15px] text-fog">{body}</p>
              </div>
            ))}
          </div>
        </div>
      </div>
    </section>
  );
}
