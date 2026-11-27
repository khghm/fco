import type { PoolClient, QueryResultRow } from "pg";
import { getPostgresPool } from "./postgres";

export interface AdminProduct {
  id: string;
  slug: string;
  title: string;
  status: "draft" | "published" | "archived";
  version: number;
  updated_at: string | null;
  active_variants: number;
  price_from_rial: number | null;
}

export interface AdminProductDetail {
  id: string;
  slug: string;
  title: string;
  description: string | null;
  brand_id: string | null;
  category_id: string | null;
  attributes: Record<string, unknown>;
  status: "draft" | "published" | "archived";
  version: number;
  updated_at: string | null;
}

export interface AdminVariantPrice {
  id: string;
  amount_rial: number;
  compare_at_rial: number | null;
  channel: string;
  effective_from: string;
  effective_to: string | null;
  created_by: string | null;
}

export interface AdminVariant {
  id: string;
  sku: string;
  barcode: string | null;
  is_active: boolean;
  prices: AdminVariantPrice[];
}

interface AdminProductRow extends QueryResultRow {
  id: string;
  slug: string;
  title: string;
  status: AdminProduct["status"];
  version: number;
  updated_at: Date | null;
  active_variants: string;
  price_from_rial: string | null;
  total_count: string;
}

interface AdminProductDetailRow extends QueryResultRow {
  id: string;
  slug: string;
  title: string;
  description: string | null;
  brand_id: string | null;
  category_id: string | null;
  attributes: Record<string, unknown>;
  status: AdminProductDetail["status"];
  version: number;
  updated_at: Date | null;
}

interface AdminVariantPriceRow extends QueryResultRow {
  variant_id: string;
  sku: string;
  barcode: string | null;
  is_active: boolean;
  price_id: string | null;
  amount_rial: string | null;
  compare_at_rial: string | null;
  channel: string | null;
  effective_from: Date | null;
  effective_to: Date | null;
  created_by: string | null;
}

async function beginApplicationTransaction(): Promise<PoolClient> {
  const client = await getPostgresPool("fco-admin").connect();
  try {
    await client.query("begin");
    await client.query("set local role fco_app");
    return client;
  } catch (error) {
    try {
      await client.query("rollback");
    } catch (rollbackError) {
      client.release();
      throw new AggregateError(
        [error, rollbackError],
        "Admin catalog transaction setup rollback failed.",
      );
    }
    client.release();
    throw error;
  }
}

async function finishTransaction(
  client: PoolClient,
  operation: () => Promise<void>,
): Promise<void> {
  try {
    await operation();
  } catch (error) {
    try {
      await client.query("rollback");
    } catch (rollbackError) {
      throw new AggregateError([error, rollbackError], "Admin catalog transaction rollback failed.");
    }
    throw error;
  } finally {
    client.release();
  }
}

function safeInteger(value: string, name: string): number {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new RangeError(`Database returned an unsafe ${name} value.`);
  }
  return parsed;
}

export async function listAdminProducts(
  actorId: string,
  limit: number,
  offset: number,
): Promise<{ items: AdminProduct[]; total: number }> {
  const client = await beginApplicationTransaction();
  let response: { items: AdminProduct[]; total: number } | undefined;
  await finishTransaction(client, async () => {
    await client.query("select iam.authorize($1::uuid, 'catalog.product.read')", [actorId]);
    const result = await client.query<AdminProductRow>(
      `select p.id, p.slug, p.title, p.status, p.version, p.updated_at,
              count(distinct v.id) filter (
                where v.is_active and v.archived_at is null
              )::text as active_variants,
              min(pr.amount_rial) filter (
                where pr.effective_from <= now()
                  and (pr.effective_to is null or pr.effective_to > now())
              )::text as price_from_rial,
              count(*) over ()::text as total_count
         from cat.products p
         left join cat.variants v on v.product_id = p.id
         left join pricing.prices pr on pr.variant_id = v.id and pr.channel = 'web'
        group by p.id
        order by p.created_at desc, p.id
        limit $1 offset $2`,
      [limit, offset],
    );
    const total = result.rows[0]
      ? safeInteger(result.rows[0].total_count, "total_count")
      : 0;
    response = {
      items: result.rows.map((row) => ({
        id: row.id,
        slug: row.slug,
        title: row.title,
        status: row.status,
        version: row.version,
        updated_at: row.updated_at?.toISOString() ?? null,
        active_variants: safeInteger(row.active_variants, "active_variants"),
        price_from_rial:
          row.price_from_rial === null
            ? null
            : safeInteger(row.price_from_rial, "price_from_rial"),
      })),
      total,
    };
    await client.query("commit");
  });
  if (!response) {
    throw new Error("Admin product list completed without a result.");
  }
  return response;
}

