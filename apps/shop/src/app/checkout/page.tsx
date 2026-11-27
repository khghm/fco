import Link from "next/link";
import CheckoutForm from "./checkout-form";

export const dynamic = "force-dynamic";

export default function CheckoutPage() {
  return (
    <main className="storefront">
      <header className="site-header">
        <Link className="wordmark" href="/" aria-label="صفحهٔ اصلی فروشگاه FCO">
          FCO
        </Link>
        <Link href="/">بازگشت به فروشگاه</Link>
      </header>
      <CheckoutForm />
    </main>
  );
}
