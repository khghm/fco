import { describe, expect, it, vi } from "vitest";
import {
  InvalidCatalogQueryError,
  parsePublicCatalogQuery,
  searchPublicCatalog,
  type PublicCatalogRepository,
} from "./catalog";

describe("parsePublicCatalogQuery", () => {
  it("uses safe defaults and trims the search query", () => {
    expect(parsePublicCatalogQuery(new URLSearchParams("q=%20مانتو%20"))).toEqual({
      query: "مانتو",
      categorySlug: null,
      brandSlug: null,
      page: 1,
      pageSize: 24,
    });
  });

  it.each([
    ["page_size=61", "تعداد نتیجه"],
    ["page=0", "page"],
    ["page_size=24.5", "page_size"],
    ["q=" + "x".repeat(101), "۱۰۰ نویسه"],
    ["unexpected=1", "پشتیبانی نمی‌شود"],
    ["page=1&page=2", "تکرار"],
  ])("rejects invalid input %s", (query, expectedMessage) => {
    expect(() => parsePublicCatalogQuery(new URLSearchParams(query))).toThrow(
      expect.objectContaining({
        name: "InvalidCatalogQueryError",
        message: expect.stringContaining(expectedMessage),
      }),
    );
  });
});

describe("searchPublicCatalog", () => {
  it("delegates the validated query to the repository", async () => {
    const result = { items: [], page: 1, page_size: 24, total: 0 };
    const repository: PublicCatalogRepository = {
      searchProducts: vi.fn().mockResolvedValue(result),
    };

    await expect(
      searchPublicCatalog(repository, {
        query: null,
        categorySlug: null,
        brandSlug: null,
        page: 1,
        pageSize: 24,
      }),
    ).resolves.toEqual(result);
    expect(repository.searchProducts).toHaveBeenCalledOnce();
  });
});
