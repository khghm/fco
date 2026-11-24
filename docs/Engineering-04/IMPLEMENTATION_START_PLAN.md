# برنامه شروع پیاده‌سازی — BR-1 گام‌به‌گام

> **وضعیت:** تأییدشده · **نسخه:** v1.7 · **تاریخ:** ۱۴۰۵/۰۹/۰۳
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
| ۳ | ADR-007/008/009/010 | ✅ پذیرفته‌شده (ADR-007 در ۱۴۰۵/۰۹/۰۳ نهایی شد) |
| ۴ | مدیر بسته | ✅ npm |
| ۵ | محیط Production | ⏳ Q-11 پذیرفته؛ سرور مشخص نشده (مانع BR-1 نیست) |

## ۳. BR-1 — ده گام

| # | گام | شاهد پذیرش | وضعیت |
|---|---|---|---|
| ۱ | مخزن: `git init`، `.gitignore`، `.gitattributes`، `.editorconfig`، README | تاریخچه کامیت + فایل‌های سیاست | ✅ انجام شد |
| ۲ | اسکلت پوشه‌ها (`apps/`, `packages/`, `docs/`, `infra/`, `scripts/`) | ساختار قابل‌مشاهده و کامیت‌شده | ✅ انجام شد |
| ۳ | محیط محلی Docker (PostgreSQL/Redis + S3 اختیاری) + فایل نمونه محیط | `compose config` معتبر + سرویس‌های سالم | ✅ PostgreSQL 16.16 و Redis 7.4.12 هر دو healthy (شاهد: §5.۲) |
| ۴ | Migration و اسکیمای پایه (IAM/Audit/Outbox/Setting) | اجرا از صفر + rollback | ✅ ۱۵ جدول در `iam`/`sys`؛ از صفر، بازگشت، drift و اتمیک بودن آزمون شد (§5.۴) |
| ۵ | هویت و مجوز (ورود کارکنان، سیاست رمز، نشست، RBAC) | آزمون منفی دسترسی | ✅ `T-SEC-01/03/05/06` سبز + نقش اپ بدون DDL (§5.۵) |
| ۶ | OTP مشتری (توسعه: Spool) | انقضا/نرخ/ضد Brute Force | ✅ `T-SEC-12` + ۱۲ سناریوی منفی؛ Spool با پیش‌فرض خاموش (D-13، §5.۶) |
| ۷ | Audit و تنظیمات نسخه‌دار | رکورد قابل‌جست‌وجو + مجوز تغییر | ✅ `T-PLT-04/05` + ۱۷ سناریوی منفی؛ فقط مسیر تابع (§5.۷) |
| ۸ | Outbox/Queue Port/Worker/DLQ | اجرای دوبار بدون اثر تکراری | ✅ `T-PLT-01/02` + lease/برای تست؛ مسیر DLQ (§5.۸) |
| ۹ | رصد و پشتیبان + آزمون Restore | بازیابی مستند روی محیط جدا | ✅ `T-DR-01` + Job پاک‌سازی/retry/سقف + health (stuck) + GRANT بازیابی (§5.۹) |
| ۱۰ | CI پایه (lint/typecheck/test/migration/build) | CI برای خطای عمدی قرمز شود | ✅ پنج مرحله با شاهد قرمز/سبز + `dist/` تأییدشده (§5.۱۰) |

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
CI کامل (lint/typecheck/test/migration/build) در گام ۱۰ بسته شد؛ شاهد در §5.۱۰.

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

### ۵.۵ گام ۵ — هویت و مجوز (۱۴۰۵/۰۹/۰۳)

مبنای تصمیم: **ADR-007 پذیرفته شد** (کوکی `HttpOnly` + نشست سرور در `iam.sessions`، MFA TOTP برای نقش حساس).

محدوده `0002_identity_and_authorization`: `iam.mfa_factors`، پرچم `roles.requires_mfa`، بذر ۱۱ نقش و ۱۷ مجوز گروه `iam`/`platform`/`export`، `iam.sod_role_conflicts` + تریگر، سیاست رمز/نشست/قفل به‌صورت `sys.setting_versions`، توابع `iam.authorize`/`start_session`/`authenticate`/`revoke_session`/`set_password_hash`/`register_login_*`/`grant_role` و نقش `fco_app` با حداقل GRANT.

عمداً بیرون: هش Argon2id (لایه اپ)، UI ثبت TOTP، `iam.otp_requests` (گام ۶)، جدول تأییدهای Maker/Checker (BR-2).

