export function requestIdFrom(request: Request): string {
  const supplied = request.headers.get("x-request-id");
  return supplied && /^[A-Za-z0-9._-]{1,128}$/.test(supplied)
    ? supplied
    : crypto.randomUUID();
}

export function apiErrorResponse(
  status: number,
  code: string,
  message: string,
  requestId: string,
): Response {
  return Response.json(
    { error: { code, message, request_id: requestId } },
    {
      status,
      headers: {
        "Cache-Control": "no-store",
        "X-Request-Id": requestId,
      },
    },
  );
}

export type JsonBodyResult =
  | { kind: "ok"; value: unknown }
  | { kind: "invalid" }
  | { kind: "too_large" };

export async function readJsonBody(
  request: Request,
  maxBytes: number,
): Promise<JsonBodyResult> {
  const declaredLength = Number(request.headers.get("content-length") ?? "0");
  if (Number.isFinite(declaredLength) && declaredLength > maxBytes) {
    return { kind: "too_large" };
  }
  if (!request.body) {
    return { kind: "invalid" };
  }

  const reader = request.body.getReader();
  const decoder = new TextDecoder();
  let text = "";
  let size = 0;
  while (true) {
    const chunk = await reader.read();
    if (chunk.done) {
      break;
    }
    size += chunk.value.byteLength;
    if (size > maxBytes) {
      await reader.cancel();
      return { kind: "too_large" };
    }
    text += decoder.decode(chunk.value, { stream: true });
  }
  text += decoder.decode();

  try {
    return { kind: "ok", value: JSON.parse(text) as unknown };
  } catch (error) {
    if (error instanceof SyntaxError) {
      return { kind: "invalid" };
    }
    throw error;
  }
}

export function isDatabaseUnavailable(error: unknown): boolean {
  if (!(error instanceof Error) || !("code" in error) || typeof error.code !== "string") {
    return false;
  }
  return (
    error.code.startsWith("08") ||
    ["ECONNREFUSED", "ECONNRESET", "ETIMEDOUT", "ENOTFOUND", "EHOSTUNREACH", "57P01"].includes(
      error.code,
    )
  );
}

export function apiFailureResponse(error: unknown, requestId: string): Response {
  const state =
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    typeof error.code === "string"
      ? error.code
      : undefined;
  const domainCode =
    error instanceof Error ? error.message.match(/\bFCO-\d{4}\b/)?.[0] : undefined;

  if (state === "53300") {
    return apiErrorResponse(429, domainCode ?? "FCO-1007", "درخواست‌های ورود بیش از حد مجاز است.", requestId);
  }
  if (state === "22023") {
    return apiErrorResponse(400, domainCode ?? "FCO-1001", "اطلاعات ارسالی معتبر نیست.", requestId);
  }
  if (state === "28000") {
    return apiErrorResponse(401, domainCode ?? "FCO-1005", "اطلاعات احراز هویت معتبر نیست.", requestId);
  }
  if (state === "42501") {
    return apiErrorResponse(403, domainCode ?? "FCO-1003", "برای این عملیات مجوز ندارید.", requestId);
  }
  if (state === "23505" || state === "23514" || state === "40001") {
    return apiErrorResponse(409, domainCode ?? "FCO-1001", "درخواست با وضعیت فعلی سبد تعارض دارد.", requestId);
  }
  if (isDatabaseUnavailable(error) || state === "ECONNREFUSED") {
    return apiErrorResponse(503, "FCO-1010", "ارتباط با سرویس داده برقرار نشد.", requestId);
  }
  return apiErrorResponse(500, "FCO-3001", "خطای پیش‌بینی‌نشده رخ داد.", requestId);
}

export function logApiFailure(event: string, requestId: string, error: unknown): void {
  const errorCode =
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    typeof error.code === "string"
      ? error.code
      : undefined;
  process.stderr.write(
    `${JSON.stringify({
      level: "error",
      event,
      request_id: requestId,
      error_type: error instanceof Error ? error.name : "UnknownError",
      ...(errorCode ? { error_code: errorCode } : {}),
      ...(process.env.NODE_ENV !== "production" && error instanceof Error
        ? { error_message: error.message.slice(0, 256) }
        : {}),
    })}\n`,
  );
}

export function sameOriginRequest(request: Request): boolean {
  const origin = request.headers.get("origin");
  if (!origin) {
    return false;
  }
  try {
    const source = new URL(origin);
    const requestUrl = new URL(request.url);
    const forwardedProtocol =
      process.env.TRUST_PROXY === "true"
        ? request.headers.get("x-forwarded-proto")?.split(",", 1)[0]?.trim()
        : undefined;
    const protocol =
      forwardedProtocol === "https" || forwardedProtocol === "http"
        ? `${forwardedProtocol}:`
        : requestUrl.protocol;
    const host = request.headers.get("host") ?? requestUrl.host;
    return source.origin === new URL(`${protocol}//${host}`).origin;
  } catch {
    return false;
  }
}

export function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
