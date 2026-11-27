"use client";

import { useState, type FormEvent } from "react";

interface LoginResponse {
  error?: { message?: string; request_id?: string };
}

export function LoginForm() {
  const [message, setMessage] = useState("");
  const [requestId, setRequestId] = useState("");
  const [pending, setPending] = useState(false);
  const [authenticated, setAuthenticated] = useState(false);

  async function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setPending(true);
    setMessage("");
    setRequestId("");
    const form = new FormData(event.currentTarget);
    try {
      const response = await fetch("/api/v1/admin/auth/login", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          email: form.get("email"),
          password: form.get("password"),
          totp: form.get("totp") || null,
        }),
      });
      const body = (await response.json()) as LoginResponse;
      if (!response.ok) {
        setMessage(body.error?.message ?? "ورود انجام نشد.");
        setRequestId(body.error?.request_id ?? response.headers.get("X-Request-Id") ?? "");
        return;
      }
      setAuthenticated(true);
      setMessage("ورود موفق انجام شد؛ نشست امن فعال است.");
      setRequestId(response.headers.get("X-Request-Id") ?? "");
    } catch {
      setMessage("ارتباط با سرویس ورود برقرار نشد.");
    } finally {
      setPending(false);
    }
  }

  async function logout() {
    setPending(true);
    try {
      const response = await fetch("/api/v1/admin/auth/logout", { method: "POST" });
      if (!response.ok) {
        setMessage("خروج انجام نشد؛ کمی بعد دوباره تلاش کنید.");
        return;
      }
      setAuthenticated(false);
      setMessage("از پنل خارج شدید.");
    } catch {
      setMessage("ارتباط با سرویس خروج برقرار نشد.");
    } finally {
      setPending(false);
    }
  }

  return (
    <>
      {authenticated ? (
        <div className="login-success">
          <p role="status">{message}</p>
          <button type="button" onClick={logout} disabled={pending}>
            {pending ? "در حال خروج…" : "خروج امن"}
          </button>
        </div>
      ) : (
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
            کد MFA (در صورت فعال بودن)
            <input name="totp" type="text" inputMode="numeric" autoComplete="one-time-code" maxLength={6} />
          </label>
          <button type="submit" disabled={pending}>
            {pending ? "در حال بررسی…" : "ورود"}
          </button>
        </form>
      )}
      {!authenticated && message && <p className="login-message" role="alert">{message}</p>}
      {requestId && <p className="request-id">شناسهٔ درخواست: {requestId}</p>}
    </>
  );
}
