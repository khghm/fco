import {
  createMfaSetupChallenge,
  loginStaff,
} from "@fco/infrastructure/staff-auth";
import {
  STAFF_MFA_SETUP_COOKIE,
  STAFF_SESSION_COOKIE,
} from "@fco/infrastructure/admin-session";
import {
  adminClientIp,
  consumeAdminLoginAttempt,
} from "../../../../../../lib/admin-login-rate-limit";
import {
  adminFailureResponse,
  apiError,
  logAdminApiFailure,
  readJsonBody,
  requestIdFrom,
  sameOriginRequest,
} from "../../../../../../lib/http";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function sessionCookie(token: string, expiresAt: Date): string {
  const maxAge = Math.max(0, Math.floor((expiresAt.getTime() - Date.now()) / 1000));
  return `${STAFF_SESSION_COOKIE}=${token}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${maxAge}; Expires=${expiresAt.toUTCString()}`;
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

  let parsedBody;
  try {
    parsedBody = await readJsonBody(request, 4096);
  } catch (error) {
    logAdminApiFailure("admin_login_body_read_failed", requestId, error);
    return adminFailureResponse(error, requestId);
  }
  if (parsedBody.kind === "too_large") {
    return apiError(413, "FCO-1001", "اندازهٔ درخواست بیش از حد مجاز است.", requestId);
  }
  if (parsedBody.kind === "invalid") {
    return apiError(400, "FCO-1001", "بدنهٔ JSON معتبر نیست.", requestId);
  }
  const body = parsedBody.value;
  if (!isRecord(body)) {
    return apiError(400, "FCO-1001", "اطلاعات ورود معتبر نیست.", requestId);
  }

  const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
  const password = typeof body.password === "string" ? body.password : "";
  const totp =
    body.totp === undefined || body.totp === ""
      ? null
      : typeof body.totp === "string"
        ? body.totp
        : undefined;
  const recoveryCode =
    body.recovery_code === undefined || body.recovery_code === ""
      ? null
      : typeof body.recovery_code === "string"
        ? body.recovery_code
        : undefined;
  if (
    !/^[^@\s]{1,64}@[^@\s]{1,190}\.[^@\s]{2,}$/.test(email) ||
    password.length === 0 ||
    Buffer.byteLength(password, "utf8") > 1024 ||
    totp === undefined ||
    (totp !== null && !/^\d{6}$/.test(totp)) ||
    recoveryCode === undefined ||
    (recoveryCode !== null &&
      !/^[A-Z2-7]{4}(?:-[A-Z2-7]{4}){3}$/i.test(recoveryCode)) ||
    (totp !== null && recoveryCode !== null)
  ) {
    return apiError(400, "FCO-1001", "اطلاعات ورود معتبر نیست.", requestId);
  }

  try {
    const rateLimit = await consumeAdminLoginAttempt(email, adminClientIp(request));
    if (!rateLimit.allowed) {
      const response = apiError(
        429,
        "FCO-1007",
        "تعداد تلاش‌های ورود بیش از حد مجاز است.",
        requestId,
      );
      response.headers.set("Retry-After", String(rateLimit.retryAfterSeconds));
      return response;
    }

    const result = await loginStaff({
      email,
      password,
      totp,
      recoveryCode,
      userAgent: request.headers.get("user-agent")?.slice(0, 512) ?? null,
      ip: adminClientIp(request),
      requestId,
    });

    if (result.kind === "invalid_credentials") {
      return apiError(401, "FCO-1005", "ایمیل، رمز یا کد تأیید معتبر نیست.", requestId);
    }
    if (result.kind === "mfa_required") {
      return apiError(401, "FCO-1006", "کد تأیید MFA لازم یا معتبر نیست.", requestId);
    }
    if (result.kind === "mfa_setup_required") {
      const challenge = createMfaSetupChallenge(result.userId);
      const response = apiError(
        403,
        "FCO-1006",
        "برای این حساب، MFA باید پیش از ورود راه‌اندازی شود.",
        requestId,
      );
      response.headers.set(
        "Set-Cookie",
        setupChallengeCookie(challenge.token, challenge.expiresAt),
      );
      return response;
    }
    if (result.kind === "password_change_required") {
      return apiError(403, "FCO-1008", "پیش از ورود باید رمز اولیه تغییر کند.", requestId);
    }

    return Response.json(
      { data: { user_id: result.userId }, meta: { request_id: requestId } },
      {
        headers: {
          "Cache-Control": "no-store",
          "Set-Cookie": sessionCookie(result.token, result.expiresAt),
          "X-Request-Id": requestId,
        },
      },
    );
  } catch (error) {
    logAdminApiFailure("admin_login_failed", requestId, error);
    return adminFailureResponse(error, requestId);
  }
}
