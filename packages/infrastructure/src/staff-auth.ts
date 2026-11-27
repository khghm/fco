import {
  createCipheriv,
  createDecipheriv,
  createHmac,
  randomBytes,
  timingSafeEqual,
} from "node:crypto";
import argon2 from "argon2";
import type { PoolClient, QueryResultRow } from "pg";
import { getPostgresPool } from "./postgres";
import { hashStaffSessionToken } from "./admin-session";

const ARGON2_OPTIONS = {
  type: argon2.argon2id,
  memoryCost: 65536,
  timeCost: 3,
  parallelism: 1,
} as const;
const TOTP_STEP_SECONDS = 30;
const TOTP_WINDOW_STEPS = 1;
const MFA_ENVELOPE_VERSION = 1;

export type StaffLoginResult =
  | { kind: "authenticated"; userId: string; token: string; expiresAt: Date }
  | { kind: "invalid_credentials" }
  | { kind: "mfa_required" }
  | { kind: "mfa_setup_required" }
  | { kind: "password_change_required" };

interface StaffLoginRow extends QueryResultRow {
  id: string;
  password_hash: string | null;
  status: "active" | "locked" | "disabled";
  must_change_password: boolean;
  mfa_required: boolean;
}

interface MfaFactorRow extends QueryResultRow {
  id: string;
  secret_ciphertext: Buffer;
  last_used_at: Date | null;
}

interface ExpiryRow extends QueryResultRow {
  expires_at: Date;
}

let dummyHashPromise: Promise<string> | undefined;

function getDummyHash(): Promise<string> {
  dummyHashPromise ??= argon2.hash("FCO dummy staff password", ARGON2_OPTIONS);
  return dummyHashPromise;
}

function mfaEncryptionKey(): Buffer {
  const encoded = process.env.MFA_ENCRYPTION_KEY;
  if (!encoded) {
    throw new Error("MFA_ENCRYPTION_KEY must be configured for MFA-protected staff roles.");
  }

  const key = Buffer.from(encoded, "base64");
  if (key.length !== 32 || key.toString("base64") !== encoded) {
    throw new Error("MFA_ENCRYPTION_KEY must be a canonical base64-encoded 32-byte key.");
  }
  return key;
}

function decodeBase32(secret: string): Buffer {
  const normalized = secret.toUpperCase().replace(/=+$/g, "");
  if (!normalized || !/^[A-Z2-7]+$/.test(normalized)) {
    throw new Error("MFA secret must be a valid base32 value.");
  }

  let bits = 0;
  let value = 0;
  const bytes: number[] = [];
  for (const character of normalized) {
    value = (value << 5) | "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".indexOf(character);
    bits += 5;
    if (bits >= 8) {
      bytes.push((value >>> (bits - 8)) & 0xff);
      bits -= 8;
    }
  }
  if (bytes.length < 10) {
    throw new Error("MFA secret must contain at least 80 bits.");
  }
  return Buffer.from(bytes);
}

function decryptMfaSecret(ciphertext: Buffer): string {
  if (ciphertext.length < 30 || ciphertext[0] !== MFA_ENVELOPE_VERSION) {
    throw new Error("Stored MFA secret has an unsupported envelope.");
  }
  const iv = ciphertext.subarray(1, 13);
  const tag = ciphertext.subarray(13, 29);
  const encrypted = ciphertext.subarray(29);
  const decipher = createDecipheriv("aes-256-gcm", mfaEncryptionKey(), iv);
  decipher.setAuthTag(tag);
  return Buffer.concat([decipher.update(encrypted), decipher.final()]).toString("utf8");
}

export function encryptMfaSecret(secret: string): Buffer {
  decodeBase32(secret);
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", mfaEncryptionKey(), iv);
  const encrypted = Buffer.concat([
    cipher.update(secret.toUpperCase().replace(/=+$/g, ""), "utf8"),
    cipher.final(),
  ]);
  return Buffer.concat([
    Buffer.from([MFA_ENVELOPE_VERSION]),
    iv,
    cipher.getAuthTag(),
    encrypted,
  ]);
}

function totpAtStep(secret: string, step: number): string {
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(step));
  const digest = createHmac("sha1", decodeBase32(secret)).update(counter).digest();
  const offset = digest[digest.length - 1] & 0x0f;
  const binary =
    ((digest[offset] & 0x7f) << 24) |
    ((digest[offset + 1] & 0xff) << 16) |
    ((digest[offset + 2] & 0xff) << 8) |
    (digest[offset + 3] & 0xff);
  return String(binary % 1_000_000).padStart(6, "0");
}

export function matchingTotpStep(
  secret: string,
  code: string,
  nowMilliseconds = Date.now(),
): number | null {
  if (!/^\d{6}$/.test(code)) {
    return null;
  }

  const currentStep = Math.floor(nowMilliseconds / 1000 / TOTP_STEP_SECONDS);
  for (let offset = TOTP_WINDOW_STEPS; offset >= -TOTP_WINDOW_STEPS; offset -= 1) {
    const step = currentStep + offset;
    if (step < 0) {
      continue;
    }
    const expected = Buffer.from(totpAtStep(secret, step));
    const actual = Buffer.from(code);
    if (timingSafeEqual(expected, actual)) {
      return step;
    }
  }
  return null;
}

