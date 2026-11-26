import {
  InvalidCatalogQueryError,
  parsePublicCatalogQuery,
  searchPublicCatalog,
} from "@fco/application/catalog";
import { createPostgresPublicCatalogRepository } from "@fco/infrastructure/catalog";
import {
  apiErrorResponse,
  isDatabaseUnavailable,
  logApiFailure,
  requestIdFrom,
} from "../http";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  const requestId = requestIdFrom(request);
  const responseHeaders = { "X-Request-Id": requestId };

  try {
    const query = parsePublicCatalogQuery(new URL(request.url).searchParams);
    const result = await searchPublicCatalog(
      createPostgresPublicCatalogRepository(),
      query,
    );

    return Response.json(
      {
        data: result.items,
        meta: {
          page: result.page,
          page_size: result.page_size,
          total: result.total,
          request_id: requestId,
        },
      },
      { headers: responseHeaders },
    );
  } catch (error) {
    if (error instanceof InvalidCatalogQueryError) {
      return apiErrorResponse(400, "FCO-1001", error.message, requestId);
    }

    logApiFailure("public_catalog_search_failed", requestId, error);
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
