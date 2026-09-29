"use client";

import { useId } from "react";
import type { BrandSvg } from "./brand-logos.generated";

/**
 * The markup in `logo.body` is generated at build time from vetted, licensed
 * icon sets (see scripts/build-brand-logos.mjs). It never comes from user input.
 *
 * The same logo can appear several times on a page (the
 * typewriter heading), so each instance gets its own gradient and mask ids.
 * Shared ids would make every copy depend on the first one in the document,
 * which breaks masks whenever that copy is hidden.
 */
export function BrandLogo({ logo, className, title }: { logo: BrandSvg; className?: string; title?: string }) {
  const uid = useId().replace(/[^a-zA-Z0-9_-]/g, "");
  const body = logo.body.replaceAll("tfid-", `tfid-${uid}-`);
  const a11y = title ? ({ role: "img", "aria-label": title } as const) : ({ "aria-hidden": true, focusable: "false" } as const);

  return (
    <svg
      viewBox={logo.viewBox}
      xmlns="http://www.w3.org/2000/svg"
      className={className}
      {...a11y}
      dangerouslySetInnerHTML={{ __html: body }}
    />
  );
}
