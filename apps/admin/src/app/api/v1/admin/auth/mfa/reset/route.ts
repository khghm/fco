import { createMfaSetupChallenge, resetStaffMfa } from "@fco/infrastructure/staff-auth";
import {
  STAFF_MFA_SETUP_COOKIE,
  STAFF_SESSION_COOKIE,
} from "@fco/infrastructure/admin-session";
import {
  adminClientIp,
  consumeAdminLoginAttempt,
} from "../../../../../../../lib/admin-login-rate-limit";
import { adminSessionFromRequest } from "../../../../../../../lib/admin-session";
import {
  adminFailureResponse,
  apiError,
  logAdminApiFailure,
  readJsonBody,
  requestIdFrom,
  sameOriginRequest,
} from "../../../../../../../lib/http";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function setupChallengeCookie(token: string, expiresAt: Date): string {
  const maxAge = Math.max(0, Math.floor((expiresAt.getTime() - Date.now()) / 1000));
  return `${STAFF_MFA_SETUP_COOKIE}=${token}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${maxAge}; Expires=${expiresAt.toUTCString()}`;
}

export async function POST(request: Request): Promise<Response> {
  const requestId = requestIdFrom(request);
  if (!sameOriginRequest(request)) {
    return apiError(403, "FCO-1003", "درخواست از مبدأ معتبر نیست.", requestId);
  }

  try {
    const session = await adminSessionFromRequest(request);
    if (!session) {
      return apiError(401, "FCO-1005", "نشست معتبر نیست.", requestId);
    }

    const parsedBody = await readJsonBody(request, 4096);
    if (parsedBody.kind === "too_large") {
      return apiError(413, "FCO-1001", "اندازهٔ درخواست بیش از حد مجاز است.", requestId);
    }
    if (parsedBody.kind === "invalid" || !isRecord(parsedBody.value)) {
      return apiError(400, "FCO-1001", "اطلاعات تأیید MFA معتبر نیست.", requestId);
    }

    const { password, totp, recovery_code: recoveryCode } = parsedBody.value;
    const hasTotp = typeof totp === "string" && /^\d{6}$/.test(totp);
    const hasRecoveryCode =
      typeof recoveryCode === "string" &&
      /^[A-Z2-7]{4}(?:-[A-Z2-7]{4}){3}$/i.test(recoveryCode);
    if (
      typeof password !== "string" ||
      password.length === 0 ||
      Buffer.byteLength(password, "utf8") > 1024 ||
      hasTotp === hasRecoveryCode ||
      (totp !== undefined && totp !== null && !hasTotp) ||
      (recoveryCode !== undefined && recoveryCode !== null && !hasRecoveryCode)
    ) {
      return apiError(
        400,
        "FCO-1001",
        "رمز فعلی و دقیقاً یکی از کد TOTP یا کد بازیابی لازم است.",
        requestId,
      );
    }

    const rateLimit = await consumeAdminLoginAttempt(
      `mfa-reset:${session.uid}`,
      adminClientIp(request),
    );
    if (!rateLimit.allowed) {
      const response = apiError(
        429,
        "FCO-1007",
        "تعداد تلاش‌های بازنشانی MFA بیش از حد مجاز است.",
        requestId,
      );
      response.headers.set("Retry-After", String(rateLimit.retryAfterSeconds));
      return response;
    }

    const result = await resetStaffMfa({
      userId: session.uid,
      password,
      totp: hasTotp ? totp : null,
      recoveryCode: hasRecoveryCode ? recoveryCode : null,
      requestId,
    });
    if (result.kind === "invalid_credentials") {
      return apiError(401, "FCO-1005", "رمز یا کد تأیید معتبر نیست.", requestId);
    }
    if (result.kind === "mfa_required") {
      return apiError(401, "FCO-1006", "کد MFA معتبر یا تازه نیست.", requestId);
    }
    if (result.kind === "account_unavailable") {
      return apiError(403, "FCO-1005", "حساب کارکنان فعال نیست.", requestId);
    }
    if (result.kind === "password_change_required") {
      return apiError(403, "FCO-1008", "ابتدا باید رمز حساب را تغییر دهید.", requestId);
    }

    const challenge = createMfaSetupChallenge(session.uid);
    const response = Response.json(
      {
        data: { setup_required: true },
        meta: { request_id: requestId },
      },
      {
        headers: {
          "Cache-Control": "no-store",
          "X-Request-Id": requestId,
        },
      },
    );
    response.headers.append(
      "Set-Cookie",
      setupChallengeCookie(challenge.token, challenge.expiresAt),
    );
    response.headers.append(
      "Set-Cookie",
      `${STAFF_SESSION_COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0`,
    );
    return response;
  } catch (error) {
    logAdminApiFailure("admin_mfa_reset_failed", requestId, error);
    return adminFailureResponse(error, requestId);
  }
}
