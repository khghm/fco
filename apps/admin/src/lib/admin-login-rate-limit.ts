import { isIP } from "node:net";
import Redis from "ioredis";
import {
  RateLimiterMemory,
  RateLimiterRedis,
  RateLimiterRes,
} from "rate-limiter-flexible";

const POINTS = 5;
const DURATION_SECONDS = 15 * 60;

type Limiter = RateLimiterMemory | RateLimiterRedis;

let runtime:
  | {
      signature: string;
      client: Redis | null;
      limiter: Limiter;
    }
  | undefined;

function logRateLimitEvent(event: string): void {
  process.stderr.write(`${JSON.stringify({ level: "warn", event })}\n`);
}

function getLimiter(): Limiter {
  const redisUrl = process.env.REDIS_URL?.trim();
  const signature = redisUrl ?? "memory";
  if (runtime?.signature === signature) {
    return runtime.limiter;
  }
  runtime?.client?.disconnect();

  const insuranceLimiter = new RateLimiterMemory({
    keyPrefix: "fco:admin_login:memory",
    points: POINTS,
    duration: DURATION_SECONDS,
  });
  if (!redisUrl) {
    logRateLimitEvent("admin_login_rate_limit_memory_only");
    runtime = {
      signature,
      client: null,
      limiter: insuranceLimiter,
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
      logRateLimitEvent("admin_login_rate_limit_redis_error");
    }
  });
  client.on("ready", () => {
    if (degraded) {
      degraded = false;
      process.stderr.write(
        `${JSON.stringify({ level: "info", event: "admin_login_rate_limit_redis_recovered" })}\n`,
      );
    }
  });

  runtime = {
    signature,
    client,
    limiter: new RateLimiterRedis({
      storeClient: client,
      keyPrefix: "fco:admin_login",
      points: POINTS,
      duration: DURATION_SECONDS,
      insuranceLimiter,
    }),
  };
  return runtime.limiter;
}

export function adminClientIp(request: Request): string | null {
  if (process.env.TRUST_PROXY !== "true") {
    return null;
  }
  const realIp = request.headers.get("x-real-ip")?.trim();
  if (realIp && isIP(realIp)) {
    return realIp;
  }
  const forwardedIp = request.headers.get("x-forwarded-for")?.split(",", 1)[0]?.trim();
  return forwardedIp && isIP(forwardedIp) ? forwardedIp : null;
}

export async function consumeAdminLoginAttempt(
  email: string,
  ip: string | null,
): Promise<{ allowed: true } | { allowed: false; retryAfterSeconds: number }> {
  const limiter = getLimiter();
  const keys = [`email:${email}`, ...(ip ? [`ip:${ip}`] : [])];
  let retryAfterMilliseconds = 0;
  for (const key of keys) {
    try {
      await limiter.consume(key);
    } catch (error) {
      if (!(error instanceof RateLimiterRes)) {
        throw error;
      }
      retryAfterMilliseconds = Math.max(retryAfterMilliseconds, error.msBeforeNext);
    }
  }
  return retryAfterMilliseconds > 0
    ? {
        allowed: false,
        retryAfterSeconds: Math.max(1, Math.ceil(retryAfterMilliseconds / 1000)),
      }
    : { allowed: true };
}
