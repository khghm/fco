import assert from "node:assert/strict";
import { Client } from "pg";

const baseUrl = process.env.FCO_E2E_BASE_URL;
const databaseUrl = process.env.FCO_E2E_DATABASE_URL;
if (!baseUrl || !databaseUrl || process.env.FCO_E2E_MODE !== "true") {
  throw new Error("Checkout E2E requires the storefront, isolated database, and E2E mode.");
}

const database = new Client({ connectionString: databaseUrl });
await database.connect();

const address = {
  recipient_name: "مشتری آزمایشی",
  mobile: "09120000000",
  province: "تهران",
  city: "تهران",
  postal_code: "1234567890",
  address: "خیابان آزمایشی، پلاک ۱",
};
const json = (value) => JSON.stringify(value);

async function request(path, { method = "GET", cookie, body, idempotencyKey } = {}) {
  const headers = { origin: baseUrl, "x-request-id": crypto.randomUUID() };
  if (cookie) headers.cookie = cookie;
  if (body !== undefined) headers["content-type"] = "application/json";
  if (idempotencyKey) headers["idempotency-key"] = idempotencyKey;
  const response = await fetch(new URL(path, baseUrl), {
    method,
    headers,
    ...(body === undefined ? {} : { body: json(body) }),
  });
  const responseBody = await response.json();
  assert.equal(response.headers.get("x-request-id"), responseBody.meta?.request_id ?? responseBody.error?.request_id);
  return { response, body: responseBody };
}

async function newGuestCart(items) {
  const initial = await request("/api/v1/cart");
  assert.equal(initial.response.status, 200, json(initial.body));
  const cartId = initial.response.headers
    .get("set-cookie")
    ?.match(/__Host-fco_cart_sid=([^;]+)/)?.[1];
  assert.ok(cartId, "guest cart cookie should be set");
  const cookie = `__Host-fco_cart_sid=${cartId}`;
  for (const [variantId, quantity] of items) {
    const item = variantId.startsWith("CART-")
      ? { sku: variantId, quantity, price_rial: 1 }
      : { variant_id: variantId, quantity, price_rial: 1 };
    const added = await request("/api/v1/cart/items", {
      method: "POST",
      cookie,
      body: item,
    });
    assert.equal(added.response.status, 201, json(added.body));
  }
  return { cartId, cookie };
}

async function placeGuestOrder(cookie, key, overrides = {}) {
  return request("/api/v1/checkout/orders", {
    method: "POST",
    cookie,
    idempotencyKey: key,
    body: {
      shipping_address: address,
      guest_email: "checkout-e2e@example.invalid",
      guest_mobile: address.mobile,
      ...overrides,
    },
  });
}

async function completePayment(paymentUrl, outcome, cookie) {
  const url = new URL(paymentUrl, baseUrl);
  const paymentId = url.pathname.split("/").at(-1);
  const token = url.searchParams.get("token");
  assert.ok(paymentId);
  assert.match(token ?? "", /^[A-Za-z0-9_-]{43}$/);
  return request(`/api/v1/payments/mock/${paymentId}/complete`, {
    method: "POST",
    cookie,
    body: { token, outcome },
  });
}