```
$ bash scripts/db-migrate.sh up
→ اعمال 0002_identity_and_authorization
1 Migration اعمال شد.                                   (exit 0)

$ bash scripts/db-migrate.sh verify
چک‌سام همه Migration های اعمال‌شده درست است.              (exit 0)

$ select count(*) ...
11 roles | 17 permissions | 32 role-grant | 2 sod-rules | 9 auth-settings

$ bash scripts/db-migrate.sh down all
← بازگشت 0002_identity_and_authorization
← بازگشت 0001_init_base
2 Migration بازگشت داده شد.                              (exit 0)

$ select ... from information_schema.tables where table_schema in ('iam','sys');
0|0                                                      (۰ جدول، نقش اپ حذف‌شده)

$ bash scripts/db-migrate.sh up                            (از صفر)
→ اعمال 0001_init_base
→ اعمال 0002_identity_and_authorization
2 Migration اعمال شد.                                    (exit 0)
```

**آزمون منفی دسترسی (`packages/infrastructure/tests/0005_identity_negative.sql`، اجرای واقعی):**

```
PASS T-SEC-01 | بدون مجوز → FCO-1003: مجوز iam.audit.read برای این کاربر وجود ندارد
PASS T-SEC-01 | با مجوز iam.audit.read عبور کرد
PASS T-SEC-01 | مجوز تعریف‌نشده رد شد
PASS T-SEC-03 | SoD-7 (ترکیب نقش) → FCO-1004: … ترکیب نقش‌های R-FIN و R-SYS … مجاز نیست
PASS T-SEC-03 | SoD-4 (تخصیص به خود) → FCO-1004
PASS T-SEC-03 | Maker=Checker → FCO-1004 / Maker≠Checker عبور کرد
PASS T-SEC-06 | بدون MFA → FCO-1006: ورود نقش حساس بدون MFA تأییدشده مسدود است
PASS T-SEC-06 | پس از تأیید TOTP نشست ساخته شد (a837bb54-…)
PASS T-SEC-05 | نشست معتبر شناسایی شد → پس از ابطال → FCO-1001: نشست ابطال شده است
PASS T-SEC-05 | تغییر رمز همه نشست‌ها را باطل کرد
PASS POLICY   | رمز کوتاه / رمز رایج / تنوع ناکافی → FCO-1007، رمز مطابق سیاست عبور کرد
PASS LOCK     | پس از ۵ تلاش قفل تا 2026-11-24 11:37:20+00
PASS APP-ROLE | DDL مسدود · درج Audit مجاز · تغییر/حذف Audit مسدود · Outbox مستقیم مسدود
ALL STEP-5 NEGATIVE CASES PASSED                          (exit 0)
```

**اثبات کارکرد آزمون (کنترل آگاهانه برداشته شد):**

```
$ alter table iam.user_roles disable trigger user_roles_sod_conflict;
$ <همان فایل آزمون>
ERROR: FAIL T-SEC-03: ترکیب R-SYS + R-FIN پذیرفته شد      (exit 3)

$ alter table iam.user_roles enable trigger user_roles_sod_conflict;
$ <همان فایل آزمون>
ALL STEP-5 NEGATIVE CASES PASSED                          (exit 0)
```

**`T-MIG-02` — اجرا روی نسخه قبل با داده نمونه:** ابتدا فقط `0001` اعمال و یک کاربر/نقش/تنظیم نمونه ساخته شد؛ سپس `0002` اجرا شد:

```
09120000009|کارمند نسخه قبل|R-FIN|t|11|{"fa": "فروشگاه"}
```

یعنی داده قدیمی دست‌نخورده ماند، نشست/رمز نسخه قبل معتبر نماند (بدون رکورد نشست) و پرچم `requires_mfa` نقش موجود از `false` به `true` ارتقا یافت (بذر `on conflict do update`).

**محدودیت‌های اعلام‌شده:** لایه HTTP و use-case اپ هنوز نوشته نشده؛ آزمون‌ها در سطح توابع امنیتی و نقش DB اجرا شدند و نگاشت `42501→403`/`28000→401` در نخستین endpoint آزموده می‌شود. هش Argon2id در لایه اپ ساخته می‌شود (این‌جا فقط هش و سیاست). `fco_app` نقش `NOLOGIN` است؛ رمز آن باید از محیط/مخزن اسرار تزریق شود. `T-SEC-02/04/07` باز است.

