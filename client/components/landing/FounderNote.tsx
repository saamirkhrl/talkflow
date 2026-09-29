import { MEDIA } from "./content";
import { Blueprint, ImageSlot } from "./primitives";

export function FounderNote() {
  return (
    <section data-reveal className="py-[clamp(64px,9vw,120px)]">
      <div className="grid max-w-[820px] grid-cols-[auto_minmax(0,1fr)] items-start gap-x-[clamp(24px,4vw,48px)] gap-y-6">
        <Blueprint className="size-[88px]">
          <ImageSlot src={MEDIA.founderAvatar} alt="Samir, creator of TalkFlow" placeholder="Photo" sizes="86px" className="p-0 text-[11px] text-muted" />
        </Blueprint>
        <div className="flex flex-col gap-6">
          <p className="font-display text-[clamp(26px,3vw,36px)] leading-[1.25] tracking-[-0.005em]">
            &quot;I built TalkFlow because I wanted it myself. I&apos;ve used it every day for 51 days and dictated over 45,000
            words. I barely touch my keyboard anymore.&quot;
          </p>
          <p className="text-[16px] text-muted">— Samir, creator of TalkFlow</p>
        </div>
      </div>
    </section>
  );
}
