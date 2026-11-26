import Link from "next/link";
import {
  parsePublicCatalogQuery,
  searchPublicCatalog,
} from "@fco/application/catalog";
import { createPostgresPublicCatalogRepository } from "@fco/infrastructure/catalog";
import { formatPrice, persianNumber } from "../lib/catalog-presentation";

export const dynamic = "force-dynamic";

type HomeProps = {
  searchParams: Promise<Record<string, string | string[] | undefined>>;
};

function pageHref(
  page: number,
  query: { query: string | null; categorySlug: string | null; brandSlug: string | null; pageSize: number },
): string {
  const params = new URLSearchParams();
  if (query.query) params.set("q", query.query);
  if (query.categorySlug) params.set("category", query.categorySlug);
  if (query.brandSlug) params.set("brand", query.brandSlug);
  params.set("page", String(page));
  params.set("page_size", String(query.pageSize));
  return `/?${params.toString()}`;
}

export default async function Home({ searchParams }: HomeProps) {
  const rawSearchParams = await searchParams;
  const params = new URLSearchParams();
  for (const [key, value] of Object.entries(rawSearchParams)) {
    if (Array.isArray(value)) {
      for (const item of value) params.append(key, item);
    } else if (value !== undefined) {
      params.set(key, value);
    }
  }

  const query = parsePublicCatalogQuery(params);
  const result = await searchPublicCatalog(
    createPostgresPublicCatalogRepository(),
    query,
  );
  const pageCount = Math.ceil(result.total / result.page_size);

  return (
    <main className="storefront">
      <header className="site-header">
        <Link className="wordmark" href="/" aria-label="صفحهٔ اصلی فروشگاه FCO">
          FCO
        </Link>
        <span className="header-note">پوشاک برای هر روز</span>
      </header>

      <section className="catalog-intro" aria-labelledby="catalog-title">
        <p className="eyebrow">انتخاب تازهٔ شما</p>
        <h1 id="catalog-title">محصولات فروشگاه</h1>
        <p>محصول موردنظرتان را جست‌وجو کنید.</p>
        <form className="search-form" action="/" method="get" role="search">
          <label className="visually-hidden" htmlFor="catalog-search">
            جست‌وجوی محصولات
          </label>
          <input
            id="catalog-search"
            name="q"
            type="search"
            defaultValue={query.query ?? ""}
            placeholder="مثلاً مانتو یا شلوار"
            maxLength={100}
          />
          <button type="submit">جست‌وجو</button>
        </form>
      </section>

      <section className="catalog-results" aria-live="polite">
        <div className="results-heading">
          <h2>{query.query ? `نتایج «${query.query}»` : "همهٔ محصولات"}</h2>
          <p>{persianNumber.format(result.total)} محصول</p>
        </div>

        {result.items.length === 0 ? (
          <div className="empty-state">
            <h3>{query.query ? "محصولی پیدا نشد" : "هنوز محصولی برای نمایش نیست"}</h3>
            <p>
              {query.query
                ? "عبارت دیگری را جست‌وجو کنید."
                : "به‌محض انتشار محصولات، آن‌ها را در همین‌جا خواهید دید."}
            </p>
          </div>
        ) : (
          <ul className="product-grid">
            {result.items.map((product) => (
              <li className="product-card" key={product.id}>
                <div className="product-art" aria-hidden="true">
                  <span>تصویر محصول</span>
                </div>
                <div className="product-details">
                  {product.brand_title && (
                    <p className="product-brand">{product.brand_title}</p>
                  )}
                  <h3>
                    <Link href={`/products/${product.slug}`}>{product.title}</Link>
                  </h3>
                  <p className="product-price">{formatPrice(product.price_rial)}</p>
                  <p className={product.in_stock ? "stock in-stock" : "stock"}>
                    {product.in_stock ? "موجود" : "ناموجود"}
                  </p>
                </div>
              </li>
            ))}
          </ul>
        )}

        {pageCount > 1 && (
          <nav className="pagination" aria-label="صفحه‌بندی محصولات">
            {query.page > 1 && (
              <Link href={pageHref(query.page - 1, query)}>صفحهٔ قبل</Link>
            )}
            <span>
              صفحهٔ {persianNumber.format(query.page)} از{" "}
              {persianNumber.format(pageCount)}
            </span>
            {query.page < pageCount && (
              <Link href={pageHref(query.page + 1, query)}>صفحهٔ بعد</Link>
            )}
          </nav>
        )}
      </section>
    </main>
  );
}
