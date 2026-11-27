import { afterEach, describe, expect, it } from "vitest";
import {
  createMfaSetupChallenge,
  encryptMfaSecret,
  hashMfaRecoveryCode,
  hashStaffPassword,
  matchingTotpStep,
  verifyStaffPassword,
  verifyMfaSetupChallenge,
} from "./staff-auth";

const originalEncryptionKey = process.env.MFA_ENCRYPTION_KEY;
const originalSessionPepper = process.env.SESSION_TOKEN_PEPPER;

afterEach(() => {
  if (originalEncryptionKey === undefined) {
    delete process.env.MFA_ENCRYPTION_KEY;
  } else {
    process.env.MFA_ENCRYPTION_KEY = originalEncryptionKey;
  }
  if (originalSessionPepper === undefined) {
    delete process.env.SESSION_TOKEN_PEPPER;
  } else {
    process.env.SESSION_TOKEN_PEPPER = originalSessionPepper;
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

  it("signs short-lived MFA setup challenges and rejects expired or modified values", () => {
    process.env.SESSION_TOKEN_PEPPER = "test-session-pepper-with-at-least-32-bytes";
    const now = 1_800_000_000_000;
    const userId = "11111111-1111-4111-8111-111111111111";
    const challenge = createMfaSetupChallenge(userId, now);

    expect(verifyMfaSetupChallenge(challenge.token, now)).toBe(userId);
    expect(verifyMfaSetupChallenge(challenge.token, challenge.expiresAt.getTime())).toBeNull();
    expect(verifyMfaSetupChallenge(`${challenge.token}x`, now)).toBeNull();
  });

  it("hashes normalized recovery codes without retaining the usable code", () => {
    process.env.SESSION_TOKEN_PEPPER = "test-session-pepper-with-at-least-32-bytes";

    const hash = hashMfaRecoveryCode("abcd-efgh-ijkl-mnop");

    expect(hash).toBeInstanceOf(Buffer);
    expect(hash).toHaveLength(32);
    expect(hash).toEqual(hashMfaRecoveryCode("ABCD-EFGH-IJKL-MNOP"));
    expect(hashMfaRecoveryCode("ABCD-EFGH")).toBeNull();
  });
});
