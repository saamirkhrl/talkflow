import { redirect } from "next/navigation";
import { BUILDS, buildUrl, type BuildId } from "@/components/landing/content";

// Download paths of the retired Windows app. talkflow is Mac-only now; old
// links to them go to the home page instead of a 404.
const RETIRED = new Set(["windows", "windows-x64", "windows-arm64"]);

// talkflow.live/download/<build> -> the newest release file for that build,
// so the browser downloads it straight away. The Mac files are attached when
// the release is created, so GitHub's latest-release URL is always the newest
// one, worked out by GitHub when the browser asks. No lookup, nothing that can
// go stale. Anything else goes to the Mac page.
export async function GET(_request: Request, { params }: { params: Promise<{ build: string }> }) {
  const { build } = await params;
  if (RETIRED.has(build)) redirect("/");
  if (!(build in BUILDS)) redirect("/download/mac");
  redirect(buildUrl(build as BuildId));
}
