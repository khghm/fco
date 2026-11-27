"use client";

import { useState } from "react";

export default function AddToCartButton({
  sku,
  available,
}: {
  sku: string;
  available: boolean;
}) {
  const [message, setMessage] = useState("");
  const [saving, setSaving] = useState(false);

  async function addItem() {
    setSaving(true);
    setMessage("");
    try {
      const response = await fetch("/api/v1/cart/items", {
        method: "POST",
        headers: {
          "content-type": "application/json",
          "x-request-id": crypto.randomUUID(),
        },
        body: JSON.stringify({ sku, quantity: 1 }),
      });
      const body: unknown = await response.json();
      if (!response.ok) {
        setMessage("افزودن به سبد انجام نشد؛ دوباره تلاش کنید.");
        return;
      }
      if (typeof body !== "object" || body === null || !("data" in body)) {
        setMessage("پاسخ سبد خرید معتبر نیست.");
        return;
      }
      setMessage("به سبد خرید اضافه شد.");
    } catch {
      setMessage("ارتباط با فروشگاه برقرار نشد؛ دوباره تلاش کنید.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <div className="cart-add">
      <button
        disabled={!available || saving}
        onClick={() => void addItem()}
        type="button"
      >
        {saving ? "در حال افزودن…" : "افزودن به سبد"}
      </button>
      {message && <span role="status">{message}</span>}
    </div>
  );
}
