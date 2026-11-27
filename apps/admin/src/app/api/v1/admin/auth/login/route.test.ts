import { beforeEach, describe, expect, it, vi } from "vitest";

const { loginStaff } = vi.hoisted(() => ({ loginStaff: vi.fn() }));

vi.mock("@fco/infrastructure/staff-auth", () => ({ loginStaff }));
vi.mock("@fco/infrastructure/admin-session", () => ({
  STAFF_SESSION_COOKIE: "__Host-fco_sid",
}));

import { POST } from "./route";

function loginRequest(body: string, origin = "http://localhost"): Request {
  return new Request("http://localhost/api/v1/admin/auth/login", {
    method: "POST",
    headers: { origin, "content-type": "application/json" },
    body,
  });
}

describe("POST /api/v1/admin/auth/login", () => {
  beforeEach(() => {
    loginStaff.mockReset();
  });

  it("sets a secure host-only session cookie after authentication", async () => {
    loginStaff.mockResolvedValue({
      kind: "authenticated",
      userId: "11111111-1111-4111-8111-111111111111",
      token: "A".repeat(43),
      expiresAt: new Date(Date.now() + 60_000),
    });

    const response = await POST(
      loginRequest(JSON.stringify({ email: "Staff@Example.com", password: "secret" })),
    );

    expect(response.status).toBe(200);
    expect(response.headers.get("set-cookie")).toContain("__Host-fco_sid=");
    expect(response.headers.get("set-cookie")).toContain("HttpOnly");
    expect(response.headers.get("set-cookie")).toContain("Secure");
    expect(response.headers.get("set-cookie")).toContain("SameSite=Lax");
    expect(response.headers.get("x-request-id")).toBeTruthy();
    expect(loginStaff).toHaveBeenCalledWith(
      expect.objectContaining({ email: "staff@example.com", password: "secret", totp: null }),
    );
  });

  it("does not create a session when MFA is required", async () => {
    loginStaff.mockResolvedValue({ kind: "mfa_required" });

    const response = await POST(
      loginRequest(JSON.stringify({ email: "staff@example.com", password: "secret" })),
    );

    expect(response.status).toBe(401);
    expect(response.headers.has("set-cookie")).toBe(false);
    await expect(response.json()).resolves.toMatchObject({
      error: { code: "FCO-1006" },
    });
  });

  it("rejects cross-origin and oversized login requests before authentication", async () => {
    const crossOrigin = await POST(
      loginRequest(
        JSON.stringify({ email: "staff@example.com", password: "secret" }),
        "https://attacker.example",
      ),
    );
    const oversized = await POST(
      loginRequest(JSON.stringify({ email: "staff@example.com", password: "x".repeat(5000) })),
    );

    expect(crossOrigin.status).toBe(403);
    expect(oversized.status).toBe(413);
    expect(loginStaff).not.toHaveBeenCalled();
  });
});
