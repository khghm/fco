import { describe, expect, it } from "vitest";
import { isUuid, parseAdminProductInput } from "./product-input";

describe("admin product input", () => {
  it("validates product fields and applies safe optional defaults", () => {
    expect(
      parseAdminProductInput({
        title: "  پوشاک  ",
        description: "",
        brand_id: null,
        category_id: null,
      }),
    ).toEqual({
      title: "پوشاک",
      description: null,
      brandId: null,
      categoryId: null,
      attributes: {},
    });
  });

  it("rejects malformed identifiers and non-object attributes", () => {
    expect(isUuid("not-a-uuid")).toBe(false);
    expect(
      parseAdminProductInput({
        title: "Item",
        brand_id: "bad-id",
        attributes: [],
      }),
    ).toBeNull();
    expect(parseAdminProductInput({ title: " ".repeat(2) })).toBeNull();
  });
});
