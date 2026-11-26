import { GetObjectCommand, S3Client } from "@aws-sdk/client-s3";
import { getSignedUrl } from "@aws-sdk/s3-request-presigner";

const URL_TTL_SECONDS = 900;

type StorageConfiguration = {
  endpoint: string;
  bucket: string;
  region: string;
  accessKey: string | undefined;
  secretKey: string | undefined;
};

let client: S3Client | undefined;
let clientFingerprint: string | undefined;

function getStorageConfiguration(): StorageConfiguration {
  const endpoint = process.env.S3_ENDPOINT?.trim();
  const bucket = process.env.S3_BUCKET?.trim();
  const region = process.env.S3_REGION?.trim();
  const accessKey = process.env.S3_ACCESS_KEY || undefined;
  const secretKey = process.env.S3_SECRET_KEY || undefined;

  if (!endpoint || !bucket || !region) {
    throw new Error("S3_ENDPOINT, S3_BUCKET, and S3_REGION must be configured.");
  }

  const endpointUrl = new URL(endpoint);
  if (
    !["http:", "https:"].includes(endpointUrl.protocol) ||
    endpointUrl.username ||
    endpointUrl.password ||
    endpointUrl.search ||
    endpointUrl.hash
  ) {
    throw new Error("S3_ENDPOINT must be an HTTP(S) endpoint without credentials or query parameters.");
  }
  if (Boolean(accessKey) !== Boolean(secretKey)) {
    throw new Error("S3_ACCESS_KEY and S3_SECRET_KEY must be configured together.");
  }

  return { endpoint, bucket, region, accessKey, secretKey };
}

function getClient(configuration: StorageConfiguration): S3Client {
  const fingerprint = [
    configuration.endpoint,
    configuration.region,
    configuration.accessKey ?? "",
    configuration.secretKey ?? "",
  ].join("\0");

  if (!client || clientFingerprint !== fingerprint) {
    client?.destroy();
    client = new S3Client({
      endpoint: configuration.endpoint,
      region: configuration.region,
      forcePathStyle: true,
      ...(configuration.accessKey && configuration.secretKey
        ? {
            credentials: {
              accessKeyId: configuration.accessKey,
              secretAccessKey: configuration.secretKey,
            },
          }
        : {}),
    });
    clientFingerprint = fingerprint;
  }

  return client;
}

function validateObjectKey(key: string): void {
  if (
    !key ||
    key.startsWith("/") ||
    key.includes("\\") ||
    /[\u0000-\u001f]/.test(key) ||
    key.split("/").some((segment) => segment === "" || segment === "." || segment === "..")
  ) {
    throw new Error("Catalog media contains an invalid storage key.");
  }
}

export async function createPresignedMediaUrl(key: string): Promise<string> {
  validateObjectKey(key);
  const configuration = getStorageConfiguration();

  return getSignedUrl(
    getClient(configuration),
    new GetObjectCommand({ Bucket: configuration.bucket, Key: key }),
    { expiresIn: URL_TTL_SECONDS },
  );
}
