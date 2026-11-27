import Link from "next/link";
import Image from "next/image";
import { notFound } from "next/navigation";
import { getPublicProduct } from "@fco/application/catalog";
import { createPostgresPublicCatalogRepository } from "@fco/infrastructure/catalog";
import { formatPrice, persianNumber } from "../../../lib/catalog-presentation";
import { addPublicMediaUrls } from "../../../lib/public-media";
import AddToCartButton from "./add-to-cart-button";

export const dynamic = "force-dynamic";

type ProductPageProps = {
  params: Promise<{ slug: string }>;
};

export default async function ProductPage({ params }: ProductPageProps) {
  const { slug } = await params;
  const productRecord = await getPublicProduct(
    createPostgresPublicCatalogRepository(),
    slug,
  );
  if (productRecord === null) {
    notFound();
  }
  const product = await addPublicMediaUrls(productRecord);

  return (
    <main className="storefront">
      <header className="site-header">
        <Link className="wordmark" href="/" aria-label="صفحهٔ اصلی فروشگاه FCO">
          FCO
        </Link>
        <Link href="/">بازگشت به کاتالوگ</Link>
        <Link href="/checkout">سبد خرید و تسویه</Link>
      </header>

      <article className="product-page">
        <div className="product-gallery">
          {product.media.length > 0 ? (
            product.media.map((media, index) => (
              <Image
                key={media.key}
                className="product-image"
                src={media.url}
                alt={media.alt ?? product.title}
                width={720}
                height={960}
                sizes="(max-width: 720px) 100vw, 50vw"
                priority={index === 0}
              />
            ))
          ) : (
            <div className="product-art product-art-large" role="img" aria-label={`تصویر ${product.title}`}>
              <span>تصویر محصول</span>
            </div>
          )}
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
                    <AddToCartButton
                      sku={variant.sku}
                      available={variant.available_qty > 0}
                    />
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