export async function getAdminProduct(
  actorId: string,
  productId: string,
): Promise<AdminProductDetail | null> {
  const client = await beginApplicationTransaction();
  let product: AdminProductDetail | null = null;
  await finishTransaction(client, async () => {
    await client.query("select iam.authorize($1::uuid, 'catalog.product.read')", [actorId]);
    const result = await client.query<AdminProductDetailRow>(
      `select id, slug, title, description, brand_id, category_id,
              attributes, status, version, updated_at
         from cat.products
        where id = $1 and status <> 'archived'`,
      [productId],
    );
    const row = result.rows[0];
    if (row) {
      product = {
        id: row.id,
        slug: row.slug,
        title: row.title,
        description: row.description,
        brand_id: row.brand_id,
        category_id: row.category_id,
        attributes: row.attributes,
        status: row.status,
        version: row.version,
        updated_at: row.updated_at?.toISOString() ?? null,
      };
    }
    await client.query("commit");
  });
  return product;
}

export async function listAdminVariants(
  actorId: string,
  productId: string,
): Promise<AdminVariant[] | null> {
  const client = await beginApplicationTransaction();
  let variants: AdminVariant[] | null = null;
  await finishTransaction(client, async () => {
    await client.query("select iam.authorize($1::uuid, 'catalog.product.read')", [actorId]);
    const product = await client.query<{ id: string }>(
      "select id from cat.products where id = $1 and status <> 'archived'",
      [productId],
    );
    if (!product.rows[0]) {
      await client.query("commit");
      variants = null;
      return;
    }

    const result = await client.query<AdminVariantPriceRow>(
      `select v.id as variant_id, v.sku, v.barcode, v.is_active,
              pr.id as price_id, pr.amount_rial::text as amount_rial,
              pr.compare_at_rial::text as compare_at_rial, pr.channel,
              pr.effective_from, pr.effective_to, pr.created_by
         from cat.variants v
         left join pricing.prices pr on pr.variant_id = v.id
        where v.product_id = $1 and v.archived_at is null
        order by v.created_at, v.id, pr.effective_from desc, pr.id`,
      [productId],
    );
    const byId = new Map<string, AdminVariant>();
    for (const row of result.rows) {
      let variant = byId.get(row.variant_id);
      if (!variant) {
        variant = {
          id: row.variant_id,
          sku: row.sku,
          barcode: row.barcode,
          is_active: row.is_active,
          prices: [],
        };
        byId.set(row.variant_id, variant);
      }
      if (row.price_id && row.amount_rial !== null && row.channel && row.effective_from) {
        variant.prices.push({
          id: row.price_id,
          amount_rial: safeInteger(row.amount_rial, "amount_rial"),
          compare_at_rial:
            row.compare_at_rial === null
              ? null
              : safeInteger(row.compare_at_rial, "compare_at_rial"),
          channel: row.channel,
          effective_from: row.effective_from.toISOString(),
          effective_to: row.effective_to?.toISOString() ?? null,
          created_by: row.created_by,
        });
      }
    }
    await client.query("commit");
    variants = [...byId.values()];
  });
  return variants;
}

