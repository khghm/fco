import {
  addCustomerCartItem,
  getPublicCartItems,
  readCustomerCart,
  resolveSellableVariantSku,
  validateSellableCartItem,
} from "@fco/infrastructure/cart";
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
  guestCartCookie,
  guestCartIdFromRequest,
  GUEST_CART_COOKIE,
} from "@/lib/customer-cookies";
import { addGuestCartItem, newGuestCartId, readGuestCart } from "@/lib/guest-cart";
import { recoverGuestCart } from "@/lib/checkout";

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
    return apiErrorResponse(400, "FCO-1001", "اطلاعات قلم سبد معتبر نیست.", requestId);
  }
  const suppliedVariantId =
    typeof parsedBody.value.variant_id === "string"
      ? parsedBody.value.variant_id
      : "";
  const sku =
    typeof parsedBody.value.sku === "string"
      ? parsedBody.value.sku.trim()
      : "";
  const quantity = parsedBody.value.quantity;
  if (
    (Boolean(suppliedVariantId) === Boolean(sku)) ||
    (suppliedVariantId !== "" &&
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(
        suppliedVariantId,
      )) ||
    (sku !== "" && sku.length > 128) ||
    typeof quantity !== "number" ||
    !Number.isSafeInteger(quantity) ||
    quantity < 1 ||
    quantity > 99
  ) {
    return apiErrorResponse(400, "FCO-1001", "شناسهٔ تنوع یا تعداد معتبر نیست.", requestId);
  }

  const variantId = suppliedVariantId || (await resolveSellableVariantSku(sku));
  if (!variantId) {
    return apiErrorResponse(404, "FCO-1004", "تنوع محصول برای فروش در دسترس نیست.", requestId);
  }

  const customerToken = customerSessionTokenFromRequest(request);
  const suppliedCartId = cookieValue(request, GUEST_CART_COOKIE);
  if (suppliedCartId && !guestCartIdFromRequest(request)) {
    return apiErrorResponse(400, "FCO-1001", "شناسهٔ سبد مهمان معتبر نیست.", requestId);
  }

  try {
    const sellableItem = await validateSellableCartItem(variantId);
    if (!sellableItem) {
      return apiErrorResponse(404, "FCO-1004", "تنوع محصول برای فروش در دسترس نیست.", requestId);
    }

    if (customerToken) {
      const session = await resolveCustomerSession(customerToken);
      if (!session) {
        return apiErrorResponse(401, "FCO-1005", "نشست مشتری معتبر نیست.", requestId);
      }
      await addCustomerCartItem(session.uid, variantId, quantity);
      const items = await readCustomerCart(session.uid);
      return Response.json(
        { data: { items }, meta: { request_id: requestId } },
        {
          headers: {
            "Cache-Control": "no-store",
            "X-Request-Id": requestId,
          },
        },
      );
    }

    let cartId = suppliedCartId ?? newGuestCartId();
    if (suppliedCartId) {
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
    const addResult = await addGuestCartItem(cartId, variantId, quantity);
    if (addResult === "merge_in_progress") {
      return apiErrorResponse(
        409,
        "FCO-1091",
        "سبد خرید هم‌زمان در حال ادغام است؛ دوباره تلاش کنید.",
        requestId,
      );
    }
    if (addResult === "quantity_limit") {
      return apiErrorResponse(409, "FCO-1090", "تعداد این قلم از سقف مجاز بیشتر می‌شود.", requestId);
    }
    const items = await getPublicCartItems(await readGuestCart(cartId));
    const headers = new Headers({
      "Cache-Control": "no-store",
      "X-Request-Id": requestId,
    });
    headers.set("Set-Cookie", guestCartCookie(cartId));
    return Response.json(
      { data: { items }, meta: { request_id: requestId } },
      { status: 201, headers },
    );
  } catch (error) {
    logApiFailure("cart_item_add_failed", requestId, error);
    return apiFailureResponse(error, requestId);
  }
}
