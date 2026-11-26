import { isIP } from "node:net";
import Redis from "ioredis";
import {
  RateLimiterMemory,
  RateLimiterRedis,
  type RateLimiterRes,
} from "rate-limiter-flexible";

const DURATION_SECONDS = 60;
const DEFAULT_POINTS = 100;

type CatalogRateLimiter = RateLimiterMemory | RateLimiterRedis;

type RateLimiterRuntime = {
  signature: string;
  client: Redis | null;
  limiter: CatalogRateLimiter;
};

let runtime: RateLimiterRuntime | undefined;

function logRedisState(event: string): void {
  process.stderr.write(
    `${JSON.stringify({
      level:
        event === "public_rate_limit_redis_error" ||
        event === "public_rate_limit_memory_only"
          ? "warn"
          : "info",
      event,
    })}\n`,
  );
}

export function getCatalogRateLimitPoints(): number {
  const rawPoints = process.env.CATALOG_RATE_LIMIT_POINTS;
  if (rawPoints === undefined || rawPoints.trim() === "") {
    return DEFAULT_POINTS;
  }

  const points = Number(rawPoints);
  if (!Number.isSafeInteger(points) || points < 1) {
    throw new Error("CATALOG_RATE_LIMIT_POINTS must be a positive safe integer.");
  }
  return points;
}

export function resolveClientIp(
  headers: Pick<Headers, "get">,
  trustProxy = process.env.TRUST_PROXY === "true",
): string {
  if (trustProxy) {
    const realIp = headers.get("x-real-ip")?.trim();
    if (realIp && isIP(realIp)) {
      return realIp;
    }

    const firstForwardedIp = headers
      .get("x-forwarded-for")
      ?.split(",", 1)[0]
      ?.trim();
    if (firstForwardedIp && isIP(firstForwardedIp)) {
      return firstForwardedIp;
    }
  }

  const remoteAddress = headers.get("x-fco-remote-address")?.trim();
  return remoteAddress && isIP(remoteAddress) ? remoteAddress : "unknown";
}

export function createCatalogRateLimiter(
  client: Redis,
  points: number,
): RateLimiterRedis {
  const insuranceLimiter = new RateLimiterMemory({
    keyPrefix: "fco:public_catalog:memory",
    points,
    duration: DURATION_SECONDS,
  });

  return new RateLimiterRedis({
    storeClient: client,
    keyPrefix: "fco:public_catalog",
    points,
    duration: DURATION_SECONDS,
    insuranceLimiter,
  });
}

function getLimiter(points: number): CatalogRateLimiter {
  const redisUrl = process.env.REDIS_URL?.trim();
  const signature = `${points}\0${redisUrl ?? ""}`;
  if (runtime?.signature === signature) {
    return runtime.limiter;
  }

  runtime?.client?.disconnect();
  if (!redisUrl) {
    logRedisState("public_rate_limit_memory_only");
    runtime = {
      signature,
      client: null,
      limiter: new RateLimiterMemory({
        keyPrefix: "fco:public_catalog:memory",
        points,
        duration: DURATION_SECONDS,
      }),
    };
    return runtime.limiter;
  }

  const client = new Redis(redisUrl, {
    lazyConnect: true,
    maxRetriesPerRequest: 1,
    enableOfflineQueue: false,
    connectTimeout: 1000,
    retryStrategy: (attempt) => Math.min(attempt * 500, 5000),
  });
  let degraded = false;
  client.on("error", () => {
    if (!degraded) {
      degraded = true;
      logRedisState("public_rate_limit_redis_error");
    }
  });
  client.on("ready", () => {
    if (degraded) {
      degraded = false;
      logRedisState("public_rate_limit_redis_recovered");
    }
  });

  runtime = {
    signature,
    client,
    limiter: createCatalogRateLimiter(client, points),
  };
  return runtime.limiter;
}

export function consumeCatalogRequest(
  ip: string,
  points = getCatalogRateLimitPoints(),
): Promise<RateLimiterRes> {
  return getLimiter(points).consume(ip);
}
