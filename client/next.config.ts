import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  // The retired Windows guide page: talkflow is Mac-only now, and links to it
  // go to the home page instead of a 404.
  async redirects() {
    return [{ source: "/dictation-for-windows", destination: "/", permanent: true }];
  },
};

export default nextConfig;
