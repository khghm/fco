import { Pool } from "pg";

let pool: Pool | undefined;

export function getPostgresPool(applicationName: string): Pool {
  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) {
    throw new Error("DATABASE_URL must be configured before querying PostgreSQL.");
  }

  pool ??= new Pool({
    connectionString,
    max: 10,
    connectionTimeoutMillis: 5000,
    idleTimeoutMillis: 30000,
    application_name: applicationName,
    ssl: process.env.DATABASE_SSL === "true" ? { rejectUnauthorized: true } : false,
  });

  return pool;
}
