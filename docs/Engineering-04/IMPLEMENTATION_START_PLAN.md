# برنامه شروع پیاده‌سازی — BR-1 گام‌به‌گام

> **وضعیت:** تأییدشده · **نسخه:** v1.0 · **تاریخ:** ۱۴۰۵/۰۹/۰۲
> **خروجی ۱۰ از ۱۰** — وضعیت اجرا در انتهای همین سند ثبت می‌شود.

## ۱. وضعیت محیط (اندازه‌گیری‌شده)

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
| ۳ | محیط محلی Docker (PostgreSQL/Redis/MinIO) + فایل نمونه محیط | `docker compose config` معتبر + سرویس سالم | ✅ پیکربندی معتبر شد؛ راه‌اندازی در گام بعدی |
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

## ۵. ثبت اجرای گام ۱ تا ۳ (شاهد واقعی)

```
$ git init
Initialized empty Git repository in D:/Works/fco/.git/

$ git log --oneline -1
<first commit> chore: initialise repository with docs and skeleton

$ docker compose -f infra/compose/docker-compose.yml config --quiet
(exit 0 — configuration valid)
```

- فایل‌های سیاست: `.gitignore`, `.gitattributes` (LF), `.editorconfig`
- ساختار: `apps/shop`, `apps/admin`, `packages/*`, `docs/*`, `infra/compose`, `scripts`
- مستندات: ۲۰ سند در ساختار شماره‌دار `docs/Management-00`…`docs/Engineering-04` + `product/` و `quality/` (طبق `docs/README.md`)

## ۶. ریسک‌های شروع و پاسخ
bun خراب → npm · نبود psql → `docker exec` · CRLF → `.gitattributes` · نبود Sandbox درگاه → BR-1 مستقل است · فشار دمو → M1 جایگزین دموی ظاهری.

## ۷. گام بعدی
گام ۴: Migration پایه و جدول‌های IAM/Audit/Outbox/Setting، سپس گام ۵ (هویت و مجوز) با آزمون منفی.
