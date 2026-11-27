import { randomUUID } from "node:crypto";
import Redis from "ioredis";
import type { GuestCartLine } from "@fco/infrastructure/customer-auth";

export const GUEST_CART_TTL_SECONDS = 7 * 24 * 60 * 60;
const MERGE_LOCK_TTL_MS = 60_000;
const CART_KEY_PREFIX = "fco:guest-cart:";
const MERGE_LOCK_PREFIX = "fco:guest-cart-merge-lock:";
const RESTORE_MARKER_PREFIX = "fco:guest-cart-restored:";

let client: Redis | undefined;
let clientUrl: string | undefined;

function getRedisClient(): Redis {
  const redisUrl = process.env.REDIS_URL?.trim();
  if (!redisUrl) {
    throw new Error("REDIS_URL must be configured for guest carts.");
  }
  if (client && clientUrl === redisUrl) {
    return client;
  }

  client?.disconnect();
  clientUrl = redisUrl;
  client = new Redis(redisUrl, {
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
      process.stderr.write(
        `${JSON.stringify({ level: "warn", event: "guest_cart_redis_error" })}\n`,
      );
    }
  });
  client.on("ready", () => {
    if (degraded) {
      degraded = false;
      process.stderr.write(
        `${JSON.stringify({ level: "info", event: "guest_cart_redis_recovered" })}\n`,
      );
    }
  });
  return client;
}

async function connectedRedis(): Promise<Redis> {
  const redis = getRedisClient();
  if (redis.status === "wait") {
    await redis.connect();
    return redis;
  }
  if (redis.status === "ready") {
    return redis;
  }
  await new Promise<void>((resolve, reject) => {
    const cleanup = () => {
      redis.off("ready", onReady);
      redis.off("error", onError);
    };
    const onReady = () => {
      cleanup();
      resolve();
    };
    const onError = (error: Error) => {
      cleanup();
      reject(error);
    };
    redis.once("ready", onReady);
    redis.once("error", onError);
  });
  return redis;
}

export function newGuestCartId(): string {
  return randomUUID();
}

export function isGuestCartId(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value,
  );
}

function cartKey(cartId: string): string {
  if (!isGuestCartId(cartId)) {
    throw new TypeError("Guest cart identifier has an invalid format.");
  }
  return `${CART_KEY_PREFIX}${cartId}`;
}

function mergeLockKey(cartId: string): string {
  return `${MERGE_LOCK_PREFIX}${cartId}`;
}

function restoreMarkerKey(cartId: string): string {
  return `${RESTORE_MARKER_PREFIX}${cartId}`;
}

export async function addGuestCartItem(
  cartId: string,
  variantId: string,
  quantity: number,
): Promise<"added" | "merge_in_progress" | "quantity_limit"> {
  const script = `
    if redis.call("EXISTS", KEYS[2]) == 1 then
      return -1
    end
    local current = tonumber(redis.call("HGET", KEYS[1], ARGV[1]) or "0")
    local added = tonumber(ARGV[2])
    if current + added > 9999 then
      return -2
    end
    redis.call("HINCRBY", KEYS[1], ARGV[1], added)
    redis.call("EXPIRE", KEYS[1], ARGV[3])
    if redis.call("EXISTS", KEYS[3]) == 1 then
      redis.call("EXPIRE", KEYS[3], ARGV[3])
    end
    return 1
  `;
  const redis = await connectedRedis();
  const result = await redis.eval(
    script,
    3,
    cartKey(cartId),
    mergeLockKey(cartId),
    restoreMarkerKey(cartId),
    variantId,
    String(quantity),
    String(GUEST_CART_TTL_SECONDS),
  );
  if (result === -1) {
    return "merge_in_progress";
  }
  if (result === -2) {
    return "quantity_limit";
  }
  if (result !== 1) {
    throw new Error("Redis returned an unexpected guest cart update result.");
  }
  return "added";
}

export async function readGuestCart(cartId: string): Promise<GuestCartLine[]> {
  const key = cartKey(cartId);
  const redis = await connectedRedis();
  const stored = await redis.hgetall(key);
  if (Object.keys(stored).length === 0) {
    return [];
  }
  await redis.expire(key, GUEST_CART_TTL_SECONDS);
  await redis.expire(restoreMarkerKey(cartId), GUEST_CART_TTL_SECONDS);

  return Object.entries(stored).map(([variantId, rawQuantity]) => {
    if (
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(variantId)
    ) {
      throw new Error("Redis guest cart contains an invalid variant identifier.");
    }
    const quantity = Number(rawQuantity);
    if (!Number.isSafeInteger(quantity) || quantity < 1 || quantity > 9999) {
      throw new Error("Redis guest cart contains an invalid quantity.");
    }
    return { variantId, quantity };
  });
}

