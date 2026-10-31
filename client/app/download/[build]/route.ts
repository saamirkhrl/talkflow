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
// Windows installer is attached by CI some minutes after the Mac files (or
// not at all, when that build fails), and until then GitHub's
// releases/latest/download/<name> is a 404 page. Asked fresh on every request:
// it used to be cached for 5 minutes, and Next serves an expired cache entry
// to the next request while it refreshes in the background, so the first
// download after a quiet spell got whatever release was newest when the cache
// last filled (0.1.10, the day 0.1.12 shipped). If GitHub cannot be asked
// (it allows 60 unauthenticated calls an hour per address), the latest-release
// URL.
async function newestAsset(asset: string): Promise<string | null> {
  try {
    const response = await fetch(`https://api.github.com/repos/${REPO_URL.replace("https://github.com/", "")}/releases?per_page=10`, {
      headers: { Accept: "application/vnd.github+json" },
      cache: "no-store",
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
  // The Mac files are attached when the release is created, so GitHub's
  // latest-release URL is always the newest one, worked out by GitHub when the
  // browser asks. No lookup, nothing that can go stale.
  if (BUILDS[id].os === "mac") redirect(buildUrl(id));
  redirect((await newestAsset(BUILDS[id].asset)) ?? buildUrl(id));
}
