import { createHmac, randomInt } from "node:crypto";
import type { PoolClient, QueryResultRow } from "pg";
import { mergeGuestCart } from "./cart";
import { getPostgresPool } from "./postgres";
import { createSessionToken, hashSessionToken } from "./session-token";

export const CUSTOMER_SESSION_COOKIE = "__Host-fco_customer_sid";

export interface OtpDelivery {
  requestId: string;
  mobile: string;
  code: string;
}

export interface ISmsProvider {
  sendOtp(delivery: OtpDelivery): Promise<void>;
}

export interface GuestCartLine {
  variantId: string;
  quantity: number;
}

export interface CustomerLoginResult {
  userId: string;
  token: string;
  expiresAt: Date;
  mergedGuestCartId: string | null;
}

interface OtpRequestRow extends QueryResultRow {
  request_id: string;
}

interface OtpVerificationRow extends QueryResultRow {
  outcome: "ok" | "invalid" | "locked";
  request_id: string | null;
}

interface CustomerRow extends QueryResultRow {
  id: string;
}

interface CustomerSessionRow extends QueryResultRow {
  session_id: string;
  expires_at: Date;
}

function otpPepper(): string {
  const pepper = process.env.OTP_CODE_PEPPER;
  if (!pepper || Buffer.byteLength(pepper, "utf8") < 32) {
    throw new Error("OTP_CODE_PEPPER must contain at least 32 bytes.");
  }
  return pepper;
}

function hashOtp(mobile: string, code: string): Buffer {
  return createHmac("sha256", otpPepper())
    .update(mobile, "utf8")
    .update("\0login\0", "utf8")
    .update(code, "utf8")
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
    throw new AggregateError([cause, rollbackError], "Customer auth transaction rollback failed.");
  }
}

async function invalidateOtp(requestId: string): Promise<void> {
  const client = await getPostgresPool("fco-shop-otp").connect();
  let transactionOpen = false;
  try {
    await client.query("begin");
    transactionOpen = true;
    await client.query("set local role fco_app");
    await client.query("select iam.invalidate_otp($1::uuid)", [requestId]);
    await client.query("commit");
    transactionOpen = false;
  } catch (error) {
    if (transactionOpen) {
      await rollbackOrThrow(client, error);
    }
    throw error;
  } finally {
    client.release();
  }
}

export class MockSmsProvider implements ISmsProvider {
  async sendOtp(delivery: OtpDelivery): Promise<void> {
    if (
      process.env.NODE_ENV === "production" &&
      process.env.FCO_E2E_MODE !== "true"
    ) {
      throw new Error("MockSmsProvider is only available in development and E2E.");
    }

    const client = await getPostgresPool("fco-shop-mock-sms").connect();
    let transactionOpen = false;
    try {
      await client.query("begin");
      transactionOpen = true;
      await client.query("set local role fco_app");
      await client.query("select iam.spool_otp($1::uuid, $2::text)", [
        delivery.requestId,
        delivery.code,
      ]);
      await client.query("commit");
      transactionOpen = false;
    } catch (error) {
      if (transactionOpen) {
        await rollbackOrThrow(client, error);
      }
      throw error;
    } finally {
      client.release();
    }
  }
}

export function createSmsProvider(): ISmsProvider {
  const providerName = process.env.FCO_SMS_PROVIDER?.trim();
  const mockAllowed =
    process.env.NODE_ENV !== "production" || process.env.FCO_E2E_MODE === "true";
  if (
    (providerName === "mock" && mockAllowed) ||
    (!providerName && mockAllowed)
  ) {
    return new MockSmsProvider();
  }

  throw new Error(
    "No production SMS provider is configured; customer OTP delivery is unavailable.",
  );
}

export async function requestCustomerOtp(
  mobile: string,
  ip: string | null,
  smsProvider: ISmsProvider,
): Promise<void> {
  if (!/^09[0-9]{9}$/.test(mobile)) {
    throw new TypeError("Customer mobile number has an invalid format.");
  }

  const code = String(randomInt(0, 1_000_000)).padStart(6, "0");
  const client = await getPostgresPool("fco-shop-otp").connect();
  let transactionOpen = false;
  let requestId: string;
  try {
    await client.query("begin");
    transactionOpen = true;
    await client.query("set local role fco_app");
    const result = await client.query<OtpRequestRow>(
      "select iam.request_otp($1::text, 'login', $2::bytea, $3::inet) as request_id",
      [mobile, hashOtp(mobile, code), ip],
    );
    const row = result.rows[0];
    if (!row) {
      throw new Error("OTP request did not return a request identifier.");
    }
    requestId = row.request_id;
    await client.query("commit");
    transactionOpen = false;
  } catch (error) {
    if (transactionOpen) {
      await rollbackOrThrow(client, error);
    }
    throw error;
  } finally {
    client.release();
  }

  try {
    await smsProvider.sendOtp({ requestId, mobile, code });
  } catch (deliveryError) {
    try {
      await invalidateOtp(requestId);
    } catch (invalidationError) {
      throw new AggregateError(
        [deliveryError, invalidationError],
        "OTP delivery failed and the OTP request could not be invalidated.",
      );
    }
    throw deliveryError;
  }
}

