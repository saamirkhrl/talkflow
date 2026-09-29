import { APP_LOGOS } from "./brand-logos.generated";
import { BrandLogo } from "./BrandLogo";

type App = (typeof APP_LOGOS)[number];

const half = Math.ceil(APP_LOGOS.length / 2);
const ROWS: App[][] = [APP_LOGOS.slice(0, half), APP_LOGOS.slice(half)];

const FADE =
  "linear-gradient(to right, transparent, #000 8%, #000 92%, transparent)";

function Item({ app }: { app: App }) {
  return (
    <li className="flex shrink-0 items-center gap-3">
      <BrandLogo logo={app} className="size-9 shrink-0" />
      <span className="whitespace-nowrap font-sans text-[15px] text-graphite">
        {app.name}
      </span>
    </li>
  );
}

export function LogoMarquee() {
  return (
    <div className="group relative w-full overflow-hidden">
      {/* Screen readers: every app once. */}
      <ul className="sr-only">
        {APP_LOGOS.map((a) => (
          <li key={a.name}>{a.name}</li>
        ))}
      </ul>

      {/* Reduced-motion layout: the same logos, standing still. */}
      <ul aria-hidden="true" className="hidden flex-wrap justify-center gap-x-10 gap-y-7 px-4 motion-reduce:flex">
        {APP_LOGOS.map((a) => (
          <Item key={a.name} app={a} />
        ))}
      </ul>

      <div
        aria-hidden="true"
        className="flex flex-col gap-8 motion-reduce:hidden"
        style={{ maskImage: FADE, WebkitMaskImage: FADE }}
      >
        {ROWS.map((row, r) => (
          <div
            key={r}
            className="flex w-max [animation:marquee_80s_linear_infinite] group-focus-within:[animation-play-state:paused] group-hover:[animation-play-state:paused]"
            style={r === 1 ? { animationDirection: "reverse" } : undefined}
          >
            {[0, 1].map((copy) => (
              <ul
                key={copy}
                aria-hidden={copy === 1 ? true : undefined}
                className="flex w-max shrink-0 items-center gap-14 pr-14"
              >
                {row.map((a) => (
                  <Item key={a.name} app={a} />
                ))}
              </ul>
            ))}
          </div>
        ))}
      </div>
    </div>
  );
}
