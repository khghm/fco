import type { PoolClient, QueryResultRow } from "pg";
import { getPostgresPool } from "./postgres";
import type { GuestCartLine } from "./customer-auth";
import type { PublicCartItem } from "./cart";

export interface CheckoutQuoteItem {
  variant_id: string;
  quantity: number;
  sku: string | null;
  product_title: string | null;
  unit_price_rial: number;
  line_total_rial: number;
}

export interface CheckoutQuote {
  items: CheckoutQuoteItem[];
  subtotal_rial: number;
  shipping_rial: number;
  tax_amount_rial: number;
  total_rial: number;
}

export interface CheckoutOrder {
  order_id: string;
  order_number: string;
  payment_id: string;
  subtotal_rial: number;
  shipping_rial: number;
  tax_amount_rial: number;
  total_rial: number;
  payment_deadline: string;
  status: "awaiting_payment" | "paid" | "cancelled" | "expired";
  payment_status: "pending" | "succeeded" | "failed" | "expired";
  already_placed: boolean;
}

export interface CheckoutOrderInput {
  customerId: string | null;
  guestCartId: string | null;
  guestEmail: string | null;
  guestMobile: string | null;
  shippingAddress: Record<string, string>;
  idempotencyKey: string;
  requestHash: string;
  guestItems: GuestCartLine[] | null;
  paymentId: string;
  mockTokenHash: Buffer;
  orderYear: number;
  requestId: string;
}

export interface MockPaymentDetails {
  order_id: string;
  order_number: string;
  amount_rial: string;
  status: "initiated" | "succeeded" | "failed" | "unknown" | "reconciled" | "expired";
  payment_deadline: Date;
  mock_token_hash: Buffer;
}

export interface MockPaymentResult {
  result: "succeeded" | "failed" | "expired";
  order_id: string;
  order_number: string;
  customer_id: string | null;
  guest_cart_id: string | null;
  restore_cart_id: string | null;
  restore_items: Array<{ variant_id: string; quantity: number }> | null;
}

interface CheckoutOrderRow extends QueryResultRow {
  order_id: string;
  order_number: string;
  payment_id: string;
  subtotal_rial: string | number;
  shipping_rial: string | number;
  tax_amount_rial: string | number;
  total_rial: string | number;
  payment_deadline: Date;
  status: CheckoutOrder["status"];
  payment_status: CheckoutOrder["payment_status"];
  already_placed: boolean;
}

interface MockPaymentDetailsRow extends QueryResultRow, MockPaymentDetails {}
interface MockPaymentResultRow extends QueryResultRow, MockPaymentResult {}

export class CheckoutUnavailableError extends Error {
  readonly code = "FCO-2001";

  constructor() {
    super("FCO-2001: no active warehouse can fulfill the complete cart.");
    this.name = "CheckoutUnavailableError";
  }
}

function safeRial(value: number | string, field: string): number {
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new RangeError(`Database returned an unsafe ${field} value.`);
  }
  return parsed;
}

function mapCheckoutOrder(row: CheckoutOrderRow): CheckoutOrder {
  return {
    order_id: row.order_id,
    order_number: row.order_number,
    payment_id: row.payment_id,
    subtotal_rial: safeRial(row.subtotal_rial, "subtotal_rial"),
    shipping_rial: safeRial(row.shipping_rial, "shipping_rial"),
    tax_amount_rial: safeRial(row.tax_amount_rial, "tax_amount_rial"),
    total_rial: safeRial(row.total_rial, "total_rial"),
    payment_deadline: row.payment_deadline.toISOString(),
    status: row.status,
    payment_status: row.payment_status,
    already_placed: row.already_placed,
  };
}

async function setApplicationRole(client: PoolClient): Promise<void> {
  await client.query("set local role fco_app");
}