export async function createAdminVariant(input: {
  actorId: string;
  requestId: string;
  productId: string;
  sku: string;
  barcode: string | null;
  weightG: number | null;
}): Promise<string> {
  const client = await beginApplicationTransaction();
  let variantId: string | undefined;
  await finishTransaction(client, async () => {
    const result = await client.query<{ variant_id: string }>(
      `select cat.variant_create(
         $1::uuid, $2::uuid, $3::text, $4::text, $5::integer, $6::text
       ) as variant_id`,
      [
        input.actorId,
        input.productId,
        input.sku.toUpperCase(),
        input.barcode,
        input.weightG,
        input.requestId,
      ],
    );
    variantId = result.rows[0].variant_id;
    await client.query("commit");
  });
  if (!variantId) {
    throw new Error("Admin variant creation completed without an identifier.");
  }
  return variantId;
}

export async function createAdminProduct(input: {
  actorId: string;
  requestId: string;
  slug: string;
  title: string;
  description: string | null;
  brandId: string | null;
  categoryId: string | null;
  attributes: Record<string, unknown>;
}): Promise<string> {
  const client = await beginApplicationTransaction();
  let productId: string | undefined;
  await finishTransaction(client, async () => {
    const result = await client.query<{ product_id: string }>(
      `select cat.product_create(
         $1::uuid, $2::text, $3::text, $4::text, $5::uuid, $6::uuid, $7::jsonb, $8::text
       ) as product_id`,
      [
        input.actorId,
        input.slug,
        input.title,
        input.description,
        input.brandId,
        input.categoryId,
        JSON.stringify(input.attributes),
        input.requestId,
      ],
    );
    productId = result.rows[0].product_id;
    await client.query("commit");
  });
  if (!productId) {
    throw new Error("Admin product creation completed without an identifier.");
  }
  return productId;
}

export async function updateAdminProduct(input: {
  actorId: string;
  requestId: string;
  productId: string;
  title: string;
  description: string | null;
  brandId: string | null;
  categoryId: string | null;
  attributes: Record<string, unknown>;
  expectedVersion: number;
}): Promise<number> {
  const client = await beginApplicationTransaction();
  let version: number | undefined;
  await finishTransaction(client, async () => {
    const result = await client.query<{ version: number }>(
      `select cat.product_update(
         $1::uuid, $2::uuid, $3::text, $4::text, $5::uuid, $6::uuid,
         $7::jsonb, $8::integer, $9::text
       ) as version`,
      [
        input.actorId,
        input.productId,
        input.title,
        input.description,
        input.brandId,
        input.categoryId,
        JSON.stringify(input.attributes),
        input.expectedVersion,
        input.requestId,
      ],
    );
    version = result.rows[0].version;
    await client.query("commit");
  });
  if (version === undefined) {
    throw new Error("Admin product update completed without a version.");
  }
  return version;
}

export async function setAdminProductPrice(input: {
  actorId: string;
  requestId: string;
  variantId: string;
  amountRial: number;
  compareAtRial: number | null;
  effectiveFrom: string;
  channel: string;
  reason: string | null;
}): Promise<string> {
  const client = await beginApplicationTransaction();
  let priceId: string | undefined;
  await finishTransaction(client, async () => {
    const result = await client.query<{ price_id: string }>(
      `select pricing.price_set(
         $1::uuid, $2::uuid, $3::bigint, $4::bigint, $5::timestamptz,
         $6::text, $7::text, $8::text
       ) as price_id`,
      [
        input.actorId,
        input.variantId,
        input.amountRial,
        input.compareAtRial,
        input.effectiveFrom,
        input.channel,
        input.requestId,
        input.reason,
      ],
    );
    priceId = result.rows[0].price_id;
    await client.query("commit");
  });
  if (!priceId) {
    throw new Error("Admin price update completed without a version identifier.");
  }
  return priceId;
}
