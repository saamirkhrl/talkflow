import { redirect } from "next/navigation";
import { BUILDS, REPO_URL, buildUrl, type BuildId } from "@/components/landing/content";

// Paths that name an OS or an old build rather than a build id. Windows has
// one build, so /download/windows is that file, not a page. The Arm build was
// never separate from the x64 one for the user.
const ALIASES: Record<string, BuildId> = {
  windows: "windows-x64",
  "windows-arm64": "windows-x64",
};

type GithubRelease = { draft: boolean; prerelease: boolean; assets: { name: string; browser_download_url: string }[] };

// The newest published release that has this file attached. A release's
// Windows installer is attached by CI some minutes after the Mac files, and
// in that gap GitHub's releases/latest/download/<name> is a 404 page. Asked
// at most every 5 minutes; if GitHub cannot be asked, the latest-release URL.
async function newestAsset(asset: string): Promise<string | null> {
  try {
    const response = await fetch(`https://api.github.com/repos/${REPO_URL.replace("https://github.com/", "")}/releases?per_page=10`, {
      headers: { Accept: "application/vnd.github+json" },
      next: { revalidate: 300 },
    });
    if (!response.ok) return null;
    const releases = (await response.json()) as GithubRelease[];
    for (const release of releases) {
      if (release.draft || release.prerelease) continue;
      const file = release.assets.find((a) => a.name === asset);
      if (file?.browser_download_url.startsWith("https://github.com/")) return file.browser_download_url;
    }
  } catch {}
  return null;
}

// talkflow.live/download/<build> -> the newest release file for that build,
// so the browser downloads it straight away. A build that isn't published
// yet goes to the home page's download section, which says so. Anything else
// goes to the Mac page.
export async function GET(_request: Request, { params }: { params: Promise<{ build: string }> }) {
  const { build: requested } = await params;
  const build = ALIASES[requested] ?? requested;
  if (!(build in BUILDS)) redirect("/download/mac");
  const id = build as BuildId;
  if (!BUILDS[id].available) redirect("/#download");
  redirect((await newestAsset(BUILDS[id].asset)) ?? buildUrl(id));
}
