import {
  completeGuestCartMerge,
  getPublicCartItems,
  listPendingGuestCartMerges,
  readCustomerCart,
} from "@fco/infrastructure/cart";
import {
  customerSessionTokenFromRequest,
  resolveCustomerSession,
} from "@fco/infrastructure/customer-auth";
import {
  apiErrorResponse,
  apiFailureResponse,
  logApiFailure,
  requestIdFrom,
} from "../http";
import {
  cookieValue,
  guestCartCookie,
  guestCartIdFromRequest,
  GUEST_CART_COOKIE,
} from "@/lib/customer-cookies";
import {
  cleanupPendingGuestCart,
  newGuestCartId,
  readGuestCart,
} from "@/lib/guest-cart";
import { recoverGuestCart } from "@/lib/checkout";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function GET(request: Request): Promise<Response> {
  const requestId = requestIdFrom(request);
  const customerToken = customerSessionTokenFromRequest(request);
  try {
    if (customerToken) {
      const session = await resolveCustomerSession(customerToken);
      if (!session) {
        return apiErrorResponse(401, "FCO-1005", "نشست مشتری معتبر نیست.", requestId);
      }
      let cleanupPending = false;
      const pendingMerges = await listPendingGuestCartMerges(session.uid);
      for (const guestCartId of pendingMerges) {
        const cleaned = await cleanupPendingGuestCart(guestCartId);
        if (cleaned) {
          await completeGuestCartMerge(guestCartId, session.uid);
        } else {
          cleanupPending = true;
        }
      }
      const items = await readCustomerCart(session.uid);
      return Response.json(
        {
          data: { items, guest_cart_cleanup_pending: cleanupPending },
          meta: { request_id: requestId },
        },
        {
          headers: {
            "Cache-Control": "no-store",
            "X-Request-Id": requestId,
          },
        },
      );
    }

    const rawCartId = cookieValue(request, GUEST_CART_COOKIE);
    if (rawCartId && !guestCartIdFromRequest(request)) {
      return apiErrorResponse(400, "FCO-1001", "شناسهٔ سبد مهمان معتبر نیست.", requestId);
    }
    let cartId = rawCartId ?? newGuestCartId();
    if (rawCartId) {
      const recovery = await recoverGuestCart(cartId);
      if (recovery.cleanupPending) {
        return apiErrorResponse(
          409,
          "FCO-1091",
          "تکمیل سفارش پیشین هنوز در حال بازیابی است؛ دوباره تلاش کنید.",
          requestId,
        );
      }
      cartId = recovery.cartId;
    }
    const storedItems = await readGuestCart(cartId);
    const items = await getPublicCartItems(storedItems);
    const headers = new Headers({
      "Cache-Control": "no-store",
      "X-Request-Id": requestId,
    });
    headers.set("Set-Cookie", guestCartCookie(cartId));
    return Response.json(
      { data: { items }, meta: { request_id: requestId } },
      { headers },
    );
  } catch (error) {
    logApiFailure("cart_read_failed", requestId, error);
    return apiFailureResponse(error, requestId);
  }
}
