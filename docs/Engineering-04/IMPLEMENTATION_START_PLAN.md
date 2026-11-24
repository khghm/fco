# برنامه شروع پیاده‌سازی — BR-1 گام‌به‌گام

> **وضعیت:** تأییدشده · **نسخه:** v1.0 · **تاریخ:** ۱۴۰۵/۰۹/۰۲
> **خروجی ۱۰ از ۱۰** — وضعیت اجرا در انتهای همین سند ثبت می‌شود.
> **مالک گام‌های BR-1 و تنها محل ثبت «انجام شد» با شاهد واقعی.**

## ۱. وضعیت محیط (اندازه‌گیری‌شده)

> **این جدول تنها مرجع وضعیت جاری محیط است**؛ عکس تاریخی لحظه کشف در `Business-01/PROJECT_DISCOVERY_REPORT.md §1` نگه داشته می‌شود و به‌روز نمی‌شود.

| مورد | وضعیت | اقدام |
|---|---|---|
| پوشه پروژه | خالی بود | اسکلت ساخته شد |
| Git | نبود | `git init` انجام شد |
| Node.js | v24.10.0 | کافی |
| npm | 11.18.0 | **مدیر بسته انتخابی** |
| bun | خراب (شیم نامعتبر) | استفاده نمی‌شود |
| Docker | 29.9.2 | محیط محلی |
| psql CLI | نصب نیست | کار با `docker exec` |
| ویندوز/MINGW | LF با `.gitattributes` | Production روی Linux |

## ۲. پیش‌نیازهای شروع (G0) — وضعیت

| # | پیش‌نیاز | وضعیت |
|---|---|---|
| ۱ | تأیید ۱۰ سند طراحی | ✅ |
| ۲ | تصمیم Q-02/04/06/11 | ✅ پذیرفته‌شده (`product/OPEN_DECISIONS.md`) |
| ۳ | ADR-008/009/010 | ✅ پذیرفته‌شده |
| ۴ | مدیر بسته | ✅ npm |
| ۵ | محیط Production | ⏳ Q-11 پذیرفته؛ سرور مشخص نشده (مانع BR-1 نیست) |

## ۳. BR-1 — ده گام

| # | گام | شاهد پذیرش | وضعیت |
|---|---|---|---|
| ۱ | مخزن: `git init`، `.gitignore`، `.gitattributes`، `.editorconfig`، README | تاریخچه کامیت + فایل‌های سیاست | ✅ انجام شد |
| ۲ | اسکلت پوشه‌ها (`apps/`, `packages/`, `docs/`, `infra/`, `scripts/`) | ساختار قابل‌مشاهده و کامیت‌شده | ✅ انجام شد |
| ۳ | محیط محلی Docker (PostgreSQL/Redis + S3 اختیاری) + فایل نمونه محیط | `compose config` معتبر + سرویس‌های سالم | ✅ PostgreSQL 16.16 و Redis 7.4.12 هر دو healthy (شاهد: §5.۲) |
| ۴ | Migration و اسکیمای پایه (IAM/Audit/Outbox/Setting) | اجرا از صفر + rollback | ✅ ۱۵ جدول در `iam`/`sys`؛ از صفر، بازگشت، drift و اتمیک بودن آزمون شد (§5.۴) |
| ۵ | هویت و مجوز (ورود کارکنان، سیاست رمز، نشست، RBAC) | آزمون منفی دسترسی | ⏳ |
| ۶ | OTP مشتری (توسعه: Spool) | انقضا/نرخ/ضد Brute Force | ⏳ |
| ۷ | Audit و تنظیمات نسخه‌دار | رکورد قابل‌جست‌وجو + مجوز تغییر | ⏳ |
| ۸ | Outbox/Queue Port/Worker/DLQ | اجرای دوبار بدون اثر تکراری | ⏳ |
| ۹ | رصد و پشتیبان + آزمون Restore | بازیابی مستند روی محیط جدا | ⏳ |
| ۱۰ | CI پایه (lint/typecheck/test/migration) | CI برای خطای عمدی قرمز شود | ⏳ |

## ۴. Milestone M1 (تعریف «BR-1 تمام شد»)

> «یک کارمند با ورود امن و مجوز محدود وارد پنل می‌شود، هر کار حساسش در Audit ثبت می‌شود، یک Job پس‌زمینه اجرا و در صورت خطا در DLQ ظاهر می‌شود، و اگر سرور از دست برود، از پشتیبان با مستند بازیابی می‌شود.»

