import { randomUUID } from "node:crypto";
import {
  completeGuestCartRestore,
  completeMockPayment,
  guestCartRestoreTarget,
  mockPaymentDetails,
} from "@fco/infrastructure/checkout";
import {
  apiErrorResponse,
  apiFailureResponse,
  isRecord,
  logApiFailure,
  readJsonBody,
  requestIdFrom,
  sameOriginRequest,
} from "../../../../http";
import { guestCartCookie, clearGuestCartCookie } from "@/lib/customer-cookies";
import {
  matchesMockPaymentToken,
  mockPaymentEnabled,
  mockPaymentTokenHash,
} from "@/lib/checkout";
import { restoreGuestCart } from "@/lib/guest-cart";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export async function POST(
  request: Request,
  context: { params: Promise<{ paymentId: string }> },
): Promise<Response> {
  const requestId = requestIdFrom(request);
  if (!mockPaymentEnabled()) {
    return apiErrorResponse(404, "FCO-1004", "مسیر پرداخت پیدا نشد.", requestId);
  }
  if (!sameOriginRequest(request)) {
    return apiErrorResponse(403, "FCO-1003", "درخواست از مبدأ معتبر نیست.", requestId);
  }
  const { paymentId } = await context.params;
  if (!uuidPattern.test(paymentId)) {
    return apiErrorResponse(404, "FCO-1004", "تراکنش پرداخت پیدا نشد.", requestId);
  }
  const parsedBody = await readJsonBody(request, 4096);
  if (parsedBody.kind === "too_large") {
    return apiErrorResponse(413, "FCO-1001", "اندازهٔ درخواست بیش از حد مجاز است.", requestId);
  }
  if (parsedBody.kind !== "ok" || !isRecord(parsedBody.value)) {
    return apiErrorResponse(400, "FCO-1001", "درخواست پرداخت معتبر نیست.", requestId);
  }
  const token =
    typeof parsedBody.value.token === "string" ? parsedBody.value.token : "";
  const outcome = parsedBody.value.outcome;
  if (
    !/^[A-Za-z0-9_-]{43}$/.test(token) ||
    (outcome !== "succeeded" && outcome !== "failed")
  ) {
    return apiErrorResponse(400, "FCO-1001", "توکن یا نتیجهٔ پرداخت معتبر نیست.", requestId);
  }

  try {
    const details = await mockPaymentDetails(paymentId);
    if (!details || !matchesMockPaymentToken(token, details.mock_token_hash)) {
      return apiErrorResponse(401, "FCO-1005", "لینک پرداخت معتبر نیست.", requestId);
    }

    const result = await completeMockPayment(
      paymentId,
      mockPaymentTokenHash(token),
      outcome,
      randomUUID(),
      requestId,
    );
    const headers = new Headers({
      "Cache-Control": "no-store",
      "X-Request-Id": requestId,
    });
    let cartRestorePending = false;
    if (result.guest_cart_id && result.result !== "succeeded") {
      try {
        const restore = await guestCartRestoreTarget(result.guest_cart_id);
        if (restore) {
          if (restore.restore_pending) {
            await restoreGuestCart(restore.restore_cart_id, restore.items);
            await completeGuestCartRestore(result.guest_cart_id);
          }
          headers.set("Set-Cookie", guestCartCookie(restore.restore_cart_id));
        }
      } catch (error) {
        cartRestorePending = true;
        logApiFailure("checkout_guest_cart_restore_pending", requestId, error);
      }
    } else if (result.guest_cart_id && result.result === "succeeded") {
      headers.set("Set-Cookie", clearGuestCartCookie());
    }

    return Response.json(
      {
        data: {
          result: result.result,
          order_id: result.order_id,
          order_number: result.order_number,
          cart_restore_pending: cartRestorePending,
        },
        meta: { request_id: requestId },
      },
      { headers },
    );
  } catch (error) {
    logApiFailure("mock_payment_completion_failed", requestId, error);
    return apiFailureResponse(error, requestId);
  }
}
