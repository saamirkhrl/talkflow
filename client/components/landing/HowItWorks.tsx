import { RecDot, SectionTitle, Waveform } from "./primitives";

const STEP = "flex flex-col gap-5 border-t border-line pt-6";
const STAGE = "flex h-36 items-center justify-center rounded-3xl bg-mist px-6";

export function HowItWorks() {
  return (
    <section className="mx-auto max-w-[1200px] px-gutter py-[clamp(72px,10vw,136px)]">
      <SectionTitle className="max-w-[16ch]">Three moves, no typing.</SectionTitle>
      <ol className="mt-14 grid gap-x-8 gap-y-12 md:grid-cols-3">
        <li className={STEP}>
          <div className={STAGE}>
            <kbd className="grid h-[68px] w-[76px] place-items-end rounded-[14px] border border-line border-b-[5px] bg-paper p-2.5 font-sans text-[22px] text-ink shadow-[0_1px_0_rgba(31,30,34,0.05)]">
              fn
            </kbd>
          </div>
          <div>
            <h3 className="text-[19px] font-semibold">1. Hold fn</h3>
            <p className="mt-1.5 text-graphite">The Globe key in the corner of your keyboard. talkflow starts listening.</p>
          </div>
        </li>
        <li className={STEP}>
          <div className={STAGE}>
            <span className="flex h-14 items-center gap-3 rounded-full bg-ink px-5 text-paper">
              <RecDot />
              <Waveform bars={14} height={22} />
            </span>
          </div>
          <div>
            <h3 className="text-[19px] font-semibold">2. Talk normally</h3>
            <p className="mt-1.5 text-graphite">Your words appear as you speak. Say &quot;comma&quot; or &quot;new paragraph&quot; when you want them.</p>
          </div>
        </li>
        <li className={STEP}>
          <div className={STAGE}>
            <p className="max-w-[22ch] text-left text-[17px] leading-snug">
              Can we move standup to Thursday?
              <span aria-hidden="true" className="ml-0.5 inline-block h-[1.1em] w-0.5 translate-y-[0.2em] animate-blink bg-ink" />
            </p>
          </div>
          <div>
            <h3 className="text-[19px] font-semibold">3. Let go</h3>
            <p className="mt-1.5 text-graphite">talkflow finishes the last words and fixes punctuation. The text is already where your cursor was.</p>
          </div>
        </li>
      </ol>
    </section>
  );
}
