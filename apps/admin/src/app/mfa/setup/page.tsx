import { MfaSetup } from "./mfa-setup";

export default function MfaSetupPage() {
  return (
    <main className="admin-shell">
      <section className="admin-page mfa-setup-page">
        <p className="admin-eyebrow">امنیت حساب</p>
        <h1>راه‌اندازی تأیید دومرحله‌ای</h1>
        <MfaSetup />
      </section>
    </main>
  );
}
