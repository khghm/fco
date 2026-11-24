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
| ۴ | Migration و اسکیمای پایه (IAM/Audit/Outbox/Setting) | اجرا از صفر + rollback | ⏳ |
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

## ۶. ریسک‌های شروع و پاسخ
bun خراب → npm · نبود psql → `docker exec` · CRLF → `.gitattributes` · نبود Sandbox درگاه → BR-1 مستقل است · فشار دمو → M1 جایگزین دموی ظاهری.

## ۷. گام بعدی
گام ۴: Migration پایه و جدول‌های IAM/Audit/Outbox/Setting، سپس گام ۵ (هویت و مجوز) با آزمون منفی.
