import { afterEach, describe, expect, it } from "vitest";
import {
  encryptMfaSecret,
  hashStaffPassword,
  matchingTotpStep,
  verifyStaffPassword,
} from "./staff-auth";

const originalEncryptionKey = process.env.MFA_ENCRYPTION_KEY;

afterEach(() => {
  if (originalEncryptionKey === undefined) {
    delete process.env.MFA_ENCRYPTION_KEY;
  } else {
    process.env.MFA_ENCRYPTION_KEY = originalEncryptionKey;
  }
});

describe("staff authentication primitives", () => {
  it("matches the RFC 6238 SHA-1 test vector and rejects malformed codes", () => {
    const secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";

    expect(matchingTotpStep(secret, "287082", 59_000)).toBe(1);
    expect(matchingTotpStep(secret, "12345", 59_000)).toBeNull();
    expect(matchingTotpStep(secret, "287082", 90_000)).toBeNull();
  });

  it("hashes and verifies staff passwords with Argon2id", async () => {
    const hash = await hashStaffPassword("correct horse battery staple");

    expect(hash.startsWith("$argon2id$v=19$")).toBe(true);
    await expect(
      verifyStaffPassword(hash, "correct horse battery staple"),
    ).resolves.toBe(true);
    await expect(verifyStaffPassword(hash, "wrong password")).resolves.toBe(false);
    await expect(verifyStaffPassword(null, "wrong password")).resolves.toBe(false);
  });

  it("encrypts MFA seeds using a versioned AES-256-GCM envelope", () => {
    process.env.MFA_ENCRYPTION_KEY = Buffer.alloc(32, 7).toString("base64");
    const secret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";

    const envelope = encryptMfaSecret(secret);

    expect(envelope[0]).toBe(1);
    expect(envelope.length).toBeGreaterThan(29);
    expect(envelope.includes(Buffer.from(secret))).toBe(false);
  });
});