export async function claimGuestCartForMerge(
  cartId: string,
): Promise<{ token: string; items: GuestCartLine[] } | null> {
  const token = randomUUID();
  const redis = await connectedRedis();
  const claimed = await redis.set(
    mergeLockKey(cartId),
    token,
    "PX",
    MERGE_LOCK_TTL_MS,
    "NX",
  );
  if (claimed !== "OK") {
    return null;
  }
  try {
    return { token, items: await readGuestCart(cartId) };
  } catch (error) {
    await releaseGuestCartMergeLock(cartId, token);
    throw error;
  }
}

export async function releaseGuestCartMergeLock(
  cartId: string,
  token: string,
): Promise<void> {
  const script = `
    if redis.call("GET", KEYS[1]) == ARGV[1] then
      return redis.call("DEL", KEYS[1])
    end
    return 0
  `;
  const redis = await connectedRedis();
  await redis.eval(script, 1, mergeLockKey(cartId), token);
}

export async function deleteGuestCartAfterMerge(
  cartId: string,
  token: string,
): Promise<boolean> {
  const script = `
    if redis.call("GET", KEYS[2]) ~= ARGV[1] then
      return 0
    end
    redis.call("DEL", KEYS[1])
    redis.call("SET", KEYS[2], "merged", "EX", ARGV[2])
    return 1
  `;
  const redis = await connectedRedis();
  const result = await redis.eval(
    script,
    2,
    cartKey(cartId),
    mergeLockKey(cartId),
    token,
    String(GUEST_CART_TTL_SECONDS),
  );
  if (result !== 0 && result !== 1) {
    throw new Error("Redis returned an unexpected guest cart cleanup result.");
  }
  return result === 1;
}

export async function cleanupPendingGuestCart(cartId: string): Promise<boolean> {
  const script = `
    local lock = redis.call("GET", KEYS[2])
    if lock and lock ~= "merged" then
      return 0
    end
    redis.call("SET", KEYS[2], "merged", "EX", ARGV[1])
    redis.call("DEL", KEYS[1])
    return 1
  `;
  const redis = await connectedRedis();
  const result = await redis.eval(
    script,
    2,
    cartKey(cartId),
    mergeLockKey(cartId),
    String(GUEST_CART_TTL_SECONDS),
  );
  if (result !== 0 && result !== 1) {
    throw new Error("Redis returned an unexpected pending cart cleanup result.");
  }
  return result === 1;
}

export async function restoreGuestCart(
  cartId: string,
  items: GuestCartLine[],
): Promise<void> {
  if (!Array.isArray(items) || items.length < 1 || items.length > 50) {
    throw new RangeError("Restored guest cart must contain between one and fifty items.");
  }
  const seen = new Set<string>();
  const args: string[] = [String(GUEST_CART_TTL_SECONDS), String(items.length)];
  for (const item of items) {
    if (
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
        item.variantId,
      ) ||
      !Number.isSafeInteger(item.quantity) ||
      item.quantity < 1 ||
      item.quantity > 9999 ||
      seen.has(item.variantId)
    ) {
      throw new TypeError("Database returned invalid guest cart restore items.");
    }
    seen.add(item.variantId);
    args.push(item.variantId, String(item.quantity));
  }

  const script = `
    if redis.call("EXISTS", KEYS[2]) == 1 then
      return 0
    end
    if redis.call("EXISTS", KEYS[1]) == 1 then
      return -1
    end
    local count = tonumber(ARGV[2])
    for i = 1, count do
      redis.call("HSET", KEYS[1], ARGV[2 + (i * 2) - 1], ARGV[2 + (i * 2)])
    end
    redis.call("EXPIRE", KEYS[1], ARGV[1])
    redis.call("SET", KEYS[2], "restored", "EX", ARGV[1])
    return 1
  `;
  const redis = await connectedRedis();
  const result = await redis.eval(
    script,
    2,
    cartKey(cartId),
    restoreMarkerKey(cartId),
    ...args,
  );
  if (result === -1) {
    throw new Error("Restore cart identifier already contains unrelated data.");
  }
  if (result !== 0 && result !== 1) {
    throw new Error("Redis returned an unexpected guest cart restore result.");
  }
}
