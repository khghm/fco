#!/usr/bin/env bash
# =============================================================================
# ci.sh — BR-1 گام ۱۰: خط CI پایه (lint / typecheck / test / migration / build)
#
# روی دیتابیس‌های یکبارمصرف اجرا می‌شود؛ دیتابیس توسعه (`fco`) دست‌نخورده می‌ماند.
#
#   bash scripts/ci.sh all
#   bash scripts/ci.sh lint|typecheck|test|migration|build
#
# حالت اتصال:
#   * محلی (پیش‌فرض): از psql داخل کانتینر `fco-postgres` استفاده می‌کند.
#   * CI/میزبان: اگر PSQL تنظیم شود (مثلاً PSQL=psql) مستقیم وصل می‌شود و
#     PGHOST/PGPORT/PGUSER/PGPASSWORD را از محیط می‌خواند.
#
# متغیرهای اختیاری: FCO_PG_CONTAINER, POSTGRES_USER, FCO_CI_PREFIX,
#                    FCO_CI_KEEP=1 (دیتابیس‌های موقت را نگه می‌دارد)
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# خروجی فارسی روی کنسول ویندوز (cp1252) می‌شکند؛ UTF-8 را تحمیل می‌کنیم.
export PYTHONIOENCODING=utf-8
CONTAINER="${FCO_PG_CONTAINER:-fco-postgres}"
DB_USER="${POSTGRES_USER:-fco}"
MIG_DIR="${FCO_MIGRATIONS_DIR:-$ROOT/packages/infrastructure/migrations}"
TEST_DIR="${FCO_TESTS_DIR:-$ROOT/packages/infrastructure/tests}"
PREFIX="${FCO_CI_PREFIX:-${POSTGRES_DB:-fco}_ci}"
DB_TYPECHECK="${PREFIX}_typecheck"
DB_TEST="${PREFIX}_test"
DB_MIGRATION="${PREFIX}_migration"
DB_BUILD="${PREFIX}_build"
DB_BUILD_VERIFY="${PREFIX}_build_verify"
DIST="$ROOT/dist"

step() { printf '\n== %s\n' "$*"; }
ok()   { printf 'PASS %s\n' "$*"; }
die()  { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

pick_python() {
  local c
  for c in ${PYTHON:-} python3 python; do
    if "$c" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
      printf '%s' "$c"; return 0
    fi
  done
  return 1
}
PYTHON="$(pick_python || true)"

if [[ -n "${PSQL:-}" ]]; then
  MODE=direct
else
  MODE=docker
  docker inspect "$CONTAINER" >/dev/null 2>&1 || die "کانتینر $CONTAINER در دسترس نیست (یا PSQL را تنظیم کنید)"
fi

psql_run() { # <db> <psql args...>
  local db="$1"; shift
  if [[ "$MODE" = direct ]]; then
    $PSQL -X -v ON_ERROR_STOP=1 -q -d "$db" "$@"
  else
    docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -q -U "$DB_USER" -d "$db" "$@" < /dev/null
  fi
}

psql_file() { # <db> <file>
  local db="$1" file="$2"
  if [[ "$MODE" = direct ]]; then
    $PSQL -X -v ON_ERROR_STOP=1 -q --single-transaction -d "$db" -f "$file"
  else
    docker exec -i "$CONTAINER" psql -X -v ON_ERROR_STOP=1 -q --single-transaction \
      -U "$DB_USER" -d "$db" -f - < "$file"
  fi
}

q() { psql_run "$1" -tA -c "$2"; }

recreate_db() { # <name>
  psql_run postgres -c "drop database if exists \"$1\" with (force);" >/dev/null
  psql_run postgres -c "create database \"$1\";" >/dev/null
}

drop_db() { # <name>
  [[ "${FCO_CI_KEEP:-0}" = "1" ]] && return 0
  psql_run postgres -c "drop database if exists \"$1\" with (force);" >/dev/null 2>&1 || true
}

migrate() { # <db> <args...>
  local db="$1"; shift
  POSTGRES_DB="$db" PGDATABASE="$db" FCO_MIGRATIONS_DIR="$MIG_DIR" \
    bash "$ROOT/scripts/db-migrate.sh" "$@"
}

migration_files() {
  find "$MIG_DIR" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]_*.sql' \
    ! -name '*.down.sql' | sort
}

