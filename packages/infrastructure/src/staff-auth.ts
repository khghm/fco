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
  | { kind: "mfa_setup_required"; userId: string }
  | { kind: "password_change_required" };

export interface MfaEnrollmentResult {
  recoveryCodes: string[];
  session: { token: string; expiresAt: Date } | null;
}

const BASE32_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
const MFA_SETUP_CHALLENGE_TTL_SECONDS = 600;

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

function sessionPepper(): string {
  const pepper = process.env.SESSION_TOKEN_PEPPER;
  if (!pepper || Buffer.byteLength(pepper, "utf8") < 32) {
    throw new Error("SESSION_TOKEN_PEPPER must contain at least 32 bytes.");
  }
  return pepper;
}

function hmacToken(payload: string): Buffer {
  return createHmac("sha256", sessionPepper()).update(payload, "utf8").digest();
}

export function createMfaSetupChallenge(
  userId: string,
  nowMilliseconds = Date.now(),
): { token: string; expiresAt: Date } {
  const expiresAt = new Date(nowMilliseconds + MFA_SETUP_CHALLENGE_TTL_SECONDS * 1000);
  const payload = `${userId}.${expiresAt.getTime()}.${randomBytes(16).toString("base64url")}`;
  const encodedPayload = Buffer.from(payload, "utf8").toString("base64url");
  const signature = hmacToken(`mfa-setup\0${encodedPayload}`).toString("base64url");
  return { token: `${encodedPayload}.${signature}`, expiresAt };
}

export function verifyMfaSetupChallenge(
  token: string,
  nowMilliseconds = Date.now(),
): string | null {
  const [encodedPayload, suppliedSignature, extra] = token.split(".");
  if (!encodedPayload || !suppliedSignature || extra !== undefined) {
    return null;
  }
  let actualSignature: Buffer;
  let payload: string;
  try {
    actualSignature = Buffer.from(suppliedSignature, "base64url");
    payload = Buffer.from(encodedPayload, "base64url").toString("utf8");
  } catch {
    return null;
  }
  const expectedSignature = hmacToken(`mfa-setup\0${encodedPayload}`);
  if (
    actualSignature.length !== expectedSignature.length ||
    !timingSafeEqual(actualSignature, expectedSignature)
  ) {
    return null;
  }
  const [userId, expiresAtText, nonce, extraPayload] = payload.split(".");
  const expiresAt = Number(expiresAtText);
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      userId ?? "",
    ) ||
    !/^[A-Za-z0-9_-]{22}$/.test(nonce ?? "") ||
    extraPayload !== undefined ||
    !Number.isSafeInteger(expiresAt) ||
    expiresAt <= nowMilliseconds
  ) {
    return null;
  }
  return userId;
}

function generateRecoveryCode(): string {
  const bits = [...randomBytes(10)]
    .map((byte) => byte.toString(2).padStart(8, "0"))
    .join("");
  const value = Array.from({ length: 16 }, (_, index) =>
    BASE32_ALPHABET[Number.parseInt(bits.slice(index * 5, index * 5 + 5), 2)],
  ).join("");
  return value.match(/.{4}/g)?.join("-") ?? value;
}

function normalizeRecoveryCode(value: string): string | null {
  const normalized = value.trim().toUpperCase();
  return /^[A-Z2-7]{4}(?:-[A-Z2-7]{4}){3}$/.test(normalized)
    ? normalized.replaceAll("-", "")
    : null;
}

