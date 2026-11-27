import { createCipheriv, randomBytes } from "node:crypto";
import argon2 from "argon2";
import { Client } from "pg";

const databaseUrl = process.env.DATABASE_URL;
const password = process.env.FCO_E2E_STAFF_PASSWORD;
const encryptionKey = process.env.MFA_ENCRYPTION_KEY;
if (!databaseUrl || !password || !encryptionKey) {
  throw new Error("DATABASE_URL, FCO_E2E_STAFF_PASSWORD, and MFA_ENCRYPTION_KEY are required.");
}

const adminId = "92000000-0000-4000-8000-000000000001";
const operatorId = "92000000-0000-4000-8000-000000000002";
const brandId = "92000000-0000-4000-8000-000000000003";
const categoryId = "92000000-0000-4000-8000-000000000004";
const setupStaffId = "92000000-0000-4000-8000-000000000005";
const totpSecret = "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ";
const client = new Client({ connectionString: databaseUrl });

function encryptMfaSecret(secret) {
  const key = Buffer.from(encryptionKey, "base64");
  if (key.length !== 32) {
    throw new Error("MFA_ENCRYPTION_KEY must decode to 32 bytes.");
  }
  const iv = randomBytes(12);
  const cipher = createCipheriv("aes-256-gcm", key, iv);
  const encrypted = Buffer.concat([
    cipher.update(secret, "utf8"),
    cipher.final(),
  ]);
  return Buffer.concat([
    Buffer.from([1]),
    iv,
    cipher.getAuthTag(),
    encrypted,
  ]);
}

await client.connect();
try {
  await client.query("begin");
  const passwordHash = await argon2.hash(password, {
    type: argon2.argon2id,
    memoryCost: 65536,
    timeCost: 3,
    parallelism: 1,
  });
  const email = process.env.FCO_E2E_STAFF_EMAIL ?? "admin-e2e@fco.invalid";
  const operatorEmail = process.env.FCO_E2E_OPERATOR_EMAIL ?? "operator-e2e@fco.invalid";
  const setupStaffEmail = process.env.FCO_E2E_SETUP_EMAIL ?? "mfa-setup-e2e@fco.invalid";
  await client.query(
    `insert into iam.users (id, mobile, email, full_name, password_hash, status)
     values
       ($1::uuid, '09129999001', $4::citext, 'E2E مدیر فروش', $7, 'active'),
       ($2::uuid, '09129999002', $5::citext, 'E2E اپراتور', $7, 'active'),
       ($3::uuid, '09129999003', $6::citext, 'E2E مدیر نیازمند MFA', $7, 'active')`,
    [adminId, operatorId, setupStaffId, email, operatorEmail, setupStaffEmail, passwordHash],
  );
  await client.query(
    `insert into iam.user_roles (user_id, role_id)
     select $1::uuid, id from iam.roles where key = 'R-SALES'
     union all
     select $2::uuid, id from iam.roles where key = 'R-OP'
     union all
     select $3::uuid, id from iam.roles where key = 'R-SALES'`,
    [adminId, operatorId, setupStaffId],
  );
  await client.query(
    `insert into iam.mfa_factors (user_id, kind, secret_ciphertext, confirmed_at)
     values ($1::uuid, 'totp', $2::bytea, now())`,
    [adminId, encryptMfaSecret(totpSecret)],
  );
  await client.query(
    `insert into cat.brands (id, slug, title) values ($1::uuid, 'admin-e2e-brand', 'E2E Brand')`,
    [brandId],
  );
  await client.query(
    `insert into cat.categories (id, slug, title) values ($1::uuid, 'admin-e2e-category', 'E2E Category')`,
    [categoryId],
  );

  const product = await client.query(
    `select cat.product_create(
       $1::uuid, 'admin-e2e-seeded-product', 'E2E Seeded Product',
       null, $2::uuid, $3::uuid, '{}'::jsonb, 'admin-e2e-seed-product'
     ) as id`,
    [adminId, brandId, categoryId],
  );
  const variant = await client.query(
    "select cat.variant_create($1::uuid, $2::uuid, 'ADMIN-E2E-SKU') as id",
    [adminId, product.rows[0].id],
  );
  await client.query(
    `select pricing.price_set(
       $1::uuid, $2::uuid, 100000, null, now() - interval '1 day',
       'web', 'admin-e2e-seed-price'
     )`,
    [adminId, variant.rows[0].id],
  );
  await client.query("commit");
  process.stdout.write(
    JSON.stringify({
      adminId,
      operatorId,
      setupStaffId,
      email,
      operatorEmail,
      setupStaffEmail,
      productId: product.rows[0].id,
      variantId: variant.rows[0].id,
    }),
  );
} catch (error) {
  await client.query("rollback");
  throw error;
} finally {
  await client.end();
}
