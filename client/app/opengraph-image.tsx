import { ImageResponse } from "next/og";
import { OG_IMAGE_ALT } from "@/lib/seo";

// The card shown when a talkflow link is shared. Built at build time with
// next/og (part of Next, no extra dependency) in its bundled font, so it
// fetches nothing. Colors are the site's paper, ink and graphite.
export const alt = OG_IMAGE_ALT;
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

// The app icon (app/icon.svg).
const ICON =
  '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><rect width="1024" height="1024" rx="230" fill="#1f1e22"/><g fill="#fff"><rect x="159" y="348" width="92" height="328" rx="46"/><rect x="312" y="231" width="92" height="562" rx="46"/><rect x="466" y="77" width="92" height="870" rx="46"/><rect x="620" y="231" width="92" height="562" rx="46"/><rect x="773" y="348" width="92" height="328" rx="46"/></g></svg>';

export default function OpengraphImage() {
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "center",
          padding: "0 96px",
          background: "#f5f5f3",
          color: "#1f1e22",
        }}
      >
        <img src={`data:image/svg+xml;base64,${Buffer.from(ICON).toString("base64")}`} width={120} height={120} alt="" />
        <div style={{ marginTop: 48, fontSize: 96, letterSpacing: "-0.03em" }}>talkflow</div>
        <div style={{ marginTop: 20, fontSize: 40, color: "#5f5e66", maxWidth: 900 }}>
          Hold a key, speak, and your words are typed wherever your cursor is. Free, open source, on your own Mac.
        </div>
      </div>
    ),
    size,
  );
}
