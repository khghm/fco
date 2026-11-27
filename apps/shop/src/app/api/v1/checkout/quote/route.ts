import { getPublicCartItems, readCustomerCart } from "@fco/infrastructure/cart";
import {
  CheckoutUnavailableError,
  quoteCheckout,
} from "@fco/infrastructure/checkout";
import {
  customerSessionTokenFromRequest,
  resolveCustomerSession,
} from "@fco/infrastructure/customer-auth";
import {
  apiErrorResponse,
  apiFailureResponse,
  isRecord,
  logApiFailure,
  readJsonBody,
  requestIdFrom,
  sameOriginRequest,
} from "../../http";
import {
  cookieValue,
  guestCartIdFromRequest,
  GUEST_CART_COOKIE,
} from "@/lib/customer-cookies";
import { recoverGuestCart } from "@/lib/checkout";
import { readGuestCart } from "@/lib/guest-cart";

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
  if (parsedBody.kind !== "ok" || !isRecord(parsedBody.value)) {
    return apiErrorResponse(400, "FCO-1001", "درخواست برآورد معتبر نیست.", requestId);
  }

  const customerToken = customerSessionTokenFromRequest(request);
  const suppliedCartId = cookieValue(request, GUEST_CART_COOKIE);
  if (suppliedCartId && !guestCartIdFromRequest(request)) {
    return apiErrorResponse(400, "FCO-1001", "شناسهٔ سبد مهمان معتبر نیست.", requestId);
  }

  try {
    let items;
    if (customerToken) {
      const session = await resolveCustomerSession(customerToken);
      if (!session) {
        return apiErrorResponse(401, "FCO-1005", "نشست مشتری معتبر نیست.", requestId);
      }
      items = await readCustomerCart(session.uid);
    } else {
      if (!suppliedCartId) {
        return apiErrorResponse(400, "FCO-1001", "سبد خرید مهمان پیدا نشد.", requestId);
      }
      const recovery = await recoverGuestCart(suppliedCartId);
      if (recovery.cleanupPending) {
        return apiErrorResponse(409, "FCO-1091", "سبد سفارش قبلی در حال بازیابی است.", requestId);
      }
      items = await getPublicCartItems(await readGuestCart(recovery.cartId));
    }

    if (items.length === 0) {
      return apiErrorResponse(400, "FCO-1001", "سبد خرید خالی است.", requestId);
    }
    if (items.some((item) => !item.sellable || item.price_rial === null)) {
      return apiErrorResponse(409, "FCO-2002", "یکی از اقلام برای فروش در دسترس نیست.", requestId);
    }
    if (items.some((item) => item.available_qty < item.quantity)) {
      return apiErrorResponse(409, "FCO-2001", "موجودی کافی برای سبد وجود ندارد.", requestId);
    }

    const quote = await quoteCheckout(items);
    return Response.json(
      { data: quote, meta: { request_id: requestId } },
      {
        headers: {
          "Cache-Control": "no-store",
          "X-Request-Id": requestId,
        },
      },
    );
  } catch (error) {
    if (error instanceof CheckoutUnavailableError) {
      return apiErrorResponse(409, error.code, "موجودی کافی برای سبد وجود ندارد.", requestId);
    }
    logApiFailure("checkout_quote_failed", requestId, error);
    return apiFailureResponse(error, requestId);
  }
}
