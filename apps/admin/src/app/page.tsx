import Link from "next/link";

export default function Home() {
  return (
    <main className="admin-shell">
      <header className="admin-header">
        <Link href="/" aria-label="صفحهٔ اصلی پنل FCO">
          FCO
        </Link>
        <span>پنل عملیات</span>
      </header>
      <section aria-labelledby="admin-title">
        <p className="admin-eyebrow">مدیریت کسب‌وکار</p>
        <h1 id="admin-title">پنل مدیریت FCO</h1>
        <p>
          ورود کارکنان و ابزارهای عملیاتی هنوز به این پنل متصل نشده‌اند؛ تا
          آماده‌شدن احراز هویت، هیچ عملیات مدیریتی در دسترس نیست.
        </p>
      </section>
    </main>
  );
}
