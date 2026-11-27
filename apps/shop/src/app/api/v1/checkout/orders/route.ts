import { randomUUID } from "node:crypto";
import {
  completeGuestCartCheckout,
  findCheckoutByIdempotency,
  placeCheckoutOrder,
} from "@fco/infrastructure/checkout";
import {
  customerSessionTokenFromRequest,
  resolveCustomerSession,
  type GuestCartLine,
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
import { readCustomerCart as listCustomerCart } from "@fco/infrastructure/cart";
import {
  checkoutRequestHash,
  mockPaymentEnabled,
  mockPaymentToken,
  mockPaymentTokenHash,
  recoverGuestCart,
} from "@/lib/checkout";
import {
  claimGuestCartForMerge,
  deleteGuestCartAfterMerge,
  releaseGuestCartMergeLock,
} from "@/lib/guest-cart";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

function shippingAddress(value: unknown): Record<string, string> | null {
  if (!isRecord(value)) {
    return null;
  }
  const fields = ["recipient_name", "mobile", "province", "city", "postal_code", "address"] as const;
  const address: Record<string, string> = {};
  for (const field of fields) {
    const item = value[field];
    if (typeof item !== "string" || item.trim().length === 0 || item.length > 500) {
      return null;
    }
    address[field] = item.trim();
  }
  if (
    !/^09[0-9]{9}$/.test(address.mobile) ||
    !/^[0-9]{10}$/.test(address.postal_code)
  ) {
    return null;
  }
  return address;
}

function paymentUrl(request: Request, paymentId: string): string {
  const token = mockPaymentToken(paymentId);
  const url = new URL(`/mock-payment/${paymentId}`, request.url);
  url.searchParams.set("token", token);
  return `${url.pathname}${url.search}`;
}

export async function POST(request: Request): Promise<Response> {
  const requestId = requestIdFrom(request);
  if (!mockPaymentEnabled()) {
    return apiErrorResponse(
      503,
      "FCO-1018",
      "درگاه پرداخت سفارش در این محیط پیکربندی نشده است.",
      requestId,
    );
  }
  if (!sameOriginRequest(request)) {
    return apiErrorResponse(403, "FCO-1003", "درخواست از مبدأ معتبر نیست.", requestId);
  }
  const parsedBody = await readJsonBody(request, 16_384);
  if (parsedBody.kind === "too_large") {
    return apiErrorResponse(413, "FCO-1001", "اندازهٔ درخواست بیش از حد مجاز است.", requestId);
  }
  if (parsedBody.kind !== "ok" || !isRecord(parsedBody.value)) {
    return apiErrorResponse(400, "FCO-1001", "اطلاعات ثبت سفارش معتبر نیست.", requestId);
  }

  const address = shippingAddress(parsedBody.value.shipping_address);
  const guestEmail =
    typeof parsedBody.value.guest_email === "string"
      ? parsedBody.value.guest_email.trim().toLowerCase()
      : "";
  const guestMobile =
    typeof parsedBody.value.guest_mobile === "string"
      ? parsedBody.value.guest_mobile.trim()
      : "";
  const idempotencyKey = request.headers.get("idempotency-key")?.trim() ?? "";
  const customerToken = customerSessionTokenFromRequest(request);
  if (
    !address ||
    (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(guestEmail) && !customerToken) ||
    (!/^09[0-9]{9}$/.test(guestMobile) && !customerToken) ||
    !/^[A-Za-z0-9._:-]{8,128}$/.test(idempotencyKey)
  ) {
    return apiErrorResponse(
      400,
      "FCO-1001",
      "نشانی، اطلاعات تماس یا کلید Idempotency معتبر نیست.",
      requestId,
    );
  }

  const suppliedCartId = cookieValue(request, GUEST_CART_COOKIE);
  if (suppliedCartId && !guestCartIdFromRequest(request)) {
    return apiErrorResponse(400, "FCO-1001", "شناسهٔ سبد مهمان معتبر نیست.", requestId);
  }

  let customerId: string | null = null;
  if (customerToken) {
    try {
      const session = await resolveCustomerSession(customerToken);
      if (!session) {
        return apiErrorResponse(401, "FCO-1005", "نشست مشتری معتبر نیست.", requestId);
      }
      customerId = session.uid;
    } catch (error) {
      logApiFailure("checkout_session_resolution_failed", requestId, error);
      return apiFailureResponse(error, requestId);
    }
  } else if (!suppliedCartId) {
    return apiErrorResponse(400, "FCO-1001", "سبد خرید مهمان پیدا نشد.", requestId);
  }

  const guestCartId = customerId ? null : suppliedCartId;
  const normalizedEmail = customerId ? null : guestEmail;
  const normalizedMobile = customerId ? null : guestMobile;
  const requestHash = checkoutRequestHash({
    customer_id: customerId,
    guest_cart_id: guestCartId,
    guest_email: normalizedEmail,
    guest_mobile: normalizedMobile,
    shipping_address: address,
  });

  let guestLock: { token: string; items: GuestCartLine[] } | null = null;
  let orderPlaced = false;
  try {
    const existing = await findCheckoutByIdempotency(
      customerId,
      guestCartId,
      idempotencyKey,
      requestHash,
    );
    if (existing) {
      let restoredCartId = guestCartId;
      let cleanupPending = false;
      if (guestCartId) {
        const recovery = await recoverGuestCart(guestCartId);
        restoredCartId = recovery.cartId;
        cleanupPending = recovery.cleanupPending;
      }
      const headers = new Headers({
        "Cache-Control": "no-store",
        "X-Request-Id": requestId,
      });
      if (restoredCartId && restoredCartId !== guestCartId) {
        headers.set("Set-Cookie", guestCartCookie(restoredCartId));
      }
      return Response.json(
        {
          data: {
            ...existing,
            payment_url: paymentUrl(request, existing.payment_id),
            guest_cart_cleanup_pending: cleanupPending,
          },
          meta: { request_id: requestId },
        },
        { headers },
      );
    }

    let guestItems: GuestCartLine[] | null = null;
    if (guestCartId) {
      guestLock = await claimGuestCartForMerge(guestCartId);
      if (!guestLock) {
        return apiErrorResponse(
          409,
          "FCO-1091",
          "سبد خرید هم‌زمان در حال پردازش است؛ دوباره تلاش کنید.",
          requestId,
        );
      }
      guestItems = guestLock.items;
    } else if (customerId) {
      const accountItems = await listCustomerCart(customerId);
      if (accountItems.length === 0) {
        return apiErrorResponse(400, "FCO-1001", "سبد خرید خالی است.", requestId);
      }
    }

    const paymentId = randomUUID();
    const token = mockPaymentToken(paymentId);
    const order = await placeCheckoutOrder({
      customerId,
      guestCartId,
      guestEmail: normalizedEmail,
      guestMobile: normalizedMobile,
      shippingAddress: address,
      idempotencyKey,
      requestHash,
      guestItems,
      paymentId,
      mockTokenHash: mockPaymentTokenHash(token),
      orderYear: new Date().getUTCFullYear(),
      requestId,
    });
    orderPlaced = true;

    let cleanupPending = false;
    if (guestCartId && guestLock) {
      try {
        const deleted = await deleteGuestCartAfterMerge(guestCartId, guestLock.token);
        if (!deleted) {
          cleanupPending = true;
        } else {
          await completeGuestCartCheckout(guestCartId);
        }
      } catch (error) {
        cleanupPending = true;
        logApiFailure("checkout_guest_cart_cleanup_pending", requestId, error);
      }
    }

    const headers = new Headers({
      "Cache-Control": "no-store",
      "X-Request-Id": requestId,
    });
    return Response.json(
      {
        data: {
          ...order,
          payment_url: paymentUrl(request, order.payment_id),
          guest_cart_cleanup_pending: cleanupPending,
        },
        meta: { request_id: requestId },
      },
      { status: 201, headers },
    );
  } catch (error) {
    if (!orderPlaced && guestCartId && guestLock) {
      try {
        await releaseGuestCartMergeLock(guestCartId, guestLock.token);
      } catch (releaseError) {
        logApiFailure("checkout_guest_cart_lock_release_failed", requestId, releaseError);
      }
    }
    if (
      typeof error === "object" &&
      error !== null &&
      "code" in error &&
      (error.code === "40001" || error.code === "23505")
    ) {
      try {
        const replay = await findCheckoutByIdempotency(
          customerId,
          guestCartId,
          idempotencyKey,
          requestHash,
        );
        if (replay) {
          const headers = new Headers({
            "Cache-Control": "no-store",
            "X-Request-Id": requestId,
          });
          return Response.json(
            {
              data: {
                ...replay,
                payment_url: paymentUrl(request, replay.payment_id),
              },
              meta: { request_id: requestId },
            },
            { status: 200, headers },
          );
        }
      } catch (replayError) {
        logApiFailure("checkout_conflict_replay_failed", requestId, replayError);
      }
    }
    if (
      typeof error === "object" &&
      error !== null &&
      "code" in error &&
      error.code === "22023" &&
      error instanceof Error &&
      error.message.includes("FCO-2001")
    ) {
      return apiErrorResponse(409, "FCO-2001", "موجودی کافی برای سبد وجود ندارد.", requestId);
    }
    logApiFailure("checkout_order_place_failed", requestId, error);
    return apiFailureResponse(error, requestId);
  }
}
