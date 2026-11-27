import type { PoolClient, QueryResultRow } from "pg";
import { getPostgresPool } from "./postgres";
import type { GuestCartLine } from "./customer-auth";

export interface PublicCartItem {
  variant_id: string;
  quantity: number;
  product_slug: string | null;
  product_title: string | null;
  sku: string | null;
  price_rial: number | null;
  available_qty: number;
  sellable: boolean;
}

interface PublicCartItemRow extends QueryResultRow {
  variant_id: string;
  quantity: number;
  product_slug: string | null;
  product_title: string | null;
  sku: string | null;
  price_rial: string | null;
  available_qty: number | string | null;
  sellable: boolean;
}

interface CartIdRow extends QueryResultRow {
  id: string;
}

function safeNonNegativeInteger(value: number | string, field: string): number {
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new RangeError(`Database returned an unsafe ${field} value.`);
  }
  return parsed;
}

function mapPublicCartItem(row: PublicCartItemRow): PublicCartItem {
  return {
    variant_id: row.variant_id,
    quantity: safeNonNegativeInteger(row.quantity, "cart quantity"),
    product_slug: row.product_slug,
    product_title: row.product_title,
    sku: row.sku,
    price_rial:
      row.price_rial === null
        ? null
        : safeNonNegativeInteger(row.price_rial, "price_rial"),
    available_qty: safeNonNegativeInteger(row.available_qty ?? 0, "available_qty"),
    sellable: row.sellable,
  };
}

export async function getPublicCartItems(
  items: GuestCartLine[],
): Promise<PublicCartItem[]> {
  if (items.length === 0) {
    return [];
  }

  const client = await getPostgresPool("fco-shop-cart").connect();
  let transactionOpen = false;
  try {
    await client.query("begin isolation level repeatable read read only");
    transactionOpen = true;
    await client.query("set local role fco_app");
    const result = await client.query<PublicCartItemRow>(
      `with requested as (
         select (item.value->>'variant_id')::uuid as variant_id,
                (item.value->>'quantity')::integer as quantity,
                item.position
           from jsonb_array_elements($1::jsonb)
             with ordinality as item(value, position)
       )
       select requested.variant_id,
              requested.quantity,
              product.slug as product_slug,
              product.title as product_title,
              variant.sku,
              current_price.amount_rial::text as price_rial,
              coalesce(stock.available_qty, 0) as available_qty,
              coalesce(
                product.status = 'published'
                and variant.is_active
                and variant.archived_at is null
                and current_price.amount_rial is not null,
                false
              ) as sellable
         from requested
         left join cat.variants variant on variant.id = requested.variant_id
         left join cat.products product on product.id = variant.product_id
         left join lateral (
           select price.amount_rial
             from pricing.prices price
            where price.variant_id = variant.id
              and price.channel = 'web'
              and price.effective_from <= now()
              and (price.effective_to is null or price.effective_to > now())
            order by price.effective_from desc
            limit 1
         ) current_price on true
         left join lateral (
           select sum(balance.on_hand - balance.reserved - balance.quarantined) as available_qty
             from inv.stock_balance balance
             join inv.warehouses warehouse on warehouse.id = balance.warehouse_id
            where balance.variant_id = variant.id
              and warehouse.is_active
         ) stock on true
        order by requested.position`,
      [
        JSON.stringify(
          items.map((item) => ({
            variant_id: item.variantId,
            quantity: item.quantity,
          })),
        ),
      ],
    );
    await client.query("commit");
    transactionOpen = false;
    return result.rows.map(mapPublicCartItem);
  } catch (error) {
    if (transactionOpen) {
      try {
        await client.query("rollback");
      } catch (rollbackError) {
        throw new AggregateError([error, rollbackError], "Cart read transaction rollback failed.");
      }
    }
    throw error;
  } finally {
    client.release();
  }
}

export async function readCustomerCart(userId: string): Promise<PublicCartItem[]> {
  const client = await getPostgresPool("fco-shop-cart").connect();
  let transactionOpen = false;
  try {
    await client.query("begin isolation level repeatable read read only");
    transactionOpen = true;
    await client.query("set local role fco_app");
    const cart = await client.query<CartIdRow>(
      "select id from shop.carts where user_id = $1::uuid and status = 'active' limit 1",
      [userId],
    );
    const cartId = cart.rows[0]?.id;
    if (!cartId) {
      await client.query("commit");
      transactionOpen = false;
      return [];
    }
    const result = await client.query<PublicCartItemRow>(
      `with requested as (
         select source.variant_id, source.quantity,
                row_number() over (order by source.variant_id) as position
           from shop.cart_items source
          where source.cart_id = $1::uuid
       )
       select requested.variant_id,
              requested.quantity,
              product.slug as product_slug,
              product.title as product_title,
              variant.sku,
              current_price.amount_rial::text as price_rial,
              coalesce(stock.available_qty, 0) as available_qty,
              coalesce(
                product.status = 'published'
                and variant.is_active
                and variant.archived_at is null
                and current_price.amount_rial is not null,
                false
              ) as sellable
         from requested
         left join cat.variants variant on variant.id = requested.variant_id
         left join cat.products product on product.id = variant.product_id
         left join lateral (
           select price.amount_rial
             from pricing.prices price
            where price.variant_id = variant.id
              and price.channel = 'web'
              and price.effective_from <= now()
              and (price.effective_to is null or price.effective_to > now())
            order by price.effective_from desc
            limit 1
         ) current_price on true
         left join lateral (
           select sum(balance.on_hand - balance.reserved - balance.quarantined) as available_qty
             from inv.stock_balance balance
             join inv.warehouses warehouse on warehouse.id = balance.warehouse_id
            where balance.variant_id = variant.id
              and warehouse.is_active
         ) stock on true
        order by requested.position`,
      [cartId],
    );
    await client.query("commit");
    transactionOpen = false;
    return result.rows.map(mapPublicCartItem);
  } catch (error) {
    if (transactionOpen) {
      try {
        await client.query("rollback");
      } catch (rollbackError) {
        throw new AggregateError([error, rollbackError], "Cart read transaction rollback failed.");
      }
    }
    throw error;
  } finally {
    client.release();
  }
}