### ۵.۶ گام ۶ — OTP مشتری (۱۴۰۵/۰۹/۰۳)

**بازبینی تازه گام ۵** سه شکاف و یک باگ واقعی پیدا کرد که در `0003_identity_hardening` بسته شدند:

| مورد | مشکل | اصلاح |
|---|---|---|
| `iam.sessions` | اپ اجازه INSERT داشت؛ می‌شد بدون `start_session` و بدون MFA نشست ساخت | نوشتن نشست فقط از تابع؛ اپ فقط SELECT |
| `iam.users` | UPDATE/INSERT کامل اجازه تغییر یا درج `password_hash` دور از ابطال نشست‌ها را می‌داد | GRANT ستونی (جدول و ستون جدا لغو شد)؛ `password_hash` فقط از `set_password_hash` |
| قفل ورود | پس از انقضای `locked_until` هیچ مسیر موفقی نبود؛ کاربر برای همیشه قفل می‌ماند | `iam.unlock_if_expired` در شروع ورود |
| هش رمز | فقط طول بررسی می‌شد | قالب Argon2id یا bcrypt با cost ≥ ۱۲ الزامی شد |

شاهد اصلاح در همان مجموعه گام ۵ (پنج مورد جدید؛ مجموع ۳۱ PASS):

```
PASS APP-ROLE | درج مستقیم نشست مسدود شد
PASS APP-ROLE | تغییر مستقیم password_hash مسدود شد
PASS APP-ROLE | درج کاربر با password_hash مسدود شد · ایجاد کاربر بدون ستون رمز مجاز بود
PASS HASH     | قالب نامعتبر → FCO-1008: هش رمز باید Argon2id یا bcrypt با cost ≥ 12 باشد
PASS LOCK     | قفل فعال ورود را رد کرد · قفل منقضی خودکار آزاد شد و نشست ساخته شد
```

محدوده `0004_otp_customer`: `iam.otp_requests` (یک کد فعال در هر موبایل+هدف)، `sys.otp_spool` توسعه، هفت تنظیم `auth.otp.*` نسخه‌دار، و توابع `request_otp`/`verify_otp`/`spool_otp`/`read_spool` بدون هیچ GRANT جدولی به اپ.

```
$ bash scripts/db-migrate.sh down all
4 Migration بازگشت داده شد.                              (exit 0)

$ bash scripts/db-migrate.sh up                           (از صفر)
→ اعمال 0001_init_base
→ اعمال 0002_identity_and_authorization
→ اعمال 0003_identity_hardening
→ اعمال 0004_otp_customer
4 Migration اعمال شد.                                    (exit 0)

$ bash scripts/db-migrate.sh verify
چک‌سام همه Migration های اعمال‌شده درست است.              (exit 0)
```

**آزمون منفی OTP (`tests/0007_otp_negative.sql`، خروجی واقعی):**

```
PASS OTP | درخواست کد ساخته شد و کد در Spool توسعه خوانده شد
PASS OTP | cooldown ارسال → FCO-1013
PASS OTP | درخواست جدید کد فعال قبلی را باطل کرد
PASS OTP | کد باطل‌شده → invalid
PASS OTP | پنج تلاش غلط شمرده و پایدار شد (attempts=5)
PASS OTP | پس از سقف تلاش → locked
PASS OTP | سقف پنجره موبایل → FCO-1012
PASS OTP | کد منقضی → invalid
PASS OTP | مصرف یک‌باره کد (ok سپس invalid)
PASS OTP | موبایل ناموجود همان مسیر را طی کرد (بدون شمارش کاربر)
PASS OTP | سقف پنجره IP → FCO-1012
PASS SPOOL | خاموش → FCO-1017 · بدون تنظیم، هیچ کد خامی ذخیره نشد
PASS APP-ROLE | درج مستقیم iam.otp_requests / خواندن مستقیم Spool مسدود شد
ALL STEP-6 NEGATIVE CASES PASSED                          (exit 0)
```

**باگی که همین آزمون پیدا کرد:** در نسخه اول `verify_otp` پس از افزایش `attempts` استثنا می‌داد؛ چون استثنا همان دستور را بازمی‌گرداند، شمارنده هیچ‌وقت ذخیره نمی‌شد و محافظت Brute Force بی‌اثر بود (`FAIL OTP: شمارش تلاش نادرست است (0)`). اکنون تابع وضعیت `ok|invalid|locked` برمی‌گرداند و اپ آن را به ۲۰۰/۴۰۰/۴۲۹ نگاشت می‌کند.

