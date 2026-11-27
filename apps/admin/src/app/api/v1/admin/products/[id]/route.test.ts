import { beforeEach, describe, expect, it, vi } from "vitest";

const { updateAdminProduct, resolveStaffSession } = vi.hoisted(() => ({
  updateAdminProduct: vi.fn(),
  resolveStaffSession: vi.fn(),
}));

vi.mock("@fco/infrastructure/admin-catalog", () => ({ updateAdminProduct }));
vi.mock("@fco/infrastructure/admin-session", () => ({
  resolveStaffSession,
  staffSessionTokenFromRequest: (request: Request) =>
    request.headers.get("cookie")?.includes("__Host-fco_sid=") ? "valid-token" : null,
}));

import { PATCH } from "./route";

const actorId = "11111111-1111-4111-8111-111111111111";
const productId = "22222222-2222-4222-8222-222222222222";

describe("PATCH /api/v1/admin/products/:id", () => {
  beforeEach(() => {
    updateAdminProduct.mockReset();
    resolveStaffSession.mockReset();
    resolveStaffSession.mockResolvedValue({ sid: "session-id", uid: actorId });
  });

  it("requires a complete versioned product state and forwards the expected version", async () => {
    updateAdminProduct.mockResolvedValue(4);
    const request = new Request(`http://localhost/api/v1/admin/products/${productId}`, {
      method: "PATCH",
      headers: {
        cookie: "__Host-fco_sid=valid-token",
        origin: "http://localhost",
        "if-match": '"3"',
        "content-type": "application/json",
      },
      body: JSON.stringify({
        title: "Coat",
        description: null,
        brand_id: null,
        category_id: null,
        attributes: { color: "black" },
      }),
    });

    const response = await PATCH(request, { params: Promise.resolve({ id: productId }) });

    expect(response.status).toBe(200);
    expect(updateAdminProduct).toHaveBeenCalledWith(
      expect.objectContaining({ actorId, productId, expectedVersion: 3 }),
    );
  });

  it("rejects stale/invalid version inputs before calling the database", async () => {
    const response = await PATCH(
      new Request(`http://localhost/api/v1/admin/products/${productId}`, {
        method: "PATCH",
        headers: {
          cookie: "__Host-fco_sid=valid-token",
          origin: "http://localhost",
          "if-match": '"3"',
          "content-type": "application/json",
        },
        body: JSON.stringify({ title: "Coat" }),
      }),
      { params: Promise.resolve({ id: productId }) },
    );

    expect(response.status).toBe(400);
    expect(updateAdminProduct).not.toHaveBeenCalled();
  });

  it("requires the optimistic concurrency header", async () => {
    const response = await PATCH(
      new Request(`http://localhost/api/v1/admin/products/${productId}`, {
        method: "PATCH",
        headers: {
          cookie: "__Host-fco_sid=valid-token",
          origin: "http://localhost",
          "content-type": "application/json",
        },
        body: JSON.stringify({
          title: "Coat",
          description: null,
          brand_id: null,
          category_id: null,
          attributes: {},
        }),
      }),
      { params: Promise.resolve({ id: productId }) },
    );

    expect(response.status).toBe(428);
    expect(updateAdminProduct).not.toHaveBeenCalled();
  });
});
