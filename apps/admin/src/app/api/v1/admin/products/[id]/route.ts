import { updateAdminProduct } from "@fco/infrastructure/admin-catalog";
import {
  adminFailureResponse,
  apiError,
  logAdminApiFailure,
  readJsonBody,
  requestIdFrom,
  sameOriginRequest,
} from "../../../../../../lib/http";
import { adminSessionFromRequest } from "../../../../../../lib/admin-session";
import { isUuid, parseAdminProductInput } from "../../../../../../lib/product-input";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export async function PATCH(
  request: Request,
  context: { params: Promise<{ id: string }> },
): Promise<Response> {
  const requestId = requestIdFrom(request);
  if (!sameOriginRequest(request)) {
    return apiError(403, "FCO-1003", "درخواست از مبدأ معتبر نیست.", requestId);
  }

  try {
    const { id } = await context.params;
    if (!isUuid(id)) {
      return apiError(400, "FCO-1001", "شناسهٔ محصول معتبر نیست.", requestId);
    }
    const session = await adminSessionFromRequest(request);
    if (!session) {
      return apiError(401, "FCO-1005", "نشست معتبر نیست.", requestId);
    }

    const ifMatch = request.headers.get("if-match");
    if (!ifMatch) {
      return apiError(
        428,
        "FCO-1001",
        "هدر If-Match برای نسخهٔ مورد انتظار الزامی است.",
        requestId,
      );
    }
    const expectedVersionText = ifMatch.match(/^"([1-9]\d*)"$/)?.[1];
    if (!expectedVersionText) {
      return apiError(400, "FCO-1001", "هدر If-Match معتبر نیست.", requestId);
    }
    const expectedVersion = Number(expectedVersionText);

    const parsedBody = await readJsonBody(request, 65_536);
    if (parsedBody.kind === "too_large") {
      return apiError(413, "FCO-1001", "اندازهٔ درخواست بیش از حد مجاز است.", requestId);
    }
    if (parsedBody.kind === "invalid") {
      return apiError(400, "FCO-1001", "بدنهٔ JSON معتبر نیست.", requestId);
    }
    const body = parsedBody.value;
    if (!isRecord(body)) {
      return apiError(400, "FCO-1001", "اطلاعات محصول معتبر نیست.", requestId);
    }
    const product = parseAdminProductInput(body);
    if (
      !product ||
      typeof expectedVersion !== "number" ||
      !Number.isSafeInteger(expectedVersion) ||
      expectedVersion < 1 ||
      !["title", "description", "brand_id", "category_id", "attributes"].every((key) =>
        Object.hasOwn(body, key),
      )
    ) {
      return apiError(400, "FCO-1001", "اطلاعات نسخهٔ محصول معتبر نیست.", requestId);
    }

    const version = await updateAdminProduct({
      actorId: session.uid,
      requestId,
      productId: id,
      expectedVersion,
      ...product,
    });
    return Response.json(
      { data: { id, version }, meta: { request_id: requestId } },
      { headers: { "Cache-Control": "no-store", "X-Request-Id": requestId } },
    );
  } catch (error) {
    logAdminApiFailure("admin_product_update_failed", requestId, error);
    return adminFailureResponse(error, requestId);
  }
}
