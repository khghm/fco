import { beforeEach, describe, expect, it, vi } from "vitest";

const { revokeStaffSession } = vi.hoisted(() => ({ revokeStaffSession: vi.fn() }));

vi.mock("@fco/infrastructure/admin-session", () => ({
  revokeStaffSession,
  STAFF_SESSION_COOKIE: "__Host-fco_sid",
  staffSessionTokenFromRequest: (request: Request) =>
    request.headers.get("cookie")?.includes("__Host-fco_sid=") ? "valid-token" : null,
}));

import { POST } from "./route";

describe("POST /api/v1/admin/auth/logout", () => {
  beforeEach(() => {
    revokeStaffSession.mockReset();
  });

  it("revokes the server session and clears its secure cookie", async () => {
    revokeStaffSession.mockResolvedValue(true);
    const response = await POST(
      new Request("http://localhost/api/v1/admin/auth/logout", {
        method: "POST",
        headers: {
          cookie: "__Host-fco_sid=valid-token",
          origin: "http://localhost",
        },
      }),
    );

    expect(response.status).toBe(204);
    expect(revokeStaffSession).toHaveBeenCalledWith("valid-token");
    expect(response.headers.get("set-cookie")).toContain("Max-Age=0");
    expect(response.headers.get("set-cookie")).toContain("Secure");
  });

  it("rejects cross-origin logout requests", async () => {
    const response = await POST(
      new Request("http://localhost/api/v1/admin/auth/logout", {
        method: "POST",
        headers: { origin: "https://attacker.example" },
      }),
    );

    expect(response.status).toBe(403);
    expect(revokeStaffSession).not.toHaveBeenCalled();
  });
});
