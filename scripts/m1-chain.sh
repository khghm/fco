#!/usr/bin/env bash
# =============================================================================
# m1-chain.sh — Milestone M1: زنجیره کامل با شاهد واقعی
#
# زنجیره: ورود کارمند (نقش محدود) → ثبت Audit → اجرای Job/Outbox Worker →
#         شکست تا DLQ → پشتیبان‌گیری و بازیابی روی دیتابیس جدا
#
# روی دو دیتابیس یکبارمصرف اجرا می‌شود؛ دیتابیس توسعه (`fco`) دست‌نخورده می‌ماند:
#   * `fco_m1_chain`   — منبع: Migrationها + سناریوی m1_chain.sql
#   * `fco_m1_restore` — بازیابی از pg_dump با `--exit-on-error --no-owner`
# آزمون منفی درونی: پشتیبان مخدوش (۱۰۲۴ بایت اول) نباید بازیابی شود.
#
# اجرا:
#   bash scripts/m1-chain.sh
#
# متغیرها: FCO_PG_CONTAINER، POSTGRES_USER، FCO_M1_DB، FCO_M1_RESTORE_DB،
#          FCO_M1_KEEP_DB=1، KEEP_DUMP=1، FCO_M1_REUSE_DB=1 (برای اثبات قرمز:
#          دیتابیس موجود بازاستفاده می‌شود و Migration دوباره اجرا نمی‌شود)
# =============================================================================
set -euo pipefail

# Git Bash روی Windows مسیرهای /tmp را برای pg_dump/pg_restore داخل کانتینر
# تبدیل می‌کند؛ فقط همان دستورها با MSYS_NO_PATHCONV=1 اجرا می‌شوند (نه سراسری،
# وگرنه Python مسیر /d/... را نمی‌شناسد).
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTAINER="${FCO_PG_CONTAINER:-fco-postgres}"
DB_USER="${POSTGRES_USER:-fco}"
SOURCE_DB="${FCO_M1_DB:-fco_m1_chain}"
RESTORE_DB="${FCO_M1_RESTORE_DB:-fco_m1_restore}"
BAD_DB="${RESTORE_DB}_bad"
SCENARIO="$ROOT/packages/infrastructure/scenarios/m1_chain.sql"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DUMP="/tmp/fco-m1-${STAMP}.dump"
BAD_DUMP="/tmp/fco-m1-${STAMP}.bad.dump"
HOST_DIR="$ROOT/backups"
HOST_BACKUP="$HOST_DIR/fco-m1-${STAMP}.dump"
ADMIN_ID="11111111-1111-1111-1111-111111111112"
EMP_ID="11111111-1111-1111-1111-111111111111"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
step() { printf '\n== %s\n' "$*"; }

admin_sql() { # <sql>
  docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -q -U "$DB_USER" -d postgres -c "$1"
}

db_sql() { # <db> <sql>
  docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -tA -q -U "$DB_USER" -d "$1" -c "$2"
}

run_file() { # <db> <file>
  docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -q -U "$DB_USER" -d "$1" -f - < "$2"
}

recreate_db() { # <db>
  admin_sql "drop database if exists \"$1\" with (force);" >/dev/null
  admin_sql "create database \"$1\";" >/dev/null
}

drop_db() { # <db>
  [[ "${FCO_M1_KEEP_DB:-0}" = "1" ]] && return 0
  admin_sql "drop database if exists \"$1\" with (force);" >/dev/null 2>&1 || true
}

fingerprint() { # <db> — اثر انگشت داده‌ای/ساختاری منبع و بازیابی
  db_sql "$1" "
    select (select count(*) from iam.users)
        || '|' || (select count(*) from iam.sessions)
        || '|' || (select count(*) from sys.audit_log)
        || '|' || (select count(*) from sys.outbox where dead_lettered_at is not null)
        || '|' || (select count(*) from sys.schema_migrations)
        || '|' || (select coalesce(md5(string_agg(action, ',' order by action, id)), '-')
                     from sys.audit_log);"
}

docker inspect "$CONTAINER" >/dev/null 2>&1 || fail "کانتینر $CONTAINER در دسترس نیست"

if [[ "${FCO_M1_REUSE_DB:-0}" = "1" ]]; then
  printf 'reuse_db=%s (Migration دوباره اجرا نمی‌شود)\n' "$SOURCE_DB"
else
  step "آماده‌سازی $SOURCE_DB و اعمال Migrationها"
  recreate_db "$SOURCE_DB"
  POSTGRES_DB="$SOURCE_DB" PGDATABASE="$SOURCE_DB" \
    bash "$ROOT/scripts/db-migrate.sh" up | tail -1
fi

