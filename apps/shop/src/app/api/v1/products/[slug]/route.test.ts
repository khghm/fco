import { beforeEach, describe, expect, it, vi } from "vitest";

const { getProductBySlug, createPresignedMediaUrl } = vi.hoisted(() => ({
  getProductBySlug: vi.fn(),
  createPresignedMediaUrl: vi.fn(),
}));

vi.mock("@fco/infrastructure/catalog", () => ({
  createPostgresPublicCatalogRepository: () => ({ getProductBySlug }),
}));
vi.mock("@fco/infrastructure/media", () => ({ createPresignedMediaUrl }));

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
    createPresignedMediaUrl.mockReset();
    createPresignedMediaUrl.mockImplementation(
      async (key: string) => `https://media.example/${key}?X-Amz-Expires=900`,
    );
  });

  it("returns product details and preserves a valid request ID", async () => {
    const product = {
      slug: "e2e-shirt",
      title: "پیراهن آزمایشی",
      media: [{ key: "catalog/e2e-shirt/front.jpg", alt: "نمای جلو" }],
      variants: [],
    };
    getProductBySlug.mockResolvedValue(product);

    const response = await GET(
      request("e2e-shirt", { "x-request-id": "product-test-123" }),
      context("e2e-shirt"),
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("x-request-id")).toBe("product-test-123");
    const body = await response.json();
    expect(body.meta).toEqual({ request_id: "product-test-123" });
    expect(body.data.media).toEqual([
      {
        key: "catalog/e2e-shirt/front.jpg",
        alt: "نمای جلو",
        url: "https://media.example/catalog/e2e-shirt/front.jpg?X-Amz-Expires=900",
      },
    ]);
    expect(getProductBySlug).toHaveBeenCalledWith("e2e-shirt");
    expect(createPresignedMediaUrl).toHaveBeenCalledWith("catalog/e2e-shirt/front.jpg");
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
