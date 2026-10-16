import type { MetadataRoute } from "next";
import { GUIDES } from "@/components/landing/content";
import { SITE_URL } from "@/lib/seo";

// Every public page. Left out: /api/* and the /download and /download/<build>
// redirects, which lead to the Mac download page or straight to a release file.
const PATHS = ["/", ...GUIDES.map((guide) => guide.path), "/download/mac", "/privacy", "/terms"];

export default function sitemap(): MetadataRoute.Sitemap {
  return PATHS.map((path) => ({ url: path === "/" ? SITE_URL : `${SITE_URL}${path}` }));
}