fingerprint() { # <db> — سطح API و تاریخچه Migration
  q "$1" "
    select (select count(*) from information_schema.tables where table_schema in ('iam','sys','cat','pricing','inv'))
        || '|' || (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname in ('iam','sys','cat','pricing','inv'))
        || '|' || (select count(*) from sys.schema_migrations)
        || '|' || (select coalesce(md5(string_agg(checksum, ',' order by version)), '-')
                     from sys.schema_migrations);"
}

# -----------------------------------------------------------------------------
# stage: lint
# -----------------------------------------------------------------------------
stage_lint() {
  [[ -n "$PYTHON" ]] || die "python لازم است"

  step "lint | ممیزی اسناد"
  "$PYTHON" "$ROOT/scripts/docs-audit.py" > /dev/null || die "ممیزی اسناد قرمز شد"
  ok "بدون تکرار خط/ردیف، ارجاع شکسته یا CRLF در اسناد"

  step "lint | نحو اسکریپت‌های bash"
  local f checked=0
  while IFS= read -r f; do
    bash -n "$f" || die "نحو نامعتبر: $f"
    checked=$((checked + 1))
  done < <(git -C "$ROOT" ls-files 'scripts/*.sh')
  ok "$checked اسکریپت با نحو درست"

  step "lint | فاصله انتهایی و CRLF در فایل‌های ردیابی‌شده"
  "$PYTHON" - "$ROOT" <<'PY' || die "فایل ناسالم در درخت کاری"
import subprocess, sys
root = sys.argv[1]
files = subprocess.check_output(["git", "-C", root, "ls-files", "-z"]).split(b"\0")
bad = []
for raw in files:
    if not raw:
        continue
    path = raw.decode("utf-8")
    try:
        data = open(f"{root}/{path}", "rb").read()
    except OSError:
        continue
    if b"\0" in data:
        continue
    if b"\r" in data:
        bad.append(f"{path}: CRLF")
        continue
    for number, line in enumerate(data.split(b"\n"), 1):
        if line.endswith((b" ", b"\t")):
            bad.append(f"{path}:{number}: فاصله انتهایی")
            break
if bad:
    print("\n".join(bad[:20]))
    raise SystemExit(1)
print(f"OK: {len([f for f in files if f])} فایل بدون CRLF و فاصله انتهایی")
PY
}

# -----------------------------------------------------------------------------
# stage: typecheck — همه Migrationها روی دیتابیس خالی کامپایل و سطح API بررسی می‌شود
# -----------------------------------------------------------------------------
stage_typecheck() {
  step "typecheck | هر Migration باید مسیر بازگشت داشته باشد"
  local f v n=0
  while IFS= read -r f; do
    v="$(basename "$f")"
    [[ -f "${f%.sql}.down.sql" ]] || die "مسیر بازگشت ندارد: $v"
    n=$((n + 1))
  done < <(migration_files)
  ok "$n Migration با فایل بازگشت"

  step "typecheck | اجرای همه Migrationها روی $DB_TYPECHECK"
  recreate_db "$DB_TYPECHECK"
  migrate "$DB_TYPECHECK" up > /dev/null || die "Migration روی دیتابیس خالی اجرا نشد"
  ok "همه Migrationها کامپایل شدند"

  step "typecheck | سطح API مورد انتظار"
  local tables="iam.users iam.roles iam.permissions iam.user_roles iam.role_permissions iam.sessions iam.password_resets iam.mfa_factors iam.otp_requests iam.sod_role_conflicts sys.audit_log sys.outbox sys.inbox_events sys.idempotency_keys sys.job_runs sys.settings sys.setting_versions sys.schema_migrations sys.otp_spool cat.brands cat.categories cat.products cat.variants cat.product_media pricing.prices inv.warehouses inv.stock_balance inv.stock_ledger inv.reservations inv.cost_layers inv.cost_layer_consumption"
  local missing="" count=0
  for t in $tables; do
    [[ "$(q "$DB_TYPECHECK" "select to_regclass('$t') is not null;")" = "t" ]] || missing="$missing $t"
    count=$((count + 1))
  done
  [[ -z "$missing" ]] || die "جدول(های) غایب:$missing"
  ok "$count جدول کلیدی موجود است"

  local funcs="health_report job_begin job_finish purge_expired_sessions run_session_cleanup outbox_emit outbox_claim inbox_consume audit_write audit_search setting_set authorize start_session authenticate revoke_session request_otp verify_otp"
  local have
  have="$(q "$DB_TYPECHECK" "select count(distinct p.proname) from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname in ('iam','sys')
        and p.proname in ('$(echo $funcs | sed "s/ /','/g")');")"
  [[ "$have" -ge 17 ]] || die "تابع(های) کلیدی غایب: $have از ۱۷"
  ok "۱۷ تابع کلیدی روی دیتابیس تازه وجود دارند"

  local cat_have
  cat_have="$(q "$DB_TYPECHECK" "select count(distinct p.proname) from pg_proc p
      join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'cat'
        and p.proname in ('product_create','product_update','variant_create','variant_update',
                          'normalize_text','search_query','public_product_ids',
                          'search_products','public_product','category_path');")"
  [[ "$cat_have" -ge 10 ]] || die "use-case/توابع کاتالوگ غایب‌اند: $cat_have از ۱۰"
  ok "۴ use-case کاتالوگ و ۶ تابع خواندن/جست‌وجوی عمومی موجود است"

  drop_db "$DB_TYPECHECK"
}

