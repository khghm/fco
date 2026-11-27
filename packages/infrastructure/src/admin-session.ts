import { createHash } from "node:crypto";
import type { PoolClient, QueryResultRow } from "pg";
import { getPostgresPool } from "./postgres";

export const STAFF_SESSION_COOKIE = "__Host-fco_sid";
export const STAFF_MFA_SETUP_COOKIE = "__Host-fco_mfa_setup";

export interface StaffSession {
  sid: string;
  uid: string;
}

interface SessionRow extends QueryResultRow, StaffSession {}

function sessionPepper(): string {
  const pepper = process.env.SESSION_TOKEN_PEPPER;
  if (!pepper || Buffer.byteLength(pepper, "utf8") < 32) {
    throw new Error("SESSION_TOKEN_PEPPER must contain at least 32 bytes.");
  }
  return pepper;
}

export function hashStaffSessionToken(token: string): Buffer {
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) {
    throw new Error("Staff session token has an invalid format.");
  }

  return createHash("sha256")
    .update(token, "utf8")
    .update(sessionPepper(), "utf8")
    .digest();
}

function sqlState(error: unknown): string | undefined {
  if (
    typeof error === "object" &&
    error !== null &&
    "code" in error &&
    typeof error.code === "string"
  ) {
    return error.code;
  }
  return undefined;
}

async function rollbackOrThrow(client: PoolClient, cause: unknown): Promise<void> {
  try {
    await client.query("rollback");
  } catch (rollbackError) {
    throw new AggregateError([cause, rollbackError], "Staff session transaction rollback failed.");
  }
}

export function staffSessionTokenFromRequest(request: Request): string | null {
  const cookie = request.headers.get("cookie");
  if (!cookie) {
    return null;
  }

  for (const part of cookie.split(";")) {
    const separator = part.indexOf("=");
    if (separator < 0 || part.slice(0, separator).trim() !== STAFF_SESSION_COOKIE) {
      continue;
    }
    return part.slice(separator + 1).trim() || null;
  }

  return null;
}

export async function resolveStaffSession(
  token: string,
  touch = true,
): Promise<StaffSession | null> {
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) {
    return null;
  }

  const client = await getPostgresPool("fco-admin").connect();
  let transactionOpen = false;
  try {
    await client.query("begin");
    transactionOpen = true;
    await client.query("set local role fco_app");
    const result = await client.query<SessionRow>(
      "select sid, uid from iam.authenticate($1::bytea, $2)",
      [hashStaffSessionToken(token), touch],
    );
    await client.query("commit");
    transactionOpen = false;
    return result.rows[0] ?? null;
  } catch (error) {
    if (transactionOpen) {
      await rollbackOrThrow(client, error);
    }
    if (sqlState(error) === "28000") {
      return null;
    }
    throw error;
  } finally {
    client.release();
  }
}

export async function revokeStaffSession(token: string): Promise<boolean> {
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) {
    return false;
  }

  const client = await getPostgresPool("fco-admin").connect();
  let transactionOpen = false;
  try {
    await client.query("begin");
    transactionOpen = true;
    await client.query("set local role fco_app");
    const session = await client.query<SessionRow>(
      "select sid, uid from iam.authenticate($1::bytea, false)",
      [hashStaffSessionToken(token)],
    );
    if (!session.rows[0]) {
      await client.query("commit");
      transactionOpen = false;
      return false;
    }

    await client.query("select iam.revoke_session($1::uuid, 'logout')", [
      session.rows[0].sid,
    ]);
    await client.query("commit");
    transactionOpen = false;
    return true;
  } catch (error) {
    if (transactionOpen) {
      await rollbackOrThrow(client, error);
    }
    if (sqlState(error) === "28000") {
      return false;
    }
    throw error;
  } finally {
    client.release();
  }
}
