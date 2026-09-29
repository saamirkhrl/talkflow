import type { Metadata } from "next";
import { Newsreader } from "next/font/google";
import "./globals.css";

const newsreader = Newsreader({
  variable: "--font-newsreader",
  subsets: ["latin"],
  style: ["normal", "italic"],
  axes: ["opsz"],
});

export const metadata: Metadata = {
  title: {
    default: "TalkFlow: talk to your computer, for free",
    template: "%s | TalkFlow",
  },
  description: "Hold fn, speak, and your words are typed wherever your cursor is. Free, open source, and runs entirely on your Mac.",
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html lang="en" className={newsreader.variable}>
      <body className="font-sans">{children}</body>
    </html>
  );
}
