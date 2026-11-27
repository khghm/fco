import {
  createAdminVariant,
  listAdminVariants,
} from "@fco/infrastructure/admin-catalog";
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

export async function GET(
  request: Request,
  context: { params: Promise<{ id: string }> },
): Promise<Response> {
  const requestId = requestIdFrom(request);
  try {
    const { id: productId } = await context.params;
    if (!isUuid(productId)) {
      return apiError(400, "FCO-1001", "شناسهٔ محصول معتبر نیست.", requestId);
    }
    const session = await adminSessionFromRequest(request);
    if (!session) {
      return apiError(401, "FCO-1005", "نشست معتبر نیست.", requestId);
    }
    const variants = await listAdminVariants(session.uid, productId);
    if (variants === null) {
      return apiError(404, "FCO-1004", "محصول پیدا نشد.", requestId);
    }
    return Response.json(
      { data: variants, meta: { request_id: requestId } },
      { headers: { "Cache-Control": "no-store", "X-Request-Id": requestId } },
    );
  } catch (error) {
    logAdminApiFailure("admin_variant_list_failed", requestId, error);
    return adminFailureResponse(error, requestId);
  }
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
    const { id: productId } = await context.params;
    if (!isUuid(productId)) {
      return apiError(400, "FCO-1001", "شناسهٔ محصول معتبر نیست.", requestId);
    }
    const session = await adminSessionFromRequest(request);
    if (!session) {
      return apiError(401, "FCO-1005", "نشست معتبر نیست.", requestId);
    }

    const parsedBody = await readJsonBody(request, 4096);
    if (parsedBody.kind === "too_large") {
      return apiError(413, "FCO-1001", "اندازهٔ درخواست بیش از حد مجاز است.", requestId);
    }
    if (parsedBody.kind === "invalid" || !isRecord(parsedBody.value)) {
      return apiError(400, "FCO-1001", "اطلاعات تنوع معتبر نیست.", requestId);
    }
    const sku = typeof parsedBody.value.sku === "string"
      ? parsedBody.value.sku.trim().toUpperCase()
      : "";
    const barcode = parsedBody.value.barcode;
    const weightG = parsedBody.value.weight_g;
    if (
      !/^[A-Z0-9._-]{1,32}$/.test(sku) ||
      (barcode !== undefined &&
        barcode !== null &&
        (typeof barcode !== "string" || barcode.trim().length === 0 || barcode.trim().length > 32)) ||
      (weightG !== undefined &&
        weightG !== null &&
        (typeof weightG !== "number" ||
          !Number.isSafeInteger(weightG) ||
          weightG < 1 ||
          weightG > 2_147_483_647))
    ) {
      return apiError(400, "FCO-1001", "SKU، بارکد یا وزن تنوع معتبر نیست.", requestId);
    }

    const variantId = await createAdminVariant({
      actorId: session.uid,
      requestId,
      productId,
      sku,
      barcode: typeof barcode === "string" ? barcode.trim() : null,
      weightG: typeof weightG === "number" ? weightG : null,
    });
    return Response.json(
      { data: { id: variantId }, meta: { request_id: requestId } },
      {
        status: 201,
        headers: { "Cache-Control": "no-store", "X-Request-Id": requestId },
      },
    );
  } catch (error) {
    logAdminApiFailure("admin_variant_create_failed", requestId, error);
    return adminFailureResponse(error, requestId);
  }
}
