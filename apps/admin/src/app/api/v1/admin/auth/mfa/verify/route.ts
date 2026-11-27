import { confirmStaffMfaEnrollment } from "@fco/infrastructure/staff-auth";
import {
  STAFF_SESSION_COOKIE,
} from "@fco/infrastructure/admin-session";
import {
  adminFailureResponse,
  apiError,
  logAdminApiFailure,
  readJsonBody,
  requestIdFrom,
  sameOriginRequest,
} from "../../../../../../../lib/http";
import { adminClientIp } from "../../../../../../../lib/admin-login-rate-limit";
import {
  clearMfaSetupCookie,
  mfaSetupActor,
} from "../../../../../../../lib/mfa-setup";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function sessionCookie(token: string, expiresAt: Date): string {
  const maxAge = Math.max(0, Math.floor((expiresAt.getTime() - Date.now()) / 1000));
  return `${STAFF_SESSION_COOKIE}=${token}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${maxAge}; Expires=${expiresAt.toUTCString()}`;
}

export async function POST(request: Request): Promise<Response> {
  const requestId = requestIdFrom(request);
  if (!sameOriginRequest(request)) {
    return apiError(403, "FCO-1003", "درخواست از مبدأ معتبر نیست.", requestId);
  }

  try {
    const actor = await mfaSetupActor(request);
    if (!actor) {
      return apiError(401, "FCO-1005", "نشست یا مجوز راه‌اندازی معتبر نیست.", requestId);
    }
    const parsedBody = await readJsonBody(request, 1024);
    if (parsedBody.kind === "too_large") {
      return apiError(413, "FCO-1001", "اندازهٔ درخواست بیش از حد مجاز است.", requestId);
    }
    if (parsedBody.kind === "invalid" || !isRecord(parsedBody.value)) {
      return apiError(400, "FCO-1001", "کد تأیید معتبر نیست.", requestId);
    }
    const code = parsedBody.value.code;
    if (typeof code !== "string" || !/^\d{6}$/.test(code)) {
      return apiError(400, "FCO-1001", "کد تأیید باید شش رقم باشد.", requestId);
    }

    const result = await confirmStaffMfaEnrollment({
      userId: actor.userId,
      code,
      requestId,
      issueSession: actor.challenge,
      ip: adminClientIp(request),
      userAgent: request.headers.get("user-agent")?.slice(0, 512) ?? null,
    });
    if (result.kind === "invalid_code") {
      return apiError(400, "FCO-1006", "کد تأیید درست یا تازه نیست.", requestId);
    }
    if (result.kind === "not_pending") {
      return apiError(409, "FCO-1006", "راه‌اندازی MFA در انتظار تأیید نیست.", requestId);
    }

    const response = Response.json(
      {
        data: {
          recovery_codes: result.recoveryCodes,
          session_established: result.session !== null,
        },
        meta: { request_id: requestId },
      },
      { headers: { "Cache-Control": "no-store", "X-Request-Id": requestId } },
    );
    if (result.session) {
      response.headers.append(
        "Set-Cookie",
        sessionCookie(result.session.token, result.session.expiresAt),
      );
    }
    if (actor.challenge) {
      response.headers.append("Set-Cookie", clearMfaSetupCookie());
    }
    return response;
  } catch (error) {
    logAdminApiFailure("admin_mfa_verify_failed", requestId, error);
    return adminFailureResponse(error, requestId);
  }
}