اگر هر بخش قابل‌نمایش نباشد، BR-1 تمام نیست.

## ۵. ثبت اجرا (شاهد واقعی)

### ۵.۱ گام ۱ و ۲ — مخزن و اسکلت

```
$ git init
Initialized empty Git repository in D:/Works/fco/.git/

$ git log --oneline
d33c5c4 chore: initialise repository with design docs, docs tree and dev environment
d90b5f4 docs: add the 18 missing design documents and align the docs tree
bce9c4b docs: enforce single-source ownership and strip duplicated sections
```

- فایل‌های سیاست: `.gitignore`، `.gitattributes` (LF)، `.editorconfig`
- ساختار: `apps/shop`، `apps/admin`، `packages/*`، `infra/compose`، `scripts`، `docs/*`
- مستندات: ۳۴ سند در ساختار شماره‌دار `docs/Management-00`…`docs/Engineering-04` + `product/` و `quality/`

### ۵.۲ گام ۳ — استک محلی بالا آمد (۱۴۰۵/۰۹/۰۳)

اعمال **D-09**: سرویس S3 (MinIO) به `profiles: ["storage"]` منتقل شد تا نبود تصویر آن، اجرای استک پایه را نشکند.

```
$ docker compose -f infra/compose/docker-compose.yml config --services
postgres
redis

$ docker compose -f infra/compose/docker-compose.yml --profile storage config --services
postgres
redis
minio

$ docker compose -f infra/compose/docker-compose.yml up -d
exit=0

$ docker compose -f infra/compose/docker-compose.yml ps
NAME           SERVICE    STATUS
fco-postgres   postgres   Up 31 seconds (healthy)
fco-redis      redis      Up 36 seconds (healthy)

$ docker exec fco-postgres pg_isready -U fco -d fco
/run/postgresql:5432 - accepting connections      (exit 0)

$ docker exec fco-postgres psql -U fco -d fco -tAc "select version();"
PostgreSQL 16.16 on x86_64-pc-linux-musl, compiled by gcc (Alpine 15.2.0) 15.2.0, 64-bit

$ docker exec fco-postgres psql -U fco -d fco -tAc "show timezone;"
UTC

$ docker exec fco-postgres psql -U fco -d fco -tAc "select now(), now() at time zone 'Asia/Tehran';"
2026-11-24 08:48:04.619897+00|2026-11-24 12:18:04.619897

$ docker exec fco-redis redis-cli ping
PONG

$ docker exec fco-redis redis-cli info server | grep redis_version
redis_version:7.4.12
```

| مورد | نتیجه |
|---|---|
| PostgreSQL | **healthy** — `accepting connections`، نسخه ۱۶.۱۶ |
| منطقه زمانی | `UTC` در ذخیره؛ تبدیل به `Asia/Tehran` (+۰۳:۳۰) درست است (ADR-006) |
| Redis | **healthy** — `PONG`، نسخه ۷.۴.۱۲ |
| S3/MinIO | **خارج از استک پایه** (D-09)؛ نیازمند `--profile storage`؛ مسدودکننده BR-1 نیست و برای BR-2 لازم می‌شود |

### ۵.۳ گام ۱۰ — گیت ممیزی اسناد (پیش‌اجرا)

```
$ python scripts/docs-audit.py
نتیجه: OK — بدون تکرار، بدون ارجاع شکسته، پایان خط LF.

# آزمون منفی (یک خط تکراری + یک فایل CRLF به‌صورت موقت تزریق شد):
نقض (2): تکرار خط بین اسناد … · پایان خط CRLF در 1 فایل
نتیجه: FAILED …        (exit 1)

# پس از بازگردانی:
نتیجه: OK …            (exit 0)
```

گیت در `.github/workflows/docs.yml` روی `push` به `main` و هر `pull_request` اجرا می‌شود و مسدودکننده است.
CI کامل (lint/typecheck/test/migration) همچنان **باز** است تا کد اپ و Migration وجود داشته باشد (گام ۴ و ۱۰).

### ۵.۴ گام ۴ — Migration پایه (۱۴۰۵/۰۹/۰۳)

محدوده: `iam` (users، roles، permissions، role_permissions، user_roles، sessions، password_resets) و `sys` (audit_log، outbox، inbox_events، idempotency_keys، job_runs، settings، setting_versions، schema_migrations). سیاست در `Architecture-02/DATABASE_DESIGN §5`؛ مالک جدول‌ها `§3.1` و `§3.11`.

