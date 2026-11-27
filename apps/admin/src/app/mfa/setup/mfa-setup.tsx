"use client";

import { QRCodeSVG } from "qrcode.react";
import { useEffect, useState } from "react";
import { useRouter } from "next/navigation";

interface MfaStatus {
  enabled: boolean;
  pending: boolean;
  recoveryCodesRemaining: number;
  setup_challenge: boolean;
}

interface SetupData {
  secret: string;
  otpauth_url: string;
}

interface ApiResponse<T> {
  data?: T;
  error?: { message?: string; request_id?: string };
  meta?: { request_id?: string };
}

export function MfaSetup() {
  const router = useRouter();
  const [status, setStatus] = useState<MfaStatus | null>(null);
  const [setup, setSetup] = useState<SetupData | null>(null);
  const [code, setCode] = useState("");
  const [recoveryCodes, setRecoveryCodes] = useState<string[]>([]);
  const [sessionEstablished, setSessionEstablished] = useState(false);
  const [pending, setPending] = useState(false);
  const [message, setMessage] = useState("");
  const [requestId, setRequestId] = useState("");
  const [error, setError] = useState("");

  useEffect(() => {
    let active = true;
    async function loadStatus() {
      try {
        const response = await fetch("/api/v1/admin/auth/mfa", { cache: "no-store" });
        const body = (await response.json()) as ApiResponse<MfaStatus>;
        if (!active) {
          return;
        }
        if (!response.ok || !body.data) {
          setError(body.error?.message ?? "وضعیت MFA دریافت نشد.");
          setRequestId(body.error?.request_id ?? "");
          return;
        }
        setStatus(body.data);
        setRequestId(body.meta?.request_id ?? response.headers.get("X-Request-Id") ?? "");
      } catch {
        if (active) {
          setError("ارتباط با سرویس امنیت حساب برقرار نشد.");
        }
      }
    }
    void loadStatus();
    return () => {
      active = false;
    };
  }, []);

  async function beginSetup() {
    setPending(true);
    setError("");
    setMessage("");
    setRequestId("");
    try {
      const response = await fetch("/api/v1/admin/auth/mfa/setup", { method: "POST" });
      const body = (await response.json()) as ApiResponse<SetupData>;
      if (!response.ok || !body.data) {
        setError(body.error?.message ?? "راه‌اندازی MFA آغاز نشد.");
        setRequestId(body.error?.request_id ?? response.headers.get("X-Request-Id") ?? "");
        return;
      }
      setSetup(body.data);
      setCode("");
      setRequestId(body.meta?.request_id ?? response.headers.get("X-Request-Id") ?? "");
    } catch {
      setError("ارتباط با سرویس راه‌اندازی MFA برقرار نشد.");
    } finally {
      setPending(false);
    }
  }

  async function verifyCode(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setPending(true);
    setError("");
    setMessage("");
    setRequestId("");
    try {
      const response = await fetch("/api/v1/admin/auth/mfa/verify", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code }),
      });
      const body = (await response.json()) as ApiResponse<{
        recovery_codes: string[];
        session_established: boolean;
      }>;
      if (!response.ok || !body.data) {
        setError(body.error?.message ?? "تأیید کد انجام نشد.");
        setRequestId(body.error?.request_id ?? response.headers.get("X-Request-Id") ?? "");
        return;
      }
      setRecoveryCodes(body.data.recovery_codes);
      setSessionEstablished(body.data.session_established);
      setSetup(null);
      setStatus((current) =>
        current
          ? {
              ...current,
              enabled: true,
              pending: false,
              recoveryCodesRemaining: body.data?.recovery_codes.length ?? 0,
            }
          : current,
      );
      setMessage("MFA فعال شد. کدهای بازیابی فقط همین‌بار نمایش داده می‌شوند.");
      setRequestId(body.meta?.request_id ?? response.headers.get("X-Request-Id") ?? "");
    } catch {
      setError("ارتباط با سرویس تأیید MFA برقرار نشد.");
    } finally {
      setPending(false);
    }
  }

  async function copyRecoveryCodes() {
    try {
      await navigator.clipboard.writeText(recoveryCodes.join("\n"));
      setMessage("کدهای بازیابی کپی شدند؛ آن‌ها را در جای امن نگه دارید.");
    } catch {
      setError("کپی خودکار ممکن نشد؛ کدها را دستی ذخیره کنید.");
    }
  }

  function downloadRecoveryCodes() {
    const blob = new Blob([`FCO recovery codes\n${recoveryCodes.join("\n")}\n`], {
      type: "text/plain;charset=utf-8",
    });
    const url = URL.createObjectURL(blob);
    const anchor = document.createElement("a");
    anchor.href = url;
    anchor.download = "fco-recovery-codes.txt";
    anchor.click();
    URL.revokeObjectURL(url);
  }

  return (
    <div className="mfa-setup">
      {error && <p className="admin-alert admin-alert-error" role="alert">{error}</p>}
      {message && <p className="admin-alert admin-alert-success" role="status">{message}</p>}
      {requestId && <p className="request-id">شناسهٔ درخواست: {requestId}</p>}

      {status ? (
        <div className="admin-status-card">
          <strong>{status.enabled ? "MFA فعال است" : "MFA فعال نیست"}</strong>
          <span>
            {status.enabled
              ? `${status.recoveryCodesRemaining} کد بازیابی باقی مانده`
              : status.setup_challenge
                ? "حساب برای ورود به این مرحله، راه‌اندازی MFA را الزامی کرده است."
                : "برای فعال‌شدن MFA، QR را اسکن و کد شش‌رقمی را تأیید کنید."}
          </span>
        </div>
      ) : (
        <p role="status">در حال بررسی وضعیت MFA…</p>
      )}

      {status && !status.enabled && !setup && recoveryCodes.length === 0 && (
        <button type="button" onClick={beginSetup} disabled={pending}>
          {pending ? "در حال آماده‌سازی…" : status.pending ? "ادامهٔ راه‌اندازی MFA" : "فعال‌سازی MFA"}
        </button>
      )}

      {setup && (
        <div className="admin-panel mfa-enrollment-panel">
          <h2>۱. اسکن کد یا ورود دستی</h2>
          <p>در برنامهٔ احراز هویت، حساب جدیدی اضافه و QR زیر را اسکن کنید.</p>
          <div className="mfa-qr">
            <QRCodeSVG value={setup.otpauth_url} size={220} level="M" includeMargin />
          </div>
          <p className="mfa-secret-label">اگر امکان اسکن نیست، این کلید را دستی وارد کنید:</p>
          <code className="mfa-secret">{setup.secret}</code>
          <h2>۲. تأیید مالکیت</h2>
          <p>کد شش‌رقمی تازهٔ برنامه را وارد کنید؛ تا تأیید نشود MFA فعال نخواهد شد.</p>
          <form className="admin-form-grid" onSubmit={verifyCode}>
            <label>
              کد تأیید
              <input
                value={code}
                onChange={(event) => setCode(event.currentTarget.value.replace(/\D/g, "").slice(0, 6))}
                inputMode="numeric"
                autoComplete="one-time-code"
                pattern="\d{6}"
                minLength={6}
                maxLength={6}
                required
              />
            </label>
            <button type="submit" disabled={pending || code.length !== 6}>
              {pending ? "در حال تأیید…" : "تأیید و فعال‌سازی"}
            </button>
          </form>
        </div>
      )}

      {recoveryCodes.length > 0 && (
        <div className="admin-panel recovery-codes">
          <h2>کدهای بازیابی یک‌بارمصرف</h2>
          <p>
            هر کد فقط یک‌بار برای ورود قابل‌استفاده است. این صفحه را ذخیره یا چاپ کنید؛
            کدها بعد از خروج از این صفحه دوباره قابل دریافت نیستند.
          </p>
          <ol>
            {recoveryCodes.map((recoveryCode) => <li key={recoveryCode}>{recoveryCode}</li>)}
          </ol>
          <div className="admin-button-row">
            <button type="button" onClick={() => void copyRecoveryCodes()}>کپی کدها</button>
            <button type="button" className="admin-secondary-button" onClick={downloadRecoveryCodes}>
              دانلود فایل
            </button>
          </div>
          {sessionEstablished && (
            <button type="button" onClick={() => router.replace("/admin/products")}>
              کدها را ذخیره کردم؛ ورود به پنل
            </button>
          )}
        </div>
      )}
    </div>
  );
}
