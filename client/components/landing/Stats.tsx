import Image from "next/image";
import { SectionTitle } from "./primitives";
import { ForOs } from "./visitor";
import { Wallpaper } from "./Wallpaper";

export function Stats() {
  return (
    <section className="mx-auto max-w-[1200px] px-gutter py-[clamp(72px,10vw,136px)]">
      <div className="grid items-end gap-x-16 gap-y-8 lg:grid-cols-2">
        <SectionTitle className="max-w-[14ch]">See how much you didn&apos;t type.</SectionTitle>
        <p className="max-w-[44ch] text-[18px] text-graphite lg:justify-self-end">
          <ForOs mac="Open Dashboard from the menu bar" windows="Open talkflow from the tray" /> to see your words, speed, streak
          and the typing time you&apos;ve saved. It&apos;s worked out on your <ForOs mac="Mac" windows="computer" /> and stays
          there.
        </p>
      </div>

      <figure className="mt-14">
        <div className="relative isolate grid place-items-center overflow-hidden rounded-3xl px-3 pt-8 pb-[clamp(64px,9vw,96px)] sm:pt-12">
          <Wallpaper className="-z-10" />
          {/* The Dock along the bottom, as on the Mac desktop in the app tour. */}
          <Image
            src="/app/dock.png"
            alt=""
            width={476.5}
            height={62}
            unoptimized
            className="absolute bottom-2 left-1/2 h-auto w-[min(476.5px,calc(100%-24px))] -translate-x-1/2"
          />
          {/* A screenshot of the real window, shadow included, taken at 2x: 560 x 588 pt plus the shadow. */}
          <Image
            src="/app/dashboard-dark.webp"
            width={606}
            height={634}
            unoptimized
            className="h-auto w-full max-w-[606px]"
            alt="The talkflow Dashboard window: 155,284 total words dictated, 968 words today, 145 wpm, a 62-day streak and 1 day 22 hours saved, above a grid of daily activity for the last 26 weeks."
          />
        </div>
      </figure>
    </section>
  );
}
