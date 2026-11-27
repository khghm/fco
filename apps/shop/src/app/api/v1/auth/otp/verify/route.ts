import {
  verifyCustomerOtp,
  type GuestCartLine,
} from "@fco/infrastructure/customer-auth";
import { completeGuestCartMerge } from "@fco/infrastructure/cart";
import {
  apiErrorResponse,
  apiFailureResponse,
  isRecord,
  logApiFailure,
  readJsonBody,
  requestIdFrom,
  sameOriginRequest,
} from "../../../http";
import { resolveClientIp } from "@/lib/rate-limit";
import {
  clearGuestCartCookie,
  cookieValue,
  customerSessionCookie,
  GUEST_CART_COOKIE,
} from "@/lib/customer-cookies";
import {
  claimGuestCartForMerge,
  deleteGuestCartAfterMerge,
  isGuestCartId,
  releaseGuestCartMergeLock,
} from "@/lib/guest-cart";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  const requestId = requestIdFrom(request);
  if (!sameOriginRequest(request)) {
    return apiErrorResponse(403, "FCO-1003", "درخواست از مبدأ معتبر نیست.", requestId);
  }

  const parsedBody = await readJsonBody(request, 4096);
  if (parsedBody.kind === "too_large") {
    return apiErrorResponse(413, "FCO-1001", "اندازهٔ درخواست بیش از حد مجاز است.", requestId);
  }
  if (parsedBody.kind === "invalid" || !isRecord(parsedBody.value)) {
    return apiErrorResponse(400, "FCO-1001", "اطلاعات ورود معتبر نیست.", requestId);
  }
  const mobile =
    typeof parsedBody.value.mobile === "string"
      ? parsedBody.value.mobile.trim()
      : "";
  const code =
    typeof parsedBody.value.code === "string" ? parsedBody.value.code.trim() : "";
  if (!/^09[0-9]{9}$/.test(mobile) || !/^[0-9]{6}$/.test(code)) {
    return apiErrorResponse(400, "FCO-1001", "شمارهٔ موبایل یا کد یک‌بارمصرف معتبر نیست.", requestId);
  }

  const suppliedCartId = cookieValue(request, GUEST_CART_COOKIE);
  if (suppliedCartId && !isGuestCartId(suppliedCartId)) {
    return apiErrorResponse(400, "FCO-1001", "شناسهٔ سبد مهمان معتبر نیست.", requestId);
  }

  let lock: { token: string; items: GuestCartLine[] } | null = null;
  try {
    if (suppliedCartId) {
      lock = await claimGuestCartForMerge(suppliedCartId);
      if (!lock) {
        return apiErrorResponse(
          409,
          "FCO-1091",
          "سبد خرید هم‌زمان در حال ادغام است؛ دوباره تلاش کنید.",
          requestId,
        );
      }
    }

    const ip = resolveClientIp(request.headers);
    const result = await verifyCustomerOtp(
      mobile,
      code,
      ip === "unknown" ? null : ip,
      request.headers.get("user-agent")?.slice(0, 512) ?? null,
      suppliedCartId,
      lock?.items ?? [],
    );

    if (result.kind === "locked") {
      if (suppliedCartId && lock) {
        await releaseGuestCartMergeLock(suppliedCartId, lock.token);
      }
      return apiErrorResponse(429, "FCO-1007", "تعداد تلاش‌های کد بیش از حد مجاز است.", requestId);
    }
    if (result.kind === "invalid") {
      if (suppliedCartId && lock) {
        await releaseGuestCartMergeLock(suppliedCartId, lock.token);
      }
      return apiErrorResponse(401, "FCO-1005", "شمارهٔ موبایل یا کد معتبر نیست.", requestId);
    }

    let cartCleanupPending = false;
    if (suppliedCartId && lock) {
      try {
        const deleted = await deleteGuestCartAfterMerge(suppliedCartId, lock.token);
        if (!deleted) {
          throw new Error("Guest cart merge lock expired before cleanup.");
        }
        await completeGuestCartMerge(suppliedCartId, result.session.userId);
      } catch (error) {
        cartCleanupPending = true;
        logApiFailure("customer_cart_merge_cleanup_pending", requestId, error);
      }
    }

    const headers = new Headers({
      "Cache-Control": "no-store",
      "Set-Cookie": customerSessionCookie(result.session),
      "X-Request-Id": requestId,
    });
    if (suppliedCartId && !cartCleanupPending) {
      headers.append("Set-Cookie", clearGuestCartCookie());
    }
    return Response.json(
      {
        data: {
          user_id: result.session.userId,
          cart_merge: suppliedCartId
            ? cartCleanupPending
              ? "cleanup_pending"
              : "complete"
            : "not_requested",
        },
        meta: { request_id: requestId },
      },
      { headers },
    );
  } catch (error) {
    if (suppliedCartId && lock) {
      try {
        await releaseGuestCartMergeLock(suppliedCartId, lock.token);
      } catch (releaseError) {
        logApiFailure("customer_cart_merge_lock_release_failed", requestId, releaseError);
      }
    }
    logApiFailure("customer_otp_verification_failed", requestId, error);
    return apiFailureResponse(error, requestId);
  }
}
