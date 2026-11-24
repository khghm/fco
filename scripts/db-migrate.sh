#!/usr/bin/env bash
# =============================================================================
# db-migrate.sh — اجرای Migration نسخه‌دار (BR-1 گام ۴)
#
# قاعده: هر تغییر schema فقط از این مسیر. جزئیات سیاست در
# `docs/Architecture-02/DATABASE_DESIGN.md §5` است.
#
#   scripts/db-migrate.sh up            # اجرای Migration های اعمال‌نشده (به ترتیب شماره)
#   scripts/db-migrate.sh down          # بازگشت آخرین Migration
#   scripts/db-migrate.sh down 2        # بازگشت دو Migration آخر
#   scripts/db-migrate.sh down all      # بازگشت همه
#   scripts/db-migrate.sh status        # فهرست اعمال‌شده
#   scripts/db-migrate.sh verify        # تطابق چک‌سام فایل با ثبت‌شده (تشخیص تغییر تاریخی)
#
# ویژگی‌ها:
#   * هر Migration در یک تراکنش اجرا می‌شود: یا کامل، یا هیچ (`--single-transaction`).
#   * چک‌سام SHA-256 ثبت می‌شود؛ تغییر فایلِ اعمال‌شده = خطا (بدون اجرای دوباره).
#   * هر Migration باید فایل `.down.sql` داشته باشد، وگرنه بازگشت رد می‌شود.
#   * اتصال پیش‌فرض از طریق کانتینر توسعه (psql محلی لازم نیست).
#
# متغیرهای محیطی اختیاری:
#   FCO_PG_CONTAINER (پیش‌فرض fco-postgres) · POSTGRES_USER · POSTGRES_DB
#   FCO_MIGRATIONS_DIR · PSQL (برای اجرا با psql بیرونی: PSQL="psql -h … -U … -d …")
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIG_DIR="${FCO_MIGRATIONS_DIR:-$ROOT/packages/infrastructure/migrations}"
CONTAINER="${FCO_PG_CONTAINER:-fco-postgres}"
DB_USER="${POSTGRES_USER:-fco}"
DB_NAME="${POSTGRES_DB:-fco}"
die() { printf 'خطا: %s\n' "$*" >&2; exit 1; }

# مفسر پایتون باید واقعاً اجرا شود؛ در ویندوز `python3` ممکن است فقط
# میان‌بر فروشگاه مایکروسافت باشد که با کد ۴۹ خارج می‌شود.
pick_python() {
  local c
  for c in ${PYTHON:-} python3 python; do
    if "$c" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 8) else 1)' 2>/dev/null; then
      printf '%s' "$c"
      return 0
    fi
  done
  return 1
}
PYTHON="$(pick_python || true)"

# --- اتصال -------------------------------------------------------------------
# PSQL اگر تنظیم شده باشد، دستور کامل با -c/-f - پذیرفته می‌شود.
# stdin همیشه /dev/null است تا `docker exec -i` فهرست Migration ها را از حلقه نخورد.
run_psql() {
  # $@: آرگومان‌های psql (بدون نام دیتابیس/کاربر)
  if [[ -n "${PSQL:-}" ]]; then
    $PSQL -v ON_ERROR_STOP=1 -q "$@" < /dev/null
  else
    docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -q \
      -U "$DB_USER" -d "$DB_NAME" "$@" 2>&1 < /dev/null
  fi
}

query() { run_psql -tA -c "$1"; }

# فایل را از stdin می‌خوانیم: مسیر ميزبان لزوماً داخل کانتینر وجود ندارد.
exec_sql_file() {
  local file="$1"
  if [[ -n "${PSQL:-}" ]]; then
    $PSQL -v ON_ERROR_STOP=1 -q --single-transaction -f "$file" > /dev/null
  else
    docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -q --single-transaction \
      -U "$DB_USER" -d "$DB_NAME" -f - < "$file" > /dev/null
  fi
}

checksum() {
  [[ -n "$PYTHON" ]] || die "python یافت نشد؛ برای چک‌سام لازم است"
  "$PYTHON" - "$1" <<'PY'
import hashlib, sys
print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())
PY
}

bootstrap() {
  query "create schema if not exists sys;" > /dev/null
  query "create table if not exists sys.schema_migrations (
           version    text primary key,
           name       text not null,
           checksum   text not null,
           applied_at timestamptz not null default now()
         );" > /dev/null
}

migration_files() {
  find "$MIG_DIR" -maxdepth 1 -type f -name '[0-9][0-9][0-9][0-9]_*.sql' \
    ! -name '*.down.sql' | sort
}

