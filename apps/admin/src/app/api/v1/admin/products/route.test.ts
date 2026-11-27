import { beforeEach, describe, expect, it, vi } from "vitest";

const { createAdminProduct, listAdminProducts, resolveStaffSession } = vi.hoisted(() => ({
  createAdminProduct: vi.fn(),
  listAdminProducts: vi.fn(),
  resolveStaffSession: vi.fn(),
}));

vi.mock("@fco/infrastructure/admin-catalog", () => ({
  createAdminProduct,
  listAdminProducts,
}));
vi.mock("@fco/infrastructure/admin-session", () => ({
  resolveStaffSession,
  staffSessionTokenFromRequest: (request: Request) =>
    request.headers.get("cookie")?.includes("__Host-fco_sid=") ? "valid-token" : null,
}));

import { GET, POST } from "./route";

const actorId = "11111111-1111-4111-8111-111111111111";

describe("/api/v1/admin/products", () => {
  beforeEach(() => {
    createAdminProduct.mockReset();
    listAdminProducts.mockReset();
    resolveStaffSession.mockReset();
  });

  it("returns 401 without a session and does not query products", async () => {
    resolveStaffSession.mockResolvedValue(null);

    const response = await GET(new Request("http://localhost/api/v1/admin/products"));

    expect(response.status).toBe(401);
    expect(listAdminProducts).not.toHaveBeenCalled();
  });

  it("lists products using the authenticated actor and bounded pagination", async () => {
    resolveStaffSession.mockResolvedValue({ sid: "session-id", uid: actorId });
    listAdminProducts.mockResolvedValue({ items: [], total: 0 });

    const response = await GET(
      new Request("http://localhost/api/v1/admin/products?limit=20&offset=5", {
        headers: { cookie: "__Host-fco_sid=valid-token" },
      }),
    );

    expect(response.status).toBe(200);
    expect(listAdminProducts).toHaveBeenCalledWith(actorId, 20, 5);
    await expect(response.json()).resolves.toMatchObject({
      data: [],
      meta: { total: 0, limit: 20, offset: 5 },
    });
  });

  it("creates a product only for same-origin requests and passes the actor to the use-case", async () => {
    resolveStaffSession.mockResolvedValue({ sid: "session-id", uid: actorId });
    createAdminProduct.mockResolvedValue("22222222-2222-4222-8222-222222222222");

    const response = await POST(
      new Request("http://localhost/api/v1/admin/products", {
        method: "POST",
        headers: {
          cookie: "__Host-fco_sid=valid-token",
          origin: "http://localhost",
          "content-type": "application/json",
        },
        body: JSON.stringify({ slug: "coat", title: "Coat", attributes: {} }),
      }),
    );

    expect(response.status).toBe(201);
    expect(createAdminProduct).toHaveBeenCalledWith(
      expect.objectContaining({ actorId, slug: "coat", title: "Coat", requestId: expect.any(String) }),
    );
  });

  it("maps database authorization denials without exposing the database message", async () => {
    resolveStaffSession.mockResolvedValue({ sid: "session-id", uid: actorId });
    listAdminProducts.mockRejectedValue(
      Object.assign(new Error("FCO-1003: denied; private detail"), { code: "42501" }),
    );
    const write = vi.spyOn(process.stderr, "write").mockImplementation(() => true);

    try {
      const response = await GET(
        new Request("http://localhost/api/v1/admin/products", {
          headers: { cookie: "__Host-fco_sid=valid-token" },
        }),
      );

      expect(response.status).toBe(403);
      await expect(response.json()).resolves.toMatchObject({
        error: { code: "FCO-1003", message: "برای این عملیات مجوز ندارید." },
      });
    } finally {
      write.mockRestore();
    }
  });
});
