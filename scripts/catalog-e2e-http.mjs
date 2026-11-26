import assert from "node:assert/strict";

const baseUrl = process.env.FCO_E2E_BASE_URL;
if (!baseUrl) {
  throw new Error("FCO_E2E_BASE_URL must point to the running storefront.");
}

async function getWithRetry(url) {
  const deadline = Date.now() + 30_000;
  let lastError;

  while (Date.now() < deadline) {
    try {
      return await fetch(url);
    } catch (error) {
      lastError = error;
      await new Promise((resolve) => setTimeout(resolve, 300));
    }
  }

  throw new Error("Storefront did not become reachable within 30 seconds.", {
    cause: lastError,
  });
}

const validResponse = await getWithRetry(
  `${baseUrl}/api/v1/products?q=FCO`,
);
const validBody = await validResponse.json();
assert.equal(validResponse.status, 200);
assert.equal(validBody.data.length, 1);
assert.equal(validBody.data[0].slug, "e2e-shirt");
assert.equal(validBody.data[0].price_rial, 650000);
assert.equal(validBody.data[0].available_qty, 4);
assert.equal(validBody.data[0].in_stock, true);
assert.equal(validResponse.headers.get("x-request-id"), validBody.meta.request_id);
assert.equal(validResponse.headers.get("x-ratelimit-limit"), "20");
assert.equal(validResponse.headers.get("x-ratelimit-remaining"), "19");
console.log(
  `PASS HTTP GET valid | status=200 slug=e2e-shirt price_rial=650000 available_qty=4 request_id=${validBody.meta.request_id}`,
);

const detailResponse = await getWithRetry(
  `${baseUrl}/api/v1/products/e2e-shirt`,
);
const detailBody = await detailResponse.json();
assert.equal(detailResponse.status, 200);
assert.equal(detailBody.data.slug, "e2e-shirt");
assert.equal(detailBody.data.description, "محصول نمونه برای آزمون endpoint");
assert.equal(detailBody.data.media.length, 1);
assert.equal(detailBody.data.media[0].key, "catalog/e2e-shirt/front.png");
assert.equal(detailBody.data.media[0].alt, "نمای جلو");
assert.equal(
  new URL(detailBody.data.media[0].url).searchParams.get("X-Amz-Expires"),
  "900",
);
assert.deepEqual(detailBody.data.variants, [
  {
    sku: "E2E-SHIRT-001",
    barcode: null,
    price_rial: 650000,
    compare_at_rial: 800000,
    available_qty: 4,
  },
]);
assert.equal(detailResponse.headers.get("x-request-id"), detailBody.meta.request_id);
console.log(
  `PASS HTTP GET product detail | status=200 slug=e2e-shirt media=1 signed_ttl=900s variants=1 request_id=${detailBody.meta.request_id}`,
);

const mediaResponse = await fetch(detailBody.data.media[0].url);
assert.equal(mediaResponse.status, 200);
assert.match(mediaResponse.headers.get("content-type") ?? "", /^image\/png/);
console.log("PASS HTTP GET presigned media | status=200 content_type=image/png");

const optimizedImageUrl = new URL("/_next/image", baseUrl);
optimizedImageUrl.searchParams.set("url", detailBody.data.media[0].url);
optimizedImageUrl.searchParams.set("w", "640");
optimizedImageUrl.searchParams.set("q", "75");
const optimizedImageResponse = await fetch(optimizedImageUrl);
assert.equal(optimizedImageResponse.status, 200);
assert.match(optimizedImageResponse.headers.get("content-type") ?? "", /^image\//);
console.log("PASS HTTP GET optimized image | status=200");

const detailPageResponse = await getWithRetry(
  `${baseUrl}/products/e2e-shirt`,
);
const detailPage = await detailPageResponse.text();
assert.equal(detailPageResponse.status, 200);
assert.ok(detailPage.includes("پیراهن آزمایشی FCO"));
assert.ok(detailPage.includes("E2E-SHIRT-001"));
assert.ok(detailPage.includes('alt="نمای جلو"'));
console.log("PASS HTTP GET product page | status=200 title and variant rendered");

const missingPageResponse = await fetch(
  `${baseUrl}/products/not-a-published-product`,
);
assert.equal(missingPageResponse.status, 404);
console.log("PASS HTTP GET unpublished product page | status=404");

const invalidResponse = await fetch(
  `${baseUrl}/api/v1/products?page_size=61`,
);
const invalidBody = await invalidResponse.json();
assert.equal(invalidResponse.status, 400);
assert.equal(invalidBody.error.code, "FCO-1001");
assert.equal(
  invalidResponse.headers.get("x-request-id"),
  invalidBody.error.request_id,
);
console.log(
  `PASS HTTP GET invalid | status=400 code=FCO-1001 request_id=${invalidBody.error.request_id}`,
);

const missingResponse = await fetch(
  `${baseUrl}/api/v1/products/not-a-published-product`,
);
const missingBody = await missingResponse.json();
assert.equal(missingResponse.status, 404);
assert.equal(missingBody.error.code, "FCO-1004");
assert.equal(
  missingResponse.headers.get("x-request-id"),
  missingBody.error.request_id,
);
console.log(
  `PASS HTTP GET unpublished product | status=404 code=FCO-1004 request_id=${missingBody.error.request_id}`,
);

let remaining = Number(missingResponse.headers.get("x-ratelimit-remaining"));
assert.ok(Number.isInteger(remaining) && remaining >= 0);
const spoofedHeadersResponse = await fetch(`${baseUrl}/api/v1/products?q=FCO`, {
  headers: {
    "X-Real-IP": "203.0.113.20",
    "X-Forwarded-For": "203.0.113.20",
  },
});
assert.equal(spoofedHeadersResponse.status, 200);
assert.equal(
  Number(spoofedHeadersResponse.headers.get("x-ratelimit-remaining")),
  remaining - 1,
);
assert.equal(spoofedHeadersResponse.headers.get("retry-after"), null);
remaining = Number(spoofedHeadersResponse.headers.get("x-ratelimit-remaining"));
while (remaining > 0) {
  const allowed = await fetch(`${baseUrl}/api/v1/products?q=FCO`);
  assert.equal(allowed.status, 200);
  remaining = Number(allowed.headers.get("x-ratelimit-remaining"));
}

const limitedResponse = await fetch(`${baseUrl}/api/v1/products?q=FCO`);
const limitedBody = await limitedResponse.json();
assert.equal(limitedResponse.status, 429);
assert.equal(limitedBody.error.code, "FCO-1007");
assert.equal(
  limitedResponse.headers.get("x-request-id"),
  limitedBody.error.request_id,
);
assert.equal(limitedResponse.headers.get("x-ratelimit-limit"), "20");
assert.equal(limitedResponse.headers.get("x-ratelimit-remaining"), "0");
assert.ok(Number(limitedResponse.headers.get("retry-after")) >= 1);
console.log(
  `PASS HTTP GET rate limit | status=429 limit=20 retry_after=${limitedResponse.headers.get("retry-after")} request_id=${limitedBody.error.request_id}`,
);
