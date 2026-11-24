#!/usr/bin/env bash
# =============================================================================
# db-backup-restore-drill.sh — BR-1 گام ۹: پشتیبان‌گیری و تمرین بازیابی
#
# کارها:
#   ۱) pg_dump قالب custom از دیتابیس اصلی داخل کانتینر
#   ۲) کپی فایل پشتیبان به `backups/` روی میزبان (از نظر git نادیده گرفته می‌شود)
#   ۳) ساخت دیتابیس تست و pg_restore با `--exit-on-error`
#   ۴) مقایسه شمارش جدول‌های کلیدی و Migrationهای اعمال‌شده (منبع vs بازیابی)
#   ۵) **آزمون منفی:** پشتیبان مخدوش (۱۰۲۴ بایت اول) نباید بازیابی شود
#   ۶) پاک‌سازی دیتابیس‌های آزمایشی و فایل داخل کانتینر
#
# اجرا:  bash scripts/db-backup-restore-drill.sh
# متغیرها: FCO_PG_CONTAINER، POSTGRES_USER، POSTGRES_DB، FCO_RESTORE_DB، KEEP_DUMP=1
# =============================================================================
set -euo pipefail

# Git Bash روی Windows مسیرهای /tmp را به مسیر میزبان تبدیل می‌کند و
# pg_dump داخل کانتینر مسیر را پیدا نمی‌کند؛ این متغیر تبدیل را خاموش می‌کند.
export MSYS_NO_PATHCONV=1

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="${FCO_PG_CONTAINER:-fco-postgres}"
DB_USER="${POSTGRES_USER:-fco}"
DB_NAME="${POSTGRES_DB:-fco}"
RESTORE_DB="${FCO_RESTORE_DB:-fco_restore_drill}"
SOURCE_DB="${FCO_DRILL_SOURCE_DB:-fco_drill_source}"
BAD_DB="${RESTORE_DB}_bad"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP="/tmp/fco-${STAMP}.dump"
BAD_DUMP="/tmp/fco-${STAMP}.bad.dump"
HOST_DIR="$ROOT/backups"
HOST_BACKUP="$HOST_DIR/fco-${STAMP}.dump"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

psql_admin() {
  docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -q -U "$DB_USER" -d postgres "$@"
}

fingerprint() {
  # شمارش‌های کلیدی + fingerprint محتوا تا «بازیابی خالی» هم گرفته شود
  docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -tA -U "$DB_USER" -d "$1" -c "
    select
      (select count(*) from information_schema.tables where table_schema in ('iam','sys'))
      || '|' || (select count(*) from iam.users)
      || '|' || (select count(*) from iam.roles)
      || '|' || (select count(*) from iam.role_permissions)
      || '|' || (select count(*) from iam.sessions)
      || '|' || (select count(*) from sys.audit_log)
      || '|' || (select count(*) from sys.outbox)
      || '|' || (select count(*) from sys.settings)
      || '|' || (select count(*) from sys.setting_versions)
      || '|' || (select count(*) from sys.schema_migrations)
      || '|' || (select coalesce(md5(string_agg(key, ',' order by key)), '-') from iam.roles)
      || '|' || (select coalesce(md5(string_agg(key, ',' order by key)), '-') from sys.settings);
  "
}

docker inspect "$CONTAINER" >/dev/null 2>&1 || fail "کانتینر $CONTAINER در دسترس نیست"

