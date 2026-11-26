import {
  InvalidCatalogQueryError,
  parsePublicCatalogQuery,
  searchPublicCatalog,
} from "@fco/application/catalog";
import { createPostgresPublicCatalogRepository } from "@fco/infrastructure/catalog";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function hasErrorCode(error: unknown): error is Error & { code: string } {
  return error instanceof Error && "code" in error && typeof error.code === "string";
}

function isDatabaseUnavailable(error: unknown): boolean {
  if (!hasErrorCode(error)) {
    return false;
  }
  return (
    error.code.startsWith("08") ||
    ["ECONNREFUSED", "ECONNRESET", "ETIMEDOUT", "ENOTFOUND", "EHOSTUNREACH", "57P01"].includes(
      error.code,
    )
  );
}

function requestIdFrom(request: Request): string {
  const supplied = request.headers.get("x-request-id");
  return supplied && /^[A-Za-z0-9._-]{1,128}$/.test(supplied)
    ? supplied
    : crypto.randomUUID();
}

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
      return Response.json(
        {
          error: {
            code: "FCO-1001",
            message: error.message,
            request_id: requestId,
          },
        },
        { status: 400, headers: responseHeaders },
      );
    }

    process.stderr.write(
      `${JSON.stringify({
        level: "error",
        event: "public_catalog_search_failed",
        request_id: requestId,
        error_type: error instanceof Error ? error.name : "UnknownError",
      })}\n`,
    );
    const unavailable = isDatabaseUnavailable(error);
    return Response.json(
      {
        error: {
          code: unavailable ? "FCO-1010" : "FCO-3001",
          message: unavailable
            ? "در حال حاضر ارتباط با فروشگاه برقرار نیست."
            : "خطای پیش‌بینی‌نشده رخ داد.",
          request_id: requestId,
        },
      },
      { status: unavailable ? 503 : 500, headers: responseHeaders },
    );
  }
}
