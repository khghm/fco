"use client";

import { useState } from "react";

interface MockPaymentActionsProps {
  paymentId: string;
  token: string;
  initialStatus: string;
}

export default function MockPaymentActions({
  paymentId,
  token,
  initialStatus,
}: MockPaymentActionsProps) {
  const [status, setStatus] = useState(initialStatus);
  const [message, setMessage] = useState("");
  const [saving, setSaving] = useState(false);

  async function complete(outcome: "succeeded" | "failed") {
    setSaving(true);
    setMessage("");
    try {
      const response = await fetch(
        `/api/v1/payments/mock/${paymentId}/complete`,
        {
          method: "POST",
          headers: {
            "content-type": "application/json",
            "x-request-id": crypto.randomUUID(),
          },
          body: JSON.stringify({ token, outcome }),
        },
      );
      const body: unknown = await response.json();
      if (!response.ok || typeof body !== "object" || body === null || !("data" in body)) {
        setMessage("ثبت نتیجهٔ پرداخت انجام نشد؛ دوباره تلاش کنید.");
        return;
      }
      const data = body.data;
      if (typeof data !== "object" || data === null || !("result" in data)) {
        setMessage("پاسخ درگاه معتبر نیست.");
        return;
      }
      const result = data.result;
      if (result === "succeeded" || result === "failed" || result === "expired") {
        setStatus(result);
        setMessage(
          result === "succeeded"
            ? "پرداخت آزمایشی با موفقیت ثبت شد."
            : result === "expired"
              ? "مهلت پرداخت پایان یافته است؛ سبد خرید بازیابی شد."
              : "پرداخت ناموفق بود؛ سبد خرید بازیابی شد.",
        );
      }
    } catch {
      setMessage("ارتباط با درگاه برقرار نشد؛ دوباره تلاش کنید.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="payment-actions">
      {status === "initiated" ? (
        <>
          <button disabled={saving} onClick={() => void complete("succeeded")} type="button">
            پرداخت آزمایشی موفق
          </button>
          <button
            className="secondary-button"
            disabled={saving}
            onClick={() => void complete("failed")}
            type="button"
          >
            شبیه‌سازی پرداخت ناموفق
          </button>
        </>
      ) : (
        <p role="status">وضعیت پرداخت: {status}</p>
      )}
      {message && <p role="status">{message}</p>}
    </div>
  );
}
