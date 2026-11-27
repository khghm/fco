export interface AdminProductInput {
  title: string;
  description: string | null;
  brandId: string | null;
  categoryId: string | null;
  attributes: Record<string, unknown>;
}

const uuidPattern =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && uuidPattern.test(value);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function parseAdminProductInput(value: unknown): AdminProductInput | null {
  if (!isRecord(value)) {
    return null;
  }
  if (
    typeof value.title !== "string" ||
    value.title.trim().length === 0 ||
    value.title.trim().length > 240 ||
    (value.description !== null &&
      value.description !== undefined &&
      (typeof value.description !== "string" || value.description.length > 5000)) ||
    (value.brand_id !== null &&
      value.brand_id !== undefined &&
      !isUuid(value.brand_id)) ||
    (value.category_id !== null &&
      value.category_id !== undefined &&
      !isUuid(value.category_id)) ||
    (value.attributes !== undefined && !isRecord(value.attributes))
  ) {
    return null;
  }

  return {
    title: value.title.trim(),
    description:
      typeof value.description === "string" ? value.description.trim() || null : null,
    brandId: typeof value.brand_id === "string" ? value.brand_id : null,
    categoryId: typeof value.category_id === "string" ? value.category_id : null,
    attributes: value.attributes === undefined ? {} : value.attributes,
  };
}