export async function quoteCheckout(items: PublicCartItem[]): Promise<CheckoutQuote> {
  if (items.length === 0 || items.length > 50) {
    throw new RangeError("Checkout requires between one and fifty cart items.");
  }

  const quoteItems = items.map((item): CheckoutQuoteItem => {
    if (!item.sellable || item.price_rial === null || item.available_qty < item.quantity) {
      throw new RangeError("FCO-2001: one or more cart items are unavailable.");
    }
    const lineTotal = item.price_rial * item.quantity;
    if (!Number.isSafeInteger(lineTotal)) {
      throw new RangeError("Cart line total exceeds the supported range.");
    }
    return {
      variant_id: item.variant_id,
      quantity: item.quantity,
      sku: item.sku,
      product_title: item.product_title,
      unit_price_rial: item.price_rial,
      line_total_rial: lineTotal,
    };
  });
  const subtotal = quoteItems.reduce((sum, item) => sum + item.line_total_rial, 0);
  if (!Number.isSafeInteger(subtotal)) {
    throw new RangeError("Checkout subtotal exceeds the supported range.");
  }

  const client = await getPostgresPool("fco-shop-checkout-quote").connect();
  let transactionOpen = false;
  try {
    await client.query("begin read only");
    transactionOpen = true;
    await setApplicationRole(client);
    const fulfillment = await client.query<{ has_warehouse: boolean }>(
      `select exists (
         select warehouse.id
           from inv.warehouses warehouse
          where warehouse.is_active
            and not exists (
              select 1
                from jsonb_to_recordset($1::jsonb) as requested(variant_id uuid, quantity integer)
                left join inv.stock_balance balance
                  on balance.warehouse_id = warehouse.id
                 and balance.variant_id = requested.variant_id
               where balance.variant_id is null
                  or balance.on_hand - balance.reserved - balance.quarantined < requested.quantity
            )
       ) as has_warehouse`,
      [
        JSON.stringify(
          items.map(({ variant_id, quantity }) => ({ variant_id, quantity })),
        ),
      ],
    );
    if (fulfillment.rows[0]?.has_warehouse !== true) {
      throw new CheckoutUnavailableError();
    }
    const result = await client.query<{
      shipping_rial: number | string;
      tax_amount_rial: number | string;
    }>(
      `select sys.setting_int('shipping.flat_rate_rial') as shipping_rial,
              oms.tax_amount_rial($1::bigint, sys.setting_int('shipping.flat_rate_rial'))
                as tax_amount_rial`,
      [subtotal],
    );
    const shipping = safeRial(result.rows[0].shipping_rial, "shipping_rial");
    const tax = safeRial(result.rows[0].tax_amount_rial, "tax_amount_rial");
    const total = subtotal + shipping + tax;
    if (!Number.isSafeInteger(total)) {
      throw new RangeError("Checkout total exceeds the supported range.");
    }
    await client.query("commit");
    transactionOpen = false;
    return {
      items: quoteItems,
      subtotal_rial: subtotal,
      shipping_rial: shipping,
      tax_amount_rial: tax,
      total_rial: total,
    };
  } catch (error) {
    if (transactionOpen) {
      try {
        await client.query("rollback");
      } catch (rollbackError) {
        throw new AggregateError([error, rollbackError], "Checkout quote rollback failed.");
      }
    }
    throw error;
  } finally {
    client.release();
  }
}

async function checkoutOrderQuery(
  query: (client: PoolClient) => Promise<CheckoutOrderRow | undefined>,
  applicationName: string,
): Promise<CheckoutOrder | null> {
  const client = await getPostgresPool(applicationName).connect();
  let transactionOpen = false;
  try {
    await client.query("begin");
    transactionOpen = true;
    await setApplicationRole(client);
    const row = await query(client);
    await client.query("commit");
    transactionOpen = false;
    return row ? mapCheckoutOrder(row) : null;
  } catch (error) {
    if (transactionOpen) {
      try {
        await client.query("rollback");
      } catch (rollbackError) {
        throw new AggregateError([error, rollbackError], "Checkout transaction rollback failed.");
      }
    }
    throw error;
  } finally {
    client.release();
  }
}

