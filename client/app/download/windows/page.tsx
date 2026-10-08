import type { Metadata } from "next";
import { DownloadChooser } from "@/components/landing/DownloadChooser";

export const metadata: Metadata = {
  title: "Download for Windows",
  description: "Download talkflow for Windows 10 and 11. One installer for every PC.",
};

export default function DownloadWindowsPage() {
  return <DownloadChooser os="windows" />;
}
