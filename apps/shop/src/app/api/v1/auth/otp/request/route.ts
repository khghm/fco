import {
  createSmsProvider,
  requestCustomerOtp,
  type ISmsProvider,
} from "@fco/infrastructure/customer-auth";
import {
  apiErrorResponse,
  apiFailureResponse,
  isRecord,
  logApiFailure,
  readJsonBody,
  requestIdFrom,
  sameOriginRequest,
} from "../../../http";
import { resolveClientIp } from "@/lib/rate-limit";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  const requestId = requestIdFrom(request);
  if (!sameOriginRequest(request)) {
    return apiErrorResponse(403, "FCO-1003", "درخواست از مبدأ معتبر نیست.", requestId);
  }

  const parsedBody = await readJsonBody(request, 4096);
  if (parsedBody.kind === "too_large") {
    return apiErrorResponse(413, "FCO-1001", "اندازهٔ درخواست بیش از حد مجاز است.", requestId);
  }
  if (parsedBody.kind === "invalid" || !isRecord(parsedBody.value)) {
    return apiErrorResponse(400, "FCO-1001", "اطلاعات درخواست کد معتبر نیست.", requestId);
  }
  const mobile =
    typeof parsedBody.value.mobile === "string"
      ? parsedBody.value.mobile.trim()
      : "";
  if (!/^09[0-9]{9}$/.test(mobile)) {
    return apiErrorResponse(400, "FCO-1001", "شمارهٔ موبایل معتبر نیست.", requestId);
  }

  let smsProvider: ISmsProvider;
  try {
    smsProvider = createSmsProvider();
  } catch (error) {
    logApiFailure("customer_otp_provider_unavailable", requestId, error);
    return apiErrorResponse(
      503,
      "FCO-1018",
      "ارسال پیامک ورود در این محیط پیکربندی نشده است.",
      requestId,
    );
  }

  try {
    const ip = resolveClientIp(request.headers);
    await requestCustomerOtp(mobile, ip === "unknown" ? null : ip, smsProvider);
    return Response.json(
      { data: { accepted: true }, meta: { request_id: requestId } },
      {
        status: 202,
        headers: {
          "Cache-Control": "no-store",
          "X-Request-Id": requestId,
        },
      },
    );
  } catch (error) {
    logApiFailure("customer_otp_request_failed", requestId, error);
    if (error instanceof Error && error.message.includes("FCO-1017")) {
      return apiErrorResponse(
        503,
        "FCO-1018",
        "Spool پیامک توسعه خاموش است.",
        requestId,
      );
    }
    return apiFailureResponse(error, requestId);
  }
}
