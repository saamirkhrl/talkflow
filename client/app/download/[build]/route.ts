import { redirect } from "next/navigation";
import { BUILDS, buildUrl, type BuildId } from "@/components/landing/content";

// talkflow.live/download/<build> -> the newest release asset for that build.
// A build that isn't published yet goes to its OS's download page instead,
// which says so. Anything else goes to the Mac page.
export async function GET(_request: Request, { params }: { params: Promise<{ build: string }> }) {
  const { build: requested } = await params;
  // Links to the Arm build, which was never separate from the x64 one for the user, still work.
  const build = requested === "windows-arm64" ? "windows-x64" : requested;
  if (!(build in BUILDS)) redirect("/download/mac");
  const id = build as BuildId;
  if (!BUILDS[id].available) redirect(`/download/${BUILDS[id].os}`);
  redirect(buildUrl(id));
}
