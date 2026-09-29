import { CloudOff, Cpu, Mic } from "lucide-react";
import { cn } from "@/lib/cn";
import { Blueprint, labelClass, Numbered, Section } from "./primitives";

const FACTS = [
  ["The model runs locally", "The speech model ships inside the app and runs on your own processor."],
  ["There is no server", "No backend, no account, no sign-in. There's nothing for your audio to be sent to."],
  ["Nothing is recorded", "Audio lives in memory while you speak, then it's gone. Only your word counts are kept, on your machine."],
  ["Works with Wi-Fi off", "On a plane, on a train, air-gapped. Turn off the network and it works exactly the same."],
];

const NODE = "flex flex-[1_1_120px] flex-col items-center gap-2.5 text-center text-[15px]";
const NODE_ICON = "grid size-16 place-items-center border";
const LINK = "h-px min-w-6 flex-[0_1_56px] bg-ink opacity-50";

export function Privacy() {
  return (
    <Section id="privacy" index="03" title="Privacy">
      <h2 className="mb-5 max-w-[14ch] font-display text-[clamp(40px,6vw,80px)] leading-[.98] font-normal tracking-[-0.02em]">
        Your voice stays on your machine.
      </h2>
      <p className="mb-14 max-w-[52ch] text-[18px] text-muted">
        Not &quot;encrypted in transit&quot;. Not &quot;deleted after 30 days&quot;. It simply never goes anywhere, because
        there&apos;s nowhere for it to go.
      </p>

      <div className="mb-16 flex flex-wrap items-center gap-y-7">
        <Blueprint className="flex-[1_1_560px] border-accent px-[clamp(20px,3vw,40px)] pt-10 pb-8">
          <span className={cn(labelClass, "absolute -top-2.5 left-6 bg-bg px-2.5 text-ink-accent")}>Your computer</span>
          <div className="flex flex-wrap items-center justify-between gap-4">
            <div className={NODE}>
              <span className={cn(NODE_ICON, "border-divider")}>
                <Mic size={26} strokeWidth={1.5} aria-hidden="true" />
              </span>
              Your voice
            </div>
            <span aria-hidden="true" className={LINK} />
            <div className={NODE}>
              <span className={cn(NODE_ICON, "border-accent text-ink-accent")}>
                <Cpu size={26} strokeWidth={1.5} aria-hidden="true" />
              </span>
              On-device speech model
            </div>
            <span aria-hidden="true" className={LINK} />
            <div className={NODE}>
              <span className={cn(NODE_ICON, "border-divider font-heading text-[24px]")}>Aa</span>
              Text at your cursor
            </div>
          </div>
        </Blueprint>

        <div className="flex flex-none items-center">
          <span aria-hidden="true" className="w-12 border-t border-dashed border-divider" />
          <span aria-hidden="true" className="mx-1 h-[22px] w-px rotate-20 bg-ink opacity-50" />
          <span aria-hidden="true" className="w-7 border-t border-dashed border-divider" />
          <div className="flex flex-col items-center gap-2.5 pr-3 pl-4 text-[14px] text-muted">
            <CloudOff size={40} strokeWidth={1.5} aria-hidden="true" />
            No server
          </div>
        </div>
      </div>

      <div className="grid grid-cols-1 gap-x-[clamp(24px,3vw,44px)] gap-y-9 min-[600px]:grid-cols-2 min-[1080px]:grid-cols-4">
        {FACTS.map(([title, body], i) => (
          <Numbered key={title} index={String(i + 1).padStart(2, "0")}>
            <h3 className="mt-1.5 mb-2 text-[23px]">{title}</h3>
            <p className="text-[15px] text-muted">{body}</p>
          </Numbered>
        ))}
      </div>
    </Section>
  );
}
