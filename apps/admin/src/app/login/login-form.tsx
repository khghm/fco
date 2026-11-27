"use client";

import { useState, type FormEvent } from "react";
import { useRouter } from "next/navigation";

interface LoginResponse {
  error?: { code?: string; message?: string; request_id?: string };
}

export function LoginForm() {
  const router = useRouter();
  const [message, setMessage] = useState("");
  const [requestId, setRequestId] = useState("");
  const [pending, setPending] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setPending(true);
    setMessage("");
    setRequestId("");
    const form = new FormData(event.currentTarget);
    const mfaCode = String(form.get("mfa_code") ?? "").trim();
    const isTotp = /^\d{6}$/.test(mfaCode);
    const isRecoveryCode = /^[A-Z2-7]{4}(?:-[A-Z2-7]{4}){3}$/i.test(mfaCode);
    if (mfaCode && !isTotp && !isRecoveryCode) {
      setMessage("کد برنامه باید ۶ رقم یا کد بازیابی ۱۶ حرفی باشد.");
      setPending(false);
      return;
    }
    try {
      const response = await fetch("/api/v1/admin/auth/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          email: form.get("email"),
          password: form.get("password"),
          totp: isTotp ? mfaCode : null,
          recovery_code: isRecoveryCode ? mfaCode.toUpperCase() : null,
        }),
      });
      const body = (await response.json()) as LoginResponse;
      if (!response.ok) {
        if (response.status === 403 && body.error?.code === "FCO-1006") {
          router.push("/mfa/setup");
          return;
        }
        setMessage(body.error?.message ?? "ورود انجام نشد.");
        setRequestId(body.error?.request_id ?? response.headers.get("X-Request-Id") ?? "");
        return;
      }
      router.replace("/admin/products");
      router.refresh();
    } catch {
      setMessage("ارتباط با سرویس ورود برقرار نشد.");
    } finally {
      setPending(false);
    }
  }

  return (
    <>
      <form className="login-form" onSubmit={submit}>
        <label>
          ایمیل سازمانی
          <input name="email" type="email" autoComplete="username" required maxLength={254} />
        </label>
        <label>
          رمز عبور
          <input
            name="password"
            type="password"
            autoComplete="current-password"
            required
            maxLength={1024}
          />
        </label>
        <label>
          کد برنامهٔ احراز هویت یا کد بازیابی
          <input
            name="mfa_code"
            type="text"
            inputMode="text"
            autoComplete="one-time-code"
            aria-describedby="mfa-help"
            maxLength={19}
          />
          <small id="mfa-help">برای حساب‌های دارای MFA، کد شش‌رقمی یا یکی از کدهای بازیابی را وارد کنید.</small>
        </label>
        <button type="submit" disabled={pending}>
          {pending ? "در حال بررسی…" : "ورود"}
        </button>
      </form>
      {message && <p className="login-message" role="alert">{message}</p>}
      {requestId && <p className="request-id">شناسهٔ درخواست: {requestId}</p>}
    </>
  );
}