# --- دستورها -----------------------------------------------------------------
cmd_up() {
  bootstrap
  local file version name recorded sum applied=0
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    version="$(basename "$file" | cut -d_ -f1)"
    name="$(basename "$file" .sql)"
    sum="$(checksum "$file")"
    recorded="$(query "select checksum from sys.schema_migrations where version = '$version';")"

    if [[ -n "$recorded" ]]; then
      if [[ "$recorded" != "$sum" ]]; then
        die "فایل اعمال‌شده تغییر کرده است (version=$version).
  ثبت‌شده: $recorded
  فعلی   : $sum
راه‌حل: Migration اعمال‌شده را ویرایش نکنید؛ Migration جدید بسازید."
      fi
      continue
    fi

    printf '→ اعمال %s\n' "$name"
    exec_sql_file "$file" || die "اجرای $name شکست خورد (تراکنش بازگشت داده شد)"
    query "insert into sys.schema_migrations (version, name, checksum)
           values ('$version', '$name', '$sum');" > /dev/null
    applied=$((applied + 1))
  done < <(migration_files)

  if [[ "$applied" -eq 0 ]]; then
    echo "همه Migration ها اعمال شده‌اند — کاری نبود."
  else
    printf '%s Migration اعمال شد.\n' "$applied"
  fi
}

cmd_down() {
  local target="${1:-1}" versions v file
  bootstrap

  versions="$(query "select version from sys.schema_migrations order by version desc;")"
  [[ -n "$versions" ]] || { echo "هیچ Migration اعمال‌شده‌ای نیست."; return 0; }

  if [[ "$target" == "all" ]]; then
    target="$(printf '%s\n' "$versions" | wc -l | tr -d ' ')"
  fi
  [[ "$target" =~ ^[0-9]+$ ]] || die "مقدار بازگشت نامعتبر است: $target (عدد یا all)"

  local i=0
  while IFS= read -r v; do
    [[ -n "$v" ]] || continue
    [[ "$i" -lt "$target" ]] || break
    file="$(find "$MIG_DIR" -maxdepth 1 -type f -name "${v}_*.down.sql" -print -quit)"
    [[ -n "$file" ]] || die "برای version=$v مسیر بازگشت (.down.sql) وجود ندارد"
    printf '← بازگشت %s\n' "$(basename "$file" .down.sql)"

    # رکورد پیش از اجرا حذف می‌شود: فایل بازگشت ممکن است `sys` را هم بردارد
    # (0001 این کار را می‌کند)، وگرنه حذف رکورد به جدولی می‌خورد که وجود ندارد.
    local up_name up_sum
    up_name="$(query "select name from sys.schema_migrations where version = '$v';")"
    up_sum="$(query "select checksum from sys.schema_migrations where version = '$v';")"
    query "delete from sys.schema_migrations where version = '$v';" > /dev/null

    if ! exec_sql_file "$file"; then
      query "insert into sys.schema_migrations (version, name, checksum)
             values ('$v', '$up_name', '$up_sum');" > /dev/null || true
      die "بازگشت $v شکست خورد (رکورد اعمال دوباره ثبت شد)"
    fi
    i=$((i + 1))
  done < <(printf '%s\n' "$versions")

  printf '%s Migration بازگشت داده شد.\n' "$i"
}

cmd_status() {
  bootstrap
  query "select rpad(version, 8) || rpad(name, 26) || rpad(left(checksum, 12), 14)
                || to_char(applied_at, 'YYYY-MM-DD HH24:MI:SS')
         from sys.schema_migrations order by version;"
}

cmd_verify() {
  bootstrap
  local file version sum recorded bad=0
  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    version="$(basename "$file" | cut -d_ -f1)"
    sum="$(checksum "$file")"
    recorded="$(query "select checksum from sys.schema_migrations where version = '$version';")"
    if [[ -z "$recorded" ]]; then
      printf 'اعمال‌نشده: %s\n' "$(basename "$file")"
    elif [[ "$recorded" != "$sum" ]]; then
      printf 'تغییر یافته (نقض): %s\n' "$(basename "$file")"
      bad=1
    fi
  done < <(migration_files)
  [[ "$bad" -eq 0 ]] || die "چک‌سام Migration اعمال‌شده با فایل نمی‌خواند"
  echo "چک‌سام همه Migration های اعمال‌شده درست است."
}

case "${1:-}" in
  up)      cmd_up ;;
  down)    cmd_down "${2:-1}" ;;
  status)  cmd_status ;;
  verify)  cmd_verify ;;
  *)       sed -n '2,24p' "$0"; exit 1 ;;
esac
