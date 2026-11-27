import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { Client } from "pg";

const baseUrl = process.env.FCO_ADMIN_E2E_BASE_URL;
const databaseUrl = process.env.DATABASE_URL;
const email = process.env.FCO_E2E_STAFF_EMAIL ?? "admin-e2e@fco.invalid";
const password = process.env.FCO_E2E_STAFF_PASSWORD;
const variantId = process.env.FCO_E2E_VARIANT_ID;
const adminId = process.env.FCO_E2E_ADMIN_ID;
const operatorId = process.env.FCO_E2E_OPERATOR_ID;
const totpSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
if (!baseUrl || !databaseUrl || !password || !variantId || !adminId || !operatorId) {
  throw new Error("Admin API E2E environment is incomplete.");
}

async function fetchReady(url) {
  const deadline = Date.now() + 30_000;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(url);
      if (response.ok) {
        return response;
      }
      lastError = new Error(`HTTP ${response.status}`);
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 300));
  }
  throw new Error("Admin app did not become reachable within 30 seconds.", {
    cause: lastError,
  });
}

function totpCode(secret, now = Date.now()) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  let bits = 0;
  let value = 0;
  const bytes = [];
  for (const character of secret) {
    value = (value << 5) | alphabet.indexOf(character);
    bits += 5;
    if (bits >= 8) {
      bytes.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  const counter = Math.floor(now / 1000 / 30);
  const counterBytes = Buffer.alloc(8);
  counterBytes.writeBigUInt64BE(BigInt(counter));
  const digest = createHmac("sha1", Buffer.from(bytes))
    .update(counterBytes)
    .digest();
  const offset = digest[digest.length - 1] & 0x0f;
  const binary =
    ((digest[offset] & 0x7f) << 24) |
    ((digest[offset + 1] & 0xff) << 16) |
    ((digest[offset + 2] & 0xff) << 8) |
    (digest[offset + 3] & 0xff);
  return String(binary % 1_000_000).padStart(6, "0");
}

function requestHeaders(origin, cookie) {
  return {
    origin,
    ...(cookie ? { cookie } : {}),
  };
}

const loginResponse = await fetchReady(`${baseUrl}/login`);
assert.equal(loginResponse.status, 200);

const anonymousResponse = await fetch(`${baseUrl}/api/v1/admin/products`);
const anonymousBody = await anonymousResponse.json();
assert.equal(anonymousResponse.status, 401);
assert.equal(anonymousBody.error.code, "FCO-1005");
assert.equal(anonymousResponse.headers.get("x-request-id"), anonymousBody.error.request_id);
console.log("PASS HTTP anonymous admin API | status=401 code=FCO-1005");

const loginRequestId = `admin-e2e-login-${Date.now()}`;
const login = await fetch(`${baseUrl}/api/v1/admin/auth/login`, {
  method: "POST",
  headers: {
    ...requestHeaders(baseUrl),
    "content-type": "application/json",
    "x-request-id": loginRequestId,
  },
  body: JSON.stringify({
    email,
    password,
    totp: totpCode(totpSecret),
  }),
});
const loginBody = await login.json();
assert.equal(
  login.status,
  200,
  `staff login failed: ${login.status} ${JSON.stringify(loginBody)}`,
);
assert.equal(login.headers.get("x-request-id"), loginRequestId);
const cookie = login.headers.get("set-cookie")?.match(/__Host-fco_sid=([^;]+)/)?.[0];
assert.ok(cookie, "login did not set the session cookie");
assert.match(login.headers.get("set-cookie") ?? "", /HttpOnly/);
assert.match(login.headers.get("set-cookie") ?? "", /Secure/);
assert.match(login.headers.get("set-cookie") ?? "", /SameSite=Lax/);
console.log(`PASS HTTP staff login + MFA | status=200 request_id=${loginRequestId}`);

const list = await fetch(`${baseUrl}/api/v1/admin/products?limit=20`, {
  headers: requestHeaders(baseUrl, cookie),
});
const listBody = await list.json();
assert.equal(list.status, 200);
assert.ok(listBody.data.some((product) => product.slug === "admin-e2e-seeded-product"));
assert.equal(list.headers.get("x-request-id"), listBody.meta.request_id);
console.log(`PASS HTTP admin product list | status=200 items=${listBody.data.length}`);

const create = await fetch(`${baseUrl}/api/v1/admin/products`, {
  method: "POST",
  headers: {
    ...requestHeaders(baseUrl, cookie),
    "content-type": "application/json",
  },
  body: JSON.stringify({
    slug: "admin-e2e-created-product",
    title: "E2E Created Product",
    description: "Created over HTTP",
    brand_id: null,
    category_id: null,
    attributes: { color: "black" },
  }),
});
const createBody = await create.json();
assert.equal(create.status, 201);
assert.equal(create.headers.get("x-request-id"), createBody.meta.request_id);
console.log(`PASS HTTP admin product create | status=201 id=${createBody.data.id}`);

const update = await fetch(
  `${baseUrl}/api/v1/admin/products/${createBody.data.id}`,
  {
    method: "PATCH",
    headers: {
      ...requestHeaders(baseUrl, cookie),
      "content-type": "application/json",
      "if-match": '"1"',
    },
    body: JSON.stringify({
      title: "E2E Updated Product",
      description: "Updated over HTTP",
      brand_id: null,
      category_id: null,
      attributes: { color: "blue" },
    }),
  },
);
const updateBody = await update.json();
assert.equal(update.status, 200);
assert.equal(updateBody.data.version, 2);
console.log("PASS HTTP optimistic product update | status=200 version=2");

const priceRequest = await fetch(
  `${baseUrl}/api/v1/admin/variants/${variantId}/prices`,
  {
    method: "POST",
    headers: {
      ...requestHeaders(baseUrl, cookie),
      "content-type": "application/json",
    },
    body: JSON.stringify({
      amount_rial: 125000,
      effective_from: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
      reason: "E2E versioned price",
    }),
  },
);
const priceBody = await priceRequest.json();
assert.equal(priceRequest.status, 201);
const priceRequestId = priceBody.meta.request_id;
assert.equal(priceRequest.headers.get("x-request-id"), priceRequestId);
console.log(`PASS HTTP versioned price | status=201 request_id=${priceRequestId}`);

const operatorLogin = await fetch(`${baseUrl}/api/v1/admin/auth/login`, {
  method: "POST",
  headers: {
    ...requestHeaders(baseUrl),
    "content-type": "application/json",
  },
  body: JSON.stringify({
    email: "operator-e2e@fco.invalid",
    password,
  }),
});
assert.equal(operatorLogin.status, 200);
const operatorCookie =
  operatorLogin.headers.get("set-cookie")?.match(/__Host-fco_sid=([^;]+)/)?.[0];
assert.ok(operatorCookie);
const forbidden = await fetch(`${baseUrl}/api/v1/admin/products`, {
  headers: requestHeaders(baseUrl, operatorCookie),
});
assert.equal(forbidden.status, 403);
assert.equal((await forbidden.json()).error.code, "FCO-1003");
console.log("PASS HTTP RBAC denial | status=403 code=FCO-1003");

const logout = await fetch(`${baseUrl}/api/v1/admin/auth/logout`, {
  method: "POST",
  headers: requestHeaders(baseUrl, cookie),
});
assert.equal(logout.status, 204);
assert.match(logout.headers.get("set-cookie") ?? "", /Max-Age=0/);
const afterLogout = await fetch(`${baseUrl}/api/v1/admin/products`, {
  headers: requestHeaders(baseUrl, cookie),
});
assert.equal(afterLogout.status, 401);
console.log("PASS HTTP central logout | status=204 then 401");

const db = new Client({ connectionString: databaseUrl });
await db.connect();
try {
  const loginAudit = await db.query(
    `select count(*)::int as count
       from sys.audit_log
      where action = 'auth.login'
        and actor_id = $1::uuid
        and request_id = $2`,
    [adminId, loginRequestId],
  );
  assert.equal(loginAudit.rows[0].count, 1);
  const createdAudit = await db.query(
    `select count(*)::int as count
       from sys.audit_log
      where action = 'product.create'
        and entity_id = $1::uuid`,
    [createBody.data.id],
  );
  assert.equal(createdAudit.rows[0].count, 1);
  const priceAudit = await db.query(
    `select count(*)::int as count
       from sys.audit_log
      where action = 'price.set'
        and actor_id = $1::uuid
        and request_id = $2
        and permission = 'pricing.price.update'`,
    [adminId, priceRequestId],
  );
  assert.equal(priceAudit.rows[0].count, 1);
  const history = await db.query(
    `select count(*)::int as count,
            bool_and(amount_rial in (100000, 125000)) as amounts_preserved
       from pricing.prices
      where variant_id = $1::uuid and channel = 'web'`,
    [variantId],
  );
  assert.equal(history.rows[0].count, 2);
  assert.equal(history.rows[0].amounts_preserved, true);
} finally {
  await db.end();
}
console.log("PASS PostgreSQL audit + immutable price history | actor and request IDs verified");
