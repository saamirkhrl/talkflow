"use client";

import { Download, Lock, MousePointer2 } from "lucide-react";
import { type ReactNode, useEffect, useState } from "react";
import { cn } from "@/lib/cn";
import { BUILDS, REPO_URL, type BuildId } from "./content";
import { InstallCommand } from "./DownloadCta";

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
export function DownloadChooser() {
  const [arch, setArch] = useState<Arch>(null);
  useEffect(() => {
    detectArch().then(setArch);
  }, []);

  return (
    // At least a screen tall, so the footer's big wordmark waits below the fold instead of peeking up under the choices.
    <main className="min-h-svh px-3 pt-28 pb-20 sm:px-4 sm:pt-32 sm:pb-28">
      <div className="glass mx-auto max-w-[860px] px-[clamp(24px,6vw,72px)] py-[clamp(40px,6vw,72px)]">
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

        <AfterDownload />
      </div>
    </main>
  );
}

// talkflow is not notarized, so macOS blocks the first open. Since macOS 15
// right-click > Open no longer gets past that; the way through is Open Anyway
// in Privacy & Security, which shows for about an hour after the blocked open.
const STEPS: ReactNode[] = [
  "Open the downloaded file and drag talkflow into Applications.",
  <>
    Open talkflow. macOS will say it can&apos;t be opened. Click <strong className="font-semibold">Done</strong>, not Move
    to Trash.
  </>,
  <>
    Open <strong className="font-semibold">System Settings</strong>, then{" "}
    <strong className="font-semibold">Privacy &amp; Security</strong>, scroll down to Security, and click{" "}
    <strong className="font-semibold">Open Anyway</strong> next to talkflow. Enter your Mac password.
  </>,
  "Open talkflow again. Setup takes it from there.",
];

function AfterDownload() {
  return (
    <section aria-labelledby="after-download" className="mt-14 border-t border-line pt-12">
      <h2 id="after-download" className="font-serif text-[clamp(28px,4vw,38px)] leading-[1.1] font-normal tracking-[-0.01em]">
        After you download
      </h2>
      <p className="mt-3 max-w-[60ch] text-[16px] leading-relaxed text-graphite">
        talkflow is a free, open-source app that isn&apos;t distributed through Apple, so macOS asks you to confirm it once.
        Every line of code is{" "}
        <a href={REPO_URL} target="_blank" rel="noopener noreferrer" className="text-ink underline underline-offset-4">
          on GitHub
        </a>
        .
      </p>

      <div className="mt-8 grid items-center gap-8 md:grid-cols-[1fr_minmax(0,330px)]">
        <ol className="flex flex-col gap-5">
          {STEPS.map((step, index) => (
            <li key={index} className="flex gap-4 text-[16px] leading-relaxed">
              <span
                aria-hidden="true"
                className="flex size-7 flex-none items-center justify-center rounded-full border border-line font-serif text-[15px]"
              >
                {index + 1}
              </span>
              <span className="pt-0.5">{step}</span>
            </li>
          ))}
        </ol>
        <OpenAnywayIllustration />
      </div>

      <div className="mt-10 flex flex-col gap-3">
        <p className="text-[15px] text-graphite">Or install from Terminal, which skips the warning:</p>
        <div className="min-w-0 max-w-full">
          <InstallCommand />
        </div>
      </div>
    </section>
  );
}

// A drawn stand-in for the Security row in Privacy & Security, in the site's
// own style (not a screenshot): the blocked-app line and its Open Anyway button.
function OpenAnywayIllustration() {
  return (
    <figure
      role="img"
      aria-label="In Privacy & Security, under Security: talkflow was blocked, with an Open Anyway button next to it."
      className="relative mx-auto w-full max-w-[330px] select-none rounded-3xl bg-white p-5 text-[#0b1f66] shadow-[0_18px_50px_rgb(4_20_80/0.35)]"
    >
      <p className="text-[12px] font-semibold tracking-[0.02em] text-[#56628f]">Security</p>
      <div className="mt-3 flex items-center gap-3 rounded-2xl bg-[#f1f3fb] p-3.5">
        <span className="flex size-9 flex-none items-center justify-center rounded-xl bg-[#0b1f66] text-white">
          <Lock size={16} aria-hidden="true" />
        </span>
        <span className="min-w-0 flex-1 text-[13px] leading-snug">
          &ldquo;talkflow&rdquo; was blocked to protect your Mac.
        </span>
      </div>
      <div className="relative mt-3 flex justify-end">
        <span className="rounded-full bg-[#0a41bf] px-4 py-1.5 text-[13px] font-medium text-white">Open Anyway</span>
        <MousePointer2
          size={22}
          aria-hidden="true"
          className="absolute -bottom-4 right-6 fill-white text-[#0b1f66] drop-shadow"
        />
      </div>
    </figure>
  );
}