# -----------------------------------------------------------------------------
# stage: test — پنج مجموعه منفی/دسترسی
# -----------------------------------------------------------------------------
stage_test() {
  step "test | آماده‌سازی $DB_TEST"
  recreate_db "$DB_TEST"
  migrate "$DB_TEST" up > /dev/null || die "Migration روی دیتابیس آزمون اجرا نشد"

  local f suite=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    step "test | $(basename "$f")"
    local out status=0
    out="$(psql_file "$DB_TEST" "$f" 2>&1)" || status=$?
    printf '%s\n' "$out" | grep -E '^PASS|PASS ' | sed 's/^psql:[^ ]* //' | tail -5 || true
    [[ "$status" -eq 0 ]] || die "$(basename "$f") قرمز شد (exit $status)"
    printf '%s\n' "$out" | grep -q 'ALL STEP-' || die "$(basename "$f") نتیجه نهایی PASS نداد"
    suite=$((suite + 1))
  done < <(find "$TEST_DIR" -maxdepth 1 -type f -name '*.sql' | sort)

  local expected
  expected="$(find "$TEST_DIR" -maxdepth 1 -type f -name '*.sql' | wc -l | tr -d ' ')"
  [[ "$suite" -eq "$expected" ]] || die "تعداد مجموعه آزمون $suite است، انتظار $expected"
  ok "$suite مجموعه آزمون سبز"
  drop_db "$DB_TEST"
}

# -----------------------------------------------------------------------------
# stage: migration — up/idempotency/verify/down all/up
# -----------------------------------------------------------------------------
# down all نقش مشترک fco_app را حذف می‌کند؛ اگر دیتابیس توسعه شیئی وابسته داشته باشد
# این کار روی همان سرور شکست می‌خورد. پس مرحله Migration روی یک سرور یکبارمصرف
# اجرا می‌شود تا رفتار واقعی CI (سرور تمیز) بدون آسیب به دیتابیس توسعه سنجیده شود.
stage_migration() {
  if [[ "$MODE" = docker ]]; then
    local name="fco-ci-migrate-$$" i
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --rm --name "$name" \
      -e POSTGRES_USER="$DB_USER" -e POSTGRES_PASSWORD=ci -e POSTGRES_DB=fco \
      "${FCO_CI_PG_IMAGE:-postgres:16-alpine}" >/dev/null 2>&1 \
      || die "راه‌اندازی Postgres یکبارمصرف شکست خورد (تصویر ${FCO_CI_PG_IMAGE:-postgres:16-alpine} موجود است؟)"
    # trap در زمان خروج اجرا می‌شود و متغیر local آن موقع نیست؛ مقدار را می‌نویسیم.
    trap "docker rm -f '$name' >/dev/null 2>&1 || true" EXIT
    # pg_isready و حتی دو کوئری موفق می‌توانند به سرور موقتِ مرحله init پاسخ دهند
    # که پس از init خاموش می‌شود و اتصال را می‌بندد (خطای واقعی دیده‌شده:
    # «database system is shutting down»). سرور موقت روی سوکت یونیکس گوش می‌دهد و
    # listen_addresses ندارد؛ پس پروب‌ها از TCP درون کانتینر زده می‌شوند و علاوه بر
    # آن زمان شروع postmaster باید در دو پروب با فاصله ۳ ثانیه یکی بماند.
    # مهلت زمان‌محور است، نه تعدادی: init روی ماشین کند می‌تواند بیش از ۷۰ ثانیه
    # طول بکشد و حلقه‌های عددی زودتر تمام می‌شوند.
    local ready=0 start_time stable_time deadline=$((SECONDS + 180))
    while [[ "$SECONDS" -lt "$deadline" ]]; do
      # pg_isready روی TCP سبز می‌شود فقط وقتی سرور واقعی بالا آمده باشد؛
      # سرور موقت init روی سوکت یونیکس است و پورت TCP ندارد. pg_isready احراز
      # هویت نمی‌کند، پس رمز لازم نیست و کوئری دوم از سوکت زده می‌شود.
      if docker exec "$name" pg_isready -h 127.0.0.1 -q; then
        start_time="$(docker exec "$name" psql -U "$DB_USER" -d postgres -tAc \
          'select extract(epoch from pg_postmaster_start_time())::bigint' 2>/dev/null || true)"
        sleep 3
        stable_time="$(docker exec "$name" psql -U "$DB_USER" -d postgres -tAc \
          'select extract(epoch from pg_postmaster_start_time())::bigint' 2>/dev/null || true)"
        if [[ -n "$start_time" && "$stable_time" = "$start_time" ]]; then
          ready=1; break
        fi
      fi
      sleep 2
    done
    [[ "$ready" -eq 1 ]] || die "Postgres یکبارمصرف در ۱۸۰ ثانیه پایدار نشد"
    printf 'server=disposable:%s\n' "$name"
    ( CONTAINER="$name"; export FCO_PG_CONTAINER="$name"; stage_migration_body )
    docker rm -f "$name" >/dev/null 2>&1 || true
    trap - EXIT
  else
    printf 'server=ci-service\n'
    stage_migration_body
  fi
}

