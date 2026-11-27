#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="${FCO_PG_CONTAINER:-fco-postgres}"
DB_USER="${POSTGRES_USER:-fco}"
PSQL_BIN="${PSQL:-}"
ADMIN_DB="${FCO_E2E_ADMIN_DB:-postgres}"
DB_NAME="${FCO_ADMIN_E2E_DB_NAME:-fco_admin_e2e_$(date -u +%Y%m%d%H%M%S)_$$}"

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "نام دیتابیس آزمون نامعتبر است"
[[ -n "${DATABASE_URL:-}" ]] || die "DATABASE_URL باید به PostgreSQL مدیریتی اشاره کند"
if [[ -z "$PSQL_BIN" ]]; then
  docker inspect "$CONTAINER" >/dev/null 2>&1 || die "کانتینر $CONTAINER در دسترس نیست؛ یا PSQL تنظیم کنید"
fi

run_psql() {
  local db="$1"
  shift
  if [[ -n "$PSQL_BIN" ]]; then
    # shellcheck disable=SC2086
    $PSQL_BIN -X -v ON_ERROR_STOP=1 -q -d "$db" "$@"
  else
    docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -q -U "$DB_USER" -d "$db" "$@"
  fi
}

existing="$(run_psql "$ADMIN_DB" -tA -c "select 1 from pg_database where datname = '$DB_NAME'")"
[[ -z "$existing" ]] || die "دیتابیس $DB_NAME از قبل وجود دارد؛ آن را بازنویسی نمی‌کنم"
run_psql "$ADMIN_DB" -c "create database \"$DB_NAME\""

export POSTGRES_DB="$DB_NAME"
export PGDATABASE="$DB_NAME"
export FCO_PG_CONTAINER="$CONTAINER"
export POSTGRES_USER="$DB_USER"
export PSQL="$PSQL_BIN"
export REDIS_URL="${REDIS_URL:-redis://127.0.0.1:6379}"
export DATABASE_URL="$(
  DATABASE_URL="$DATABASE_URL" DB_NAME="$DB_NAME" node -e '
    const url = new URL(process.env.DATABASE_URL);
    url.pathname = `/${process.env.DB_NAME}`;
    process.stdout.write(url.toString());
  '
)"
export SESSION_TOKEN_PEPPER="$(node -e 'process.stdout.write(require("node:crypto").randomBytes(48).toString("base64url"))')"
export MFA_ENCRYPTION_KEY="$(node -e 'process.stdout.write(require("node:crypto").randomBytes(32).toString("base64"))')"
export FCO_E2E_STAFF_PASSWORD="Temp-$(node -e 'process.stdout.write(require("node:crypto").randomBytes(24).toString("base64url"))')-Aa1!"
export FCO_E2E_STAFF_EMAIL="${FCO_E2E_STAFF_EMAIL:-admin-${DB_NAME}@fco.invalid}"
export FCO_E2E_OPERATOR_EMAIL="${FCO_E2E_OPERATOR_EMAIL:-operator-${DB_NAME}@fco.invalid}"
export FCO_E2E_SETUP_EMAIL="${FCO_E2E_SETUP_EMAIL:-setup-${DB_NAME}@fco.invalid}"
export TRUST_PROXY=false

printf 'Admin API E2E database: %s\n' "$DB_NAME"
bash "$ROOT/scripts/db-migrate.sh" up
SEED_RESULT="$(node "$ROOT/scripts/admin-api-e2e-seed.mjs")"
export FCO_E2E_ADMIN_ID="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).adminId)' "$SEED_RESULT")"
export FCO_E2E_OPERATOR_ID="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).operatorId)' "$SEED_RESULT")"
export FCO_E2E_SETUP_STAFF_ID="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).setupStaffId)' "$SEED_RESULT")"
export FCO_E2E_OPERATOR_EMAIL="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).operatorEmail)' "$SEED_RESULT")"
export FCO_E2E_SETUP_EMAIL="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).setupStaffEmail)' "$SEED_RESULT")"
export FCO_E2E_PRODUCT_ID="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).productId)' "$SEED_RESULT")"
export FCO_E2E_VARIANT_ID="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).variantId)' "$SEED_RESULT")"

npm --workspace @fco/admin run build

PORT="${FCO_ADMIN_E2E_PORT:-$(
  node -e '
    const server = require("node:net").createServer();
    server.listen(0, "127.0.0.1", () => {
      process.stdout.write(String(server.address().port));
      server.close();
    });
  '
)}"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "انتخاب پورت E2E ناموفق بود"
export FCO_ADMIN_E2E_BASE_URL="http://127.0.0.1:$PORT"

SERVER_LOG="$(mktemp)"
SERVER_PID=""
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$SERVER_PID" && "${FCO_ADMIN_E2E_EXTERNAL_CLEANUP:-false}" != "true" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ "$status" -ne 0 ]]; then
    cat "$SERVER_LOG" >&2
  fi
  if [[ "${FCO_ADMIN_E2E_EXTERNAL_CLEANUP:-false}" = "true" ]]; then
    printf 'ADMIN_E2E_SERVER_LOG=%s\n' "$(cygpath -w "$SERVER_LOG" 2>/dev/null || printf '%s' "$SERVER_LOG")"
  else
    rm -f "$SERVER_LOG"
  fi
  exit "$status"
}
trap cleanup EXIT

(
  cd "$ROOT/apps/admin"
  exec node "$ROOT/node_modules/next/dist/bin/next" start --hostname 127.0.0.1 --port "$PORT"
) >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
node "$ROOT/scripts/admin-api-e2e-http.mjs"