**اثبات کارکرد آزمون:** با تنظیم `auth.otp.resend_seconds = 0` (ضعیف‌کردن کنترل) همان فایل با `FAIL OTP: ارسال مجدد پیش از cooldown پذیرفته شد` و `exit 3` قرمز شد؛ پس از حذف آن نسخه تنظیم، دوباره سبز شد.

**محدودیت‌ها:** آداپتور پیامک واقعی و UI ورود مشتری در BR-2؛ این گام فقط قرارداد سرور و قواعد ضدسوءاستفاده را می‌بندد. اتصال OTP به حساب `R-CUST` و صدور نشست مشتری در use-case بعدی می‌آید؛ Spool باید در Production خاموش بماند (D-13).

### ۵.۷ گام ۷ — Audit و تنظیمات نسخه‌دار (۱۴۰۵/۰۹/۰۳)

محدوده `0005_audit_and_settings`:

| مؤلفه | قاعده اعمال‌شده |
|---|---|
| `sys.audit_write` | تنها مسیر نوشتن Audit؛ actor موجود، `action`/`entity_type` غیرخالی، حداقل یکی از before/after، `request_id` اجباری |
| `sys.audit_search` | مجوز `iam.audit.read`؛ فیلتر entity/actor/action/بازه زمانی؛ سقف سخت ۱۰۰ ردیف، پیش‌فرض ۵۰ |
| `sys.setting_set` | مجوز `platform.setting.write`؛ دلیل اجباری؛ تاریخ اعتبار غیرگذشته؛ Audit در همان تراکنش |
| `setting_versions` | فقط‌افزودنی و ترتیبی؛ نسخه جدید بازه قبلی را می‌بندد؛ تغییر مقدار و حذف نسخه رد می‌شود |
| عملیات حساس | `iam.grant_role` و `iam.set_password_hash` خودشان Audit می‌نویسند (حتی اگر لایه اپ فراموش کند) |

INSERT مستقیم اپ روی `sys.audit_log` لغو شد (D-14)؛ آزمون گام ۵ هم به مسیر تابع منتقل شد.

```
$ bash scripts/db-migrate.sh down all
5 Migration بازگشت داده شد.                              (exit 0)

$ bash scripts/db-migrate.sh up                           (از صفر)
→ اعمال 0001_init_base
→ اعمال 0002_identity_and_authorization
→ اعمال 0003_identity_hardening
→ اعمال 0004_otp_customer
→ اعمال 0005_audit_and_settings
5 Migration اعمال شد.                                    (exit 0)
```

**آزمون منفی (`tests/0008_audit_settings_negative.sql`، خروجی واقعی):**

```
PASS AUDIT | request_id خالی → FCO-1018
PASS AUDIT | بدون before/after → FCO-1018
PASS AUDIT | actor ناموجود → FCO-1005
PASS AUDIT | بدون iam.audit.read → FCO-1003
PASS AUDIT | جست‌وجوی فیلترشده با مجوز کار کرد
PASS AUDIT | سقف ۱۰۰ و پیش‌فرض ۵۰ اعمال شد
PASS SETTING | بدون platform.setting.write → FCO-1003
PASS SETTING | بدون دلیل → FCO-1022
PASS SETTING | کلید ناشناخته → FCO-1021
PASS SETTING | تاریخ اعتبار گذشته → FCO-1023
PASS SETTING | تغییر معتبر + بستن بازه + Audit ثبت شد
PASS SETTING | نسخه آینده مقدار جاری را تغییر نداد
PASS SETTING | نسخه خارج از ترتیب → FCO-1020
PASS SETTING | بازنویسی نسخه قدیمی → FCO-1025
PASS SETTING | حذف نسخه → FCO-1025
PASS AUDIT | تخصیص نقش خودکار Audit شد
PASS AUDIT | تغییر رمز خودکار Audit شد
PASS AUDIT | فیلتر زمانی from/to کار کرد
ALL STEP-7 NEGATIVE CASES PASSED                          (exit 0)
```

**اثبات کارکرد آزمون:** با `alter table sys.setting_versions disable trigger setting_versions_guard` همان فایل با `FAIL SETTING: بازه نسخه قبلی بسته نشد` و `exit 3` قرمز شد؛ پس از فعال‌سازی دوباره سبز شد.

**گیت قدیمی:** مجموعه گام ۵ با ۳۲ PASS و گام ۶ بدون تغییر سبز ماندند؛ `verify` هم سبز است.