export async function findCheckoutByIdempotency(
  customerId: string | null,
  guestCartId: string | null,
  idempotencyKey: string,
  requestHash: string,
): Promise<CheckoutOrder | null> {
  return checkoutOrderQuery(async (client) => {
    const result = await client.query<CheckoutOrderRow>(
      `select * from oms.find_checkout_by_idempotency(
         $1::uuid, $2::uuid, $3::text, $4::text
       )`,
      [customerId, guestCartId, idempotencyKey, requestHash],
    );
    return result.rows[0];
  }, "fco-shop-checkout-idempotency");
}

export async function placeCheckoutOrder(
  input: CheckoutOrderInput,
): Promise<CheckoutOrder> {
  const result = await checkoutOrderQuery(async (client) => {
    const rows = await client.query<CheckoutOrderRow>(
      `select * from oms.place_order(
         $1::uuid, $2::uuid, $3::citext, $4::varchar, $5::jsonb,
         $6::text, $7::text, $8::jsonb, $9::uuid, $10::bytea,
         $11::integer, $12::text
       )`,
      [
        input.customerId,
        input.guestCartId,
        input.guestEmail,
        input.guestMobile,
        JSON.stringify(input.shippingAddress),
        input.idempotencyKey,
        input.requestHash,
        input.guestItems === null
          ? null
          : JSON.stringify(
              input.guestItems.map((item) => ({
                variant_id: item.variantId,
                quantity: item.quantity,
              })),
            ),
        input.paymentId,
        input.mockTokenHash,
        input.orderYear,
        input.requestId,
      ],
    );
    return rows.rows[0];
  }, "fco-shop-checkout-place");
  if (!result) {
    throw new Error("Checkout transaction completed without returning an order.");
  }
  return result;
}

export async function pendingGuestCartCheckout(guestCartId: string): Promise<boolean> {
  const client = await getPostgresPool("fco-shop-checkout-cleanup").connect();
  try {
    await client.query("begin read only");
    await setApplicationRole(client);
    const result = await client.query<{ pending: boolean }>(
      "select oms.pending_guest_cart_checkout($1::uuid) as pending",
      [guestCartId],
    );
    await client.query("commit");
    return result.rows[0]?.pending ?? false;
  } catch (error) {
    try {
      await client.query("rollback");
    } catch (rollbackError) {
      throw new AggregateError([error, rollbackError], "Checkout cleanup lookup rollback failed.");
    }
    throw error;
  } finally {
    client.release();
  }
}

export async function completeGuestCartCheckout(guestCartId: string): Promise<void> {
  const client = await getPostgresPool("fco-shop-checkout-cleanup").connect();
  try {
    await client.query("begin");
    await setApplicationRole(client);
    await client.query("select oms.complete_guest_cart_checkout($1::uuid)", [guestCartId]);
    await client.query("commit");
  } catch (error) {
    try {
      await client.query("rollback");
    } catch (rollbackError) {
      throw new AggregateError([error, rollbackError], "Checkout cleanup update rollback failed.");
    }
    throw error;
  } finally {
    client.release();
  }
}

export async function pendingGuestCartRestore(
  guestCartId: string,
): Promise<{ restore_cart_id: string; items: GuestCartLine[] } | null> {
  const client = await getPostgresPool("fco-shop-checkout-restore").connect();
  try {
    await client.query("begin read only");
    await setApplicationRole(client);
    const result = await client.query<{
      restore_cart_id: string;
      items: Array<{ variant_id: string; quantity: number }>;
    }>("select * from oms.pending_guest_cart_restore($1::uuid)", [guestCartId]);
    await client.query("commit");
    const row = result.rows[0];
    return row
      ? {
          restore_cart_id: row.restore_cart_id,
          items: row.items.map((item) => ({
            variantId: item.variant_id,
            quantity: item.quantity,
          })),
        }
      : null;
  } catch (error) {
    try {
      await client.query("rollback");
    } catch (rollbackError) {
      throw new AggregateError([error, rollbackError], "Guest cart restore lookup rollback failed.");
    }
    throw error;
  } finally {
    client.release();
  }
}

