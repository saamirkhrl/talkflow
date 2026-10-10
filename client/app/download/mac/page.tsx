import type { Metadata } from "next";
import { DownloadChooser } from "@/components/landing/DownloadChooser";

export const metadata: Metadata = {
  title: "Download for Mac",
  description: "Download talkflow for Mac: Apple Silicon or Intel, macOS 13 or later.",
};

export default function DownloadMacPage() {
  return <DownloadChooser />;
}
