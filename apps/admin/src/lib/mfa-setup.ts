import {
  STAFF_MFA_SETUP_COOKIE,
} from "@fco/infrastructure/admin-session";
import { verifyMfaSetupChallenge } from "@fco/infrastructure/staff-auth";
import { adminSessionFromRequest } from "./admin-session";

export async function mfaSetupActor(
  request: Request,
): Promise<{ userId: string; challenge: boolean } | null> {
  const session = await adminSessionFromRequest(request);
  if (session) {
    return { userId: session.uid, challenge: false };
  }

  const cookie = request.headers.get("cookie");
  if (!cookie) {
    return null;
  }
  const setupCookie = cookie
    .split(";")
    .map((part) => part.trim())
    .find((part) => part.startsWith(`${STAFF_MFA_SETUP_COOKIE}=`));
  const token = setupCookie?.slice(STAFF_MFA_SETUP_COOKIE.length + 1);
  const userId = token ? verifyMfaSetupChallenge(token) : null;
  return userId ? { userId, challenge: true } : null;
}

export function clearMfaSetupCookie(): string {
  return `${STAFF_MFA_SETUP_COOKIE}=; Path=/; HttpOnly; Secure; SameSite=Lax; Max-Age=0`;
}