عمداً بیرون از این Migration: `iam.otp_requests` (گام ۶)، `iam.mfa_factors` (گام ۵، مسدود تا ADR-007)، نقش کاربر اپ و GRANT (گام ۵)، جدول‌های دامنه (BR-2).

```
$ docker exec fco-postgres psql -U fco -d fco -tAc "select count(*) from information_schema.schemata
    where schema_name in ('iam','sys');"
0                                        # دیتابیس تازه (volume پاک و از نو بالا آمد)

$ bash scripts/db-migrate.sh up
→ اعمال 0001_init_base
1 Migration اعمال شد.                    (exit 0)

$ bash scripts/db-migrate.sh up
همه Migration ها اعمال شده‌اند — کاری نبود.   (exit 0 — تکرار بی‌اثر)

$ bash scripts/db-migrate.sh status
0001    0001_init_base            169eef5714cf  2026-11-24 09:25:36

$ bash scripts/db-migrate.sh verify
چک‌سام همه Migration های اعمال‌شده درست است.   (exit 0)
```

**قیدها و دفترهای تغییرناپذیر (اجرای واقعی):**

```
$ insert into iam.users (mobile, full_name) values ('12345','بد')
ERROR: new row for relation "users" violates check constraint "users_mobile_format"   (exit 1)

$ update sys.audit_log set action='tamper';
ERROR: FCO-DB-001: UPDATE روی audit_log مجاز نیست — این دفتر فقط INSERT می‌پذیرد   (exit 1)
$ delete from sys.audit_log;
ERROR: FCO-DB-001: DELETE روی audit_log مجاز نیست …                                   (exit 1)

$ update sys.outbox set payload='{"id":2}'::jsonb;
ERROR: FCO-DB-003: بدنه رویداد sys.outbox تغییرناپذیر است (id=1)                       (exit 1)
$ update sys.outbox set attempts = attempts + 1, processed_at = now();   -- مسیر مجاز Worker
UPDATE 1
$ delete from sys.outbox;
ERROR: FCO-DB-002: DELETE روی sys.outbox مجاز نیست                                     (exit 1)

$ insert into iam.sessions (…, expires_at = now()-'1 hour')
ERROR: violates check constraint "sessions_expiry_after_creation"                      (exit 1)
```

**زنجیره هویت (پس از رفع قید `roles_key_format`):**

```
insert iam.roles ('R-ADMIN','R-WH_MANAGER') → INSERT 0 2
insert iam.permissions ('user.read','setting.update') → INSERT 0 2
role_permissions × 2 · user_roles × 1 · sessions × 1

$ select u.mobile, r.key, count(distinct p.key) perms, … active_sessions …
 09120000000 | R-ADMIN | 2 | 1
```

**گیت‌های خود runner (آزمون منفی):**

| آزمون | دستور | نتیجه واقعی |
|---|---|---|
| تغییر فایل اعمال‌شده | ویرایش `0001_init_base.sql` سپس `up` | `exit 1` — «فایل اعمال‌شده تغییر کرده است» + چک‌سام ثبت‌شده/فعلی |
| اتمیک بودن | Migration معیوب آزمایشی `0002` (یک DDL موفق + یک دستور نامعتبر) | `exit 1`؛ جدول آزمایشی ساخته نشد (`probe_table_left=0`)؛ رکورد `0002` ثبت نشد |
| بازگشت کامل | `down all` | `1 Migration بازگشت داده شد`؛ `iam`/`sys` = ۰ schema، ۰ جدول |
| اجرا از صفر پس از بازگشت | `up` | `1 Migration اعمال شد` (exit 0) + `verify` سبز |

**نگاشت به `TEST_STRATEGY`:** `T-MIG-01` ✅ (زنجیره کامل روی دیتابیس خالی) · `T-MIG-03` ✅ (مسیر بازگشت مستند و اجراشده) · `T-MIG-02` ⏳ نیازمند یک Migration دوم (BR-2) و داده نسخه قبل.

**تصمیم‌های مرتبط:** D-10 (psql از طریق `docker exec`) و D-12 (ابزار Migration) در `DECISION_LOG` ثبت شدند.

## ۶. ریسک‌های شروع و پاسخ
bun خراب → npm · نبود psql → `docker exec` · CRLF → `.gitattributes` · نبود Sandbox درگاه → BR-1 مستقل است · فشار دمو → M1 جایگزین دموی ظاهری.

## ۷. گام بعدی
گام ۴: Migration پایه و جدول‌های IAM/Audit/Outbox/Setting، سپس گام ۵ (هویت و مجوز) با آزمون منفی.
