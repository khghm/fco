import assert from "node:assert/strict";
import Redis from "ioredis";
import { Client } from "pg";

const baseUrl = process.env.FCO_E2E_BASE_URL;
const databaseUrl = process.env.FCO_E2E_DATABASE_URL;
if (!baseUrl || !databaseUrl || !process.env.REDIS_URL) {
  throw new Error("Cart auth E2E requires storefront, database, and Redis URLs.");
}

const guestCartResponse = await fetch(`${baseUrl}/api/v1/cart`);
const guestCartBody = await guestCartResponse.json();
assert.equal(guestCartResponse.status, 200, JSON.stringify(guestCartBody));
assert.deepEqual(guestCartBody.data.items, []);
const guestCartId = guestCartResponse.headers
  .get("set-cookie")
  ?.match(/__Host-fco_cart_sid=([^;]+)/)?.[1];
assert.ok(guestCartId);
assert.match(guestCartResponse.headers.get("set-cookie") ?? "", /HttpOnly/);
assert.match(guestCartResponse.headers.get("set-cookie") ?? "", /Secure/);
assert.match(guestCartResponse.headers.get("set-cookie") ?? "", /SameSite=Lax/);
assert.match(guestCartResponse.headers.get("set-cookie") ?? "", /Max-Age=604800/);
const guestCookie = `__Host-fco_cart_sid=${guestCartId}`;

async function addGuestCartItem(variantId, quantity) {
  return fetch(`${baseUrl}/api/v1/cart/items`, {
    method: "POST",
    headers: {
      origin: baseUrl,
      cookie: guestCookie,
      "content-type": "application/json",
    },
    body: JSON.stringify({ variant_id: variantId, quantity, price_rial: 1 }),
  });
}

const firstCartItem = await addGuestCartItem(
  "e4000000-0000-0000-0000-000000000001",
  2,
);
const firstCartItemBody = await firstCartItem.json();
assert.equal(firstCartItem.status, 201, JSON.stringify(firstCartItemBody));
assert.equal(firstCartItemBody.data.items[0].price_rial, 650000);
assert.equal(firstCartItemBody.data.items[0].quantity, 2);

const secondCartItem = await addGuestCartItem(
  "e4000000-0000-0000-0000-000000000002",
  3,
);
const secondCartItemBody = await secondCartItem.json();
assert.equal(secondCartItem.status, 201, JSON.stringify(secondCartItemBody));
assert.match(secondCartItem.headers.get("set-cookie") ?? "", /Max-Age=604800/);
assert.equal(secondCartItemBody.data.items.length, 2);
const expectedItems = [
  ["CART-E2E-SCARF-001", 3, 450000],
  ["E2E-SHIRT-001", 2, 650000],
];
const bySku = (items) =>
  items
    .map((item) => [item.sku, item.quantity, item.price_rial])
    .sort(([left], [right]) => left.localeCompare(right));
assert.deepEqual(bySku(secondCartItemBody.data.items), expectedItems);
console.log("PASS HTTP guest cart | 2 products, server-derived prices, HttpOnly Secure cookie");

const touchedGuestCart = await fetch(`${baseUrl}/api/v1/cart`, {
  headers: { cookie: guestCookie },
});
assert.equal(touchedGuestCart.status, 200);
assert.match(touchedGuestCart.headers.get("set-cookie") ?? "", /Max-Age=604800/);
const ttlRedis = new Redis(process.env.REDIS_URL);
try {
  const ttl = await ttlRedis.ttl(`fco:guest-cart:${guestCartId}`);
  assert.ok(ttl > 604700 && ttl <= 604800, `unexpected sliding TTL: ${ttl}`);
} finally {
  ttlRedis.disconnect();
}

const otpRequest = await fetch(`${baseUrl}/api/v1/auth/otp/request`, {
  method: "POST",
  headers: { origin: baseUrl, "content-type": "application/json" },
  body: JSON.stringify({ mobile: "09120000000" }),
});
assert.equal(otpRequest.status, 202);
const otpRequestBody = await otpRequest.json();
assert.equal(otpRequest.headers.get("x-request-id"), otpRequestBody.meta.request_id);

const database = new Client({ connectionString: databaseUrl });
await database.connect();
let otpCode;
try {
  const result = await database.query(
    `select code
       from sys.otp_spool
      where mobile = $1
        and expires_at > now()
      order by created_at desc
      limit 1`,
    ["09120000000"],
  );
  otpCode = result.rows[0]?.code;
} finally {
  await database.end();
}
assert.match(otpCode ?? "", /^[0-9]{6}$/);

const wrongCode = String((Number(otpCode) + 1) % 1_000_000).padStart(6, "0");
const invalidLogin = await fetch(`${baseUrl}/api/v1/auth/otp/verify`, {
  method: "POST",
  headers: {
    origin: baseUrl,
    cookie: guestCookie,
    "content-type": "application/json",
  },
  body: JSON.stringify({ mobile: "09120000000", code: wrongCode }),
});
assert.equal(invalidLogin.status, 401);