**محدودیت‌ها:** «تلاش ردشده» (403/429) در Audit نمی‌آید چون Exception تراکنش را بازمی‌گرداند؛ رفع آن با Logger/Outbox بیرونی در گام ۸ است و در `SECURITY_ARCHITECTURE §13` ثبت شد. صفحه Audit، Export و جست‌وجوی متنی در BR-2/BR-3 می‌آید؛ این گام فقط مسیر ثبت و جست‌وجوی ساختاریافته را می‌بندد.

### ۵.۸ گام ۸ — Outbox، Queue Port، Worker و DLQ (۱۴۰۵/۰۹/۰۳)

**اصلاح بازبینی گام ۷ (`0006`):** Audit تغییر رمز actor را برابر کاربر هدف می‌گذاشت. اکنون عامل واقعی پارامتر جداست و کاربر هدف در `entity_id` می‌ماند:

```
PASS AUDIT | تغییر رمز: actor=مدیر، entity=کاربر هدف
PASS AUDIT | self-service: actor=entity=کاربر
PASS AUDIT | عامل ناموجود → FCO-1005
```

**مدل گام ۸ (`0007_outbox_queue`):** تولید فقط با `sys.outbox_emit` در تراکنش کسب‌وکار؛ تحویل با `sys.outbox_claim` روی `FOR UPDATE SKIP LOCKED` **به‌همراه lease** (۶۰ ثانیه، نسخه‌دار) تا دو Worker هم‌زمان یک رویداد نگیرند؛ `attempts` در همان claim +۱ می‌شود؛ پس از `outbox.max_attempts` رویداد به DLQ می‌رود و دیگر تحویل نمی‌شود؛ مصرف با `sys.inbox_consume` و کلید `event_id` ایدم‌پوتنت است؛ فهرست DLQ مجوز `platform.dlq.inspect` می‌خواهد.

```
$ bash scripts/db-migrate.sh down all
7 Migration بازگشت داده شد.                              (exit 0)

$ bash scripts/db-migrate.sh up                           (از صفر)
→ اعمال 0001_init_base … 0007_outbox_queue
7 Migration اعمال شد.                                    (exit 0)
```

**آزمون‌ها (`tests/0009_outbox_negative.sql`، خروجی واقعی):**

```
PASS OUTBOX | نام رویداد نامعتبر → FCO-1030
PASS OUTBOX | payload غیرشیء → FCO-1030
PASS OUTBOX | aggregate_type خالی → FCO-1030
PASS OUTBOX | تحویل اول انجام شد (attempts=1)
PASS OUTBOX | lease مانع تحویل هم‌زمان شد
PASS OUTBOX | رویداد تکمیل‌شده دوباره تحویل نشد
PASS DLQ | پس از ۵ تلاش dead_letter شد و دیگر تحویل نمی‌شود
PASS INBOX | تحویل دوباره اثر تکراری نداد (کلید = event_id)
PASS DLQ | بدون platform.dlq.inspect → FCO-1003
PASS DLQ | فهرست با مجوز ۱ ردیف داد
PASS APP-ROLE | درج مستقیم Outbox مسدود شد · تولید فقط از تابع
ALL STEP-8 NEGATIVE CASES PASSED                          (exit 0)
```

**اثبات کارکرد آزمون:** با `grant insert on sys.outbox` و `grant usage on sequence sys.outbox_id_seq` به `fco_app` همان فایل با `FAIL APP-ROLE: درج مستقیم Outbox مجاز بود` و `exit 3` قرمز شد؛ پس از `revoke` دوباره سبز شد. (اجرای اول sabotage با گرانت جدول تنها، گمراه‌کننده بود چون نبود دسترسی sequence هم مانع درج می‌شد — همین نکته ثبت شد.)

**گیت‌های قبلی:** `down all` → `up` از صفر **۷ Migration**؛ هر چهار مجموعه `0005/0007/0008/0009` سبز؛ `verify` سبز.

**محدودیت‌ها:** فرایند Worker (Node) و پایش عمق صف/سن پیام در گام ۹ می‌آید؛ این گام قرارداد DB و ایدم‌پوتنسی را می‌بندد. بازگشت `0007` تاریخچه `outbox.*` را پاک نمی‌کند (حذف نسخه تنظیم ممنوع است) و بذر آن فقط در نبود نسخه اجرا می‌شود.

