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
    { status, headers: { "X-Request-Id": requestId } },
  );
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

export function logApiFailure(event: string, requestId: string, error: unknown): void {
  process.stderr.write(
    `${JSON.stringify({
      level: "error",
      event,
      request_id: requestId,
      error_type: error instanceof Error ? error.name : "UnknownError",
    })}\n`,
  );
}
