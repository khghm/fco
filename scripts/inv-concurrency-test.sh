#!/usr/bin/env bash
# =============================================================================
# inv-concurrency-test.sh — T-INV-01: ۱۰۰ رزرو هم‌زمان روی ۵ موجودی
#
# چرا pgbench: ۱۰۰ پروسه `docker exec`/psql به‌قدری پشت سر هم راه می‌افتند که
# پنجره بحرانی (خواندن available → نوشتن reserved) مصنوعاً سریال می‌شود و آزمون
# حتی بدون قفل هم سبز می‌ماند. یک پروسه pgbench صد اتصال را هم‌زمان می‌سازد.
#
# چه چیزی اثبات می‌شود:
#   * دقیقاً ۵ رزرو موفق و ۹۵ رد با FCO-1071 (نه بیشتر، نه کمتر)
#   * `reserved ≤ on_hand` و جمع دفتر = تجمیع
#   * هم‌زمانی واقعی: بیشینه تلاش‌های در جریان (هم‌پوشانی بازه‌ها) و پنجره شروع
#   * تکرارپذیری: چند دور پشت سر هم روی همان دیتابیس
#   * درخواست ۱۰۱ روی موجودی صفر → FCO-1071
#
# حالت قرمز عمدی (اثبات اینکه آزمون خودِ گارد را می‌سنجد):
#   FCO_INV_BREAK=1 bash scripts/inv-concurrency-test.sh ; echo "exit=$?"
#   یک کپی موقت از Migrationها می‌سازد، قید
#   `stock_balance_available_nonnegative` را برمی‌دارد و `inv.reserve` بی‌قفل
#   با پنجره ۵۰ms را جایگزین می‌کند. انتظار: oversell (ok > ۵) و خروج ۱.
#   اگر در این حالت «۵ موفق» دید، یعنی آزمون بی‌اثر است و با خروج ۲ اعلام می‌شود.
#
# اجرا: bash scripts/inv-concurrency-test.sh
# متغیرها: FCO_PG_CONTAINER، POSTGRES_USER، FCO_INV_DB، FCO_INV_ROUNDS،
#         FCO_INV_THREADS، FCO_INV_MAX_SPREAD_MS، FCO_INV_KEEP، FCO_INV_BREAK
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="${FCO_PG_CONTAINER:-fco-postgres}"
DB_USER="${POSTGRES_USER:-fco}"
DB="${FCO_INV_DB:-fco_inv_conc}"
REQUESTS=100
UNITS=5
ROUNDS="${FCO_INV_ROUNDS:-3}"
CLIENT_THREADS="${FCO_INV_THREADS:-20}"
MAX_SPREAD_MS="${FCO_INV_MAX_SPREAD_MS:-5000}"
BREAK="${FCO_INV_BREAK:-0}"
MIG_DIR="${FCO_MIGRATIONS_DIR:-$ROOT/packages/infrastructure/migrations}"
WORK="$(mktemp -d)"
PGLOG="$WORK/pgbench.log"
ERRL="$WORK/stderr.log"
CONTAINER_SQL="/tmp/fco-conc-$$.sql"

WH="93000000-0000-0000-0000-000000000001"
VARIANT="e3000000-0000-0000-0000-000000000001"
PRODUCT="a3000000-0000-0000-0000-000000000001"
BRAND="b3000000-0000-0000-0000-000000000001"
WH_USER="63000000-0000-0000-0000-000000000001"
SALES_USER="63000000-0000-0000-0000-000000000002"