### ۵.۹ گام ۹ — رصد، پشتیبان و تمرین بازیابی (۱۴۰۵/۰۹/۰۳)

محدوده `0008_ops_monitoring`: `sys.job_begin`/`job_finish` (یک اجرا در هر slot)، `sys.purge_expired_sessions` (فقط منقضی/باطل قدیمی‌تر از grace)، `sys.run_session_cleanup` (Job با ثبت در `job_runs` و idempotent)، و `sys.health_report` (عمق و سن صف، DLQ، نشست‌ها، کاربران قفل‌شده، Jobهای ناموفق، تعداد Migration) با مجوز `platform.health.read`. دو تنظیم نسخه‌دار `session.purge_grace_hours` و `job.session_cleanup.batch` اضافه شد.

```
$ bash scripts/db-migrate.sh down all
8 Migration بازگشت داده شد.                              (exit 0)

$ bash scripts/db-migrate.sh up
→ اعمال 0001_init_base … 0010_job_limits
10 Migration اعمال شد.                                    (exit 0)
```

**آزمون منفی (`tests/0010_ops_negative.sql`، خروجی واقعی):**

```
PASS JOB | هر slot یک‌بار شروع می‌شود
PASS JOB | پایان دوباره → FCO-1040
PASS JOB | نام خالی → FCO-1041
PASS CLEANUP | فقط نشست منقضی قدیمی حذف شد (نشست فعال و در grace ماند)
PASS CLEANUP | Job یک‌بار ran شد و دوباره already_ran
PASS CLEANUP | دسته نامعتبر → FCO-1041
PASS HEALTH | بدون platform.health.read → FCO-1003
PASS HEALTH | گزارش با مجوز و محتوای صف/نشست/Job
PASS APP-ROLE | حذف مستقیم نشست مسدود شد · پاک‌سازی فقط از تابع
ALL STEP-9 NEGATIVE CASES PASSED                          (exit 0)
```

**تمرین واقعی بازیابی (`scripts/db-backup-restore-drill.sh`):** یک کپی `fco_drill_source` از دیتابیس ساخته می‌شود، داده نمونه (کاربر، نشست، رویداد Outbox، رکورد Audit) در آن تزریق می‌شود، سپس `pg_dump -Fc` و بازیابی در دیتابیس جدا با `--exit-on-error` و مقایسه اثر انگشت:

```
$ bash scripts/db-backup-restore-drill.sh
dump=/tmp/fco-20261124T125915Z.dump bytes=126342
backup_host=/d/Works/fco/backups/fco-20261124T125915Z.dump
source_fingerprint=20|1|11|32|1|1|1|20|20|8|6e9578f1…|8d9f6760…
restored_fingerprint=20|1|11|32|1|1|1|20|20|8|6e9578f1…|8d9f6760…
PASS restore: fingerprint برابر و داده نمونه سالم است (1|1|1|1)
restore_seconds=40
app_query_source=11|false|false|true
app_query_restored=11|false|false|true
PASS grants: دسترسی fco_app در بازیابی مانند منبع است و نوشتن مستقیم بسته ماند
PASS negative: پشتیبان مخدوش رد شد
نتیجه: OK — پشتیبان سالم بازیابی شد و پشتیبان مخدوش رد شد.   (exit 0)
```

**اثبات کارکرد آزمون:** با `grant delete on iam.sessions to fco_app` همان فایل با `FAIL APP-ROLE: حذف مستقیم نشست مجاز بود` و `exit 3` قرمز شد؛ پس از `revoke` سبز شد.

**GRANT در بازیابی:** `pg_restore` دیگر بدون `--no-privileges` اجرا می‌شود؛ سپس همان کوئری با `set role fco_app` روی **منبع و بازیابی** زده و نتیجه مقایسه می‌شود (خواندن نقش‌ها + بسته‌بودن INSERT نشست و UPDATE Audit + بازبودن SELECT نقش‌ها). برابری دو نتیجه یعنی GRANTها حفظ شده‌اند و پسوند ثابت یعنی سخت‌گیری دسترسی اپ هم از دست نرفته است؛ اگر GRANT نیامده باشد، کوئری با خطای دسترسی شکست می‌خورد.

**بازبینی تلاش دوباره Job (`0009`):** پیش از این، slot شکست‌خورده تا ابد مسدود می‌ماند. اکنون همان رکورد با `attempt+1` دوباره `running` می‌شود؛ slot موفق یا در حال اجرا باز نمی‌شود:

