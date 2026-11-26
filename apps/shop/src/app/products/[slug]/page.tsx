import Link from "next/link";
import { notFound } from "next/navigation";
import { getPublicProduct } from "@fco/application/catalog";
import { createPostgresPublicCatalogRepository } from "@fco/infrastructure/catalog";
import { formatPrice, persianNumber } from "../../../lib/catalog-presentation";

export const dynamic = "force-dynamic";

type ProductPageProps = {
  params: Promise<{ slug: string }>;
};

export default async function ProductPage({ params }: ProductPageProps) {
  const { slug } = await params;
  const product = await getPublicProduct(
    createPostgresPublicCatalogRepository(),
    slug,
  );
  if (product === null) {
    notFound();
  }

  return (
    <main className="storefront">
      <header className="site-header">
        <Link className="wordmark" href="/" aria-label="صفحهٔ اصلی فروشگاه FCO">
          FCO
        </Link>
        <Link href="/">بازگشت به کاتالوگ</Link>
      </header>

      <article className="product-page">
        <div className="product-gallery">
          <div
            className="product-art product-art-large"
            role="img"
            aria-label={product.media[0]?.alt ?? `تصویر ${product.title}`}
          >
            <span>
              {product.media.length > 0
                ? `${persianNumber.format(product.media.length)} تصویر ثبت شده`
                : "تصویر محصول"}
            </span>
          </div>
        </div>

        <div className="product-summary">
          <nav className="breadcrumbs" aria-label="مسیر صفحه">
            <Link href="/">فروشگاه</Link>
            {product.category && (
              <>
                <span aria-hidden="true">/</span>
                <span>{product.category.title}</span>
              </>
            )}
          </nav>
          {product.brand && <p className="product-brand">{product.brand.title}</p>}
          <h1>{product.title}</h1>
          {product.description && <p className="product-description">{product.description}</p>}
          {product.variants.length > 0 ? (
            <section className="variant-list" aria-labelledby="variant-heading">
              <h2 id="variant-heading">تنوع و موجودی</h2>
              <ul>
                {product.variants.map((variant) => (
                  <li key={variant.sku}>
                    <bdi dir="ltr">{variant.sku}</bdi>
                    <span>{formatPrice(variant.price_rial)}</span>
                    <span className={variant.available_qty > 0 ? "stock in-stock" : "stock"}>
                      {variant.available_qty > 0
                        ? `موجود · ${persianNumber.format(variant.available_qty)} عدد`
                        : "ناموجود"}
                    </span>
                  </li>
                ))}
              </ul>
            </section>
          ) : (
            <p className="stock">در حال حاضر تنوع فعالی برای این محصول ثبت نشده است.</p>
          )}
        </div>
      </article>
    </main>
  );
}