export async function hashStaffPassword(password: string): Promise<string> {
  return argon2.hash(password, ARGON2_OPTIONS);
}

export async function verifyStaffPassword(
  hash: string | null,
  password: string,
): Promise<boolean> {
  if (!hash?.startsWith("$argon2id$v=19$")) {
    await argon2.verify(await getDummyHash(), password);
    return false;
  }
  return argon2.verify(hash, password);
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
    throw new AggregateError([cause, rollbackError], "Staff login transaction rollback failed.");
  }
}

async function markLoginFailure(client: PoolClient, userId: string): Promise<void> {
  await client.query("select iam.register_login_failure($1::uuid)", [userId]);
}

export async function loginStaff(input: {
  email: string;
  password: string;
  totp: string | null;
  userAgent: string | null;
  ip: string | null;
  requestId: string;
}): Promise<StaffLoginResult> {
  const client = await getPostgresPool("fco-admin").connect();
  let transactionOpen = false;
  try {
    await client.query("begin");
    transactionOpen = true;
    await client.query("set local role fco_app");

    const found = await client.query<{ id: string }>(
      "select id from iam.users where email = $1 and archived_at is null limit 1",
      [input.email],
    );
    const userId = found.rows[0]?.id;
    if (!userId) {
      await argon2.verify(await getDummyHash(), input.password);
      await client.query("rollback");
      transactionOpen = false;
      return { kind: "invalid_credentials" };
    }

    await client.query("select iam.unlock_if_expired($1::uuid)", [userId]);
    const result = await client.query<StaffLoginRow>(
      `select u.id, u.password_hash, u.status, u.must_change_password,
              (u.mfa_required or exists (
                select 1 from iam.user_roles ur
                join iam.roles r on r.id = ur.role_id
                where ur.user_id = u.id and r.requires_mfa
              )) as mfa_required
         from iam.users u
        where u.id = $1 and u.archived_at is null`,
      [userId],
    );
    const account = result.rows[0];
    if (!account || account.status === "disabled" || account.status === "locked") {
      await verifyStaffPassword(account?.password_hash ?? null, input.password);
      await client.query("rollback");
      transactionOpen = false;
      return { kind: "invalid_credentials" };
    }

    const passwordMatches = await verifyStaffPassword(
      account.password_hash,
      input.password,
    );
    if (!passwordMatches) {
      await markLoginFailure(client, account.id);
      await client.query("commit");
      transactionOpen = false;
      return { kind: "invalid_credentials" };
    }
    if (account.must_change_password) {
      await client.query("rollback");
      transactionOpen = false;
      return { kind: "password_change_required" };
    }

    if (account.mfa_required) {
      const factorResult = await client.query<MfaFactorRow>(
        `select id, secret_ciphertext, last_used_at
           from iam.mfa_factors
          where user_id = $1 and kind = 'totp'
            and confirmed_at is not null and disabled_at is null
          limit 1`,
        [account.id],
      );
      const factor = factorResult.rows[0];
      if (!factor) {
        await client.query("rollback");
        transactionOpen = false;
        return { kind: "mfa_setup_required" };
      }

      const secret = decryptMfaSecret(factor.secret_ciphertext);
      const matchedStep =
        input.totp === null
          ? null
          : matchingTotpStep(secret, input.totp);
      const stepTimestamp =
        matchedStep === null ? null : new Date(matchedStep * TOTP_STEP_SECONDS * 1000);
      if (
        stepTimestamp === null ||
        (factor.last_used_at !== null && stepTimestamp <= factor.last_used_at)
      ) {
        await markLoginFailure(client, account.id);
        await client.query("commit");
        transactionOpen = false;
        return { kind: "mfa_required" };
      }

      const marked = await client.query<{ id: string }>(
        `update iam.mfa_factors
            set last_used_at = $2
          where id = $1
            and (last_used_at is null or last_used_at < $2)
        returning id`,
        [factor.id, stepTimestamp],
      );
      if (!marked.rows[0]) {
        await markLoginFailure(client, account.id);
        await client.query("commit");
        transactionOpen = false;
        return { kind: "mfa_required" };
      }
    }

    await client.query("select iam.register_login_success($1::uuid)", [account.id]);
    const token = randomBytes(32).toString("base64url");
    const tokenHash = hashStaffSessionToken(token);
    const session = await client.query<{ sid: string }>(
      "select iam.start_session($1::uuid, $2::bytea, $3::inet, $4::text) as sid",
      [account.id, tokenHash, input.ip, input.userAgent],
    );
    const expiry = await client.query<ExpiryRow>(
      "select expires_at from iam.sessions where id = $1::uuid",
      [session.rows[0].sid],
    );
    await client.query(
      `select sys.audit_write(
         $1::uuid, 'auth.login', 'users', $1::uuid, null,
         jsonb_build_object('session_id', $2::uuid), null, null, $3::text
       )`,
      [account.id, session.rows[0].sid, input.requestId],
    );
    await client.query("commit");
    transactionOpen = false;
    return {
      kind: "authenticated",
      userId: account.id,
      token,
      expiresAt: expiry.rows[0].expires_at,
    };
  } catch (error) {
    if (transactionOpen) {
      await rollbackOrThrow(client, error);
    }
    if (sqlState(error) === "28000") {
      return { kind: "invalid_credentials" };
    }
    throw error;
  } finally {
    client.release();
  }
}