export async function addCustomerCartItem(
  userId: string,
  variantId: string,
  quantity: number,
): Promise<void> {
  const client = await getPostgresPool("fco-shop-cart").connect();
  let transactionOpen = false;
  try {
    await client.query("begin");
    transactionOpen = true;
    await client.query("set local role fco_app");
    const cart = await client.query<CartIdRow>(
      `insert into shop.carts (user_id)
       values ($1::uuid)
       on conflict (user_id) where status = 'active'
       do update set updated_at = now()
       returning id`,
      [userId],
    );
    const cartId = cart.rows[0]?.id;
    if (!cartId) {
      throw new Error("Customer cart creation did not return an identifier.");
    }
    await client.query(
      `insert into shop.cart_items (cart_id, variant_id, quantity)
       values ($1::uuid, $2::uuid, $3::integer)
       on conflict (cart_id, variant_id)
       do update set quantity = shop.cart_items.quantity + excluded.quantity,
                     updated_at = now()`,
      [cartId, variantId, quantity],
    );
    await client.query("commit");
    transactionOpen = false;
  } catch (error) {
    if (transactionOpen) {
      try {
        await client.query("rollback");
      } catch (rollbackError) {
        throw new AggregateError([error, rollbackError], "Cart update transaction rollback failed.");
      }
    }
    throw error;
  } finally {
    client.release();
  }
}

export async function mergeGuestCart(
  client: PoolClient,
  guestCartId: string,
  userId: string,
  items: GuestCartLine[],
): Promise<void> {
  await client.query(
    "select cart_id from shop.merge_guest_cart($1::uuid, $2::uuid, $3::jsonb)",
    [
      guestCartId,
      userId,
      JSON.stringify(
        items.map(({ variantId, quantity }) => ({
          variant_id: variantId,
          quantity,
        })),
      ),
    ],
  );
}

export async function completeGuestCartMerge(
  guestCartId: string,
  userId: string,
): Promise<void> {
  const client = await getPostgresPool("fco-shop-cart").connect();
  let transactionOpen = false;
  try {
    await client.query("begin");
    transactionOpen = true;
    await client.query("set local role fco_app");
    const result = await client.query<{ completed: boolean }>(
      "select shop.complete_guest_cart_merge($1::uuid, $2::uuid) as completed",
      [guestCartId, userId],
    );
    if (result.rows[0]?.completed !== true) {
      throw new Error("Guest cart merge cleanup state could not be recorded.");
    }
    await client.query("commit");
    transactionOpen = false;
  } catch (error) {
    if (transactionOpen) {
      try {
        await client.query("rollback");
      } catch (rollbackError) {
        throw new AggregateError([error, rollbackError], "Cart cleanup transaction rollback failed.");
      }
    }
    throw error;
  } finally {
    client.release();
  }
}

export async function listPendingGuestCartMerges(userId: string): Promise<string[]> {
  const client = await getPostgresPool("fco-shop-cart").connect();
  let transactionOpen = false;
  try {
    await client.query("begin read only");
    transactionOpen = true;
    await client.query("set local role fco_app");
    const result = await client.query<{ guest_cart_id: string }>(
      "select guest_cart_id from shop.pending_guest_cart_merges($1::uuid)",
      [userId],
    );
    await client.query("commit");
    transactionOpen = false;
    return result.rows.map((row) => row.guest_cart_id);
  } catch (error) {
    if (transactionOpen) {
      try {
        await client.query("rollback");
      } catch (rollbackError) {
        throw new AggregateError([error, rollbackError], "Pending cart merge read rollback failed.");
      }
    }
    throw error;
  } finally {
    client.release();
  }
}

export async function validateSellableCartItem(
  variantId: string,
): Promise<PublicCartItem | null> {
  const items = await getPublicCartItems([{ variantId, quantity: 1 }]);
  const item = items[0] ?? null;
  return item?.sellable ? item : null;
}