step "گام ۱ تا ۳: ورود → Audit → Job → DLQ (نقش اپ fco_app)"
OUTPUT="$(run_file "$SOURCE_DB" "$SCENARIO" 2>&1)" || STATUS=$?
STATUS="${STATUS:-0}"
printf '%s\n' "$OUTPUT" | sed 's/^psql:[^ ]* //'
[[ "$STATUS" -eq 0 ]] || fail "سناریوی M1 قرمز شد (exit $STATUS)"
printf '%s\n' "$OUTPUT" | grep -q 'ALL M1 CHAIN STEPS PASSED' \
  || fail "سناریو نشانگر پایانی PASS نداد"

step "گام ۴: پشتیبان‌گیری از $SOURCE_DB"
SOURCE_FP="$(fingerprint "$SOURCE_DB")"
printf 'source_fingerprint=%s\n' "$SOURCE_FP"
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" pg_dump -U "$DB_USER" -d "$SOURCE_DB" -Fc -f "$DUMP"
SIZE="$(MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" stat -c %s "$DUMP")"
[[ "$SIZE" -gt 0 ]] || fail "فایل پشتیبان خالی است"
printf 'dump=%s bytes=%s\n' "$DUMP" "$SIZE"

mkdir -p "$HOST_DIR"
HOST_BACKUP_NATIVE="$HOST_BACKUP"
if command -v cygpath >/dev/null 2>&1; then
  HOST_BACKUP_NATIVE="$(cygpath -w "$HOST_BACKUP")"
fi
MSYS_NO_PATHCONV=1 docker cp "$CONTAINER:$DUMP" "$HOST_BACKUP_NATIVE"
printf 'backup_host=%s\n' "$HOST_BACKUP"

step "بازیابی در $RESTORE_DB"
RESTORE_START=$(date +%s)
recreate_db "$RESTORE_DB"
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" pg_restore -U "$DB_USER" -d "$RESTORE_DB" \
  --exit-on-error --no-owner "$DUMP"

RESTORED_FP="$(fingerprint "$RESTORE_DB")"
RESTORE_SECONDS=$(( $(date +%s) - RESTORE_START ))
printf 'restored_fingerprint=%s\n' "$RESTORED_FP"
[[ "$SOURCE_FP" = "$RESTORED_FP" ]] || fail "اثر انگشت بازیابی با منبع نمی‌خواند"
printf 'PASS restore: داده و تاریخچه Migration برابر است (restore_seconds=%s)\n' "$RESTORE_SECONDS"

step "کوئری واقعی با نقش fco_app روی دیتابیس بازیابی"
PROBE="$(docker exec -i "$CONTAINER" psql -v ON_ERROR_STOP=1 -tA -q -U "$DB_USER" -d "$RESTORE_DB" <<SQL
set role fco_app;
select (select count(*) from sys.audit_log where action = 'session.login')
    || '|' || (select count(*) from sys.dlq_list('$ADMIN_ID'::uuid))
    || '|' || has_table_privilege(current_user, 'sys.audit_log', 'INSERT');
SQL
)" || fail "کوئری fco_app روی دیتابیس بازیابی شکست خورد (GRANT/DLQ بازیابی نشده است)"
printf 'restored_app_probe=%s\n' "$PROBE"
[[ "$PROBE" = '1|1|false' ]] \
  || fail "پس از بازیابی Audit/DLQ یا سخت‌گیری دسترسی از دست رفت: $PROBE"
printf 'PASS grants: Audit و DLQ پس از بازیابی در دسترس‌اند و نوشتن مستقیم بسته است\n'

step "آزمون منفی: پشتیبان مخدوش"
MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" sh -c "dd if='$DUMP' of='$BAD_DUMP' bs=1 count=1024 status=none"
recreate_db "$BAD_DB"
if MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" pg_restore -U "$DB_USER" -d "$BAD_DB" \
     --exit-on-error --no-owner "$BAD_DUMP" >/dev/null 2>&1; then
  fail "پشتیبان مخدوش بازیابی شد؛ آزمون منفی بی‌اثر است"
fi
printf 'PASS negative: پشتیبان مخدوش رد شد\n'

step "پاک‌سازی"
drop_db "$BAD_DB"
drop_db "$RESTORE_DB"
drop_db "$SOURCE_DB"
if [[ "${KEEP_DUMP:-0}" = "1" ]]; then
  printf 'kept_dump=%s\n' "$HOST_BACKUP"
else
  MSYS_NO_PATHCONV=1 docker exec "$CONTAINER" rm -f "$DUMP" "$BAD_DUMP"
  rm -f "$HOST_BACKUP"
fi

printf '\nM1 CHAIN PASS | login → audit → job → dlq → restore (%ss)\n' "$RESTORE_SECONDS"
