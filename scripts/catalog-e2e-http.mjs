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
console.log(
  `PASS HTTP GET valid | status=200 slug=e2e-shirt price_rial=650000 available_qty=4 request_id=${validBody.meta.request_id}`,
);

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
