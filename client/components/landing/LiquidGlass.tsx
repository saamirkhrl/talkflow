"use client";

import { useEffect, useId, useMemo, useRef, useState } from "react";
import { cn } from "@/lib/cn";

// Real refraction, not a blur. The button is modelled as a slab of glass
// with a rounded (squircle) bezel. For each distance from the edge we trace a
// vertical ray through that curved surface with Snell's law and measure how
// far it lands from where it entered. That 1D profile is laid around the
// rounded rectangle as a displacement map, and an SVG feDisplacementMap
// applied through backdrop-filter moves the pixels behind the button by that
// amount. A second map adds the rim highlight where the bezel faces the light.
//
// Only Chromium can use an SVG filter as a backdrop-filter. Safari and
// Firefox keep the frosted fallback.

const IOR = 1.5; // glass
const SAMPLES = 128;
const LIGHT = normalize(-0.55, -0.85); // from the top left

type Maps = { displacement: string; specular: string; scale: number };
const cache = new Map<string, Maps>();

function normalize(x: number, y: number) {
  const l = Math.hypot(x, y) || 1;
  return [x / l, y / l] as const;
}

// Convex squircle: flat on top, rolling off smoothly at the edge.
const surface = (x: number) => Math.pow(1 - Math.pow(1 - x, 4), 1 / 4);

// Lateral shift of a vertical ray at each point across the bezel (0 = outer
// edge, 1 = where the flat top begins), in px.
function refractionProfile(bezel: number, thickness: number) {
  const out = new Float32Array(SAMPLES);
  const dx = 1e-3;
  for (let i = 0; i < SAMPLES; i++) {
    const x = Math.min(i / (SAMPLES - 1), 1 - dx);
    const slope = ((surface(x + dx) - surface(x)) / dx) * (thickness / bezel);
    const incidence = Math.atan(slope); // angle between the surface normal and the ray
    const refracted = Math.asin(Math.sin(incidence) / IOR);
    const depth = surface(x) * thickness; // glass the ray travels through
    out[i] = depth * Math.tan(incidence - refracted);
  }
  return out;
}

function buildMaps(w: number, h: number, radius: number, dpr: number): Maps {
  const key = `${w}x${h}r${radius}@${dpr}`;
  const hit = cache.get(key);
  if (hit) return hit;

  const bezel = Math.max(6, Math.min(radius, h / 2, 16));
  const thickness = bezel * 2.6;
  const profile = refractionProfile(bezel, thickness);
  const max = Math.max(...profile) || 1;

  const W = Math.round(w * dpr);
  const H = Math.round(h * dpr);
  const disp = new ImageData(W, H);
  const spec = new ImageData(W, H);
  const hw = w / 2;
  const hh = h / 2;
  const r = Math.min(radius, hw, hh);
  const rim = 1.6;

  for (let py = 0; py < H; py++) {
    for (let px = 0; px < W; px++) {
      // Point relative to the centre, in CSS px.
      const x = (px + 0.5) / dpr - hw;
      const y = (py + 0.5) / dpr - hh;
      const qx = Math.abs(x) - (hw - r);
      const qy = Math.abs(y) - (hh - r);
      // Distance inside the rounded rectangle, and the outward normal there.
      let d: number;
      let nx: number;
      let ny: number;
      if (qx > 0 && qy > 0) {
        const l = Math.hypot(qx, qy) || 1;
        d = r - l;
        nx = (qx / l) * Math.sign(x);
        ny = (qy / l) * Math.sign(y);
      } else if (qx > qy) {
        d = r - qx;
        nx = Math.sign(x);
        ny = 0;
      } else {
        d = r - qy;
        nx = 0;
        ny = Math.sign(y);
      }

      const i = (py * W + px) * 4;
      let mag = 0;
      if (d >= 0 && d < bezel) {
        const t = d / bezel;
        const f = t * (SAMPLES - 1);
        const a = Math.floor(f);
        const b = Math.min(a + 1, SAMPLES - 1);
        mag = (profile[a] + (profile[b] - profile[a]) * (f - a)) / max;
      }
      // A convex lens magnifies: each pixel samples from further inward.
      disp.data[i] = 128 - nx * mag * 127;
      disp.data[i + 1] = 128 - ny * mag * 127;
      disp.data[i + 2] = 128;
      disp.data[i + 3] = 255;

      if (d >= 0 && d < rim) {
        const facing = Math.abs(nx * LIGHT[0] + ny * LIGHT[1]);
        const edge = 1 - d / rim;
        const alpha = edge * (0.25 + 0.75 * facing * facing);
        spec.data[i] = 255;
        spec.data[i + 1] = 255;
        spec.data[i + 2] = 255;
        spec.data[i + 3] = Math.round(alpha * 235);
      }
    }
  }

  const toUrl = (img: ImageData) => {
    const c = document.createElement("canvas");
    c.width = W;
    c.height = H;
    c.getContext("2d")!.putImageData(img, 0, 0);
    return c.toDataURL();
  };
  const maps = { displacement: toUrl(disp), specular: toUrl(spec), scale: max * 2 };
  cache.set(key, maps);
  return maps;
}

