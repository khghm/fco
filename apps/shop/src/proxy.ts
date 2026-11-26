import { RateLimiterRes } from "rate-limiter-flexible";
import { NextResponse, type NextRequest } from "next/server";
import {
  consumeCatalogRequest,
  getCatalogRateLimitPoints,
  resolveClientIp,
} from "./lib/rate-limit";
import { requestIdFrom } from "./app/api/v1/http";

function isCatalogApi(pathname: string): boolean {
  return pathname === "/api/v1/products" || pathname.startsWith("/api/v1/products/");
}

function rateLimitHeaders(
  points: number,
  result: Pick<RateLimiterRes, "remainingPoints" | "msBeforeNext">,
  requestId: string,
  includeRetryAfter = false,
): Headers {
  const headers = new Headers({
    "X-Request-Id": requestId,
    "X-RateLimit-Limit": String(points),
    "X-RateLimit-Remaining": String(Math.max(0, result.remainingPoints)),
    "X-RateLimit-Reset": String(
      Math.ceil((Date.now() + result.msBeforeNext) / 1000),
    ),
  });
  if (includeRetryAfter) {
    headers.set("Retry-After", String(Math.max(1, Math.ceil(result.msBeforeNext / 1000))));
  }
  return headers;
}

function publicErrorResponse(
  request: NextRequest,
  status: number,
  requestId: string,
  headers: Headers,
): Response {
  if (isCatalogApi(request.nextUrl.pathname)) {
    const rateLimited = status === 429;
    return Response.json(
      {
        error: {
          code: rateLimited ? "FCO-1007" : "FCO-1010",
          message: rateLimited
            ? "تعداد درخواست‌ها بیش از حد مجاز است. کمی بعد دوباره تلاش کنید."
            : "سرویس فعلاً در دسترس نیست.",
          request_id: requestId,
        },
      },
      { status, headers },
    );
  }

  return new Response(
    status === 429
      ? "تعداد درخواست‌ها بیش از حد مجاز است. کمی بعد دوباره تلاش کنید."
      : "سرویس فعلاً در دسترس نیست.",
    { status, headers },
  );
}

export async function proxy(request: NextRequest): Promise<Response> {
  if (!["GET", "HEAD"].includes(request.method)) {
    return NextResponse.next();
  }

  const requestId = requestIdFrom(request);
  let points = 100;

  try {
    points = getCatalogRateLimitPoints();
    const result = await consumeCatalogRequest(
      resolveClientIp(request.headers),
      points,
    );
    const headers = rateLimitHeaders(points, result, requestId);
    const requestHeaders = new Headers(request.headers);
    requestHeaders.set("x-request-id", requestId);
    const response = NextResponse.next({ request: { headers: requestHeaders } });
    headers.forEach((value, name) => response.headers.set(name, value));
    return response;
  } catch (error) {
    if (error instanceof RateLimiterRes) {
      return publicErrorResponse(
        request,
        429,
        requestId,
        rateLimitHeaders(points, error, requestId, true),
      );
    }

    process.stderr.write(
      `${JSON.stringify({
        level: "error",
        event: "public_rate_limit_failed",
        request_id: requestId,
        error_type: error instanceof Error ? error.name : "UnknownError",
      })}\n`,
    );
    return publicErrorResponse(
      request,
      503,
      requestId,
      new Headers({ "X-Request-Id": requestId }),
    );
  }
}

export const config = {
  matcher: ["/", "/products/:path*", "/api/v1/products/:path*"],
};
