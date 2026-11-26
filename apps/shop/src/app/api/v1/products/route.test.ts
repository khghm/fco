import { beforeEach, describe, expect, it, vi } from "vitest";

const { searchProducts } = vi.hoisted(() => ({
  searchProducts: vi.fn(),
}));

vi.mock("@fco/infrastructure/catalog", () => ({
  createPostgresPublicCatalogRepository: () => ({ searchProducts }),
}));

import { GET } from "./route";

describe("GET /api/v1/products", () => {
  beforeEach(() => {
    searchProducts.mockReset();
  });

  it("returns catalog data and preserves a valid request ID", async () => {
    const result = {
      items: [],
      page: 1,
      page_size: 24,
      total: 0,
    };
    searchProducts.mockResolvedValue(result);

    const response = await GET(
      new Request("http://localhost/api/v1/products", {
        headers: { "x-request-id": "catalog-test-123" },
      }),
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("x-request-id")).toBe("catalog-test-123");
    await expect(response.json()).resolves.toEqual({
      data: [],
      meta: {
        page: 1,
        page_size: 24,
        total: 0,
        request_id: "catalog-test-123",
      },
    });
  });

  it("returns the documented validation error without querying the repository", async () => {
    const response = await GET(
      new Request("http://localhost/api/v1/products?page_size=61"),
    );

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "FCO-1001" },
    });
    expect(searchProducts).not.toHaveBeenCalled();
  });

  it("returns a service-unavailable error when PostgreSQL is unreachable", async () => {
    const write = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    searchProducts.mockRejectedValue(Object.assign(new Error("database offline"), { code: "08006" }));

    try {
      const response = await GET(new Request("http://localhost/api/v1/products"));

      expect(response.status).toBe(503);
      await expect(response.json()).resolves.toMatchObject({
        error: { code: "FCO-1010" },
      });
    } finally {
      write.mockRestore();
    }
  });
});