export async function verifyCustomerOtp(
  mobile: string,
  code: string,
  ip: string | null,
  userAgent: string | null,
  guestCartId: string | null,
  guestCartItems: GuestCartLine[],
): Promise<
  | { kind: "invalid" }
  | { kind: "locked" }
  | { kind: "authenticated"; session: CustomerLoginResult }
> {
  if (!/^09[0-9]{9}$/.test(mobile) || !/^[0-9]{6}$/.test(code)) {
    return { kind: "invalid" };
  }

  const client = await getPostgresPool("fco-shop-login").connect();
  let transactionOpen = false;
  try {
    await client.query("begin");
    transactionOpen = true;
    await client.query("set local role fco_app");
    await client.query(
      "select pg_advisory_xact_lock(hashtextextended($1::text, 0))",
      [mobile],
    );
    const verified = await client.query<OtpVerificationRow>(
      "select outcome, request_id from iam.verify_otp($1::text, 'login', $2::bytea)",
      [mobile, hashOtp(mobile, code)],
    );
    const outcome = verified.rows[0]?.outcome;
    if (outcome !== "ok") {
      await client.query("commit");
      transactionOpen = false;
      return { kind: outcome === "locked" ? "locked" : "invalid" };
    }

    const customer = await client.query<CustomerRow>(
      `select id
         from iam.users
        where mobile = $1
          and status = 'active'
          and archived_at is null
        limit 1`,
      [mobile],
    );
    const userId = customer.rows[0]?.id;
    if (!userId) {
      await client.query("commit");
      transactionOpen = false;
      return { kind: "invalid" };
    }

    const token = createSessionToken();
    const tokenHash = hashSessionToken(token);
    const sessionResult = await client.query<CustomerSessionRow>(
      `select iam.start_session($1::uuid, $2::bytea, $3::inet, $4::text) as session_id`,
      [userId, tokenHash, ip, userAgent],
    );
    const sessionId = sessionResult.rows[0]?.session_id;
    if (!sessionId) {
      throw new Error("Customer session creation did not return a session identifier.");
    }
    const expiryResult = await client.query<{ expires_at: Date }>(
      "select expires_at from iam.sessions where id = $1::uuid",
      [sessionId],
    );
    const expiresAt = expiryResult.rows[0]?.expires_at;
    if (!(expiresAt instanceof Date) || Number.isNaN(expiresAt.getTime())) {
      throw new Error("Customer session did not return a valid expiry time.");
    }

    if (guestCartId) {
      await mergeGuestCart(client, guestCartId, userId, guestCartItems);
    }

    await client.query("commit");
    transactionOpen = false;
    return {
      kind: "authenticated",
      session: {
        userId,
        token,
        expiresAt,
        mergedGuestCartId: guestCartId,
      },
    };
  } catch (error) {
    if (transactionOpen) {
      await rollbackOrThrow(client, error);
    }
    if (sqlState(error) === "28000") {
      return { kind: "invalid" };
    }
    throw error;
  } finally {
    client.release();
  }
}

export function customerSessionTokenFromRequest(request: Request): string | null {
  const cookie = request.headers.get("cookie");
  if (!cookie) {
    return null;
  }

  for (const part of cookie.split(";")) {
    const separator = part.indexOf("=");
    if (
      separator < 0 ||
      part.slice(0, separator).trim() !== CUSTOMER_SESSION_COOKIE
    ) {
      continue;
    }
    return part.slice(separator + 1).trim() || null;
  }

  return null;
}

export async function resolveCustomerSession(
  token: string,
  touch = true,
): Promise<{ sid: string; uid: string } | null> {
  if (!/^[A-Za-z0-9_-]{43}$/.test(token)) {
    return null;
  }

  const client = await getPostgresPool("fco-shop-session").connect();
  let transactionOpen = false;
  try {
    await client.query("begin");
    transactionOpen = true;
    await client.query("set local role fco_app");
    const result = await client.query<{ sid: string; uid: string }>(
      "select sid, uid from iam.authenticate($1::bytea, $2::boolean)",
      [hashSessionToken(token), touch],
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
