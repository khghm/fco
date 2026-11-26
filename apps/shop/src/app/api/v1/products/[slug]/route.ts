import { getPublicProduct } from "@fco/application/catalog";
import { createPostgresPublicCatalogRepository } from "@fco/infrastructure/catalog";
import {
  apiErrorResponse,
  isDatabaseUnavailable,
  logApiFailure,
  requestIdFrom,
} from "../../http";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

type RouteContext = {
  params: Promise<{ slug: string }>;
};

export async function GET(request: Request, context: RouteContext): Promise<Response> {
  const requestId = requestIdFrom(request);

  try {
    const { slug } = await context.params;
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug)) {
      return apiErrorResponse(400, "FCO-1001", "شناسهٔ محصول معتبر نیست.", requestId);
    }

    const product = await getPublicProduct(
      createPostgresPublicCatalogRepository(),
      slug,
    );
    if (product === null) {
      return apiErrorResponse(404, "FCO-1004", "محصول یافت نشد.", requestId);
    }

    return Response.json(
      { data: product, meta: { request_id: requestId } },
      { headers: { "X-Request-Id": requestId } },
    );
  } catch (error) {
    logApiFailure("public_catalog_product_failed", requestId, error);
    const unavailable = isDatabaseUnavailable(error);
    return apiErrorResponse(
      unavailable ? 503 : 500,
      unavailable ? "FCO-1010" : "FCO-3001",
      unavailable
        ? "در حال حاضر ارتباط با فروشگاه برقرار نیست."
        : "خطای پیش‌بینی‌نشده رخ داد.",
      requestId,
    );
  }
}
