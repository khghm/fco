import {
  resolveStaffSession,
  staffSessionTokenFromRequest,
  type StaffSession,
} from "@fco/infrastructure/admin-session";

export async function adminSessionFromRequest(
  request: Request,
): Promise<StaffSession | null> {
  const token = staffSessionTokenFromRequest(request);
  return token ? resolveStaffSession(token) : null;
}
