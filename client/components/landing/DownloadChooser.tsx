"use client";

import { Download } from "lucide-react";
import Link from "next/link";
import { useEffect, useState } from "react";
import { cn } from "@/lib/cn";
import { BUILDS, INSTALL_SCRIPT_PATH, WINDOWS_AVAILABLE, type BuildId } from "./content";

type Os = "mac" | "windows";
type Arch = "arm" | "x86" | null;

const CHOICES: Record<Os, [BuildId, BuildId]> = {
  mac: ["mac-apple-silicon", "mac-intel"],
  windows: ["windows-x64", "windows-arm64"],
};
const ARCH_OF: Record<BuildId, Arch> = {
  "mac-apple-silicon": "arm",
  "mac-intel": "x86",
  "windows-x64": "x86",
  "windows-arm64": "arm",
};

// Best guess at this computer's processor, or null when the browser won't
// say. Chromium reports it directly; elsewhere the WebGL renderer names the
// chip on most Macs ("Apple M2"), but Safari reports only "Apple GPU".
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

const HOW_TO_CHECK: Record<Os, React.ReactNode> = {
  mac: (
    <>
      Not sure? Open the Apple menu and choose <strong className="font-medium text-ink">About This Mac</strong>. If it
      says <em>Chip: Apple M1</em> (or M2, M3, M4...), choose Apple Silicon. If it says <em>Processor</em> with
      Intel in the name, choose Intel.
    </>
  ),
  windows: (
    <>
      Not sure? Open <strong className="font-medium text-ink">Settings &gt; System &gt; About</strong> and look at{" "}
      <em>System type</em>. &quot;x64-based processor&quot; means x64; &quot;ARM-based processor&quot; means Arm.
    </>
  ),
};

// The page a Download button leads to: pick the build for this computer.
export function DownloadChooser({ os }: { os: Os }) {
  const [arch, setArch] = useState<Arch>(null);
  useEffect(() => {
    detectArch().then(setArch);
  }, []);

  const name = os === "mac" ? "Mac" : "Windows";
  const ready = os === "mac" || WINDOWS_AVAILABLE;

  return (
    <main className="px-gutter pt-32 pb-20 sm:pt-40 sm:pb-28">
      <div className="mx-auto max-w-[760px]">
        <h1 className="font-serif text-[clamp(40px,6vw,64px)] leading-[1.02] font-normal tracking-[-0.02em]">
          {ready ? `Download talkflow for ${name}` : `talkflow for ${name} is coming soon`}
        </h1>
        <p className="mt-4 max-w-[52ch] text-[18px] text-graphite">
          {ready
            ? `Choose the version for your ${name === "Mac" ? "Mac" : "PC"}.`
            : "The Windows version is being built. Check back soon, or use talkflow on a Mac today."}
        </p>

        <div className="mt-10 grid gap-4 sm:grid-cols-2">
          {CHOICES[os].map((id) => {
            const build = BUILDS[id];
            const recommended = ready && arch !== null && ARCH_OF[id] === arch;
            const body = (
              <>
                <span className="flex items-center justify-between gap-3">
                  <span className="font-serif text-[30px] leading-none">{build.label}</span>
                  {recommended && (
                    <span className="whitespace-nowrap rounded-full bg-ink px-2.5 py-1 text-[12px] font-medium text-paper">
                      Recommended for this {os === "mac" ? "Mac" : "PC"}
                    </span>
                  )}
                </span>
                <span className="mt-3 block text-[15px] text-graphite">{build.detail}</span>
                <span className={cn("mt-6 inline-flex items-center gap-2 text-[15px] font-medium", ready ? "text-ink" : "text-graphite")}>
                  {ready ? (
                    <>
                      <Download size={16} aria-hidden="true" /> Download for {build.label}
                    </>
                  ) : (
                    "Coming soon"
                  )}
                </span>
              </>
            );
            const box = cn(
              "block rounded-3xl border p-6 text-left transition-colors",
              recommended ? "border-ink" : "border-line",
              ready ? "hover:bg-ink/[0.03]" : "cursor-default opacity-70",
            );
            return ready ? (
              // A plain link: the route redirects to the release file.
              <a key={id} href={`/download/${id}`} className={box}>
                {body}
              </a>
            ) : (
              <div key={id} aria-disabled="true" className={box}>
                {body}
              </div>
            );
          })}
        </div>

        {ready && <p className="mt-6 max-w-[64ch] text-[15px] leading-[1.6] text-graphite">{HOW_TO_CHECK[os]}</p>}
        {os === "windows" && ready && (
          <p className="mt-4 max-w-[64ch] text-[15px] leading-[1.6] text-graphite">
            The installer is not code-signed yet, so Windows may say it &quot;protected your PC&quot;. Click{" "}
            <strong className="font-medium text-ink">More info</strong>, then <strong className="font-medium text-ink">Run anyway</strong>.
          </p>
        )}
        {os === "mac" && (
          <p className="mt-4 max-w-[64ch] text-[15px] leading-[1.6] text-graphite">
            Or install from Terminal: <code className="rounded bg-mist px-1.5 py-0.5 font-mono text-[13px] text-ink">curl -fsSL https://talkflow.live{INSTALL_SCRIPT_PATH} | bash</code>
          </p>
        )}
        <p className="mt-8 text-[15px]">
          <Link href={os === "mac" ? "/download/windows" : "/download/mac"} className="underline decoration-1 underline-offset-[3px] hover:decoration-2">
            {os === "mac" ? "Looking for Windows?" : "Download for Mac instead"}
          </Link>
        </p>
      </div>
    </main>
  );
}