const login = await fetch(`${baseUrl}/api/v1/auth/otp/verify`, {
  method: "POST",
  headers: {
    origin: baseUrl,
    cookie: guestCookie,
    "content-type": "application/json",
  },
  body: JSON.stringify({ mobile: "09120000000", code: otpCode }),
});
const loginBody = await login.json();
assert.equal(
  login.status,
  200,
  `customer OTP login failed: ${login.status} ${JSON.stringify(loginBody)}`,
);
assert.equal(loginBody.data.cart_merge, "complete");
assert.equal(login.headers.get("x-request-id"), loginBody.meta.request_id);
const cookies = login.headers.getSetCookie?.() ?? [login.headers.get("set-cookie") ?? ""];
const customerCookie = cookies
  .map((cookie) => cookie.match(/__Host-fco_customer_sid=([^;]+)/)?.[0])
  .find(Boolean);
assert.ok(customerCookie);
assert.ok(cookies.some((cookie) => /__Host-fco_cart_sid=;/.test(cookie)));
assert.ok(cookies.every((cookie) => /HttpOnly/.test(cookie)));
assert.ok(cookies.every((cookie) => /Secure/.test(cookie)));
assert.ok(cookies.every((cookie) => /SameSite=Lax/.test(cookie)));

const accountCart = await fetch(`${baseUrl}/api/v1/cart`, {
  headers: { cookie: customerCookie },
});
const accountCartBody = await accountCart.json();
assert.equal(accountCart.status, 200);
assert.deepEqual(bySku(accountCartBody.data.items), expectedItems);
assert.equal(accountCartBody.data.guest_cart_cleanup_pending, false);

const recoveryDatabase = new Client({ connectionString: databaseUrl });
const recoveryRedis = new Redis(process.env.REDIS_URL);
await recoveryDatabase.connect();
try {
  const pendingMergeUpdate = await recoveryDatabase.query(
    "update shop.cart_merge_sources set redis_deleted_at = null where guest_cart_id = $1::uuid",
    [guestCartId],
  );
  assert.equal(pendingMergeUpdate.rowCount, 1);
  await recoveryRedis.hset(`fco:guest-cart:${guestCartId}`, "e4000000-0000-0000-0000-000000000001", "1");
  await recoveryRedis.set(
    `fco:guest-cart-merge-lock:${guestCartId}`,
    "simulated-recovery-lock",
    "EX",
    60,
  );

  const pendingCart = await fetch(`${baseUrl}/api/v1/cart`, {
    headers: { cookie: customerCookie },
  });
  const pendingCartBody = await pendingCart.json();
  assert.equal(pendingCart.status, 200);
  assert.equal(pendingCartBody.data.guest_cart_cleanup_pending, true);
  assert.equal(
    await recoveryRedis.exists(`fco:guest-cart:${guestCartId}`),
    1,
  );

  await recoveryRedis.del(`fco:guest-cart-merge-lock:${guestCartId}`);
  const recoveredCart = await fetch(`${baseUrl}/api/v1/cart`, {
    headers: { cookie: customerCookie },
  });
  const recoveredCartBody = await recoveredCart.json();
  assert.equal(recoveredCart.status, 200);
  assert.equal(recoveredCartBody.data.guest_cart_cleanup_pending, false);
  assert.deepEqual(bySku(recoveredCartBody.data.items), expectedItems);
  assert.equal(await recoveryRedis.exists(`fco:guest-cart:${guestCartId}`), 0);
} finally {
  await recoveryDatabase.end();
  recoveryRedis.disconnect();
}
console.log("PASS cart merge cleanup recovery | deferred while locked, retried and completed");

console.log(
  `PASS HTTP customer OTP login + cart merge | status=200 items=2 request_id=${loginBody.meta.request_id}`,
);

const staleGuestWrite = await fetch(`${baseUrl}/api/v1/cart/items`, {
  method: "POST",
  headers: {
    origin: baseUrl,
    cookie: guestCookie,
    "content-type": "application/json",
  },
  body: JSON.stringify({
    variant_id: "e4000000-0000-0000-0000-000000000001",
    quantity: 1,
  }),
});
assert.equal(staleGuestWrite.status, 409);

const redis = new Redis(process.env.REDIS_URL);
try {
  assert.equal(await redis.exists(`fco:guest-cart:${guestCartId}`), 0);
} finally {
  redis.disconnect();
}
console.log("PASS Redis guest cart cleanup | key removed after account cart commit");

const repeatMerge = new Client({ connectionString: databaseUrl });
await repeatMerge.connect();
try {
  const before = await repeatMerge.query(
    `select sum(quantity)::integer as quantity
       from shop.cart_items item
       join shop.carts cart on cart.id = item.cart_id
      where cart.user_id = $1`,
    ["d4000000-0000-0000-0000-000000000001"],
  );
  await repeatMerge.query(
    `select * from shop.merge_guest_cart($1::uuid, $2::uuid, '[]'::jsonb)`,
    [guestCartId, "d4000000-0000-0000-0000-000000000001"],
  );
  const after = await repeatMerge.query(
    `select sum(quantity)::integer as quantity
       from shop.cart_items item
       join shop.carts cart on cart.id = item.cart_id
      where cart.user_id = $1`,
    ["d4000000-0000-0000-0000-000000000001"],
  );
  assert.equal(after.rows[0].quantity, before.rows[0].quantity);
} finally {
  await repeatMerge.end();
}
console.log("PASS cart merge idempotency | repeated merge did not duplicate quantities");
