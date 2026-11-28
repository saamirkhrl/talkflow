import { RecDot, SectionTitle, Waveform } from "./primitives";
import { LetGoDemo } from "./LetGoDemo";

const STEP = "flex flex-col gap-5";
const STAGE = "flex h-36 items-center justify-center rounded-3xl bg-mist px-6";
const KEY =
  "grid h-[68px] min-w-[76px] place-items-end rounded-[14px] border border-black/10 border-b-[5px] bg-white p-2.5 font-sans text-[22px] text-[#0b1f66] shadow-[0_10px_24px_-12px_rgb(3_12_60/0.7)]";

export function HowItWorks() {
  return (
    <section className="mx-auto max-w-[1200px] px-gutter pt-[clamp(48px,6vw,88px)] pb-[clamp(56px,7vw,96px)]">
      <SectionTitle className="max-w-[16ch]">Three moves, no typing.</SectionTitle>
      <ol className="mt-14 grid gap-x-8 gap-y-12 md:grid-cols-3">
        <li className={STEP}>
          <div className={STAGE}>
            <kbd className={KEY}>fn</kbd>
          </div>
          <div>
            <h3 className="text-[19px] font-semibold">
              1. Hold fn
            </h3>
            <p className="mt-1.5 text-graphite">
              The Globe key in the corner of your keyboard. talkflow starts listening.
            </p>
          </div>
        </li>
        <li className={STEP}>
          <div className={STAGE}>
            <span className="flex h-14 items-center gap-3 rounded-full px-5 bg-[#1f1e22] text-white shadow-[0_12px_28px_-12px_rgb(0_0_0/0.6)]">
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
            <LetGoDemo />
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
