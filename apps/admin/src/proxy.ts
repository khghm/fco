import { NextResponse, type NextRequest } from "next/server";
import {
  resolveStaffSession,
  STAFF_SESSION_COOKIE,
} from "@fco/infrastructure/admin-session";
import {
  adminFailureResponse,
  apiError,
  logAdminApiFailure,
  requestIdFrom,
} from "./lib/http";

function isAdminApi(pathname: string): boolean {
  return pathname === "/api/v1/admin" || pathname.startsWith("/api/v1/admin/");
}

function loginRedirect(request: NextRequest, requestId: string): Response {
  const response = NextResponse.redirect(new URL("/login", request.url));
  response.headers.set("X-Request-Id", requestId);
  return response;
}

export async function proxy(request: NextRequest): Promise<Response> {
  const pathname = request.nextUrl.pathname;
  if (
    pathname === "/api/v1/admin/auth/login" ||
    pathname === "/api/v1/admin/auth/logout" ||
    pathname === "/login"
  ) {
    return NextResponse.next();
  }

  const requestId = requestIdFrom(request);
  const token = request.cookies.get(STAFF_SESSION_COOKIE)?.value;
  if (!token) {
    if (isAdminApi(pathname)) {
      return apiError(401, "FCO-1005", "نشست معتبر نیست.", requestId);
    }
    return loginRedirect(request, requestId);
  }

  try {
    const session = await resolveStaffSession(token);
    if (!session) {
      if (isAdminApi(pathname)) {
        return apiError(401, "FCO-1005", "نشست معتبر نیست.", requestId);
      }
      return loginRedirect(request, requestId);
    }
    return NextResponse.next();
  } catch (error) {
    logAdminApiFailure("admin_session_check_failed", requestId, error);
    return adminFailureResponse(error, requestId);
  }
}

export const config = {
  matcher: ["/api/v1/admin/:path*", "/admin/:path*"],
};
