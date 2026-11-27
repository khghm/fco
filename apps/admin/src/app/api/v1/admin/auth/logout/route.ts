import {
  revokeStaffSession,
  STAFF_SESSION_COOKIE,
  staffSessionTokenFromRequest,
} from "@fco/infrastructure/admin-session";
import {
  adminFailureResponse,
  apiError,
  logAdminApiFailure,
  requestIdFrom,
  sameOriginRequest,
} from "../../../../../../lib/http";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  const requestId = requestIdFrom(request);
  if (!sameOriginRequest(request)) {
    return apiError(403, "FCO-1003", "درخواست از مبدأ معتبر نیست.", requestId);
  }

  try {
    const token = staffSessionTokenFromRequest(request);
    if (token) {
      await revokeStaffSession(token);
    }
    return new Response(null, {
      status: 204,
      headers: {
        "Cache-Control": "no-store",
        "Set-Cookie": `${STAFF_SESSION_COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0`,
        "X-Request-Id": requestId,
      },
    });
  } catch (error) {
    logAdminApiFailure("admin_logout_failed", requestId, error);
    return adminFailureResponse(error, requestId);
  }
}
