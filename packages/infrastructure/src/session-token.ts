import { createHash, randomBytes } from "node:crypto";

function sessionPepper(): string {
  const pepper = process.env.SESSION_TOKEN_PEPPER;
  if (!pepper || Buffer.byteLength(pepper, "utf8") < 32) {
    throw new Error("SESSION_TOKEN_PEPPER must contain at least 32 bytes.");
  }
  return pepper;
}

export function createSessionToken(): string {
  return randomBytes(32).toString("base64url");
}

export function hashSessionToken(token: string): Buffer {
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) {
    throw new Error("Session token has an invalid format.");
  }

  return createHash("sha256")
    .update(token, "utf8")
    .update(sessionPepper(), "utf8")
    .digest();
}
