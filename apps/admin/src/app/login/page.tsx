import { LoginForm } from "./login-form";

export default function LoginPage() {
  return (
    <main className="admin-shell">
      <header className="admin-header">
        <span className="admin-brand">FCO</span>
        <span>پنل عملیات</span>
      </header>
      <section aria-labelledby="login-title">
        <p className="admin-eyebrow">مدیریت کسب‌وکار</p>
        <h1 id="login-title">ورود کارکنان</h1>
        <p>برای ادامه از حساب سازمانی خود استفاده کنید.</p>
        <LoginForm />
      </section>
    </main>
  );
}
