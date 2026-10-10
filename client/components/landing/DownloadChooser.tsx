"use client";

import { Download } from "lucide-react";
import { useEffect, useState } from "react";
import { cn } from "@/lib/cn";
import { BUILDS, WINDOWS_AVAILABLE, WINDOWS_DOWNLOAD_PATH, type BuildId } from "./content";

type Arch = "arm" | "x86" | null;

const CHOICES: BuildId[] = ["mac-apple-silicon", "mac-intel"];
const ARCH_OF: Partial<Record<BuildId, Arch>> = {
  "mac-apple-silicon": "arm",
  "mac-intel": "x86",
};

// Best guess at this Mac's processor, or null when the browser won't say.
// Chromium reports it directly; elsewhere the WebGL renderer names the chip
// on most Macs ("Apple M2"), but Safari reports only "Apple GPU".
async function detectArch(): Promise<Arch> {
  const nav = navigator as Navigator & {
    userAgentData?: { getHighEntropyValues?: (hints: string[]) => Promise<{ architecture?: string }> };
  };
  try {
    const hints = await nav.userAgentData?.getHighEntropyValues?.(["architecture"]);
    if (hints?.architecture === "arm") return "arm";
    if (hints?.architecture === "x86") return "x86";
  } catch {}
  try {
    const gl = document.createElement("canvas").getContext("webgl");
    const ext = gl?.getExtension("WEBGL_debug_renderer_info");
    const renderer = ext && gl ? String(gl.getParameter(ext.UNMASKED_RENDERER_WEBGL)) : "";
    if (/Apple M\d/.test(renderer)) return "arm";
    if (/Intel|AMD|Radeon|NVIDIA/i.test(renderer)) return "x86";
  } catch {}
  return null;
}

// The Mac download page: Apple Silicon or Intel, with the chips each is for.
// (Windows has one build, so its Download buttons download it directly.)
export function DownloadChooser() {
  const [arch, setArch] = useState<Arch>(null);
  useEffect(() => {
    detectArch().then(setArch);
  }, []);

  return (
    // At least a screen tall, so the footer's big wordmark waits below the fold instead of peeking up under the choices.
    <main className="min-h-svh px-gutter pt-32 pb-20 sm:pt-40 sm:pb-28">
      <div className="mx-auto max-w-[760px]">
        <h1 className="font-serif text-[clamp(40px,6vw,64px)] leading-[1.02] font-normal tracking-[-0.02em]">
          Download talkflow for Mac
        </h1>

        <div className="mt-10 grid gap-4 sm:grid-cols-2">
          {CHOICES.map((id) => {
            const build = BUILDS[id];
            const recommended = arch !== null && ARCH_OF[id] === arch;
            return (
              // A plain link: the route redirects to the release file.
              <a
                key={id}
                href={`/download/${id}`}
                className={cn(
                  "flex flex-col rounded-3xl border p-6 text-left transition-colors hover:bg-ink/[0.03]",
                  recommended ? "border-ink" : "border-line",
                )}
              >
                <span className="flex items-center justify-between gap-3">
                  <span className="font-serif text-[30px] leading-none">{build.label}</span>
                  {recommended && (
                    <span className="whitespace-nowrap rounded-full bg-ink px-2.5 py-1 text-[12px] font-medium text-paper">
                      Recommended
                    </span>
                  )}
                </span>
                <span className="mt-4 flex flex-wrap gap-1.5">
                  {build.chips.map((chip) => (
                    <span key={chip} className="rounded-full border border-line px-2.5 py-0.5 text-[13px] text-graphite">
                      {chip}
                    </span>
                  ))}
                </span>
                <span className="mt-auto inline-flex items-center gap-2 pt-6 text-[15px] font-medium text-ink">
                  <Download size={16} aria-hidden="true" /> Download
                </span>
              </a>
            );
          })}
        </div>

        {WINDOWS_AVAILABLE && (
          <p className="mt-8 text-[15px]">
            <a href={WINDOWS_DOWNLOAD_PATH} className="underline decoration-1 underline-offset-[3px] hover:decoration-2">
              Download for Windows instead
            </a>
          </p>
        )}
      </div>
    </main>
  );
}
