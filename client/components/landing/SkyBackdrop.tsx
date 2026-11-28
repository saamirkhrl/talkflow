import { preload } from "react-dom";

// A 32 px copy of the scene, inlined so the very first paint already shows it
// instead of a flat blue.
const PREVIEW = "data:image/webp;base64,UklGRuYAAABXRUJQVlA4INoAAACQBgCdASogABIAPrVKnkmnJCKhMAgA4BaJbACdMoR6d96bDOOWUACFs4NqMTs5XxrcimJyGU5lTbm5C1oAAPaxxN/ndm1aMmxgDPBsXrpvKXmb4rvzPMekybSBf0+M1/Y3qVNs2oHBO3vbYokmYR7tmCbTOQBFCXkAHepPZnMBSol1TqQq8QaIUzM83el+L6tR0OQTpwNBTuA7HVTgqeJg/nd7+rv0X+dftZsBfWwbFI8rYy3Q67hmigotFgpmZ8I4c5106tyKhXJXpoqFclepJwu4bk4XflAAAA==";

// Runs as soon as the parser reaches it, before React loads: the full image
// stays hidden until it has downloaded and decoded, then fades in over the
// preview in one piece instead of painting in halves.
const REVEAL = `(function(){var i=document.getElementById("sky");if(!i)return;var s=function(){i.dataset.ready=""};var d=function(){i.decode?i.decode().then(s,s):s()};i.complete&&i.naturalWidth?d():i.addEventListener("load",d,{once:true})})()`;

// The plush scene behind every page, fixed to the window. It is static, so
// the glass panels can use a pre-blurred copy of it (see .glass in
// globals.css) instead of blurring it live on every scroll frame.
export function SkyBackdrop() {
  preload("/hero/sky-2400.webp", {
    as: "image",
    fetchPriority: "high",
    imageSrcSet: "/hero/sky-1200.webp 1200w, /hero/sky-2400.webp 2400w",
    imageSizes: "100vw",
  });
  preload("/hero/sky-blur.webp", { as: "image" });

  return (
    <div
      aria-hidden="true"
      className="sky-size pointer-events-none fixed inset-0 -z-10 overflow-hidden"
      style={{ backgroundImage: `url(${PREVIEW})` }}
    >
      {/* eslint-disable-next-line @next/next/no-img-element */}
      <img
        id="sky"
        src="/hero/sky-2400.webp"
        srcSet="/hero/sky-1200.webp 1200w, /hero/sky-2400.webp 2400w"
        sizes="100vw"
        alt=""
        fetchPriority="high"
        suppressHydrationWarning
        className="absolute top-0 left-1/2 h-auto w-full min-w-[calc(100svh*1.78)] max-w-none -translate-x-1/2 opacity-0 transition-opacity duration-300 data-ready:opacity-100"
      />
      <script dangerouslySetInnerHTML={{ __html: REVEAL }} />
      <noscript>
        <style>{"#sky{opacity:1}"}</style>
      </noscript>
    </div>
  );
}
