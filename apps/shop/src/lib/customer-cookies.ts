import {
  CUSTOMER_SESSION_COOKIE,
  type CustomerLoginResult,
} from "@fco/infrastructure/customer-auth";
import { GUEST_CART_TTL_SECONDS, isGuestCartId } from "./guest-cart";

export const GUEST_CART_COOKIE = "__Host-fco_cart_sid";

export function cookieValue(request: Request, name: string): string | null {
  const cookie = request.headers.get("cookie");
  if (!cookie) {
    return null;
  }
  for (const part of cookie.split(";")) {
    const separator = part.indexOf("=");
    if (separator >= 0 && part.slice(0, separator).trim() === name) {
      return part.slice(separator + 1).trim() || null;
    }
  }
  return null;
}

export function guestCartIdFromRequest(request: Request): string | null {
  const id = cookieValue(request, GUEST_CART_COOKIE);
  if (!id) {
    return null;
  }
  return isGuestCartId(id) ? id : null;
}

export function guestCartCookie(id: string): string {
  return `${GUEST_CART_COOKIE}=${id}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${GUEST_CART_TTL_SECONDS}`;
}

export function clearGuestCartCookie(): string {
  return `${GUEST_CART_COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0`;
}

export function customerSessionCookie(session: CustomerLoginResult): string {
  const maxAge = Math.max(
    0,
    Math.floor((session.expiresAt.getTime() - Date.now()) / 1000),
  );
  return `${CUSTOMER_SESSION_COOKIE}=${session.token}; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=${maxAge}; Expires=${session.expiresAt.toUTCString()}`;
}
