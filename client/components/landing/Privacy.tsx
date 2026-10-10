import { CloudOff, Cpu, Mic, TextCursorInput } from "lucide-react";
import { cn } from "@/lib/cn";
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
  { icon: CloudOff, label: "No cloud" },
];

export function Privacy() {
  return (
    <section id="privacy" className="px-3 sm:px-4">
      <div className="mx-auto max-w-[1360px] rounded-[clamp(28px,4vw,48px)] bg-ink px-gutter py-[clamp(56px,7vw,96px)] text-paper">
        <h2 className="max-w-[13ch] font-serif text-[clamp(40px,6vw,80px)] leading-[0.98] font-normal tracking-[-0.025em]">
          Your voice never leaves your {YOUR_COMPUTER}.
        </h2>

        {/* Where your audio goes, across the section: four equal columns, an icon tile over a short label, joined by lines. */}
        <div className="mt-[clamp(32px,4vw,56px)] grid grid-cols-2 gap-y-10 rounded-[clamp(20px,2.5vw,32px)] border border-paper/15 px-4 py-10 [--tile:76px] md:grid-cols-4 md:py-12 lg:[--tile:96px]">
          {STEPS.map(({ icon: Icon, label }, i) => {
            const cloud = i === STEPS.length - 1;
            return (
              <div key={i} className="relative flex flex-col items-center gap-4 text-center">
                {i > 0 && !cloud && (
                  <span
                    aria-hidden="true"
                    className="absolute top-[calc(var(--tile)/2)] right-[calc(50%+var(--tile)/2+20px)] left-[calc(-50%+var(--tile)/2+20px)] hidden h-px bg-paper/25 md:block"
                  />
                )}
                <span
                  className={cn(
                    "grid size-(--tile) place-items-center rounded-[28%]",
                    cloud ? "border border-dashed border-paper/25 text-fog" : "bg-paper/8 ring-1 ring-paper/10",
                  )}
                >
                  <Icon className="size-[42%]" strokeWidth={1.25} aria-hidden="true" />
                </span>
                <span className={cn("max-w-[18ch] text-[14px] leading-snug lg:max-w-none lg:whitespace-nowrap", cloud ? "text-fog" : "text-paper/85")}>{label}</span>
              </div>
            );
          })}
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
