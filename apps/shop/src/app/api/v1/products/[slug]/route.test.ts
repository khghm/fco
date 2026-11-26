import { beforeEach, describe, expect, it, vi } from "vitest";

const { getProductBySlug } = vi.hoisted(() => ({
  getProductBySlug: vi.fn(),
}));

vi.mock("@fco/infrastructure/catalog", () => ({
  createPostgresPublicCatalogRepository: () => ({ getProductBySlug }),
}));

import { GET } from "./route";

function request(slug: string, headers?: HeadersInit): Request {
  return new Request(`http://localhost/api/v1/products/${slug}`, { headers });
}

function context(slug: string) {
  return { params: Promise.resolve({ slug }) };
}

describe("GET /api/v1/products/{slug}", () => {
  beforeEach(() => {
    getProductBySlug.mockReset();
  });

  it("returns product details and preserves a valid request ID", async () => {
    const product = { slug: "e2e-shirt", title: "پیراهن آزمایشی", variants: [] };
    getProductBySlug.mockResolvedValue(product);

    const response = await GET(
      request("e2e-shirt", { "x-request-id": "product-test-123" }),
      context("e2e-shirt"),
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("x-request-id")).toBe("product-test-123");
    await expect(response.json()).resolves.toEqual({
      data: product,
      meta: { request_id: "product-test-123" },
    });
    expect(getProductBySlug).toHaveBeenCalledWith("e2e-shirt");
  });

  it("rejects malformed slugs without querying PostgreSQL", async () => {
    const response = await GET(request("Bad_slug"), context("Bad_slug"));

    expect(response.status).toBe(400);
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "FCO-1001" },
    });
    expect(getProductBySlug).not.toHaveBeenCalled();
  });

  it("hides unpublished and missing products behind the same 404", async () => {
    getProductBySlug.mockResolvedValue(null);

    const response = await GET(request("unknown-product"), context("unknown-product"));

    expect(response.status).toBe(404);
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "FCO-1004" },
    });
  });

  it("returns a service-unavailable error when PostgreSQL is unreachable", async () => {
    const write = vi.spyOn(process.stderr, "write").mockImplementation(() => true);
    getProductBySlug.mockRejectedValue(Object.assign(new Error("database offline"), { code: "08006" }));

    try {
      const response = await GET(request("e2e-shirt"), context("e2e-shirt"));

      expect(response.status).toBe(503);
      await expect(response.json()).resolves.toMatchObject({
        error: { code: "FCO-1010" },
      });
    } finally {
      write.mockRestore();
    }
  });
});
