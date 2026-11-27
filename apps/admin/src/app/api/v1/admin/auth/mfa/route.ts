import { getStaffMfaStatus } from "@fco/infrastructure/staff-auth";
import {
  adminFailureResponse,
  apiError,
  logAdminApiFailure,
  requestIdFrom,
} from "../../../../../../lib/http";
import { mfaSetupActor } from "../../../../../../lib/mfa-setup";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  const requestId = requestIdFrom(request);
  try {
    const actor = await mfaSetupActor(request);
    if (!actor) {
      return apiError(401, "FCO-1005", "نشست معتبر نیست.", requestId);
    }
    const status = await getStaffMfaStatus(actor.userId);
    return Response.json(
      { data: { ...status, setup_challenge: actor.challenge }, meta: { request_id: requestId } },
      { headers: { "Cache-Control": "no-store", "X-Request-Id": requestId } },
    );
  } catch (error) {
    logAdminApiFailure("admin_mfa_status_failed", requestId, error);
    return adminFailureResponse(error, requestId);
  }
}
