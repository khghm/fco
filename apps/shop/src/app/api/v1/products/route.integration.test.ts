import { beforeAll, describe, expect, it } from "vitest";
import { GET } from "./route";

const databaseUrl = process.env.FCO_E2E_DATABASE_URL;

describe.skipIf(!databaseUrl)("GET /api/v1/products with PostgreSQL", () => {
  beforeAll(() => {
    if (databaseUrl) {
      process.env.DATABASE_URL = databaseUrl;
      process.env.DATABASE_SSL = "false";
    }
  });

  it("returns the seeded catalog product and database-derived price and stock", async () => {
    const response = await GET(
      new Request("http://localhost/api/v1/products?q=پیراهن"),
    );
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body.data).toHaveLength(1);
    expect(body.data[0]).toMatchObject({
      slug: "e2e-shirt",
      price_rial: 650000,
      available_qty: 4,
      in_stock: true,
    });
    expect(body.meta).toMatchObject({
      page: 1,
      page_size: 24,
      total: 1,
    });
  });

  it("rejects invalid input without requiring a database lookup", async () => {
    const response = await GET(
      new Request("http://localhost/api/v1/products?page_size=61"),
    );
    const body = await response.json();

    expect(response.status).toBe(400);
    expect(body.error.code).toBe("FCO-1001");
  });
});
