import Redis from "ioredis";
import { RateLimiterRes } from "rate-limiter-flexible";
import { describe, expect, it } from "vitest";
import {
  createCatalogRateLimiter,
  getCatalogRateLimitPoints,
  resolveClientIp,
} from "./rate-limit";

describe("public catalog rate limiting", () => {
  it("uses the connection address unless trusted proxy headers are enabled", () => {
    const headers = new Headers({
      "x-fco-remote-address": "192.0.2.10",
      "x-real-ip": "198.51.100.10",
      "x-forwarded-for": "203.0.113.10, 10.0.0.1",
    });

    expect(resolveClientIp(headers, false)).toBe("192.0.2.10");
    expect(resolveClientIp(headers, true)).toBe("198.51.100.10");
    headers.delete("x-real-ip");
    expect(resolveClientIp(headers, true)).toBe("203.0.113.10");
  });

  it("does not trust forwarded headers when the connection address is absent", () => {
    const headers = new Headers({
      "x-real-ip": "198.51.100.10",
      "x-forwarded-for": "203.0.113.10",
    });

    expect(resolveClientIp(headers, false)).toBe("unknown");
  });

  it("rejects an invalid configured request limit", () => {
    const previous = process.env.CATALOG_RATE_LIMIT_POINTS;
    process.env.CATALOG_RATE_LIMIT_POINTS = "0";
    try {
      expect(() => getCatalogRateLimitPoints()).toThrow(
        "CATALOG_RATE_LIMIT_POINTS must be a positive safe integer.",
      );
    } finally {
      if (previous === undefined) {
        delete process.env.CATALOG_RATE_LIMIT_POINTS;
      } else {
        process.env.CATALOG_RATE_LIMIT_POINTS = previous;
      }
    }
  });

  it("uses the in-memory insurance limiter when Redis is unavailable", async () => {
    const redis = new Redis({
      host: "127.0.0.1",
      port: 1,
      lazyConnect: true,
      maxRetriesPerRequest: 1,
      enableOfflineQueue: false,
      connectTimeout: 100,
      retryStrategy: () => null,
    });
    redis.on("error", () => undefined);
    const limiter = createCatalogRateLimiter(redis, 2);

    try {
      await expect(limiter.consume("fallback-test")).resolves.toMatchObject({
        remainingPoints: 1,
      });
      await expect(limiter.consume("fallback-test")).resolves.toMatchObject({
        remainingPoints: 0,
      });
      await expect(limiter.consume("fallback-test")).rejects.toBeInstanceOf(
        RateLimiterRes,
      );
    } finally {
      redis.disconnect();
    }
  });
});
