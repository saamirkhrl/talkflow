import type { Metadata } from "next";
import { DownloadChooser } from "@/components/landing/DownloadChooser";

export const metadata: Metadata = {
  title: "Download for Windows",
  description: "Download talkflow for Windows: x64 or Arm.",
};

export default function DownloadWindowsPage() {
  return <DownloadChooser os="windows" />;
}
