import { beforeEach, describe, expect, it, vi } from "vitest";

const { setAdminProductPrice, resolveStaffSession } = vi.hoisted(() => ({
  setAdminProductPrice: vi.fn(),
  resolveStaffSession: vi.fn(),
}));

vi.mock("@fco/infrastructure/admin-catalog", () => ({ setAdminProductPrice }));
vi.mock("@fco/infrastructure/admin-session", () => ({
  resolveStaffSession,
  staffSessionTokenFromRequest: (request: Request) =>
    request.headers.get("cookie")?.includes("__Host-fco_sid=") ? "valid-token" : null,
}));

import { POST } from "./route";

const actorId = "11111111-1111-4111-8111-111111111111";
const variantId = "22222222-2222-4222-8222-222222222222";

describe("POST /api/v1/admin/variants/:id/prices", () => {
  beforeEach(() => {
    setAdminProductPrice.mockReset();
    resolveStaffSession.mockReset();
    resolveStaffSession.mockResolvedValue({ sid: "session-id", uid: actorId });
  });

  it("stores a new version with the authenticated actor and request ID", async () => {
    setAdminProductPrice.mockResolvedValue("33333333-3333-4333-8333-333333333333");
    const response = await POST(
      new Request(`http://localhost/api/v1/admin/variants/${variantId}/prices`, {
        method: "POST",
        headers: {
          cookie: "__Host-fco_sid=valid-token",
          origin: "http://localhost",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          amount_rial: 125000,
          effective_from: "2030-01-02T03:04:05.123456Z",
          reason: "سال جدید",
        }),
      }),
      { params: Promise.resolve({ id: variantId }) },
    );

    expect(response.status).toBe(201);
    expect(setAdminProductPrice).toHaveBeenCalledWith(
      expect.objectContaining({
        actorId,
        variantId,
        amountRial: 125000,
        effectiveFrom: "2030-01-02T03:04:05.123456Z",
        channel: "web",
        reason: "سال جدید",
      }),
    );
  });

  it("rejects invalid date and unsafe amounts before invoking the use-case", async () => {
    const response = await POST(
      new Request(`http://localhost/api/v1/admin/variants/${variantId}/prices`, {
        method: "POST",
        headers: {
          cookie: "__Host-fco_sid=valid-token",
          origin: "http://localhost",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          amount_rial: Number.MAX_SAFE_INTEGER + 1,
          effective_from: "2030-02-31T03:04:05Z",
        }),
      }),
      { params: Promise.resolve({ id: variantId }) },
    );

    expect(response.status).toBe(400);
    expect(setAdminProductPrice).not.toHaveBeenCalled();
  });
});