export function hashMfaRecoveryCode(value: string): Buffer | null {
  const normalized = normalizeRecoveryCode(value);
  return normalized
    ? createHmac("sha256", sessionPepper()).update(normalized, "utf8").digest()
    : null;
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

export async function getStaffMfaStatus(userId: string): Promise<{
  enabled: boolean;
  pending: boolean;
  recoveryCodesRemaining: number;
}> {
  const client = await getPostgresPool("fco-admin").connect();
  try {
    await client.query("begin read only");
    await client.query("set local role fco_app");
    const result = await client.query<{
      enabled: boolean;
      pending: boolean;
      recovery_codes_remaining: string;
    }>(
      `select exists (
         select 1 from iam.mfa_factors
          where user_id = $1 and kind = 'totp'
            and confirmed_at is not null and disabled_at is null
       ) as enabled,
       exists (
         select 1 from iam.mfa_factors
          where user_id = $1 and kind = 'totp'
            and confirmed_at is null and disabled_at is null
       ) as pending,
       count(*) filter (
         where kind = 'recovery_code' and confirmed_at is not null and disabled_at is null
       )::text as recovery_codes_remaining
       from iam.mfa_factors where user_id = $1`,
      [userId],
    );
    await client.query("commit");
    const row = result.rows[0];
    return {
      enabled: row?.enabled ?? false,
      pending: row?.pending ?? false,
      recoveryCodesRemaining: Number(row?.recovery_codes_remaining ?? "0"),
    };
  } catch (error) {
    try {
      await client.query("rollback");
    } catch (rollbackError) {
      throw new AggregateError([error, rollbackError], "MFA status transaction rollback failed.");
    }
    throw error;
  } finally {
    client.release();
  }
}

export async function beginStaffMfaEnrollment(
  userId: string,
): Promise<
  | { kind: "started"; secret: string; otpauthUrl: string }
  | { kind: "already_enabled" }
  | { kind: "account_unavailable" }
> {
  const secret = [...randomBytes(20)]
    .map((byte) => byte.toString(2).padStart(8, "0"))
    .join("")
    .match(/.{1,5}/g)
    ?.map((group) => BASE32_ALPHABET[Number.parseInt(group.padEnd(5, "0"), 2)])
    .join("") ?? "";
  const encryptedSecret = encryptMfaSecret(secret);
  const client = await getPostgresPool("fco-admin").connect();
  try {
    await client.query("begin");
    await client.query("set local role fco_app");
    const user = await client.query<{ email: string; status: string }>(
      `select email::text as email, status
         from iam.users where id = $1 and archived_at is null`,
      [userId],
    );
    if (!user.rows[0] || user.rows[0].status !== "active") {
      await client.query("rollback");
      return { kind: "account_unavailable" };
    }
    const active = await client.query<{ id: string }>(
      `select id from iam.mfa_factors
        where user_id = $1 and kind = 'totp'
          and confirmed_at is not null and disabled_at is null
        limit 1`,
      [userId],
    );
    if (active.rows[0]) {
      await client.query("commit");
      return { kind: "already_enabled" };
    }
    await client.query(
      `update iam.mfa_factors set disabled_at = now()
        where user_id = $1 and kind = 'totp'
          and confirmed_at is null and disabled_at is null`,
      [userId],
    );
    await client.query(
      `insert into iam.mfa_factors (user_id, kind, secret_ciphertext, label)
       values ($1, 'totp', $2, $3)`,
      [userId, encryptedSecret, user.rows[0].email.slice(0, 254)],
    );
    await client.query("commit");
    const label = encodeURIComponent(`FCO:${user.rows[0].email}`);
    const issuer = encodeURIComponent("FCO");
    return {
      kind: "started",
      secret,
      otpauthUrl:
        `otpauth://totp/${label}?secret=${secret}&issuer=${issuer}` +
        "&algorithm=SHA1&digits=6&period=30",
    };
  } catch (error) {
    try {
      await client.query("rollback");
    } catch (rollbackError) {
      throw new AggregateError([error, rollbackError], "MFA enrollment transaction rollback failed.");
    }
    throw error;
  } finally {
    client.release();
  }
}

export async function confirmStaffMfaEnrollment(input: {
  userId: string;
  code: string;
  requestId: string;
  issueSession: boolean;
  ip: string | null;
  userAgent: string | null;
}): Promise<
  | { kind: "invalid_code" }
  | { kind: "not_pending" }
  | {
      kind: "confirmed";
      recoveryCodes: string[];
      session: { token: string; expiresAt: Date } | null;
    }
> {
  const client = await getPostgresPool("fco-admin").connect();
  try {
    await client.query("begin");
    await client.query("set local role fco_app");
    const pending = await client.query<MfaFactorRow>(
      `select id, secret_ciphertext, last_used_at
         from iam.mfa_factors
        where user_id = $1 and kind = 'totp'
          and confirmed_at is null and disabled_at is null
        order by created_at desc
        limit 1
        for update`,
      [input.userId],
    );
    const factor = pending.rows[0];
    if (!factor) {
      await client.query("rollback");
      return { kind: "not_pending" };
    }
    const matchedStep = matchingTotpStep(
      decryptMfaSecret(factor.secret_ciphertext),
      input.code,
    );
    const stepTimestamp =
      matchedStep === null ? null : new Date(matchedStep * TOTP_STEP_SECONDS * 1000);
    if (
      stepTimestamp === null ||
      (factor.last_used_at !== null && stepTimestamp <= factor.last_used_at)
    ) {
      await client.query("rollback");
      return { kind: "invalid_code" };
    }
    const confirmed = await client.query<{ id: string }>(
      `update iam.mfa_factors
          set confirmed_at = now(), last_used_at = $2
        where id = $1 and confirmed_at is null and disabled_at is null
      returning id`,
      [factor.id, stepTimestamp],
    );
    if (!confirmed.rows[0]) {
      await client.query("rollback");
      return { kind: "not_pending" };
    }

    await client.query(
      `update iam.mfa_factors set disabled_at = now()
        where user_id = $1 and kind = 'recovery_code' and disabled_at is null`,
      [input.userId],
    );
    const recoveryCodes = Array.from({ length: 10 }, generateRecoveryCode);
    for (const recoveryCode of recoveryCodes) {
      const codeHash = hashMfaRecoveryCode(recoveryCode);
      if (!codeHash) {
        throw new Error("Generated MFA recovery code is invalid.");
      }
      await client.query(
        `insert into iam.mfa_factors
           (user_id, kind, secret_ciphertext, label, confirmed_at)
         values ($1, 'recovery_code', $2, 'recovery', now())`,
        [input.userId, codeHash],
      );
    }

    let session: MfaEnrollmentResult["session"] = null;
    if (input.issueSession) {
      await client.query("select iam.register_login_success($1::uuid)", [input.userId]);
      const token = randomBytes(32).toString("base64url");
      const created = await client.query<{ sid: string }>(
        `select iam.start_session($1::uuid, $2::bytea, $3::inet, $4::text) as sid`,
        [
          input.userId,
          hashStaffSessionToken(token),
          input.ip,
          input.userAgent,
        ],
      );
      const expiry = await client.query<ExpiryRow>(
        "select expires_at from iam.sessions where id = $1::uuid",
        [created.rows[0].sid],
      );
      session = { token, expiresAt: expiry.rows[0].expires_at };
      await client.query(
        `select sys.audit_write(
           $1::uuid, 'auth.login', 'users', $1::uuid, null,
           jsonb_build_object('session_id', $2::uuid, 'mfa_setup', true),
           null, null, $3::text
         )`,
        [input.userId, created.rows[0].sid, input.requestId],
      );
    }
    await client.query(
      `select sys.audit_write(
         $1::uuid, 'auth.mfa_enabled', 'mfa_factors', $2::uuid, null,
         jsonb_build_object('recovery_codes_issued', $3::integer),
         null, null, $4::text
       )`,
      [input.userId, factor.id, recoveryCodes.length, input.requestId],
    );
    await client.query("commit");
    return { kind: "confirmed", recoveryCodes, session };
  } catch (error) {
    try {
      await client.query("rollback");
    } catch (rollbackError) {
      throw new AggregateError([error, rollbackError], "MFA confirmation transaction rollback failed.");
    }
    throw error;
  } finally {
    client.release();
  }
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
  recoveryCode: string | null;
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
        return { kind: "mfa_setup_required", userId: account.id };
      }

      const matchedStep =
        input.totp === null
          ? null
          : matchingTotpStep(decryptMfaSecret(factor.secret_ciphertext), input.totp);
      const stepTimestamp =
        matchedStep === null ? null : new Date(matchedStep * TOTP_STEP_SECONDS * 1000);
      let authenticatedWithMfa = false;
      if (
        stepTimestamp !== null &&
        (factor.last_used_at === null || stepTimestamp > factor.last_used_at)
      ) {
        const marked = await client.query<{ id: string }>(
          `update iam.mfa_factors
              set last_used_at = $2
            where id = $1
              and (last_used_at is null or last_used_at < $2)
          returning id`,
          [factor.id, stepTimestamp],
        );
        authenticatedWithMfa = Boolean(marked.rows[0]);
      }

      if (!authenticatedWithMfa && input.recoveryCode !== null) {
        const codeHash = hashMfaRecoveryCode(input.recoveryCode);
        if (codeHash) {
          const used = await client.query<{ id: string }>(
            `update iam.mfa_factors
                set disabled_at = now()
              where id = (
                select id from iam.mfa_factors
                 where user_id = $1 and kind = 'recovery_code'
                   and secret_ciphertext = $2
                   and confirmed_at is not null and disabled_at is null
                 order by created_at
                 limit 1
                 for update
              )
            returning id`,
            [account.id, codeHash],
          );
          const recoveryFactor = used.rows[0];
          if (recoveryFactor) {
            authenticatedWithMfa = true;
            await client.query(
              `select sys.audit_write(
                 $1::uuid, 'auth.mfa_recovery_used', 'mfa_factors', $2::uuid,
                 null, jsonb_build_object('single_use', true), null, null, $3::text
               )`,
              [account.id, recoveryFactor.id, input.requestId],
            );
          }
        }
      }

      if (!authenticatedWithMfa) {
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
