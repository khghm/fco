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
        <p>برای ورود به ابزارهای عملیاتی، از حساب کارکنان خود استفاده کنید.</p>
        <Link className="admin-login-link" href="/login">ورود کارکنان</Link>
      </section>
    </main>
  );
}
