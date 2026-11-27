import { describe, expect, it } from "vitest";
import { readJsonBody, requestIdFrom, sameOriginRequest } from "./http";

describe("admin HTTP helpers", () => {
  it("uses a valid request ID and replaces malformed values", () => {
    expect(
      requestIdFrom(
        new Request("http://localhost", { headers: { "x-request-id": "admin-123" } }),
      ),
    ).toBe("admin-123");

    expect(
      requestIdFrom(
        new Request("http://localhost", { headers: { "x-request-id": "bad value" } }),
      ),
    ).toMatch(/^[0-9a-f-]{36}$/);
  });

  it("accepts only same-origin requests", () => {
    expect(
      sameOriginRequest(
        new Request("https://admin.example/api", {
          headers: { origin: "https://admin.example" },
        }),
      ),
    ).toBe(true);
    expect(
      sameOriginRequest(
        new Request("https://admin.example/api", {
          headers: { origin: "https://attacker.example" },
        }),
      ),
    ).toBe(false);
    expect(sameOriginRequest(new Request("https://admin.example/api"))).toBe(false);
    expect(
      sameOriginRequest(
        new Request("http://next-internal/api", {
          headers: {
            host: "admin.example",
            origin: "http://admin.example",
          },
        }),
      ),
    ).toBe(true);
  });

  it("uses the forwarded HTTPS scheme only when a trusted proxy is configured", () => {
    const previous = process.env.TRUST_PROXY;
    process.env.TRUST_PROXY = "true";
    try {
      expect(
        sameOriginRequest(
          new Request("http://internal/api", {
            headers: {
              host: "admin.example",
              origin: "https://admin.example",
              "x-forwarded-proto": "https",
            },
          }),
        ),
      ).toBe(true);
    } finally {
      if (previous === undefined) {
        delete process.env.TRUST_PROXY;
      } else {
        process.env.TRUST_PROXY = previous;
      }
    }
  });

  it("bounds and parses JSON request bodies", async () => {
    await expect(
      readJsonBody(new Request("http://localhost", { body: '{"ok":true}', method: "POST" }), 16),
    ).resolves.toEqual({ kind: "ok", value: { ok: true } });
    await expect(
      readJsonBody(new Request("http://localhost", { body: "{", method: "POST" }), 16),
    ).resolves.toEqual({ kind: "invalid" });
    await expect(
      readJsonBody(new Request("http://localhost", { body: "12345", method: "POST" }), 4),
    ).resolves.toEqual({ kind: "too_large" });
  });
});