stage_migration_body() {
  local expected
  expected="$(migration_files | wc -l | tr -d ' ')"

  step "migration | از صفر روی $DB_MIGRATION"
  recreate_db "$DB_MIGRATION"
  migrate "$DB_MIGRATION" up > /dev/null || die "اجرای اول شکست خورد"
  local applied
  applied="$(q "$DB_MIGRATION" 'select count(*) from sys.schema_migrations;')"
  [[ "$applied" -eq "$expected" ]] || die "$applied Migration اعمال شد، انتظار $expected"
  ok "$applied Migration اعمال شد"

  step "migration | تکرار up باید بی‌اثر باشد"
  migrate "$DB_MIGRATION" up | grep -q 'کاری نبود' || die "up دوباره بی‌اثر نبود"
  ok "up دوباره بی‌اثر بود"

  step "migration | verify چک‌سام"
  migrate "$DB_MIGRATION" verify > /dev/null || die "چک‌سام نامطابق است"
  ok "چک‌سام همه Migrationها درست است"

  step "migration | تشخیص تغییر فایل اعمال‌شده (آزمون منفی درونی)"
  local tmp one base
  tmp="$(mktemp -d)"
  cp "$MIG_DIR"/*.sql "$tmp"/
  one="$(migration_files | head -1)"
  base="$(basename "$one")"
  printf '\n-- drift probe\n' >> "$tmp/$base"
  if FCO_MIGRATIONS_DIR="$tmp" POSTGRES_DB="$DB_MIGRATION" PGDATABASE="$DB_MIGRATION" \
       bash "$ROOT/scripts/db-migrate.sh" verify > /dev/null 2>&1; then
    rm -rf "$tmp"
    die "تغییر فایل Migration اعمال‌شده تشخیص داده نشد (گیت چک‌سام بی‌اثر است)"
  fi
  rm -rf "$tmp"
  ok "تغییر فایل اعمال‌شده رد شد"

  step "migration | down all → up (مسیر بازگشت)"
  migrate "$DB_MIGRATION" down all > /dev/null || die "down all شکست خورد"
  [[ "$(q "$DB_MIGRATION" "select count(*) from information_schema.tables where table_schema in ('iam','sys','cat','pricing','inv');")" = "0" ]] \
    || die "پس از down all جدولی در iam/sys/cat/pricing/inv ماند"
  migrate "$DB_MIGRATION" up > /dev/null || die "up پس از بازگشت شکست خورد"
  migrate "$DB_MIGRATION" verify > /dev/null || die "verify پس از بازگشت قرمز شد"
  ok "بازگشت کامل و اجرای دوباره از صفر"

  drop_db "$DB_MIGRATION"
}

# -----------------------------------------------------------------------------
# stage: build — بسته schema + manifest و اثبات با بازیابی در دیتابیس تازه
# -----------------------------------------------------------------------------
stage_build() {
  step "build | آماده‌سازی $DB_BUILD"
  recreate_db "$DB_BUILD"
  migrate "$DB_BUILD" up > /dev/null || die "Migration روی دیتابیس build اجرا نشد"
  local build_fp
  build_fp="$(fingerprint "$DB_BUILD")"

  step "build | ساخت dist/fco-schema.sql و dist/manifest.json"
  rm -rf "$DIST"
  mkdir -p "$DIST"
  local bundle="$DIST/fco-schema.sql"
  {
    echo "-- FCO schema bundle — ساخته‌شده از Migrationهای نسخه‌دار؛ دستی ویرایش نکنید."
    echo "-- git: $(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)"
    echo "-- generated_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    echo "-- ==== bootstrap (همان چیزی که runner پیش از اجرا می‌سازد)"
    echo "create schema if not exists sys;"
    echo "create table if not exists sys.schema_migrations ("
    echo "  version    text primary key,"
    echo "  name       text not null,"
    echo "  checksum   text not null,"
    echo "  applied_at timestamptz not null default now()"
    echo ");"
  } > "$bundle"

  local f version name sum
  while IFS= read -r f; do
    version="$(basename "$f" | cut -d_ -f1)"
    name="$(basename "$f" .sql)"
    sum="$("$PYTHON" - "$f" <<'PY'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
)"
    {
      echo
      echo "-- ==== $name ($sum)"
      cat "$f"
    } >> "$bundle"
    printf '%s|%s|%s\n' "$version" "$name" "$sum" >> "$DIST/.checksums"
  done < <(migration_files)

  { echo; echo "-- ثبت تاریخچه Migrationها در بسته (bundle باید خودکفا باشد)";
    while IFS='|' read -r version name sum; do
      printf "insert into sys.schema_migrations (version, name, checksum) values ('%s', '%s', '%s');\n" \
        "$version" "$name" "$sum"
    done < "$DIST/.checksums"; } >> "$bundle"
  rm -f "$DIST/.checksums"

  "$PYTHON" - "$ROOT" "$DIST" "$build_fp" <<'PY'
import hashlib, json, subprocess, sys, os
root, dist, fp = sys.argv[1], sys.argv[2], sys.argv[3]
bundle = os.path.join(dist, "fco-schema.sql")
data = open(bundle, "rb").read()
entries = []
for line in data.split(b"\n"):
    if line.startswith(b"-- ==== "):
        part = line[len(b"-- ==== "):].decode().strip()
        name, checksum = part.split(" (")
        if name == "bootstrap":
            continue
        entries.append({"name": name, "checksum": checksum.rstrip(")")})
try:
    sha = subprocess.check_output(["git", "-C", root, "rev-parse", "--short", "HEAD"]).decode().strip()
except Exception:
    sha = "unknown"
manifest = {
    "artifact": "fco-schema",
    "git": sha,
    "migrations": entries,
    "count": len(entries),
    "bundle_bytes": len(data),
    "bundle_sha256": hashlib.sha256(data).hexdigest(),
    "schema_fingerprint": fp,
}
with open(os.path.join(dist, "manifest.json"), "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, ensure_ascii=False, indent=2)
print(f"bundle={len(data)} bytes · migrations={len(entries)} · sha256={manifest['bundle_sha256'][:12]}…")
PY

  printf 'artifact=%s\n' "$bundle"
  printf 'manifest=%s\n' "$DIST/manifest.json"
  ok "بسته schema و manifest ساخته شد"

  step "build | اثبات: بسته روی دیتابیس تازه همان schema را می‌دهد"
  recreate_db "$DB_BUILD_VERIFY"
  psql_file "$DB_BUILD_VERIFY" "$bundle" > /dev/null || die "اجرای بسته روی دیتابیس تازه شکست خورد"
  local verify_fp
  verify_fp="$(fingerprint "$DB_BUILD_VERIFY")"
  printf 'build_fingerprint=%s\n' "$build_fp"
  printf 'bundle_fingerprint=%s\n' "$verify_fp"
  [[ "$build_fp" = "$verify_fp" ]] || die "بسته schema با دیتابیس Migration‌شده نمی‌خواند"
  ok "بسته خودکفاست و fingerprint برابر است"

  drop_db "$DB_BUILD"
  drop_db "$DB_BUILD_VERIFY"
}

# -----------------------------------------------------------------------------
case "${1:-all}" in
  lint)      stage_lint ;;
  typecheck) stage_typecheck ;;
  test)      stage_test ;;
  migration) stage_migration ;;
  build)     stage_build ;;
  all)
    stage_lint
    stage_typecheck
    stage_test
    stage_migration
    stage_build
    step "CI PASS | lint · typecheck · test · migration · build"
    ;;
  *) sed -n '2,20p' "$0"; exit 1 ;;
esac