fail() { printf '\nFAIL: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

psql_db() { docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -tA -q -U "$DB_USER" -d "$DB" "$@"; }
psql_admin() { docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -q -U "$DB_USER" -d postgres -c "$1"; }
run_sql() { docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -q -U "$DB_USER" -d "$DB"; }

cleanup() {
  rm -rf "$WORK"
  docker exec "$CONTAINER" sh -c "rm -f '$CONTAINER_SQL'" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker inspect "$CONTAINER" >/dev/null 2>&1 || fail "کانتینر $CONTAINER در دسترس نیست"

# -----------------------------------------------------------------------------
# قرمز عمدی: کپی موقت Migrationها با گارد برداشته‌شده
# -----------------------------------------------------------------------------
prepare_migrations() {
  if [[ "$BREAK" != "1" ]]; then
    printf '%s' "$MIG_DIR"
    return 0
  fi

  printf '\n== قرمز عمدی: ساخت کپی بدون قید oversell و بدون قفل رزرو\n' >&2
  cp "$MIG_DIR"/[0-9][0-9][0-9][0-9]_*.sql "$WORK"/
  sed -i \
    -e '/available = on_hand - reserved - quarantined/d' \
    -e '/constraint stock_balance_available_nonnegative/,+1d' \
    -e 's/^  primary key (warehouse_id, variant_id),$/  primary key (warehouse_id, variant_id)/' \
    "$WORK/0011_catalog_inventory.sql"

  cat > "$WORK/9999_break_red.sql" <<'SQL'
-- فقط برای اثبات قرمز: رزرو بدون قفل با پنجره ۵۰ms بین خواندن و نوشتن.
create or replace function inv.reserve(
  p_actor uuid, p_order_line_id uuid, p_warehouse_id uuid, p_variant_id uuid,
  p_quantity integer, p_ttl_minutes integer default null
) returns uuid
language plpgsql security definer set search_path = inv, sys, iam, pg_catalog as $$
declare
  v_ttl     integer := coalesce(p_ttl_minutes, sys.setting_int('inv.reservation_ttl_minutes'));
  v_on_hand integer;
  v_reserved integer;
  v_quarantined integer;
  v_available integer;
  v_id uuid;
begin
  select on_hand, reserved, quarantined
    into v_on_hand, v_reserved, v_quarantined
    from inv.stock_balance
   where warehouse_id = p_warehouse_id and variant_id = p_variant_id;
  perform pg_sleep(0.05);
  v_available := v_on_hand - v_reserved - v_quarantined;
  if v_available < p_quantity then
    raise exception 'FCO-1071: موجودی کافی نیست (available=%)', v_available using errcode = '22023';
  end if;
  insert into inv.reservations
    (warehouse_id, variant_id, order_line_id, quantity, expires_at)
  values (p_warehouse_id, p_variant_id, p_order_line_id, p_quantity,
          now() + make_interval(mins => v_ttl))
  returning id into v_id;
  update inv.stock_balance set reserved = reserved + p_quantity
   where warehouse_id = p_warehouse_id and variant_id = p_variant_id;
  perform sys.audit_write(
    p_actor => p_actor, p_action => 'stock.reserve',
    p_entity_type => 'reservations', p_entity_id => v_id,
    p_after => jsonb_build_object('quantity', p_quantity),
    p_request_id => 'fn:reserve:break');
  return v_id;
end $$;
SQL
  printf -- '-- stub بازگشت برای Migration قرمز\n' > "$WORK/9999_break_red.down.sql"
  printf 'break_dir=%s\n' "$WORK" >&2
  printf '%s' "$WORK"
}

# -----------------------------------------------------------------------------
# دیتابیس: از صفر یا از Migration قرمز
# -----------------------------------------------------------------------------
step "آماده‌سازی $DB"
MIGRATIONS="$(prepare_migrations)"
psql_admin "drop database if exists \"$DB\" with (force);" >/dev/null
psql_admin "create database \"$DB\";" >/dev/null
POSTGRES_DB="$DB" PGDATABASE="$DB" FCO_MIGRATIONS_DIR="$MIGRATIONS" \
  bash "$ROOT/scripts/db-migrate.sh" up | tail -1

MAX_CONN="$(psql_db -c 'show max_connections;')"
[[ "$MAX_CONN" -ge "$REQUESTS" ]] \
  || fail "max_connections=$MAX_CONN کمتر از $REQUESTS کلاینت آزمون است"

# conc_attempt: خطای هر تلاش را ثبت می‌کند تا pgbench کلاینت را abort نکند و
# شمارش از دیتابیس (نه از خروجی pgbench) بیاید. بازه هر تلاش برای اثبات
# هم‌پوشانی واقعی نگه داشته می‌شود.
run_sql <<SQL
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

create table public.conc_results (
  line        uuid primary key,
  outcome     text not null default 'pending',
  started_at  timestamptz not null default clock_timestamp(),
  finished_at timestamptz
);

create function public.conc_attempt(p_line uuid) returns text
language plpgsql security definer set search_path = inv, public, pg_catalog as \$\$
begin
  insert into public.conc_results (line) values (p_line);
  begin
    perform inv.reserve('$SALES_USER'::uuid, p_line, '$WH'::uuid, '$VARIANT'::uuid, 1, 30);
    update public.conc_results set outcome = 'ok', finished_at = clock_timestamp()
     where line = p_line;
    return 'ok';
  exception when others then
    update public.conc_results set outcome = 'rejected: ' || sqlerrm,
                                   finished_at = clock_timestamp()
     where line = p_line;
    return 'rejected';
  end;
end \$\$;
SQL

printf 'stock=%s · requests=%s · rounds=%s · mode=%s\n' \
  "$UNITS" "$REQUESTS" "$ROUNDS" "$([[ "$BREAK" = "1" ]] && printf 'break(red)' || printf 'normal')"

# -----------------------------------------------------------------------------
# هر دور: بازنشانی، اجرا، شمارش
# -----------------------------------------------------------------------------
reset_stock() {
  psql_db -c "
    delete from inv.reservations
     where warehouse_id = '$WH' and variant_id = '$VARIANT';
    update inv.stock_balance set reserved = 0
     where warehouse_id = '$WH' and variant_id = '$VARIANT';
    truncate public.conc_results;" >/dev/null
}

printf 'select public.conc_attempt(gen_random_uuid());\n' > "$WORK/bench.sql"
docker exec -i "$CONTAINER" sh -c "cat > '$CONTAINER_SQL'" < "$WORK/bench.sql"

measure() { # خروجی: ok|stock|other|spread_ms|overlap
  psql_db -c "
    with ev as (
      select started_at as ts, 1 as delta from public.conc_results
      union all
      select finished_at, -1 from public.conc_results where finished_at is not null
    ), depth as (
      select sum(delta) over (order by ts, delta desc) as live from ev
    ), stats as (
      select count(*) filter (where outcome = 'ok') as ok,
             count(*) filter (where outcome like 'rejected: FCO-1071%') as stock,
             count(*) filter (where outcome like 'rejected:%'
                                 and outcome not like 'rejected: FCO-1071%') as other,
             coalesce(round(extract(epoch from (max(started_at) - min(started_at))) * 1000)::text, '-') as spread
        from public.conc_results
    )
    select s.ok || '|' || s.stock || '|' || s.other || '|' || s.spread
        || '|' || coalesce((select max(live) from depth), 0)
      from stats s;"
}

stock_state() {
  psql_db -c "
    select (select count(*) from inv.reservations
             where warehouse_id = '$WH' and variant_id = '$VARIANT' and status = 'active')
        || '|' || b.on_hand || '|' || b.reserved
        || '|' || (b.on_hand - b.reserved - b.quarantined)
        || '|' || (select coalesce(sum(quantity_delta), 0) from inv.stock_ledger
                    where warehouse_id = '$WH' and variant_id = '$VARIANT')
      from inv.stock_balance b
     where b.warehouse_id = '$WH' and b.variant_id = '$VARIANT';"
}

run_round() { # <round>
  reset_stock
  set +e
  # Git Bash مسیر /tmp را برای pgbench (باینری میزبان) تبدیل می‌کند و فایل را
  # داخل کانتینر پیدا نمی‌کند؛ تبدیل مسیر برای همین دستور خاموش است.
  MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" pgbench -n -c "$REQUESTS" -j "$CLIENT_THREADS" -t 1 \
    -U "$DB_USER" -d "$DB" -f "$CONTAINER_SQL" > "$PGLOG" 2>&1
  local status=$?
  set -e
  if [[ "$status" -ne 0 ]]; then
    printf '\n--- pgbench log (دور %s) ---\n' "$1" >&2
    tail -15 "$PGLOG" >&2 || true
    fail "pgbench در دور $1 با خطا تمام شد (exit $status)"
  fi

  local processed
  processed="$(grep -oE 'number of transactions actually processed: [0-9]+/[0-9]+' "$PGLOG" | head -1 || true)"
  [[ "$processed" = "number of transactions actually processed: $REQUESTS/$REQUESTS" ]] \
    || fail "pgbench همه $REQUESTS تراکنش را اجرا نکرد ($processed)"

  MEASURED="$(measure)"
  STATE="$(stock_state)"
  printf 'round=%s · ok|stock|other|spread_ms|overlap=%s · active|on_hand|reserved|available|ledger=%s\n' \
    "$1" "$MEASURED" "$STATE"
}

OK=0 STOCK=0 OTHER=0 SPREAD=0 OVERLAP=0

for ((round = 1; round <= ROUNDS; round++)); do
  step "دور $round از $ROUNDS: $REQUESTS رزرو هم‌زمان"
  MEASURED=""
  STATE=""
  run_round "$round"
  IFS='|' read -r OK STOCK OTHER SPREAD OVERLAP <<< "$MEASURED"

  [[ "$((OK + STOCK + OTHER))" -eq "$REQUESTS" ]] \
    || fail "تعداد تلاش‌های ثبت‌شده $((OK + STOCK + OTHER)) است، انتظار $REQUESTS"
  [[ "$SPREAD" -le "$MAX_SPREAD_MS" ]] \
    || fail "شروع تلاش‌ها $SPREAD ms طول کشید (سقف $MAX_SPREAD_MS)؛ هم‌زمانی محقق نشد"
  [[ "$OVERLAP" -ge $((REQUESTS / 2)) ]] \
    || fail "بیشینه تلاش هم‌زمان $OVERLAP است (کمتر از $((REQUESTS / 2)))؛ درخواست‌ها سریال اجرا شدند"

  if [[ "$BREAK" = "1" ]]; then
    if [[ "$OK" -gt "$UNITS" ]]; then
      printf 'RED CONFIRMED | بدون قفل و قید، %s رزرو روی %s موجودی پذیرفته شد (oversell)\n' \
        "$OK" "$UNITS"
      printf 'ورودی قرمز: %s\n' "$MEASURED"
      exit 1
    fi
    printf '\nFAIL: قرمز عمدی اثر نداشت (ok=%s)؛ آزمون گارد را نمی‌سنجد — exit 2\n' "$OK" >&2
    exit 2
  fi

  [[ "$OK" -eq "$UNITS" && "$STOCK" -eq $((REQUESTS - UNITS)) && "$OTHER" -eq 0 ]] \
    || fail "ردها باید همه FCO-1071 باشند: stock=$STOCK other=$OTHER"
  [[ "$STATE" = "$UNITS|$UNITS|$UNITS|0|$UNITS" ]] \
    || fail "وضعیت نهایی دور $round با انتظار نمی‌خواند: $STATE"
done

printf '\nPASS CONCURRENCY | %s تلاش هم‌زمان روی %s موجودی در %s دور: دقیقاً %s موفق، %s رد\n' \
  "$REQUESTS" "$UNITS" "$ROUNDS" "$UNITS" "$((REQUESTS - UNITS))"
printf 'PASS T-INV-01 | reserved ≤ on_hand، جمع دفتر = تجمیع، هم‌پوشانی %s تلاش\n' "$OVERLAP"

step "آزمون منفی: درخواست ۱۰۱"
if psql_db -c "select inv.reserve('$SALES_USER'::uuid,
  gen_random_uuid(), '$WH'::uuid, '$VARIANT'::uuid, 1, 30);" >/dev/null 2>"$ERRL"; then
  fail "درخواست ۱۰۱ روی موجودی صفر پذیرفته شد"
fi
grep -q 'FCO-1071' "$ERRL" || fail "درخواست ۱۰۱ با خطای نامنتظر رد شد"
printf 'PASS NEGATIVE | درخواست ۱۰۱ → FCO-1071\n'

step "پاک‌سازی"
if [[ "${FCO_INV_KEEP:-0}" = "1" ]]; then
  printf 'kept_db=%s\n' "$DB"
else
  psql_admin "drop database if exists \"$DB\" with (force);" >/dev/null
fi

printf '\nT-INV-01 PASS | %s × %s requests → %s success / %s rejected\n' \
  "$ROUNDS" "$REQUESTS" "$UNITS" "$((REQUESTS - UNITS))"
