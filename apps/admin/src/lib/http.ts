import { randomUUID } from "node:crypto";

export function requestIdFrom(request: Request): string {
  const supplied = request.headers.get("x-request-id")?.trim();
  return supplied && /^[A-Za-z0-9._:-]{1,128}$/.test(supplied)
    ? supplied
    : randomUUID();
}

export function apiError(
  status: number,
  code: string,
  message: string,
  requestId: string,
): Response {
  return Response.json(
    { error: { code, message, request_id: requestId } },
    {
      status,
      headers: { "Cache-Control": "no-store", "X-Request-Id": requestId },
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

export function logAdminApiFailure(
  event: string,
  requestId: string,
  error: unknown,
): void {
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
    })}\n`,
  );
}

function databaseErrorCode(error: unknown): string | undefined {
  if (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    typeof error.code === "string"
  ) {
    return error.code;
  }
  return undefined;
}

function domainErrorCode(error: unknown): string | undefined {
  if (
    typeof error === "object" &&
    error !== null &&
    "message" in error &&
    typeof error.message === "string"
  ) {
    return error.message.match(/\bFCO-\d{4}\b/)?.[0];
  }
  return undefined;
}

export function adminFailureResponse(error: unknown, requestId: string): Response {
  const state = databaseErrorCode(error);
  const code = domainErrorCode(error);
  if (state === "42501") {
    return apiError(403, code ?? "FCO-1003", "برای این عملیات مجوز ندارید.", requestId);
  }
  if (state === "28000") {
    return apiError(401, code ?? "FCO-1005", "نشست معتبر نیست.", requestId);
  }
  if (state === "22023" || state === "23505" || state === "23P01" || state === "40001") {
    const status = state === "40001" ? 409 : state === "23505" || state === "23P01" ? 409 : 400;
    return apiError(status, code ?? "FCO-1001", "اطلاعات ارسالی معتبر نیست یا با دادهٔ موجود تعارض دارد.", requestId);
  }
  if (
    state?.startsWith("08") ||
    ["ECONNREFUSED", "ECONNRESET", "ETIMEDOUT", "ENOTFOUND", "EHOSTUNREACH", "57P01", "57P03"].includes(
      state ?? "",
    )
  ) {
    return apiError(503, "FCO-1010", "ارتباط با سرویس داده برقرار نشد.", requestId);
  }
  return apiError(500, "FCO-3001", "خطای پیش‌بینی‌نشده رخ داد.", requestId);
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
