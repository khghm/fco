import Link from "next/link";
import { notFound } from "next/navigation";
import { mockPaymentDetails } from "@fco/infrastructure/checkout";
import { matchesMockPaymentToken, mockPaymentEnabled } from "@/lib/checkout";
import MockPaymentActions from "./mock-payment-actions";

export const dynamic = "force-dynamic";

type MockPaymentPageProps = {
  params: Promise<{ paymentId: string }>;
  searchParams: Promise<{ token?: string }>;
};

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export default async function MockPaymentPage({
  params,
  searchParams,
}: MockPaymentPageProps) {
  if (!mockPaymentEnabled()) {
    notFound();
  }
  const [{ paymentId }, query] = await Promise.all([params, searchParams]);
  if (!uuidPattern.test(paymentId) || !query.token) {
    notFound();
  }

  const payment = await mockPaymentDetails(paymentId);
  if (!payment || !matchesMockPaymentToken(query.token, payment.mock_token_hash)) {
    notFound();
  }

  return (
    <main className="storefront payment-page">
      <header className="site-header">
        <Link className="wordmark" href="/" aria-label="صفحهٔ اصلی فروشگاه FCO">
          FCO
        </Link>
        <Link href="/">بازگشت به فروشگاه</Link>
      </header>
      <section className="payment-panel">
        <p className="eyebrow">درگاه آزمایشی</p>
        <h1>پرداخت سفارش {payment.order_number}</h1>
        <p>
          مبلغ: <bdi dir="ltr">{Number(payment.amount_rial).toLocaleString("fa-IR")} ریال</bdi>
        </p>
        <p className="header-note">
          این درگاه فقط برای محیط آزمون فعال است و تراکنش واقعی انجام نمی‌دهد.
        </p>
        <MockPaymentActions
          paymentId={paymentId}
          token={query.token}
          initialStatus={payment.status}
        />
      </section>
    </main>
  );
}
