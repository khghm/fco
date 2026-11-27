import { createHash, createHmac, timingSafeEqual } from "node:crypto";
import {
  completeGuestCartCheckout,
  completeGuestCartRestore,
  guestCartRestoreTarget,
  guestCartCheckoutState,
  pendingGuestCartCheckout,
} from "@fco/infrastructure/checkout";
import {
  cleanupPendingGuestCart,
  newGuestCartId,
  restoreGuestCart,
} from "./guest-cart";

export function mockPaymentEnabled(): boolean {
  return process.env.FCO_E2E_MODE === "true";
}

export function checkoutRequestHash(value: unknown): string {
  return createHash("sha256")
    .update(JSON.stringify(value), "utf8")
    .digest("hex");
}

function paymentPepper(): string {
  const pepper = process.env.FCO_MOCK_PAYMENT_SECRET;
  if (!pepper || Buffer.byteLength(pepper, "utf8") < 32) {
    throw new Error("FCO_MOCK_PAYMENT_SECRET must contain at least 32 bytes.");
  }
  return pepper;
}

export function mockPaymentToken(paymentId: string): string {
  return createHmac("sha256", paymentPepper())
    .update(paymentId, "utf8")
    .digest("base64url");
}

export function mockPaymentTokenHash(token: string): Buffer {
  return createHash("sha256").update(token, "utf8").digest();
}

export function matchesMockPaymentToken(
  token: string,
  storedHash: Buffer,
): boolean {
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) {
    return false;
  }
  const suppliedHash = mockPaymentTokenHash(token);
  return (
    storedHash.length === suppliedHash.length &&
    timingSafeEqual(storedHash, suppliedHash)
  );
}

export async function recoverGuestCart(
  guestCartId: string,
): Promise<{ cartId: string; cleanupPending: boolean }> {
  if (await pendingGuestCartCheckout(guestCartId)) {
    const cleaned = await cleanupPendingGuestCart(guestCartId);
    if (!cleaned) {
      return { cartId: guestCartId, cleanupPending: true };
    }
    await completeGuestCartCheckout(guestCartId);
  }

  const restore = await guestCartRestoreTarget(guestCartId);
  if (restore) {
    if (restore.restore_pending) {
      await restoreGuestCart(restore.restore_cart_id, restore.items);
      await completeGuestCartRestore(guestCartId);
    }
    return { cartId: restore.restore_cart_id, cleanupPending: false };
  }
  if ((await guestCartCheckoutState(guestCartId)) === "succeeded") {
    return { cartId: newGuestCartId(), cleanupPending: false };
  }
  return { cartId: guestCartId, cleanupPending: false };
}
