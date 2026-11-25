#!/usr/bin/env bash
# =============================================================================
# inv-concurrency-test.sh — BR-2 گام ۳: T-INV-01 (۱۰۰ هم‌زمان روی ۵ موجودی)
#
# ۱۰۰ کلاینت pgbench در یک پروسه، هر کدام دقیقاً یک رزرو یک‌واحدی. شروع
# تراکنش‌ها از یک پروسه است تا اسپاون شدن ۱۰۰ پروسه ویندوزی، پنجره بحرانی
# (خواندن موجودی → نوشتن رزرو) را مصنوعاً سریال نکند.
#
# انتظار: دقیقاً ۵ موفق، ۹۵ رد با FCO-1071، reserved=5 و available=0.
#
# اجرا:  bash scripts/inv-concurrency-test.sh
# متغیرها: FCO_PG_CONTAINER، POSTGRES_USER، FCO_INV_DB، FCO_INV_KEEP،
#         FCO_INV_THREADS، FCO_INV_REUSE_DB (دیتابیس آماده؛ فقط برای اثبات قرمز)
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="${FCO_PG_CONTAINER:-fco-postgres}"
DB_USER="${POSTGRES_USER:-fco}"
DB="${FCO_INV_DB:-fco_inv_conc}"
REQUESTS=100
UNITS=5
CLIENT_THREADS="${FCO_INV_THREADS:-20}"

WH="93000000-0000-0000-0000-000000000001"
VARIANT="e3000000-0000-0000-0000-000000000001"
PRODUCT="a3000000-0000-0000-0000-000000000001"
BRAND="b3000000-0000-0000-0000-000000000001"
WH_USER="63000000-0000-0000-0000-000000000001"
SALES_USER="63000000-0000-0000-0000-000000000002"
CONTAINER_SCRIPT="/tmp/fco-conc-$$.sql"
LOG="$(mktemp)"

fail() { printf 'FAIL: %s\n' "$*" >&2; rm -f "$LOG"; exit 1; }
step() { printf '\n== %s\n' "$*"; }

psql_db() { docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -tA -q -U "$DB_USER" -d "$DB" "$@"; }
psql_admin() { docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -q -U "$DB_USER" -d postgres -c "$1"; }

trap 'rm -f "$LOG" "$LOG.err"; docker exec "$CONTAINER" sh -c "rm -f '$CONTAINER_SCRIPT'" >/dev/null 2>&1 || true' EXIT

docker inspect "$CONTAINER" >/dev/null 2>&1 || fail "کانتینر $CONTAINER در دسترس نیست"

step "آماده‌سازی $DB"
if [[ "${FCO_INV_REUSE_DB:-0}" = "1" ]]; then
  printf 'reuse_db=%s (داده‌ها تازه می‌شوند؛ Migration دوباره اجرا نمی‌شود)\n' "$DB"
  psql_db -c "truncate public.conc_results;
              delete from inv.reservations;
              update inv.stock_balance set reserved = 0
               where warehouse_id = '$WH' and variant_id = '$VARIANT';" >/dev/null
else
psql_admin "drop database if exists \"$DB\" with (force);" >/dev/null
psql_admin "create database \"$DB\";" >/dev/null
POSTGRES_DB="$DB" PGDATABASE="$DB" bash "$ROOT/scripts/db-migrate.sh" up | tail -1

docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -q -U "$DB_USER" -d "$DB" <<SQL
insert into iam.users (id, mobile, full_name, status, password_hash) values
  ('$WH_USER', '09120000071', 'سرپرست انبار هم‌زمانی', 'active', 'fixture-hash-0071'),
  ('$SALES_USER', '09120000072', 'کارشناس فروش هم‌زمانی', 'active', 'fixture-hash-0072');
insert into iam.user_roles (user_id, role_id)
select '$WH_USER'::uuid, id from iam.roles where key = 'R-WH';
insert into iam.user_roles (user_id, role_id)
select '$SALES_USER'::uuid, id from iam.roles where key = 'R-SALES';

insert into cat.brands (id, slug, title) values ('$BRAND', 'conc-brand', 'برند هم‌زمانی');
insert into cat.products (id, slug, title, brand_id, status, published_at)
values ('$PRODUCT', 'conc-product', 'محصول هم‌زمانی', '$BRAND', 'published', now());
insert into cat.variants (id, product_id, sku) values ('$VARIANT', '$PRODUCT', 'CONC-SKU-1');
insert into inv.warehouses (id, code, title) values ('$WH', 'CONC-WH', 'انبار هم‌زمانی');

select inv.apply_movement('$WH_USER'::uuid, '$WH'::uuid, '$VARIANT'::uuid, $UNITS,
                          'grn', 'grn', gen_random_uuid(), 'موجودی اولیه آزمون');

