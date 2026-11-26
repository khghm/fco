import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  transpilePackages: ["@fco/application", "@fco/infrastructure"],
  turbopack: {
    rules: {
      "*.css": {
        loaders: ["@tailwindcss/turbopack"],
        as: "*.css",
      },
    },
  },
};

export default nextConfig;
