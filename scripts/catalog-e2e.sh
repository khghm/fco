#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="${FCO_PG_CONTAINER:-fco-postgres}"
DB_USER="${POSTGRES_USER:-fco}"
PSQL_BIN="${PSQL:-}"
ADMIN_DB="${FCO_E2E_ADMIN_DB:-postgres}"
DB_NAME="${FCO_E2E_DB_NAME:-fco_catalog_e2e_$(date -u +%Y%m%d%H%M%S)_$$}"
SEED="$ROOT/packages/infrastructure/tests/fixtures/catalog_e2e_seed.sql"

die() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

[[ "$DB_NAME" =~ ^[A-Za-z0-9_]+$ ]] || die "نام دیتابیس آزمون نامعتبر است"
[[ -n "${DATABASE_URL:-}" ]] || die "DATABASE_URL باید به دیتابیس مدیریتی PostgreSQL اشاره کند"

if [[ -z "$PSQL_BIN" ]]; then
  docker inspect "$CONTAINER" >/dev/null 2>&1 || die "کانتینر $CONTAINER در دسترس نیست؛ یا PSQL=psql تنظیم کنید"
fi

run_psql() {
  local db="$1"
  shift
  if [[ -n "$PSQL_BIN" ]]; then
    # PSQL may include connection options, matching scripts/db-migrate.sh.
    # shellcheck disable=SC2086
    $PSQL_BIN -X -v ON_ERROR_STOP=1 -q -d "$db" "$@"
  else
    docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -q \
      -U "$DB_USER" -d "$db" "$@"
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
export DATABASE_URL="$(
  DATABASE_URL="$DATABASE_URL" DB_NAME="$DB_NAME" node -e '
    const url = new URL(process.env.DATABASE_URL);
    url.pathname = `/${process.env.DB_NAME}`;
    process.stdout.write(url.toString());
  '
)"
export DATABASE_SSL="${DATABASE_SSL:-false}"
export FCO_E2E_DATABASE_URL="$DATABASE_URL"
export REDIS_URL="${FCO_E2E_REDIS_URL:-redis://127.0.0.1:6379}"
export SESSION_TOKEN_PEPPER="$(node -e 'process.stdout.write(require("node:crypto").randomBytes(48).toString("base64url"))')"
export OTP_CODE_PEPPER="$(node -e 'process.stdout.write(require("node:crypto").randomBytes(48).toString("base64url"))')"
export FCO_MOCK_PAYMENT_SECRET="$(node -e 'process.stdout.write(require("node:crypto").randomBytes(48).toString("base64url"))')"
export FCO_SMS_PROVIDER=mock
export FCO_E2E_MODE=true
if [[ "${FCO_E2E_EXTERNAL_S3:-false}" = "true" ]]; then
  [[ -n "${S3_ENDPOINT:-}" && -n "${S3_ACCESS_KEY:-}" && -n "${S3_SECRET_KEY:-}" ]] \
    || die "S3_ENDPOINT، S3_ACCESS_KEY و S3_SECRET_KEY برای S3 خارجی الزامی‌اند"
  export S3_BUCKET="${S3_BUCKET:-fco-catalog-e2e}"
  export S3_REGION="${S3_REGION:-us-east-1}"
else
  S3_PORT="${FCO_E2E_S3_PORT:-$(
    node -e '
      const server = require("node:net").createServer();
      server.listen(0, "127.0.0.1", () => {
        process.stdout.write(String(server.address().port));
        server.close();
      });
    '
  )}"
  [[ "$S3_PORT" =~ ^[0-9]+$ ]] || die "انتخاب پورت S3 E2E ناموفق بود"
  export S3_E2E_PORT="$S3_PORT"
  export S3_ENDPOINT="http://127.0.0.1:$S3_PORT"
  export S3_BUCKET="${FCO_E2E_S3_BUCKET:-fco-catalog-e2e}"
  export S3_REGION="${FCO_E2E_S3_REGION:-us-east-1}"
  export S3_ACCESS_KEY=S3RVER
  export S3_SECRET_KEY=S3RVER
fi
export CATALOG_RATE_LIMIT_POINTS=20
export TRUST_PROXY=false

printf 'E2E database: %s\n' "$DB_NAME"
bash "$ROOT/scripts/db-migrate.sh" up

if [[ -n "$PSQL_BIN" ]]; then
  run_psql "$DB_NAME" -f "$SEED"
else
  docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -q \
    -U "$DB_USER" -d "$DB_NAME" -f - < "$SEED"
fi

npm run lint
npm run typecheck
npm test
npm run build

PORT="${FCO_E2E_PORT:-$(
  node -e '
    const server = require("node:net").createServer();
    server.listen(0, "127.0.0.1", () => {
      process.stdout.write(String(server.address().port));
      server.close();
    });
  '
)}"
[[ "$PORT" =~ ^[0-9]+$ ]] || die "انتخاب پورت E2E ناموفق بود"

SERVER_LOG="$(mktemp)"
S3_LOG="$(mktemp)"
SERVER_PID=""
S3_PID=""
cleanup() {
  local status=$?
  trap - EXIT
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [[ -n "$S3_PID" ]]; then
    kill "$S3_PID" 2>/dev/null || true
    wait "$S3_PID" 2>/dev/null || true
  fi
  if [[ "$status" -ne 0 ]]; then
    cat "$SERVER_LOG" >&2
    cat "$S3_LOG" >&2
  fi
  rm -f "$SERVER_LOG" "$S3_LOG"
  exit "$status"
}
trap cleanup EXIT

if [[ "${FCO_E2E_EXTERNAL_S3:-false}" != "true" ]]; then
  node "$ROOT/scripts/catalog-s3-e2e-server.mjs" >"$S3_LOG" 2>&1 &
  S3_PID=$!
  for _ in $(seq 1 50); do
    if node -e '
      const socket = require("node:net").connect(Number(process.env.S3_E2E_PORT), "127.0.0.1");
      socket.on("connect", () => { socket.end(); process.exit(0); });
      socket.on("error", () => process.exit(1));
    '; then
      break
    fi
    sleep 0.2
  done
  kill -0 "$S3_PID" 2>/dev/null || die "S3 E2E server did not start"
fi
node "$ROOT/scripts/catalog-media-e2e-setup.mjs"

(
  cd "$ROOT/apps/shop"
  export FCO_HOST=127.0.0.1
  export PORT
  exec node server.mjs --prod
) >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!
export FCO_E2E_BASE_URL="http://127.0.0.1:$PORT"
node "$ROOT/scripts/catalog-e2e-http.mjs"
node "$ROOT/scripts/cart-auth-e2e-http.mjs"
node "$ROOT/scripts/checkout-e2e-http.mjs"