-- پوشش تست: خطای هر تلاش را ثبت می‌کند تا pgbench کلاینت را abort نکند و
-- شمارش ۵/۹۵ از خود دیتابیس بیاید.
create table public.conc_results (line uuid primary key, outcome text not null);
create function public.conc_attempt(p_line uuid) returns text
language plpgsql security definer set search_path = inv, public, pg_catalog as \$\$
begin
  begin
    perform inv.reserve('$SALES_USER'::uuid, p_line, '$WH'::uuid, '$VARIANT'::uuid, 1, 30);
    insert into public.conc_results values (p_line, 'ok');
    return 'ok';
  exception when others then
    insert into public.conc_results values (p_line, 'rejected: ' || sqlerrm);
    return 'rejected';
  end;
end \$\$;
SQL
fi
printf 'stock=%s · requests=%s · clients=pgbench\n' "$UNITS" "$REQUESTS"

step "اجرای $REQUESTS رزرو هم‌زمان با pgbench"
cat > "$LOG" <<SQL
select public.conc_attempt(gen_random_uuid());
SQL
docker exec -i "$CONTAINER" sh -c "cat > '$CONTAINER_SCRIPT'" < "$LOG"

START=$(date +%s)
set +e
# Git Bash مسیر /tmp را برای pgbench (باینری میزبان) تبدیل می‌کند و فایل را
# داخل کانتینر پیدا نمی‌کند؛ تبدیل مسیر برای همین دستور خاموش است.
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" pgbench -n -c "$REQUESTS" -j "$CLIENT_THREADS" -t 1 \
  -U "$DB_USER" -d "$DB" -f "$CONTAINER_SCRIPT" > "$LOG" 2>&1
PGBENCH_STATUS=$?
set -e
SECONDS_ELAPSED=$(( $(date +%s) - START ))

PROCESSED="$(grep -oE 'number of transactions actually processed: [0-9]+/[0-9]+' "$LOG" | head -1 || true)"
printf 'pgbench=%s · exit=%s · elapsed=%ss\n' "${PROCESSED:-unknown}" "$PGBENCH_STATUS" "$SECONDS_ELAPSED"
[[ "$PGBENCH_STATUS" -eq 0 ]] || fail "pgbench با خطا تمام شد (خروجی در $LOG)"

ATTEMPTS="$(psql_db -c "
  select count(*) filter (where outcome = 'ok')
      || '|' || count(*) filter (where outcome like 'rejected: FCO-1071%')
      || '|' || count(*) filter (where outcome like 'rejected:%' and outcome not like 'rejected: FCO-1071%')
    from public.conc_results;")"
printf 'ok|stock_rejected|other_rejected=%s\n' "$ATTEMPTS"
[[ "$ATTEMPTS" = "$UNITS|$((REQUESTS - UNITS))|0" ]] \
  || fail "نتیجه تلاش‌ها با انتظار نمی‌خواند: $ATTEMPTS"

step "بررسی نهایی تجمیع و رزروها"
RESULT="$(psql_db -c "
  select (select count(*) from inv.reservations
           where warehouse_id = '$WH' and variant_id = '$VARIANT' and status = 'active')
      || '|' || b.on_hand || '|' || b.reserved
      || '|' || (b.on_hand - b.reserved - b.quarantined)
      || '|' || (select coalesce(sum(quantity_delta), 0) from inv.stock_ledger
                  where warehouse_id = '$WH' and variant_id = '$VARIANT')
    from inv.stock_balance b
   where b.warehouse_id = '$WH' and b.variant_id = '$VARIANT';")"
printf 'active_reservations|on_hand|reserved|available|ledger_sum=%s\n' "$RESULT"
[[ "$RESULT" = "5|5|5|0|5" ]] || fail "وضعیت نهایی با انتظار نمی‌خواند: $RESULT"
printf 'PASS CONCURRENCY | ۱۰۰ کلاینت هم‌زمان روی ۵ موجودی: دقیقاً ۵ موفق، ۹۵ رد\n'
printf 'PASS T-INV-01 | reserved ≤ on_hand و جمع دفتر = تجمیع\n'

step "آزمون منفی: درخواست ۱۰۱"
if psql_db -c "select inv.reserve('$SALES_USER'::uuid,
  gen_random_uuid(), '$WH'::uuid, '$VARIANT'::uuid, 1, 30);" \
     >/dev/null 2>"$LOG.err"; then
  fail "درخواست ۱۰۱ روی موجودی صفر پذیرفته شد"
fi
grep -q 'FCO-1071' "$LOG.err" || fail "درخواست ۱۰۱ با خطای نامنتظر رد شد"
printf 'PASS NEGATIVE | درخواست ۱۰۱ → FCO-1071\n'

step "پاک‌سازی"
if [[ "${FCO_INV_KEEP:-0}" = "1" ]]; then
  printf 'kept_db=%s\n' "$DB"
else
  psql_admin "drop database if exists \"$DB\" with (force);" >/dev/null
fi

printf '\nT-INV-01 PASS | 100 concurrent → 5 success / 95 rejected (%ss)\n' "$SECONDS_ELAPSED"
