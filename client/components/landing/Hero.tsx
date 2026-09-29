import { MEDIA } from "./content";
import { DownloadCta } from "./DownloadCta";
import { HeroMock } from "./HeroMock";
import { ImageSlot, LiveDot } from "./primitives";

export function Hero() {
  return (
    <section className="pt-[clamp(56px,9vw,112px)] pb-[clamp(72px,9vw,120px)]">
      <div className="grid grid-cols-[repeat(auto-fit,minmax(min(100%,440px),1fr))] items-end gap-x-[clamp(32px,6vw,96px)] gap-y-10">
        <h1 className="font-display text-[clamp(48px,7.4vw,100px)] leading-[.98] font-normal tracking-[-0.025em]">
          Talk to your computer, <em>for free.</em>
        </h1>
        <div className="flex max-w-[460px] flex-col gap-7">
          <p className="text-[19px] leading-[1.5] text-muted">
            TalkFlow turns your voice into text in any app, instantly. Free, private, and runs entirely on your device.
          </p>
          <DownloadCta variant="hero" />
          <p className="text-[14px] tracking-[.04em] text-muted">Free · No account · Works offline</p>
        </div>
      </div>

      {MEDIA.heroRecording ? (
        <figure data-reveal className="mt-[clamp(56px,7vw,88px)] flex flex-col gap-3.5">
          <div className="relative aspect-[16/10] w-full overflow-hidden rounded-[22px] border border-divider bg-surface shadow-lg">
            <ImageSlot
              src={MEDIA.heroRecording}
              alt="A coding agent session dictated with TalkFlow"
              placeholder="Drop your agent-session recording (GIF)"
              sizes="(max-width: 1200px) 100vw, 1056px"
            />
          </div>
          <figcaption className="flex items-center gap-2.5 text-[14px] text-muted">
            <LiveDot />A real agent session, dictated with TalkFlow. No audio, just the transcription as it happened.
          </figcaption>
        </figure>
      ) : (
        <HeroMock />
      )}
    </section>
  );
}