```
PASS RETRY | همان slot با attempt=2 دوباره running شد
PASS RETRY | slot در حال اجرا دوباره شروع نشد
PASS RETRY | slot موفق دوباره باز نشد
```

اثبات آزمون: بازگرداندن تعریف قبلی `sys.job_begin` ⇒ `FAIL RETRY: slot شکست‌خورده دوباره باز نشد` و `exit 3`؛ پس از اجرای دوباره `0009` سبز شد.

**بازبینی `0010` — سقف تلاش، شکست ماندگار و Job گیرکرده:** سه شکاف واقعی بسته شد: (۱) تلاش دوباره بی‌سقف بود و یک Job خراب می‌توانست در همان slot حلقه بزند؛ (۲) `run_session_cleanup` در exception بلافاصله `raise` می‌کرد و چون Postgres کل تراکنش را برمی‌گرداند، رکورد `failed` و `attempt` هرگز ذخیره نمی‌شد؛ (۳) گزارش سلامت اجرای `running` قدیمی (Worker مرده) را از اجرای سالم تشخیص نمی‌داد.

```
PASS CAP | سقف 3 تلاش → FCO-1042: سقف تلاش 3 برای Job retry_cap_probe …
PASS CLEANUP | شکست Job با outcome=failed ثبت شد
PASS CLEANUP | تلاش دوباره همان slot ran شد (attempt=2)
PASS HEALTH | Job گیرکرده در stuck/stuck_runs دیده شد
PASS HEALTH | Job با تلاش تمام‌شده در exhausted_24h دیده شد
```

آستانه‌ها تنظیم نسخه‌دارند: `job.max_attempts=3` و `job.stuck_after_minutes=30`. `run_session_cleanup` شکست را با `outcome='failed'` برمی‌گرداند (بدون rollback) تا caller هشدار بدهد؛ سکوت ممنوع است.

اثبات آزمون‌ها: `job_begin` بی‌سقف ⇒ `FAIL CAP: تلاش بیش از سقف 3 پذیرفته شد`؛ `run_session_cleanup` قدیمی ⇒ خطای `FCO-1041` به‌جای رکورد شکست؛ `health_report` قدیمی ⇒ `FAIL HEALTH: stuck_runs شامل stuck_probe نیست`. همه پس از بازگرداندن `0010` سبز شدند.

**گیت‌ها:** هر پنج مجموعه `0005/0007/0008/0009/0010` سبز و `verify` سبز.

**محدودیت‌ها:** فرایند Worker و Endpoint پایش هنوز نوشته نشده (گام ۱۰/BR-3)؛ پشتیبان offsite و رمزنگاری آن منتظر مشخص‌شدن سرور Production (Q-11) است و تمرین فعلی روی همان میزبان است. حذف نشست پس از grace یک عملیات نگهداشت است، نه حذف PII (که منتظر LEG-EXT/ADR-010 است).

### ۵.۱۰ گام ۱۰ — CI پایه (۱۴۰۵/۰۹/۰۳)

`scripts/ci.sh` پنج مرحله را روی **دیتابیس‌های یکبارمصرف** اجرا می‌کند تا دیتابیس توسعه (`fco`) دست‌نخورده بماند. همان اسکریپت در `.github/workflows/ci.yml` با سرویس `postgres:16` اجرا می‌شود؛ محلی از `docker exec` و در CI با `PSQL=psql` مستقیم وصل می‌شود.

| مرحله | چه چیزی را واقعاً می‌سنجد | شاهد |
|---|---|---|
| `lint` | ممیزی اسناد، `bash -n` روی اسکریپت‌ها، CRLF/فاصله انتهایی در همه فایل‌های ردیابی‌شده | ۸۴ فایل پاک · ۲ اسکریپت سالم |
| `typecheck` | هر Migration باید `.down.sql` داشته باشد؛ همه روی دیتابیس خالی کامپایل شوند؛ ۱۹ جدول و ۱۷ تابع کلیدی موجود باشند | `PASS 10 Migration با فایل بازگشت` · `PASS ۱۹ جدول` · `PASS ۱۷ تابع` |
| `test` | هر پنج مجموعه منفی روی دیتابیس تازه، با بررسی `ALL STEP-` | `PASS ۵ مجموعه آزمون سبز` |
| `migration` | `up` از صفر، `up` دوباره بی‌اثر، `verify`، **آزمون منفی drift**، `down all` → `up` | `PASS 10 Migration` · `PASS چک‌سام` · `PASS تغییر فایل اعمال‌شده رد شد` · `PASS بازگشت کامل` |
| `build` | ساخت `dist/fco-schema.sql` + `dist/manifest.json` و اثبات با اجرای بسته روی دیتابیس تازه و مقایسه fingerprint | `bundle=113943 bytes · migrations=10` · `build_fingerprint = bundle_fingerprint` |