export async function guestCartRestoreTarget(
  guestCartId: string,
): Promise<{ restore_cart_id: string; items: GuestCartLine[]; restore_pending: boolean } | null> {
  const client = await getPostgresPool("fco-shop-checkout-restore").connect();
  try {
    await client.query("begin read only");
    await setApplicationRole(client);
    const result = await client.query<{
      restore_cart_id: string;
      items: Array<{ variant_id: string; quantity: number }>;
      restore_pending: boolean;
    }>("select * from oms.guest_cart_restore_target($1::uuid)", [guestCartId]);
    await client.query("commit");
    const row = result.rows[0];
    return row
      ? {
          restore_cart_id: row.restore_cart_id,
          items: row.items.map((item) => ({
            variantId: item.variant_id,
            quantity: item.quantity,
          })),
          restore_pending: row.restore_pending,
        }
      : null;
  } catch (error) {
    try {
      await client.query("rollback");
    } catch (rollbackError) {
      throw new AggregateError([error, rollbackError], "Guest cart restore target rollback failed.");
    }
    throw error;
  } finally {
    client.release();
  }
}

export async function guestCartCheckoutState(
  guestCartId: string,
): Promise<"pending" | "succeeded" | "failed" | "expired" | null> {
  const client = await getPostgresPool("fco-shop-checkout-restore").connect();
  try {
    await client.query("begin read only");
    await setApplicationRole(client);
    const result = await client.query<{ status: "pending" | "succeeded" | "failed" | "expired" | null }>(
      "select oms.guest_cart_checkout_state($1::uuid) as status",
      [guestCartId],
    );
    await client.query("commit");
    return result.rows[0]?.status ?? null;
  } catch (error) {
    try {
      await client.query("rollback");
    } catch (rollbackError) {
      throw new AggregateError([error, rollbackError], "Guest cart checkout state rollback failed.");
    }
    throw error;
  } finally {
    client.release();
  }
}

export async function completeGuestCartRestore(guestCartId: string): Promise<void> {
  const client = await getPostgresPool("fco-shop-checkout-restore").connect();
  try {
    await client.query("begin");
    await setApplicationRole(client);
    await client.query("select oms.complete_guest_cart_restore($1::uuid)", [guestCartId]);
    await client.query("commit");
  } catch (error) {
    try {
      await client.query("rollback");
    } catch (rollbackError) {
      throw new AggregateError([error, rollbackError], "Guest cart restore update rollback failed.");
    }
    throw error;
  } finally {
    client.release();
  }
}

export async function mockPaymentDetails(
  paymentId: string,
): Promise<MockPaymentDetails | null> {
  const client = await getPostgresPool("fco-shop-mock-payment").connect();
  try {
    await client.query("begin read only");
    await setApplicationRole(client);
    const result = await client.query<MockPaymentDetailsRow>(
      "select * from pay.mock_payment_details($1::uuid)",
      [paymentId],
    );
    await client.query("commit");
    return result.rows[0] ?? null;
  } catch (error) {
    try {
      await client.query("rollback");
    } catch (rollbackError) {
      throw new AggregateError([error, rollbackError], "Mock payment lookup rollback failed.");
    }
    throw error;
  } finally {
    client.release();
  }
}

export async function completeMockPayment(
  paymentId: string,
  tokenHash: Buffer,
  outcome: "succeeded" | "failed",
  restoreCartId: string,
  requestId: string,
): Promise<MockPaymentResult> {
  const client = await getPostgresPool("fco-shop-mock-payment").connect();
  let transactionOpen = false;
  try {
    await client.query("begin");
    transactionOpen = true;
    await setApplicationRole(client);
    const result = await client.query<MockPaymentResultRow>(
      `select * from pay.complete_mock_payment(
         $1::uuid, $2::bytea, $3::text, $4::uuid, $5::text
       )`,
      [paymentId, tokenHash, outcome, restoreCartId, requestId],
    );
    await client.query("commit");
    transactionOpen = false;
    const row = result.rows[0];
    if (!row) {
      throw new Error("Mock payment completion returned no result.");
    }
    return row;
  } catch (error) {
    if (transactionOpen) {
      try {
        await client.query("rollback");
      } catch (rollbackError) {
        throw new AggregateError([error, rollbackError], "Mock payment rollback failed.");
      }
    }
    throw error;
  } finally {
    client.release();
  }
}

