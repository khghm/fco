import { beginStaffMfaEnrollment } from "@fco/infrastructure/staff-auth";
import {
  adminFailureResponse,
  apiError,
  logAdminApiFailure,
  requestIdFrom,
  sameOriginRequest,
} from "../../../../../../../lib/http";
import { mfaSetupActor } from "../../../../../../../lib/mfa-setup";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

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
    const result = await beginStaffMfaEnrollment(actor.userId);
    if (result.kind === "already_enabled") {
      return apiError(409, "FCO-1006", "MFA این حساب از قبل فعال است.", requestId);
    }
    if (result.kind === "account_unavailable") {
      return apiError(403, "FCO-1005", "حساب کارکنان فعال نیست.", requestId);
    }
    return Response.json(
      {
        data: { secret: result.secret, otpauth_url: result.otpauthUrl },
        meta: { request_id: requestId },
      },
      { headers: { "Cache-Control": "no-store", "X-Request-Id": requestId } },
    );
  } catch (error) {
    logAdminApiFailure("admin_mfa_setup_failed", requestId, error);
    return adminFailureResponse(error, requestId);
  }
}
