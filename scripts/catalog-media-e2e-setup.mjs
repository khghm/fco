import {
  CreateBucketCommand,
  HeadBucketCommand,
  ListBucketsCommand,
  PutObjectCommand,
  S3Client,
} from "@aws-sdk/client-s3";
import Redis from "ioredis";
import { deflateSync } from "node:zlib";

const endpoint = new URL(process.env.S3_ENDPOINT ?? "");
const loopbackHosts = new Set(["127.0.0.1", "localhost", "::1"]);
if (!loopbackHosts.has(endpoint.hostname)) {
  throw new Error("E2E media setup is restricted to a loopback S3 endpoint.");
}

const bucket = process.env.S3_BUCKET;
const region = process.env.S3_REGION;
const accessKey = process.env.S3_ACCESS_KEY;
const secretKey = process.env.S3_SECRET_KEY;
const redisUrl = process.env.REDIS_URL;
if (!bucket || !region || !accessKey || !secretKey || !redisUrl) {
  throw new Error("E2E S3 and Redis settings must be configured.");
}

function crc32(buffer) {
  let crc = 0xffffffff;
  for (const byte of buffer) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit += 1) {
      crc = (crc >>> 1) ^ (crc & 1 ? 0xedb88320 : 0);
    }
  }
  return (crc ^ 0xffffffff) >>> 0;
}

function pngChunk(type, data) {
  const typeBytes = Buffer.from(type, "ascii");
  const content = Buffer.concat([typeBytes, data]);
  const chunk = Buffer.alloc(12 + data.length);
  chunk.writeUInt32BE(data.length, 0);
  content.copy(chunk, 4);
  chunk.writeUInt32BE(crc32(content), 8 + data.length);
  return chunk;
}

function onePixelPng() {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(1, 0);
  header.writeUInt32BE(1, 4);
  header[8] = 8;
  header[9] = 6;

  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    pngChunk("IHDR", header),
    pngChunk("IDAT", deflateSync(Buffer.from([0, 60, 120, 180, 255]))),
    pngChunk("IEND", Buffer.alloc(0)),
  ]);
}

const redis = new Redis(redisUrl, {
  lazyConnect: true,
  connectTimeout: 1000,
  maxRetriesPerRequest: 1,
  retryStrategy: () => null,
});
redis.on("error", () => undefined);
try {
  let ready = false;
  let lastError;
  for (let attempt = 0; attempt < 30; attempt += 1) {
    try {
      await redis.ping();
      ready = true;
      break;
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 300));
    }
  }
  if (!ready) {
    throw new Error("Redis did not become ready for the catalog E2E.", {
      cause: lastError,
    });
  }
} finally {
  redis.disconnect();
}

const s3 = new S3Client({
  endpoint: endpoint.toString().replace(/\/$/, ""),
  region,
  forcePathStyle: true,
  credentials: { accessKeyId: accessKey, secretAccessKey: secretKey },
});

try {
  let ready = false;
  let lastError;
  for (let attempt = 0; attempt < 30; attempt += 1) {
    try {
      await s3.send(new ListBucketsCommand({}));
      ready = true;
      break;
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 300));
    }
  }
  if (!ready) {
    throw new Error("S3-compatible endpoint did not become ready for the catalog E2E.", {
      cause: lastError,
    });
  }

  try {
    await s3.send(new HeadBucketCommand({ Bucket: bucket }));
  } catch (error) {
    if (error?.$metadata?.httpStatusCode !== 404) {
      throw error;
    }
    await s3.send(new CreateBucketCommand({ Bucket: bucket }));
  }

  await s3.send(
    new PutObjectCommand({
      Bucket: bucket,
      Key: "catalog/e2e-shirt/front.png",
      Body: onePixelPng(),
      ContentType: "image/png",
    }),
  );
  console.log(`PASS E2E S3 fixture | bucket=${bucket} key=catalog/e2e-shirt/front.png`);
} finally {
  s3.destroy();
}
