import { MfaSetup } from "../../../mfa/setup/mfa-setup";

export default function AdminSecurityPage() {
  return (
    <section className="admin-page">
      <p className="admin-eyebrow">حساب کارکنان</p>
      <h1>امنیت و تأیید دومرحله‌ای</h1>
      <MfaSetup />
    </section>
  );
}
