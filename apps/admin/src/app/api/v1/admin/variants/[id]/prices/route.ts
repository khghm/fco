import { setAdminProductPrice } from "@fco/infrastructure/admin-catalog";
import {
  adminFailureResponse,
  apiError,
  logAdminApiFailure,
  readJsonBody,
  requestIdFrom,
  sameOriginRequest,
} from "../../../../../../../lib/http";
import { adminSessionFromRequest } from "../../../../../../../lib/admin-session";
import { isUuid } from "../../../../../../../lib/product-input";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseEffectiveFrom(value: unknown): string | null {
  if (
    typeof value !== "string" ||
    !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|[+-]\d{2}:\d{2})$/.test(value)
  ) {
    return null;
  }
  const [datePart, timePart] = value.split("T");
  const [year, month, day] = datePart.split("-").map(Number);
  const [hour, minute, second] = timePart.split(/[:.Z+-]/).map(Number);
  const calendarDate = new Date(Date.UTC(year, month - 1, day));
  if (
    calendarDate.toISOString().slice(0, 10) !== datePart ||
    hour > 23 ||
    minute > 59 ||
    second > 59 ||
    !Number.isFinite(Date.parse(value))
  ) {
    return null;
  }
  return value;
}

export async function POST(
  request: Request,
  context: { params: Promise<{ id: string }> },
): Promise<Response> {
  const requestId = requestIdFrom(request);
  if (!sameOriginRequest(request)) {
    return apiError(403, "FCO-1003", "درخواست از مبدأ معتبر نیست.", requestId);
  }

  try {
    const { id: variantId } = await context.params;
    if (!isUuid(variantId)) {
      return apiError(400, "FCO-1001", "شناسهٔ تنوع محصول معتبر نیست.", requestId);
    }
    const session = await adminSessionFromRequest(request);
    if (!session) {
      return apiError(401, "FCO-1005", "نشست معتبر نیست.", requestId);
    }

    const parsedBody = await readJsonBody(request, 8192);
    if (parsedBody.kind === "too_large") {
      return apiError(413, "FCO-1001", "اندازهٔ درخواست بیش از حد مجاز است.", requestId);
    }
    if (parsedBody.kind === "invalid") {
      return apiError(400, "FCO-1001", "بدنهٔ JSON معتبر نیست.", requestId);
    }
    const body = parsedBody.value;
    if (!isRecord(body)) {
      return apiError(400, "FCO-1001", "اطلاعات قیمت معتبر نیست.", requestId);
    }

    const amountRial = body.amount_rial;
    const compareAtRial = body.compare_at_rial;
    const channel = body.channel === undefined ? "web" : body.channel;
    const effectiveFrom = parseEffectiveFrom(body.effective_from);
    const reason = body.reason === undefined || body.reason === null ? null : body.reason;
    if (
      typeof amountRial !== "number" ||
      !Number.isSafeInteger(amountRial) ||
      amountRial < 0 ||
      (compareAtRial !== null &&
        compareAtRial !== undefined &&
        (typeof compareAtRial !== "number" ||
          !Number.isSafeInteger(compareAtRial) ||
          compareAtRial < 0)) ||
      !effectiveFrom ||
      typeof channel !== "string" ||
      channel.trim().length === 0 ||
      channel.trim().length > 40 ||
      (reason !== null && (typeof reason !== "string" || reason.trim().length > 500))
    ) {
      return apiError(400, "FCO-1001", "اطلاعات قیمت معتبر نیست.", requestId);
    }

    const priceId = await setAdminProductPrice({
      actorId: session.uid,
      requestId,
      variantId,
      amountRial,
      compareAtRial:
        typeof compareAtRial === "number" ? compareAtRial : null,
      effectiveFrom,
      channel: channel.trim(),
      reason: typeof reason === "string" ? reason.trim() || null : null,
    });
    return Response.json(
      { data: { id: priceId }, meta: { request_id: requestId } },
      {
        status: 201,
        headers: { "Cache-Control": "no-store", "X-Request-Id": requestId },
      },
    );
  } catch (error) {
    logAdminApiFailure("admin_price_update_failed", requestId, error);
    return adminFailureResponse(error, requestId);
  }
}
