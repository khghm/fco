export interface PublicProduct {
  id: string;
  slug: string;
  title: string;
  brand_slug: string | null;
  brand_title: string | null;
  category_slug: string | null;
  category_title: string | null;
  price_rial: number | null;
  compare_at_rial: number | null;
  available_qty: number;
  in_stock: boolean;
}

export interface PublicProductReference {
  slug: string;
  title: string;
}

export interface PublicProductMedia {
  key: string;
  alt: string | null;
}

export interface PublicProductVariant {
  sku: string;
  barcode: string | null;
  price_rial: number | null;
  compare_at_rial: number | null;
  available_qty: number;
}

export interface PublicProductDetail {
  id: string;
  slug: string;
  title: string;
  description: string | null;
  attributes: Record<string, unknown>;
  published_at: string;
  brand: PublicProductReference | null;
  category: PublicProductReference | null;
  media: PublicProductMedia[];
  variants: PublicProductVariant[];
}

export interface PublicCatalogQuery {
  query: string | null;
  categorySlug: string | null;
  brandSlug: string | null;
  page: number;
  pageSize: number;
}

export interface PublicCatalogPage {
  items: PublicProduct[];
  page: number;
  page_size: number;
  total: number;
}

export interface PublicCatalogRepository {
  searchProducts(query: PublicCatalogQuery): Promise<PublicCatalogPage>;
  getProductBySlug(slug: string): Promise<PublicProductDetail | null>;
}

export class InvalidCatalogQueryError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "InvalidCatalogQueryError";
  }
}

const allowedParameters = new Set(["q", "category", "brand", "page", "page_size"]);

function readSingleParameter(params: URLSearchParams, name: string): string | undefined {
  const values = params.getAll(name);
  if (values.length > 1) {
    throw new InvalidCatalogQueryError(`پارامتر «${name}» نباید تکرار شود.`);
  }
  return values[0];
}

function parsePositiveInteger(value: string | undefined, fallback: number, name: string): number {
  if (value === undefined) {
    return fallback;
  }

  if (!/^[1-9]\d*$/.test(value)) {
    throw new InvalidCatalogQueryError(`مقدار «${name}» باید عدد صحیح مثبت باشد.`);
  }

  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed)) {
    throw new InvalidCatalogQueryError(`مقدار «${name}» معتبر نیست.`);
  }

  return parsed;
}

function readSlug(value: string | undefined, name: string): string | null {
  const slug = value?.trim() || null;
  if (slug !== null && !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug)) {
    throw new InvalidCatalogQueryError(`مقدار «${name}» معتبر نیست.`);
  }
  return slug;
}

export function parsePublicCatalogQuery(params: URLSearchParams): PublicCatalogQuery {
  for (const name of params.keys()) {
    if (!allowedParameters.has(name)) {
      throw new InvalidCatalogQueryError(`پارامتر «${name}» پشتیبانی نمی‌شود.`);
    }
  }

  const rawQuery = readSingleParameter(params, "q")?.trim() ?? "";
  if (rawQuery.length > 100) {
    throw new InvalidCatalogQueryError("عبارت جست‌وجو حداکثر ۱۰۰ نویسه است.");
  }

  const page = parsePositiveInteger(readSingleParameter(params, "page"), 1, "page");
  const pageSize = parsePositiveInteger(readSingleParameter(params, "page_size"), 24, "page_size");
  if (pageSize > 60) {
    throw new InvalidCatalogQueryError("تعداد نتیجه در هر صفحه حداکثر ۶۰ است.");
  }
  if ((page - 1) * pageSize > 5000) {
    throw new InvalidCatalogQueryError("شماره صفحه از محدودهٔ مجاز بیشتر است.");
  }

  return {
    query: rawQuery || null,
    categorySlug: readSlug(readSingleParameter(params, "category"), "category"),
    brandSlug: readSlug(readSingleParameter(params, "brand"), "brand"),
    page,
    pageSize,
  };
}

export function searchPublicCatalog(
  repository: PublicCatalogRepository,
  query: PublicCatalogQuery,
): Promise<PublicCatalogPage> {
  return repository.searchProducts(query);
}

export function getPublicProduct(
  repository: PublicCatalogRepository,
  slug: string,
): Promise<PublicProductDetail | null> {
  return repository.getProductBySlug(slug);
}
