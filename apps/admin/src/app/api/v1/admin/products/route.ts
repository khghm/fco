import { createAdminProduct, listAdminProducts } from "@fco/infrastructure/admin-catalog";
import {
  adminFailureResponse,
  apiError,
  logAdminApiFailure,
  readJsonBody,
  requestIdFrom,
  sameOriginRequest,
} from "../../../../../lib/http";
import { adminSessionFromRequest } from "../../../../../lib/admin-session";
import { parseAdminProductInput } from "../../../../../lib/product-input";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export async function GET(request: Request): Promise<Response> {
  const requestId = requestIdFrom(request);
  try {
    const session = await adminSessionFromRequest(request);
    if (!session) {
      return apiError(401, "FCO-1005", "نشست معتبر نیست.", requestId);
    }

    const url = new URL(request.url);
    if (
      [...url.searchParams.keys()].some((key) => !["limit", "offset"].includes(key)) ||
      url.searchParams.getAll("limit").length > 1 ||
      url.searchParams.getAll("offset").length > 1
    ) {
      return apiError(400, "FCO-1001", "پارامترهای صفحه‌بندی معتبر نیستند.", requestId);
    }
    const limitText = url.searchParams.get("limit") ?? "50";
    const offsetText = url.searchParams.get("offset") ?? "0";
    if (!/^\d+$/.test(limitText) || !/^\d+$/.test(offsetText)) {
      return apiError(400, "FCO-1001", "پارامترهای صفحه‌بندی معتبر نیستند.", requestId);
    }
    const limit = Number(limitText);
    const offset = Number(offsetText);
    if (
      !Number.isSafeInteger(limit) ||
      limit < 1 ||
      limit > 100 ||
      !Number.isSafeInteger(offset) ||
      offset > 1_000_000
    ) {
      return apiError(400, "FCO-1001", "پارامترهای صفحه‌بندی خارج از محدوده‌اند.", requestId);
    }

    const result = await listAdminProducts(session.uid, limit, offset);
    return Response.json(
      { data: result.items, meta: { total: result.total, limit, offset, request_id: requestId } },
      { headers: { "Cache-Control": "no-store", "X-Request-Id": requestId } },
    );
  } catch (error) {
    logAdminApiFailure("admin_product_list_failed", requestId, error);
    return adminFailureResponse(error, requestId);
  }
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
    const slug = typeof body.slug === "string" ? body.slug.trim().toLowerCase() : "";
    const product = parseAdminProductInput(body);
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug) || slug.length > 120 || !product) {
      return apiError(400, "FCO-1001", "اطلاعات محصول معتبر نیست.", requestId);
    }

    const productId = await createAdminProduct({
      actorId: session.uid,
      requestId,
      slug,
      ...product,
    });
    return Response.json(
      { data: { id: productId }, meta: { request_id: requestId } },
      {
        status: 201,
        headers: { "Cache-Control": "no-store", "X-Request-Id": requestId },
      },
    );
  } catch (error) {
    logAdminApiFailure("admin_product_create_failed", requestId, error);
    return adminFailureResponse(error, requestId);
  }
}
