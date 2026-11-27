import assert from "node:assert/strict";
import { createHmac } from "node:crypto";
import { Client } from "pg";

const baseUrl = process.env.FCO_ADMIN_E2E_BASE_URL;
const databaseUrl = process.env.DATABASE_URL;
const email = process.env.FCO_E2E_STAFF_EMAIL ?? "admin-e2e@fco.invalid";
const operatorEmail = process.env.FCO_E2E_OPERATOR_EMAIL ?? "operator-e2e@fco.invalid";
const setupEmail = process.env.FCO_E2E_SETUP_EMAIL ?? "mfa-setup-e2e@fco.invalid";
const password = process.env.FCO_E2E_STAFF_PASSWORD;
const variantId = process.env.FCO_E2E_VARIANT_ID;
const productId = process.env.FCO_E2E_PRODUCT_ID;
const adminId = process.env.FCO_E2E_ADMIN_ID;
const operatorId = process.env.FCO_E2E_OPERATOR_ID;
const setupStaffId = process.env.FCO_E2E_SETUP_STAFF_ID;
const totpSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
if (
  !baseUrl ||
  !databaseUrl ||
  !password ||
  !variantId ||
  !productId ||
  !adminId ||
  !operatorId ||
  !setupStaffId
) {
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

function cookieFrom(response, name) {
  const value = response.headers.get("set-cookie")?.match(
    new RegExp(`${name}=([^;]+)`),
  )?.[1];
  return value ? `${name}=${value}` : null;
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

const productPage = await fetch(`${baseUrl}/admin/products`, {
  headers: requestHeaders(baseUrl, cookie),
});
assert.equal(productPage.status, 200);
assert.match(await productPage.text(), /مدیریت محصول و قیمت/);
const securityPage = await fetch(`${baseUrl}/admin/settings/security`, {
  headers: requestHeaders(baseUrl, cookie),
});
assert.equal(securityPage.status, 200);
assert.match(await securityPage.text(), /امنیت و تأیید دومرحله‌ای/);
console.log("PASS HTTP admin product + security pages | status=200");

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

const detail = await fetch(`${baseUrl}/api/v1/admin/products/${createBody.data.id}`, {
  headers: requestHeaders(baseUrl, cookie),
});
const detailBody = await detail.json();
assert.equal(detail.status, 200);
assert.equal(detailBody.data.id, createBody.data.id);
assert.equal(detail.headers.get("x-request-id"), detailBody.meta.request_id);
console.log("PASS HTTP admin product detail | status=200");

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

const createVariant = await fetch(
  `${baseUrl}/api/v1/admin/products/${createBody.data.id}/variants`,
  {
    method: "POST",
    headers: {
      ...requestHeaders(baseUrl, cookie),
      "content-type": "application/json",
    },
    body: JSON.stringify({ sku: "ADMIN-E2E-CREATED-SKU", weight_g: 450 }),
  },
);
const createVariantBody = await createVariant.json();
assert.equal(createVariant.status, 201);
const createdVariants = await fetch(
  `${baseUrl}/api/v1/admin/products/${createBody.data.id}/variants`,
  { headers: requestHeaders(baseUrl, cookie) },
);
const createdVariantsBody = await createdVariants.json();
assert.equal(createdVariants.status, 200);
assert.ok(createdVariantsBody.data.some((item) => item.id === createVariantBody.data.id));
console.log("PASS HTTP variant create + list | status=201/200");

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

const variantHistory = await fetch(
  `${baseUrl}/api/v1/admin/products/${productId}/variants`,
  { headers: requestHeaders(baseUrl, cookie) },
);
const variantHistoryBody = await variantHistory.json();
assert.equal(variantHistory.status, 200);
const seededVariant = variantHistoryBody.data.find((item) => item.id === variantId);
assert.equal(seededVariant.prices.length, 2);
assert.deepEqual(
  seededVariant.prices.map((item) => item.amount_rial).sort((a, b) => a - b),
  [100000, 125000],
);
console.log("PASS HTTP admin price history | 2 immutable versions displayed");

const operatorLogin = await fetch(`${baseUrl}/api/v1/admin/auth/login`, {
  method: "POST",
  headers: {
    ...requestHeaders(baseUrl),
    "content-type": "application/json",
  },
  body: JSON.stringify({
    email: operatorEmail,
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

const setupLogin = await fetch(`${baseUrl}/api/v1/admin/auth/login`, {
  method: "POST",
  headers: {
    ...requestHeaders(baseUrl),
    "content-type": "application/json",
  },
  body: JSON.stringify({ email: setupEmail, password }),
});
const setupLoginBody = await setupLogin.json();
assert.equal(setupLogin.status, 403);
assert.equal(setupLoginBody.error.code, "FCO-1006");
const setupCookie = cookieFrom(setupLogin, "__Host-fco_mfa_setup");
assert.ok(setupCookie, "MFA setup challenge cookie was not set");
const setupPage = await fetch(`${baseUrl}/mfa/setup`, {
  headers: requestHeaders(baseUrl, setupCookie),
});
assert.equal(setupPage.status, 200);
assert.match(await setupPage.text(), /راه‌اندازی تأیید دومرحله‌ای/);
const setupStatus = await fetch(`${baseUrl}/api/v1/admin/auth/mfa`, {
  headers: requestHeaders(baseUrl, setupCookie),
});
assert.equal(setupStatus.status, 200);
assert.equal((await setupStatus.json()).data.setup_challenge, true);

const setupBegin = await fetch(`${baseUrl}/api/v1/admin/auth/mfa/setup`, {
  method: "POST",
  headers: requestHeaders(baseUrl, setupCookie),
});
const setupBeginBody = await setupBegin.json();
assert.equal(setupBegin.status, 200);
assert.match(setupBeginBody.data.otpauth_url, /^otpauth:\/\/totp\//);

const setupVerify = await fetch(`${baseUrl}/api/v1/admin/auth/mfa/verify`, {
  method: "POST",
  headers: {
    ...requestHeaders(baseUrl, setupCookie),
    "content-type": "application/json",
  },
  body: JSON.stringify({ code: totpCode(setupBeginBody.data.secret) }),
});
const setupVerifyBody = await setupVerify.json();
assert.equal(setupVerify.status, 200);
assert.equal(setupVerifyBody.data.recovery_codes.length, 10);
assert.equal(setupVerifyBody.data.session_established, true);
const setupSessionCookie = cookieFrom(setupVerify, "__Host-fco_sid");
assert.ok(setupSessionCookie, "MFA setup did not issue the authenticated session");
console.log("PASS HTTP MFA enrollment + TOTP verification | 10 recovery codes issued");

const enabledStatus = await fetch(`${baseUrl}/api/v1/admin/auth/mfa`, {
  headers: requestHeaders(baseUrl, setupSessionCookie),
});
assert.equal(enabledStatus.status, 200);
assert.equal((await enabledStatus.json()).data.enabled, true);

const setupLogout = await fetch(`${baseUrl}/api/v1/admin/auth/logout`, {
  method: "POST",
  headers: requestHeaders(baseUrl, setupSessionCookie),
});
assert.equal(setupLogout.status, 204);
const recoveryLogin = await fetch(`${baseUrl}/api/v1/admin/auth/login`, {
  method: "POST",
  headers: {
    ...requestHeaders(baseUrl),
    "content-type": "application/json",
  },
  body: JSON.stringify({
    email: setupEmail,
    password,
    recovery_code: setupVerifyBody.data.recovery_codes[0],
  }),
});
assert.equal(recoveryLogin.status, 200);
const recoverySessionCookie = cookieFrom(recoveryLogin, "__Host-fco_sid");
assert.ok(recoverySessionCookie);
const recoveryLogout = await fetch(`${baseUrl}/api/v1/admin/auth/logout`, {
  method: "POST",
  headers: requestHeaders(baseUrl, recoverySessionCookie),
});
assert.equal(recoveryLogout.status, 204);
const reusedRecoveryLogin = await fetch(`${baseUrl}/api/v1/admin/auth/login`, {
  method: "POST",
  headers: {
    ...requestHeaders(baseUrl),
    "content-type": "application/json",
  },
  body: JSON.stringify({
    email: setupEmail,
    password,
    recovery_code: setupVerifyBody.data.recovery_codes[0],
  }),
});
assert.equal(reusedRecoveryLogin.status, 401);
assert.equal((await reusedRecoveryLogin.json()).error.code, "FCO-1006");
console.log("PASS HTTP one-time recovery login | first=200 reuse=401");

const rateLimitEmail = `rate-limit-${Date.now()}@fco.invalid`;
for (let attempt = 1; attempt <= 5; attempt += 1) {
  const rejected = await fetch(`${baseUrl}/api/v1/admin/auth/login`, {
    method: "POST",
    headers: {
      ...requestHeaders(baseUrl),
      "content-type": "application/json",
    },
    body: JSON.stringify({ email: rateLimitEmail, password: "wrong-password" }),
  });
  assert.equal(rejected.status, 401, `login attempt ${attempt} should be rejected as invalid`);
}
const rateLimited = await fetch(`${baseUrl}/api/v1/admin/auth/login`, {
  method: "POST",
  headers: {
    ...requestHeaders(baseUrl),
    "content-type": "application/json",
  },
  body: JSON.stringify({ email: rateLimitEmail, password: "wrong-password" }),
});
assert.equal(rateLimited.status, 429);
assert.equal((await rateLimited.json()).error.code, "FCO-1007");
assert.ok(Number(rateLimited.headers.get("retry-after")) > 0);
console.log("PASS HTTP admin login rate limit | sixth attempt=429 with Retry-After");

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
  const mfaAudit = await db.query(
    `select count(*) filter (where action = 'auth.mfa_enabled')::int as enabled_count,
            count(*) filter (where action = 'auth.mfa_recovery_used')::int as recovery_count
       from sys.audit_log
      where actor_id = $1::uuid
        and request_id = any($2::text[])`,
    [setupStaffId, [setupVerify.headers.get("x-request-id"), recoveryLogin.headers.get("x-request-id"), reusedRecoveryLogin.headers.get("x-request-id")]],
  );
  assert.ok(mfaAudit.rows[0].enabled_count >= 1);
  assert.equal(mfaAudit.rows[0].recovery_count, 1);
  const remainingCodes = await db.query(
    `select count(*)::int as count
       from iam.mfa_factors
      where user_id = $1::uuid and kind = 'recovery_code'
        and confirmed_at is not null and disabled_at is null`,
    [setupStaffId],
  );
  assert.equal(remainingCodes.rows[0].count, 9);
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