try {
  const cart = await newGuestCart([
    ["e4000000-0000-0000-0000-000000000001", 1],
    ["e4000000-0000-0000-0000-000000000002", 1],
  ]);
  const quote = await request("/api/v1/checkout/quote", {
    method: "POST",
    cookie: cart.cookie,
    body: {},
  });
  assert.equal(quote.response.status, 200, json(quote.body));
  assert.equal(quote.body.data.subtotal_rial, 1_100_000);
  assert.equal(quote.body.data.shipping_rial, 500_000);
  assert.equal(quote.body.data.tax_amount_rial, 0);
  assert.equal(quote.body.data.total_rial, 1_600_000);
  assert.equal(quote.body.data.items.length, 2);

  const placed = await placeGuestOrder(cart.cookie, "checkout-e2e-success-001");
  assert.equal(placed.response.status, 201, json(placed.body));
  const order = placed.body.data;
  assert.equal(order.total_rial, 1_600_000);
  assert.equal(order.guest_cart_cleanup_pending, false);
  assert.match(order.payment_url, /^\/mock-payment\/[0-9a-f-]+\?token=/i);
  const duplicate = await placeGuestOrder(cart.cookie, "checkout-e2e-success-001");
  assert.equal(duplicate.response.status, 200, json(duplicate.body));
  assert.equal(duplicate.body.data.order_id, order.order_id);
  assert.equal(duplicate.body.data.payment_id, order.payment_id);
  const conflictingReplay = await placeGuestOrder(cart.cookie, "checkout-e2e-success-001", {
    shipping_address: { ...address, city: "کرج" },
  });
  assert.equal(conflictingReplay.response.status, 409);

  const paymentPage = await fetch(new URL(order.payment_url, baseUrl));
  assert.equal(paymentPage.status, 200);
  assert.match(await paymentPage.text(), /درگاه آزمایشی/);
  const wrongToken = await request(
    `/api/v1/payments/mock/${order.payment_id}/complete`,
    {
      method: "POST",
      body: { token: "A".repeat(43), outcome: "succeeded" },
    },
  );
  assert.equal(wrongToken.response.status, 401);

  const payment = await completePayment(order.payment_url, "succeeded", cart.cookie);
  assert.equal(payment.response.status, 200, json(payment.body));
  assert.equal(payment.body.data.result, "succeeded");
  const paidState = await database.query(
    `select order_row.status, order_row.payment_status, transaction.status as transaction_status
       from oms.orders order_row
       join pay.transactions transaction on transaction.order_id = order_row.id
      where order_row.id = $1::uuid`,
    [order.order_id],
  );
  assert.deepEqual(paidState.rows[0], {
    status: "paid",
    payment_status: "succeeded",
    transaction_status: "succeeded",
  });
  const committedReservations = await database.query(
    `select count(*)::int as count
       from inv.reservations reservation
       join oms.order_lines line on line.id = reservation.order_line_id
      where line.order_id = $1::uuid and reservation.status = 'committed'`,
    [order.order_id],
  );
  assert.equal(committedReservations.rows[0].count, 2);
  const duplicatePayment = await completePayment(order.payment_url, "succeeded", cart.cookie);
  assert.equal(duplicatePayment.response.status, 200, json(duplicatePayment.body));
  assert.equal(duplicatePayment.body.data.result, "succeeded");
  console.log("PASS checkout quote, server-side totals, idempotent order, payment success and callback replay");

  const failedCart = await newGuestCart([
    ["e4000000-0000-0000-0000-000000000002", 1],
  ]);
  const failedOrderResponse = await placeGuestOrder(failedCart.cookie, "checkout-e2e-failed-001");
  assert.equal(failedOrderResponse.response.status, 201, json(failedOrderResponse.body));
  const failedOrder = failedOrderResponse.body.data;
  const failedPayment = await completePayment(failedOrder.payment_url, "failed", failedCart.cookie);
  assert.equal(failedPayment.response.status, 200, json(failedPayment.body));
  assert.equal(failedPayment.body.data.result, "failed");
  const restoredCookie = failedPayment.response.headers
    .get("set-cookie")
    ?.match(/__Host-fco_cart_sid=([^;]+)/)?.[0];
  assert.ok(restoredCookie);
  const restoredCart = await request("/api/v1/cart", { cookie: restoredCookie });
  assert.equal(restoredCart.response.status, 200, json(restoredCart.body));
  assert.equal(restoredCart.body.data.items.length, 1);
  assert.equal(restoredCart.body.data.items[0].quantity, 1);

  const changedRestoredCart = await request("/api/v1/cart/items", {
    method: "POST",
    cookie: restoredCookie,
    body: { variant_id: "e4000000-0000-0000-0000-000000000002", quantity: 1 },
  });
  assert.equal(changedRestoredCart.response.status, 201, json(changedRestoredCart.body));
  const failedPaymentReplay = await completePayment(
    failedOrder.payment_url,
    "failed",
    restoredCookie,
  );
  assert.equal(failedPaymentReplay.response.status, 200, json(failedPaymentReplay.body));
  const afterReplay = await request("/api/v1/cart", { cookie: restoredCookie });
  assert.equal(afterReplay.response.status, 200, json(afterReplay.body));
  assert.equal(afterReplay.body.data.items[0].quantity, 2);
  console.log("PASS failed mock payment restores guest cart once; callback replay preserves later cart changes");

  await database.query(
    `insert into iam.users (id, mobile, full_name, status, mfa_required)
     values ('d4000000-0000-0000-0000-000000000002', '09123334444',
             'Checkout E2E Account', 'active', false)
     on conflict (id) do update set
       mobile = excluded.mobile,
       full_name = excluded.full_name,
       status = 'active',
       mfa_required = false,
       archived_at = null`,
  );
  const otpRequest = await request("/api/v1/auth/otp/request", {
    method: "POST",
    body: { mobile: "09123334444" },
  });
  assert.equal(otpRequest.response.status, 202, json(otpRequest.body));
  const otpResult = await database.query(
    `select code from sys.otp_spool
      where mobile = '09123334444' and expires_at > now()
      order by created_at desc limit 1`,
  );
  const otpCode = otpResult.rows[0]?.code;
  assert.match(otpCode ?? "", /^[0-9]{6}$/);
  const accountLogin = await request("/api/v1/auth/otp/verify", {
    method: "POST",
    body: { mobile: "09123334444", code: otpCode },
  });
  assert.equal(accountLogin.response.status, 200, json(accountLogin.body));
  const customerCookie = accountLogin.response.headers
    .get("set-cookie")
    ?.match(/__Host-fco_customer_sid=([^;]+)/)?.[0];
  assert.ok(customerCookie);
  const accountItem = await request("/api/v1/cart/items", {
    method: "POST",
    cookie: customerCookie,
    body: { variant_id: "e4000000-0000-0000-0000-000000000002", quantity: 1 },
  });
  assert.equal(accountItem.response.status, 200, json(accountItem.body));
  const accountOrderRequest = () =>
    request("/api/v1/checkout/orders", {
      method: "POST",
      cookie: customerCookie,
      idempotencyKey: "checkout-e2e-account-001",
      body: {
        shipping_address: address,
        guest_email: "",
        guest_mobile: "",
      },
    });
  const accountOrderResponse = await accountOrderRequest();
  const accountOrder = accountOrderResponse.body.data;
  const accountFailure = await completePayment(
    accountOrder.payment_url,
    "failed",
    customerCookie,
  );
  assert.equal(accountFailure.response.status, 200, json(accountFailure.body));
  const accountCart = await request("/api/v1/cart", { cookie: customerCookie });
  assert.equal(accountCart.response.status, 200, json(accountCart.body));
  assert.equal(accountCart.body.data.items.length, 1);
  assert.equal(accountCart.body.data.items[0].quantity, 1);
  console.log("PASS authenticated cart checkout and account cart restoration after failed payment");

  const expiredCart = await newGuestCart([
    ["e4000000-0000-0000-0000-000000000001", 1],
  ]);
  const expiredOrderResponse = await placeGuestOrder(expiredCart.cookie, "checkout-e2e-expired-001");
  assert.equal(expiredOrderResponse.response.status, 201, json(expiredOrderResponse.body));
  const expiredOrder = expiredOrderResponse.body.data;
  await database.query(
    "update oms.orders set payment_deadline = now() - interval '1 second' where id = $1::uuid",
    [expiredOrder.order_id],
  );
  const expiredPayment = await completePayment(
    expiredOrder.payment_url,
    "succeeded",
    expiredCart.cookie,
  );
  assert.equal(expiredPayment.response.status, 200, json(expiredPayment.body));
  assert.equal(expiredPayment.body.data.result, "expired");
  const expiredState = await database.query(
    `select order_row.status, payment.status as payment_status,
            bool_and(reservation.status = 'released') as reservations_released
       from oms.orders order_row
       join pay.transactions payment on payment.order_id = order_row.id
       join oms.order_lines line on line.order_id = order_row.id
       join inv.reservations reservation on reservation.order_line_id = line.id
      where order_row.id = $1::uuid
      group by order_row.status, payment.status`,
    [expiredOrder.order_id],
  );
  assert.deepEqual(expiredState.rows[0], {
    status: "expired",
    payment_status: "expired",
    reservations_released: true,
  });
  console.log("PASS expired payment releases active reservation and returns expired order state");

  const insufficientCart = await newGuestCart([
    ["e4000000-0000-0000-0000-000000000001", 4],
  ]);
  const insufficientQuote = await request("/api/v1/checkout/quote", {
    method: "POST",
    cookie: insufficientCart.cookie,
    body: {},
  });
  assert.equal(insufficientQuote.response.status, 409);
  const beforeOrders = await database.query("select count(*)::int as count from oms.orders");
  const insufficientOrder = await placeGuestOrder(
    insufficientCart.cookie,
    "checkout-e2e-stock-001",
  );
  assert.equal(insufficientOrder.response.status, 409, json(insufficientOrder.body));
  const afterOrders = await database.query("select count(*)::int as count from oms.orders");
  assert.equal(afterOrders.rows[0].count, beforeOrders.rows[0].count);
  const untouchedCart = await request("/api/v1/cart", { cookie: insufficientCart.cookie });
  assert.equal(untouchedCart.response.status, 200, json(untouchedCart.body));
  assert.equal(untouchedCart.body.data.items[0].quantity, 4);
  console.log("PASS insufficient stock rolls back order and reservation while preserving cart");
} finally {
  await database.end();
}