function supportsSvgBackdrop() {
  const brands = (navigator as Navigator & { userAgentData?: { brands: { brand: string }[] } }).userAgentData?.brands;
  if (brands) return brands.some((b) => /Chromium|Google Chrome|Microsoft Edge/.test(b.brand));
  // userAgentData only exists on https and localhost, so on a plain-http LAN
  // address fall back to the UA string. Chrome on iOS is WebKit and says
  // "CriOS", not "Chrome/", so it correctly stays on the fallback.
  return /\b(Chrome|Chromium|Edg)\/\d+/.test(navigator.userAgent);
}

// Drop inside any `relative isolate` button. It sits behind the label and
// takes the button's rounded corners. `tint` colours the glass.
export function LiquidGlass({ tint = "rgb(255 255 255 / 0.06)", className }: { tint?: string; className?: string }) {
  const ref = useRef<HTMLSpanElement>(null);
  const id = useId().replace(/:/g, "");
  const [size, setSize] = useState<{ w: number; h: number; r: number } | null>(null);

  useEffect(() => {
    const el = ref.current;
    if (!el || !supportsSvgBackdrop()) return;
    const measure = () => {
      const w = Math.round(el.offsetWidth);
      const h = Math.round(el.offsetHeight);
      if (!w || !h) return;
      const r = Math.min(parseFloat(getComputedStyle(el).borderTopLeftRadius) || 0, w / 2, h / 2);
      setSize((s) => (s && s.w === w && s.h === h && s.r === r ? s : { w, h, r }));
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // Size is only known after mount, so this never runs on the server.
  const maps = useMemo(
    () => (size ? buildMaps(size.w, size.h, size.r, Math.min(window.devicePixelRatio || 1, 2)) : null),
    [size],
  );

  const filterId = `lg-${id}`;
  const refract = maps && size;

  return (
    <span
      ref={ref}
      aria-hidden="true"
      className={cn("pointer-events-none absolute inset-0 -z-10 rounded-[inherit]", className)}
      style={{
        background: tint,
        backdropFilter: refract ? `url(#${filterId})` : "blur(10px) saturate(1.6)",
        WebkitBackdropFilter: refract ? undefined : "blur(10px) saturate(1.6)",
        boxShadow:
          "inset 0 0 0 0.5px rgb(255 255 255 / 0.35), inset 0 -10px 18px -14px rgb(255 255 255 / 0.35), 0 10px 26px -14px rgb(3 12 60 / 0.65)",
      }}
    >
      {refract && (
        <svg width="0" height="0" className="absolute" aria-hidden="true">
          <filter
            id={filterId}
            x="0"
            y="0"
            width={size.w}
            height={size.h}
            filterUnits="userSpaceOnUse"
            primitiveUnits="userSpaceOnUse"
            colorInterpolationFilters="sRGB"
          >
            <feGaussianBlur in="SourceGraphic" stdDeviation="0.4" result="soft" />
            <feImage href={maps.displacement} x="0" y="0" width={size.w} height={size.h} preserveAspectRatio="none" result="map" />
            <feDisplacementMap in="soft" in2="map" scale={maps.scale} xChannelSelector="R" yChannelSelector="G" result="bent" />
            <feColorMatrix in="bent" type="saturate" values="1.2" result="vivid" />
            <feImage href={maps.specular} x="0" y="0" width={size.w} height={size.h} preserveAspectRatio="none" result="rim" />
            <feComposite in="rim" in2="vivid" operator="over" />
          </filter>
        </svg>
      )}
    </span>
  );
}
