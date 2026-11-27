"use client";

import { useEffect, useRef, useState } from "react";

interface QuoteItem {
  variant_id: string;
  quantity: number;
  sku: string | null;
  product_title: string | null;
  unit_price_rial: number;
  line_total_rial: number;
}

interface Quote {
  items: QuoteItem[];
  subtotal_rial: number;
  shipping_rial: number;
  tax_amount_rial: number;
  total_rial: number;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isRial(value: unknown): value is number {
  return typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
}

function parseQuote(value: unknown): Quote | null {
  if (
    !isRecord(value) ||
    !Array.isArray(value.items) ||
    !isRial(value.subtotal_rial) ||
    !isRial(value.shipping_rial) ||
    !isRial(value.tax_amount_rial) ||
    !isRial(value.total_rial)
  ) {
    return null;
  }
  const items: QuoteItem[] = [];
  for (const entry of value.items) {
    if (
      !isRecord(entry) ||
      typeof entry.variant_id !== "string" ||
      !Number.isSafeInteger(entry.quantity) ||
      typeof entry.quantity !== "number" ||
      entry.quantity < 1 ||
      (entry.sku !== null && typeof entry.sku !== "string") ||
      (entry.product_title !== null && typeof entry.product_title !== "string") ||
      !isRial(entry.unit_price_rial) ||
      !isRial(entry.line_total_rial)
    ) {
      return null;
    }
    items.push({
      variant_id: entry.variant_id,
      quantity: entry.quantity,
      sku: entry.sku,
      product_title: entry.product_title,
      unit_price_rial: entry.unit_price_rial,
      line_total_rial: entry.line_total_rial,
    });
  }
  return {
    items,
    subtotal_rial: value.subtotal_rial,
    shipping_rial: value.shipping_rial,
    tax_amount_rial: value.tax_amount_rial,
    total_rial: value.total_rial,
  };
}

const rial = new Intl.NumberFormat("fa-IR");

export default function CheckoutForm() {
  const [quote, setQuote] = useState<Quote | null>(null);
  const [error, setError] = useState("");
  const [message, setMessage] = useState("");
  const [loading, setLoading] = useState(true);
  const [submitting, setSubmitting] = useState(false);
  const idempotencyKey = useRef<string | null>(null);

  useEffect(() => {
    let active = true;
    async function loadQuote() {
      setLoading(true);
      setError("");
      try {
        await fetch("/api/v1/cart", { cache: "no-store" });
        const response = await fetch("/api/v1/checkout/quote", {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: "{}",
          cache: "no-store",
        });
        const body: unknown = await response.json();
        if (!response.ok) {
          if (typeof body === "object" && body !== null && "error" in body) {
            const apiError = body.error;
            if (
              typeof apiError === "object" &&
              apiError !== null &&
              "message" in apiError &&
              typeof apiError.message === "string"
            ) {
              throw new Error(apiError.message);
            }
          }
          throw new Error("دریافت سبد خرید ناموفق بود.");
        }
        if (!isRecord(body) || !("data" in body)) {
          throw new Error("پاسخ برآورد سفارش معتبر نیست.");
        }
        const parsedQuote = parseQuote(body.data);
        if (!parsedQuote) {
          throw new Error("پاسخ برآورد سفارش معتبر نیست.");
        }
        if (active) setQuote(parsedQuote);
      } catch (loadError) {
        if (active) {
          setError(
            loadError instanceof Error
              ? loadError.message
              : "دریافت سبد خرید ناموفق بود.",
          );
        }
      } finally {
        if (active) setLoading(false);
      }
    }
    void loadQuote();
    return () => {
      active = false;
    };
  }, []);

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSubmitting(true);
    setError("");
    setMessage("");
    const form = new FormData(event.currentTarget);
    const payload = {
      guest_email: String(form.get("guest_email") ?? "").trim(),
      guest_mobile: String(form.get("guest_mobile") ?? "").trim(),
      shipping_address: {
        recipient_name: String(form.get("recipient_name") ?? "").trim(),
        mobile: String(form.get("guest_mobile") ?? "").trim(),
        province: String(form.get("province") ?? "").trim(),
        city: String(form.get("city") ?? "").trim(),
        postal_code: String(form.get("postal_code") ?? "").trim(),
        address: String(form.get("address") ?? "").trim(),
      },
    };
    idempotencyKey.current ??= crypto.randomUUID();
    try {
      const response = await fetch("/api/v1/checkout/orders", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "idempotency-key": idempotencyKey.current,
        },
        body: JSON.stringify(payload),
      });
      const body: unknown = await response.json();
      if (!response.ok) {
        if (typeof body === "object" && body !== null && "error" in body) {
          const apiError = body.error;
          if (
            typeof apiError === "object" &&
            apiError !== null &&
            "message" in apiError &&
            typeof apiError.message === "string"
          ) {
            throw new Error(apiError.message);
          }
        }
        throw new Error("ثبت سفارش ناموفق بود.");
      }
      if (!isRecord(body) || !isRecord(body.data) || typeof body.data.payment_url !== "string") {
        throw new Error("نشانی پرداخت معتبر نیست.");
      }
      window.location.assign(body.data.payment_url);
    } catch (submitError) {
      setError(
        submitError instanceof Error
          ? submitError.message
          : "ثبت سفارش ناموفق بود؛ می‌توانید با همان درخواست دوباره تلاش کنید.",
      );
    } finally {
      setSubmitting(false);
    }
  }

  function startNewAttempt() {
    idempotencyKey.current = null;
    setMessage("شناسهٔ تلاش بعدی تازه شد.");
  }

  return (
    <section className="checkout-panel">
      <p className="eyebrow">ثبت سفارش</p>
      <h1>سبد خرید و نشانی ارسال</h1>
      {loading ? (
        <p role="status">در حال بارگذاری سبد…</p>
      ) : error && !quote ? (
        <div className="empty-state" role="alert">
          <p>{error}</p>
        </div>
      ) : quote ? (
        <>
          <ul className="checkout-items">
            {quote.items.map((item) => (
              <li key={item.variant_id}>
                <span>{item.product_title ?? item.sku ?? "محصول"}</span>
                <span>{rial.format(item.quantity)} عدد</span>
                <bdi dir="ltr">{rial.format(item.line_total_rial)} ریال</bdi>
              </li>
            ))}
          </ul>
          <dl className="checkout-totals">
            <div><dt>جمع کالاها</dt><dd>{rial.format(quote.subtotal_rial)} ریال</dd></div>
            <div><dt>هزینهٔ ثابت ارسال</dt><dd>{rial.format(quote.shipping_rial)} ریال</dd></div>
            <div><dt>مالیات</dt><dd>{rial.format(quote.tax_amount_rial)} ریال</dd></div>
            <div className="checkout-total"><dt>مبلغ نهایی</dt><dd>{rial.format(quote.total_rial)} ریال</dd></div>
          </dl>
          <form className="checkout-form" onSubmit={submit}>
            <label>
              ایمیل
              <input autoComplete="email" name="guest_email" required type="email" />
            </label>
            <label>
              موبایل
              <input autoComplete="tel" inputMode="numeric" name="guest_mobile" pattern="09[0-9]{9}" required />
            </label>
            <label>
              نام گیرنده
              <input autoComplete="name" name="recipient_name" required />
            </label>
            <label>
              استان
              <input autoComplete="address-level1" name="province" required />
            </label>
            <label>
              شهر
              <input autoComplete="address-level2" name="city" required />
            </label>
            <label>
              کد پستی
              <input autoComplete="postal-code" inputMode="numeric" name="postal_code" pattern="[0-9]{10}" required />
            </label>
            <label className="checkout-address">
              نشانی کامل
              <textarea autoComplete="street-address" name="address" required rows={3} />
            </label>
            {error && <p className="checkout-error" role="alert">{error}</p>}
            {message && <p role="status">{message}</p>}
            <button disabled={submitting} type="submit">
              {submitting ? "در حال ثبت سفارش…" : "ثبت سفارش و رفتن به پرداخت آزمایشی"}
            </button>
            <button
              className="secondary-button"
              onClick={startNewAttempt}
              type="button"
            >
              شروع تلاش تازه با شناسهٔ جدید
            </button>
          </form>
        </>
      ) : null}
    </section>
  );
}
