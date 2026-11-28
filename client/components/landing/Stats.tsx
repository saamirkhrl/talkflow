import Image from "next/image";
import { SectionTitle } from "./primitives";
import { Wallpaper } from "./Wallpaper";

export function Stats() {
  return (
    <section className="mx-auto max-w-[1200px] px-gutter py-[clamp(56px,7vw,96px)]">
      <div className="grid items-end gap-x-16 gap-y-8 lg:grid-cols-2">
        <SectionTitle className="max-w-[14ch]">See how much you didn&apos;t type.</SectionTitle>
        <p className="max-w-[44ch] text-[18px] text-graphite lg:justify-self-end">
          Click the talkflow icon in the menu bar to open Home and see your words, speed, streak and the typing time
          you&apos;ve saved. It&apos;s worked out on your Mac and stays there.
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
          {/* The app's Home screen, rendered from the app at 2x (1040 x 680 pt). */}
          <Image
            src="/app/home-light.webp"
            width={1040}
            height={680}
            unoptimized
            className="h-auto w-full max-w-[880px] rounded-[12px] shadow-[0_30px_70px_-20px_rgb(0_0_0/0.55)] ring-1 ring-black/10"
            alt="The talkflow Home screen: 45,000 total words dictated, 1,240 words today, 142 wpm, a 51-day streak and 13 hours 28 minutes saved, with today's progress, a chart of the last 30 days and a year of activity."
          />
        </div>
      </figure>
    </section>
  );
}
