import { Pool, type PoolClient, type QueryResultRow } from "pg";
import type {
  PublicCatalogPage,
  PublicCatalogQuery,
  PublicCatalogRepository,
  PublicProduct,
} from "@fco/application/catalog";

interface ProductRow extends QueryResultRow {
  product_id: string;
  slug: string;
  title: string;
  brand_slug: string | null;
  brand_title: string | null;
  category_slug: string | null;
  category_title: string | null;
  price_rial: string | null;
  compare_at_rial: string | null;
  available_qty: number;
  in_stock: boolean;
  total_count: string;
}

let pool: Pool | undefined;

function getPool(): Pool {
  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) {
    throw new Error("DATABASE_URL must be configured before querying the catalog.");
  }

  pool ??= new Pool({
    connectionString,
    max: 10,
    connectionTimeoutMillis: 5000,
    idleTimeoutMillis: 30000,
    application_name: "fco-shop",
    ssl: process.env.DATABASE_SSL === "true" ? { rejectUnauthorized: true } : false,
  });

  return pool;
}

function safeInteger(value: number | string, field: string): number {
  const parsed = typeof value === "number" ? value : Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new RangeError(`Database returned an unsafe ${field} value.`);
  }
  return parsed;
}

function mapProduct(row: ProductRow): PublicProduct {
  return {
    id: row.product_id,
    slug: row.slug,
    title: row.title,
    brand_slug: row.brand_slug,
    brand_title: row.brand_title,
    category_slug: row.category_slug,
    category_title: row.category_title,
    price_rial: row.price_rial === null ? null : safeInteger(row.price_rial, "price_rial"),
    compare_at_rial:
      row.compare_at_rial === null ? null : safeInteger(row.compare_at_rial, "compare_at_rial"),
    available_qty: safeInteger(row.available_qty, "available_qty"),
    in_stock: row.in_stock,
  };
}

async function rollback(client: PoolClient): Promise<void> {
  await client.query("rollback");
}

export function createPostgresPublicCatalogRepository(): PublicCatalogRepository {
  return {
    async searchProducts(query: PublicCatalogQuery): Promise<PublicCatalogPage> {
      const client = await getPool().connect();
      let transactionOpen = false;

      try {
        await client.query("begin isolation level repeatable read read only");
        transactionOpen = true;
        await client.query("set local role fco_app");

        const parameters = [
          query.query,
          query.categorySlug,
          query.brandSlug,
          "web",
        ];
        const totalResult = await client.query<{ total_count: string }>(
          "select total_count from cat.search_products($1, $2, $3, $4, 1, 0) limit 1",
          parameters,
        );
        const pageResult = await client.query<ProductRow>(
          `select product_id, slug, title, brand_slug, brand_title, category_slug,
                  category_title, price_rial, compare_at_rial, available_qty,
                  in_stock, total_count
             from cat.search_products($1, $2, $3, $4, $5, $6)`,
          [...parameters, query.pageSize, (query.page - 1) * query.pageSize],
        );

        await client.query("commit");
        transactionOpen = false;

        return {
          items: pageResult.rows.map(mapProduct),
          page: query.page,
          page_size: query.pageSize,
          total: safeInteger(totalResult.rows[0]?.total_count ?? "0", "total_count"),
        };
      } catch (error) {
        if (transactionOpen) {
          try {
            await rollback(client);
          } catch (rollbackError) {
            throw new AggregateError([error, rollbackError], "Catalog transaction rollback failed.");
          }
        }
        throw error;
      } finally {
        client.release();
      }
    },
  };
}
