"use client";

type CatalogErrorProps = {
  error: Error & { digest?: string };
  reset: () => void;
};

export default function CatalogError({ reset }: CatalogErrorProps) {
  return (
    <main className="storefront">
      <section className="empty-state" role="alert">
        <h1>دریافت محصولات ممکن نشد</h1>
        <p>ارتباط با فروشگاه برقرار نشد. چند لحظهٔ دیگر دوباره تلاش کنید.</p>
        <button className="retry-button" onClick={reset} type="button">
          تلاش دوباره
        </button>
      </section>
    </main>
  );
}