```
$ bash scripts/ci.sh all
== lint | ممیزی اسناد …
PASS بدون تکرار خط/ردیف، ارجاع شکسته یا CRLF در اسناد
== typecheck | اجرای همه Migrationها روی fco_ci_typecheck
PASS همه Migrationها کامپایل شدند
== test | 0010_ops_negative.sql
PASS ۵ مجموعه آزمون سبز
server=disposable:fco-ci-migrate-…
PASS 10 Migration اعمال شد
PASS تغییر فایل اعمال‌شده رد شد
PASS بازگشت کامل و اجرای دوباره از صفر
build_fingerprint=20|38|10|9ae0a0bf2a2c33eeb73e5d5417d6f3e8
bundle_fingerprint=20|38|10|9ae0a0bf2a2c33eeb73e5d5417d6f3e8
PASS بسته خودکفاست و fingerprint برابر است
== CI PASS | lint · typecheck · test · migration · build

real    4m42.358s                                  (exit 0)
```

**قرمزهای عمدی (هر چهار مورد واقعاً قرمز شدند و پس از بازگردانی سبز):**

| مرحله | دستکاری | نتیجه واقعی |
|---|---|---|
| `lint` | یک فایل موقت با CRLF در `docs/` | `FAIL: ممیزی اسناد قرمز شد` (exit 1) |
| `typecheck` | Migration معیوب `9999_broken.sql` در دایرکتوری موقت (`FCO_MIGRATIONS_DIR`) | `ERROR: syntax error at or near ";"` → `FAIL: Migration روی دیتابیس خالی اجرا نشد` (exit 1) |
| `test` | افزودن `grant insert on iam.sessions to fco_app` به نسخه موقت `0003` | `FAIL: 0005_identity_negative.sql قرمز شد (exit 3)` |
| `migration` | تغییر فایل اعمال‌شده (این آزمون **درون** مرحله است تا بی‌اثر شدن گیت چک‌سام لو برود) | سناریوی دستکاری‌شده رد می‌شود؛ اگر گیت بی‌اثر شود خود مرحله قرمز می‌شود |

**دو شکاف واقعی که همین گام پیدا کرد و بسته شد:**

1. `down all` نقش مشترک `fco_app` را حذف می‌کند و اگر دیتابیس دیگری (مثل `fco`) شیئی وابسته داشته باشد شکست می‌خورد؛ پس این مرحله روی یک کانتینر `postgres:16-alpine` یکبارمصرف اجرا می‌شود (همان چیزی که CI واقعی دارد).
2. آمادگی کانتینر با `pg_isready` گمراه‌کننده بود: سرور موقت مرحله init پاسخ می‌داد و بعد خاموش می‌شد؛ اکنون تا دو کوئری موفق پایدار صبر می‌شود.

**محدودیت‌ها:** هنوز کد اپ (TypeScript) وجود ندارد، بنابراین `lint` فقط اسناد/اسکریپت/SQL را می‌سنجد و `typecheck` همان کامپایل SQL است؛ ESLint/`tsc`/باندلر با نخستین کد اپ در BR-2 اضافه می‌شوند. `build` در این مرحله «بسته schema + manifest» است، نه باینری اپ. workflow گیت‌هاب محلی اجرا نشد (runner موجود نیست)؛ شاهد محلی همان `scripts/ci.sh all` است. زمان اجرای محلی روی ویندوز ۴ دقیقه و ۴۲ ثانیه است (سرباز `docker exec`) و در CI لینوکسی کمتر خواهد بود.

## ۶. ریسک‌های شروع و پاسخ
bun خراب → npm · نبود psql → `docker exec` · CRLF → `.gitattributes` · نبود Sandbox درگاه → BR-1 مستقل است · فشار دمو → M1 جایگزین دموی ظاهری.

## ۷. گام بعدی
BR-1 بسته شد؛ گام بعدی **M1** (نمایش زنجیره کامل: ورود → Audit → Job → DLQ → Restore) و سپس BR-2 (آداپتور پیامک، صفحه Audit، UI مشتری، فرایند Worker) است.
