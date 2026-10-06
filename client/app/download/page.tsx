import { redirect } from "next/navigation";

// talkflow.live/download on its own goes to the Mac downloads.
export default function DownloadPage() {
  redirect("/download/mac");
}
