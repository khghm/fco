import type { NextConfig } from "next";

function getMediaRemotePatterns(): NonNullable<NextConfig["images"]>["remotePatterns"] | undefined {
  const endpointValue = process.env.S3_ENDPOINT?.trim();
  const bucket = process.env.S3_BUCKET?.trim();
  const region = process.env.S3_REGION?.trim();
  if (!endpointValue || !bucket || !region) {
    if (process.env.NODE_ENV === "production") {
      throw new Error("S3_ENDPOINT, S3_BUCKET, and S3_REGION must be set at build time.");
    }
    return undefined;
  }

  const endpoint = new URL(endpointValue);
  if (
    !["http:", "https:"].includes(endpoint.protocol) ||
    endpoint.username ||
    endpoint.password ||
    endpoint.search ||
    endpoint.hash
  ) {
    throw new Error("S3_ENDPOINT must be an HTTP(S) URL without credentials or query parameters.");
  }
  const basePath = endpoint.pathname.replace(/\/+$/, "");

  return [
    {
      protocol: endpoint.protocol === "https:" ? "https" : "http",
      hostname: endpoint.hostname,
      port: endpoint.port,
      pathname: `${basePath}/${bucket}/**`,
    },
  ];
}

const remotePatterns = getMediaRemotePatterns();

const nextConfig: NextConfig = {
  ...(remotePatterns
    ? {
        images: {
          remotePatterns,
          // Self-hosted S3/MinIO endpoints commonly resolve to private network addresses.
          dangerouslyAllowLocalIP: true,
        },
      }
    : {}),
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