step "ساخت منبع آزمون $SOURCE_DB از $DB_NAME"
# روی دیتابیس کاری داده تزریق نمی‌کنیم؛ یک کپی موقت می‌سازیم و همان را می‌سنجیم.
psql_admin -c "drop database if exists \"$SOURCE_DB\";" >/dev/null
psql_admin -c "create database \"$SOURCE_DB\" template \"$DB_NAME\";" >/dev/null
docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -q -U "$DB_USER" -d "$SOURCE_DB" -c "
  insert into iam.users (id, mobile, full_name, status, password_hash)
  values ('0f0f0f0f-0f0f-0f0f-0f0f-0f0f0f0f0f0f', '09120000123',
          'کاربر آزمون بازیابی', 'active', 'drill-hash');
  insert into iam.sessions (user_id, token_hash, created_at, expires_at)
  values ('0f0f0f0f-0f0f-0f0f-0f0f-0f0f0f0f0f0f', decode(repeat('ff', 32), 'hex'),
          now(), now() + interval '1 hour');
  insert into sys.outbox (aggregate_type, aggregate_id, event_name, payload)
  values ('order', gen_random_uuid(), 'drill.event', '{\"check\":true}'::jsonb);
  insert into sys.audit_log (actor_id, action, entity_type, \"after\", request_id)
  values ('0f0f0f0f-0f0f-0f0f-0f0f-0f0f0f0f0f0f', 'drill.check', 'users',
          '{\"ok\":true}'::jsonb, 'drill-1');
" >/dev/null

step "پشتیبان‌گیری از $SOURCE_DB"
docker exec "$CONTAINER" pg_dump -U "$DB_USER" -d "$SOURCE_DB" -Fc -f "$DUMP"
SIZE="$(docker exec "$CONTAINER" stat -c %s "$DUMP")"
[ "$SIZE" -gt 0 ] || fail "فایل پشتیبان خالی است"
printf 'dump=%s bytes=%s\n' "$DUMP" "$SIZE"

mkdir -p "$HOST_DIR"
# docker CLI روی Windows مسیر /d/... را نمی‌فهمد؛ مسیر میزبان را بومی می‌کنیم
HOST_BACKUP_NATIVE="$HOST_BACKUP"
if command -v cygpath >/dev/null 2>&1; then
  HOST_BACKUP_NATIVE="$(cygpath -w "$HOST_BACKUP")"
fi
docker cp "$CONTAINER:$DUMP" "$HOST_BACKUP_NATIVE"
printf 'backup_host=%s\n' "$HOST_BACKUP"

SOURCE_FP="$(fingerprint "$SOURCE_DB")"
printf 'source_fingerprint=%s\n' "$SOURCE_FP"

step "بازیابی در $RESTORE_DB"
RESTORE_START=$(date +%s)
psql_admin -c "drop database if exists \"$RESTORE_DB\";" >/dev/null
psql_admin -c "create database \"$RESTORE_DB\";" >/dev/null
# GRANTها هم بازیابی می‌شوند (بدون --no-privileges) تا دسترسی اپ واقعی سنجیده شود؛
# --no-owner چون مالکیت اشیا در این میزبان همان کاربر بازیابی است.
docker exec "$CONTAINER" pg_restore -U "$DB_USER" -d "$RESTORE_DB" \
  --exit-on-error --no-owner "$DUMP"

RESTORED_FP="$(fingerprint "$RESTORE_DB")"
printf 'restored_fingerprint=%s\n' "$RESTORED_FP"
[ "$SOURCE_FP" = "$RESTORED_FP" ] || fail "شمارش/اثر انگشت بازیابی با منبع نمی‌خواند"

DATA_CHECK="$(docker exec -i "$CONTAINER" psql -tA -U "$DB_USER" -d "$RESTORE_DB" -c "
  select (select count(*) from iam.users)
      || '|' || (select count(*) from iam.sessions)
      || '|' || (select count(*) from sys.outbox)
      || '|' || (select count(*) from sys.audit_log);
")"
[ "$DATA_CHECK" = "1|1|1|1" ] || fail "داده نمونه در دیتابیس بازیابی نیست ($DATA_CHECK)"
RESTORE_SECONDS=$(( $(date +%s) - RESTORE_START ))
printf 'PASS restore: fingerprint برابر و داده نمونه سالم است (%s)\n' "$DATA_CHECK"
printf 'restore_seconds=%s\n' "$RESTORE_SECONDS"

# همان کوئری را روی منبع و بازیابی می‌زنیم: برابری یعنی GRANTها حفظ شده‌اند،
# و پسوند ثابت یعنی سخت‌گیری دسترسی اپ هم از دست نرفته است.
app_probe() {
  docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -tA -q -U "$DB_USER" -d "$1" <<'SQL'
set role fco_app;
select (select count(*) from iam.roles)
    || '|' || has_table_privilege(current_user, 'iam.sessions', 'INSERT')
    || '|' || has_table_privilege(current_user, 'sys.audit_log', 'UPDATE')
    || '|' || has_table_privilege(current_user, 'iam.roles', 'SELECT');
SQL
}

step "کوئری واقعی با نقش fco_app در منبع و دیتابیس بازیابی"
APP_SOURCE="$(app_probe "$SOURCE_DB")" \
  || fail "کوئری fco_app روی منبع شکست خورد"
APP_RESULT="$(app_probe "$RESTORE_DB")" \
  || fail "کوئری fco_app روی دیتابیس بازیابی شکست خورد (GRANT بازیابی نشده است)"
printf 'app_query_source=%s\napp_query_restored=%s\n' "$APP_SOURCE" "$APP_RESULT"
[ "$APP_SOURCE" = "$APP_RESULT" ] || fail "دسترسی نقش اپ پس از بازیابی با منبع نمی‌خواند"
[ "${APP_RESULT#*|}" = 'false|false|true' ] \
  || fail "سخت‌گیری دسترسی نقش اپ پس از بازیابی از دست رفت: $APP_RESULT"
[ "${APP_RESULT%%|*}" -ge 1 ] || fail "نقش‌ها برای fco_app قابل خواندن نیستند: $APP_RESULT"
printf 'PASS grants: دسترسی fco_app در بازیابی مانند منبع است و نوشتن مستقیم بسته مانده\n'

step "آزمون منفی: پشتیبان مخدوش"
docker exec "$CONTAINER" sh -c "dd if='$DUMP' of='$BAD_DUMP' bs=1 count=1024 status=none"
psql_admin -c "drop database if exists \"$BAD_DB\";" >/dev/null
psql_admin -c "create database \"$BAD_DB\";" >/dev/null

if docker exec "$CONTAINER" pg_restore -U "$DB_USER" -d "$BAD_DB" \
     --exit-on-error --no-owner "$BAD_DUMP" >/dev/null 2>&1; then
  fail "پشتیبان مخدوش بازیابی شد؛ آزمون منفی بی‌اثر است"
fi
printf 'PASS negative: پشتیبان مخدوش رد شد\n'

step "پاک‌سازی"
psql_admin -c "drop database if exists \"$BAD_DB\";" >/dev/null
psql_admin -c "drop database if exists \"$RESTORE_DB\";" >/dev/null
psql_admin -c "drop database if exists \"$SOURCE_DB\";" >/dev/null
if [ "${KEEP_DUMP:-0}" = "1" ]; then
  printf 'kept_dump=%s\n' "$DUMP"
else
  docker exec "$CONTAINER" rm -f "$DUMP" "$BAD_DUMP"
fi

printf '\nنتیجه: OK — پشتیبان سالم بازیابی شد و پشتیبان مخدوش رد شد.\n'
