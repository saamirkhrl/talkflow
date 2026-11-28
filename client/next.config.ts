import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // Lets phones and other computers on the local network load the dev build.
  allowedDevOrigins: ["10.0.0.12"],
  // The retired Windows guide page: talkflow is Mac-only now, and links to it
  // go to the home page instead of a 404.
  async redirects() {
    return [{ source: "/dictation-for-windows", destination: "/", permanent: true }];
  },
};

export default nextConfig;
