# تغییرات (CHANGELOG)

> **وضعیت:** زنده · **نسخه:** v1.3 · **آخرین به‌روزرسانی:** ۱۴۰۵/۰۹/۰۳
> قالب بر پایه Keep a Changelog، تاریخ‌ها شمسی + ISO. هر تغییر در **رفتار، دامنه یا ساختار اسناد** یک ردیف اینجا دارد.
> شاهد هر نسخه: `git show --stat <commit>`.
> **مالک تاریخ تغییرات اسناد و مخزن.**

---

## [Unreleased]

### Planned
- گام ۷: Audit و تنظیمات نسخه‌دار
- گام ۸: Outbox/Queue Port/Worker/DLQ و Job پاک‌سازی نشست
- BR-2: آداپتور پیامک واقعی و UI ورود/ثبت مشتری

---

## [0.7.0] — ۱۴۰۵/۰۹/۰۳ (2026-11-24)

### Added
- `packages/infrastructure/migrations/0003_identity_hardening.sql` (+ `.down.sql`) — بستن شکاف‌های بازبینی گام ۵: حذف INSERT/UPDATE مستقیم `iam.sessions` از اپ (دور زدن MFA)، GRANT ستونی `iam.users` (دور زدن ابطال نشست هنگام تغییر رمز)، `iam.unlock_if_expired` برای قفل موقت، و اعتبارسنجی قالب هش Argon2id/bcrypt.
- `packages/infrastructure/migrations/0004_otp_customer.sql` (+ `.down.sql`) — `iam.otp_requests` با یک کد فعال در هر موبایل+هدف، `sys.otp_spool` توسعه، هفت تنظیم `auth.otp.*` نسخه‌دار، و توابع `request_otp`/`verify_otp`/`spool_otp`/`read_spool`.
- `packages/infrastructure/tests/0007_otp_negative.sql` — ۱۲ سناریوی منفی OTP (cooldown، سقف موبایل/IP، باطل‌شدن کد قبلی، کد غلط/منقضی/مصرف‌شده، قفل تلاش، موبایل ناموجود، Spool خاموش و دسترسی مستقیم اپ).

### Fixed
- **شمارنده تلاش OTP پایدار نبود:** `verify_otp` پس از افزایش `attempts` استثنا می‌داد و استثنا همان دستور را بازمی‌گرداند؛ نتیجه: محافظت Brute Force عملاً بی‌اثر. اکنون وضعیت `ok|invalid|locked` برمی‌گردد.
- **قفل ورود دائمی می‌شد:** پس از انقضای `locked_until` هیچ مسیر موفقی وجود نداشت؛ `start_session` قفل منقضی را آزاد می‌کند.
- **دور زدن MFA و چرخش نشست از طریق نوشتن مستقیم:** با GRANT حداقلی بسته شد.

### Changed
- `DECISION_LOG` — D-13 (Spool OTP فقط توسعه، پیش‌فرض خاموش) و ردیف اثر آن.
- `SECURITY_ARCHITECTURE §2`، `DATABASE_DESIGN §3.1`، `TEST_STRATEGY §6`، `IMPLEMENTATION_START_PLAN §3/§5.۶/§7` با شاهدهای واقعی گام ۵ (بازبینی) و گام ۶.
- `tests/0005_identity_negative.sql` — پنج آزمون جدید برای نشست، `password_hash` (UPDATE و INSERT)، ایجاد کاربر و قالب هش + آزمون آزادسازی قفل منقضی (۳۱ PASS).

### Verified
- `down all` → `up` از صفر: ۴ Migration و `verify` سبز؛ `has_table_privilege('fco_app','iam.users','INSERT|UPDATE')` و `iam.sessions INSERT` همگی `false`.
- `tests/0005` → ۳۱ PASS، `exit 0`؛ `tests/0007` → `ALL STEP-6 NEGATIVE CASES PASSED`، `exit 0`.
- اثبات آزمون: `auth.otp.resend_seconds = 0` ⇒ `FAIL OTP` و `exit 3`؛ پس از بازگردانی تنظیم، سبز.

### Known gaps
- آداپتور پیامک و UI/use-case ورود مشتری در BR-2؛ اتصال OTP به حساب `R-CUST` هنوز پیاده نشده.
- `T-SEC-02/04/07` و نگاشت HTTP کدهای خطا (§6 آزمون) باز است.

---

## [0.6.0] — ۱۴۰۵/۰۹/۰۳ (2026-11-24)

### Added
- `docs/Architecture-02/ADR/ADR-007-auth-session-strategy.md` — ADR-007 نهایی شد: نشست کوکی سمت سرور در `iam.sessions` (منبع حقیقت) + MFA TOTP اجباری برای نقش حساس؛ JWT بی‌وضعیت و `localStorage` رد شدند.
- `packages/infrastructure/migrations/0002_identity_and_authorization.sql` (+ `.down.sql`) — `iam.mfa_factors`، `roles.requires_mfa`، `iam.common_passwords`، `iam.sod_role_conflicts` + تریگر، بذر ۱۱ نقش/۱۷ مجوز/۳۲ نگاشت، ۹ تنظیم `auth.*` نسخه‌دار، توابع `iam.authorize`/`start_session`/`authenticate`/`revoke_*`/`set_password_hash`/`register_login_*`/`grant_role`/`sys.assert_separation`، نقش DB `fco_app` با GRANT حداقلی.
- `packages/infrastructure/tests/0005_identity_negative.sql` — مجموعه آزمون منفی `T-SEC-01/03/05/06` + سیاست رمز + قفل ورود + دسترسی نقش اپ؛ در پایان `rollback`.

### Changed
- `DECISION_LOG` — ADR-007 به «پذیرفته و اجراشده» تغییر کرد، از فهرست تصمیم‌های معلق حذف شد و ردیف اثر آن اضافه شد.
- `SECURITY_ARCHITECTURE §2/§13`، `DATABASE_DESIGN §3.1`، `TEST_STRATEGY §6`، `ADR/README` و `IMPLEMENTATION_START_PLAN §3/§5.۵/§7` با وضعیت واقعی گام ۵ هم‌راستا شدند.

### Verified
- `up` روی ۰۰۰۱ موجود → `1 Migration اعمال شد`؛ `verify` سبز؛ ۱۱ نقش، ۱۷ مجوز، ۳۲ نگاشت، ۲ قاعده SoD، ۹ تنظیم.
- `down all` → ۰ جدول در `iam`/`sys` و حذف نقش `fco_app`؛ سپس `up` از صفر → ۲ Migration و آزمون‌های منفی سبز.
- `T-MIG-02`: اجرای `0002` روی داده نسخه قبل → کاربر/نقش/تنظیم حفظ شد و `requires_mfa` نقش موجود ارتقا یافت.
- آزمون منفی موفق (`ALL STEP-5 NEGATIVE CASES PASSED`) و **آزمون اثبات آزمون**: با غیرفعال‌کردن تریگر SoD، همان فایل با `FAIL T-SEC-03` و `exit 3` قرمز شد و پس از فعال‌سازی دوباره سبز شد.

### Known gaps
- لایه HTTP/use-case اپ وجود ندارد؛ نگاشت `42501→403 FCO-1003` و `28000→401 FCO-1001` هنوز در endpoint آزموده نشده است.
- هش Argon2id و UI ثبت TOTP در BR-2؛ Job پاک‌سازی نشست در گام ۸؛ `T-SEC-02/04/07` باز.

---

## [0.5.0] — ۱۴۰۵/۰۹/۰۳ (2026-11-24)

### Added
- `packages/infrastructure/migrations/0001_init_base.sql` (+ `.down.sql`) — Migration پایه: schemaهای `iam` و `sys`، ۱۵ جدول (هویت/نشست، حسابرسی، Outbox/Job/Idempotency، تنظیمات نسخه‌دار) با قیدهای ضد‌باگ و دفترهای تغییرناپذیر.
- `scripts/db-migrate.sh` — اجرای `up`/`down`/`status`/`verify` روی psql داخل کانتینر، چک‌سام SHA-256، تراکنش اتمیک، رد تغییر فایل اعمال‌شده، الزام مسیر بازگشت.

### Changed
- `DECISION_LOG` — D-12 (ابزار Migration) ثبت و ردیف اثر تصمیم‌ها برای D-07/D-10/D-12 اضافه شد؛ ردیف تکراری D-09 در بخش اثر تصمیم‌ها اصلاح شد.
- `DATABASE_DESIGN §5` — نام‌گذاری Migration، جدول وضعیت، چک‌سام، دستورها و ممنوعیت تغییر تاریخی اضافه شد.
- `IMPLEMENTATION_START_PLAN` — گام ۴ از BR-1 ✅ و شاهد کامل در `§5.۴`.

### Verified
- اجرا از صفر (DB خالی) → `1 Migration اعمال شد`؛ اجرای دوباره بی‌اثر؛ `verify` سبز.
- `down all` → ۰ جدول در `iam`/`sys`؛ سپس `up` دوباره سبز.
- آزمون منفی: mobile نامعتبر، UPDATE/DELETE روی `audit_log`، تغییر payload و DELETE روی `outbox`، نشست با انقضای گذشته — همه رد شدند.
- تغییر فایل اعمال‌شده → `exit 1`؛ Migration معیوب آزمایشی → `exit 1` و هیچ اثر باقی‌مانده (اتمیک).

### Known gaps
- `T-MIG-02` (اجرا روی نسخه قبل) تا ساخته‌شدن Migration دوم (BR-2) قابل اجرا نیست.
- نقش/GRANT کاربر اپ و `iam.otp_requests`/`mfa_factors` عمداً در گام ۵/۶ ساخته می‌شوند.

---

## [0.4.0] — ۱۴۰۵/۰۹/۰۳ (2026-11-24)

### Added
- `scripts/docs-audit.py` — ممیز دائمی اسناد: تکرار خط (≥۴۰ کاراکتر) و ردیف جدول بین اسناد، ارجاع شکسته، پایان خط CRLF. کد خروج ۱ در صورت نقض؛ پشتیبانی از `--verbose`.
- `.github/workflows/docs.yml` — اجرای ممیز روی `push` به `main` و هر `pull_request` به‌صورت **مسدودکننده**.

### Changed
- **D-09 اعمال شد:** سرویس S3/MinIO در `infra/compose/docker-compose.yml` به `profiles: ["storage"]` منتقل شد. استک پایه (`up -d`) فقط PostgreSQL و Redis را بالا می‌آورد؛ اجرای کامل با `--profile storage up -d`. یادداشت در `.env.example` و `DECISION_LOG`.
- `Engineering-04/IMPLEMENTATION_START_PLAN.md §5` بازنویسی شد: شاهد واقعی گام ۳ (سلامت PostgreSQL/Redis، نسخه‌ها، منطقه زمانی، `PING`) و شاهد منفی/مثبت ممیز.
- `Engineering-04/IMPLEMENTATION_PLAN.md §6` گیت «ممیزی اسناد» به جدول CI اضافه شد؛ `docs/README.md §10` قاعده اجرای ممیز پیش از کامیت.

### Verified
- `python scripts/docs-audit.py` → `OK` (۳۵ فایل، صفر تکرار/ارجاع شکسته/CRLF).
- آزمون منفی: تزریق یک خط تکراری و یک فایل CRLF → `exit 1` و گزارش دقیق؛ پس از بازگردانی → `exit 0`.
- `docker compose up -d` → `exit 0`؛ `fco-postgres` healthy (PostgreSQL 16.16، `pg_isready` = accepting connections، `timezone` = UTC، تهران +۰۳:۳۰)، `fco-redis` healthy (`PONG`، 7.4.12).

### Note
- CI کامل (lint/typecheck/test/migration) عمداً ساخته نشد؛ کد اپ و Migration هنوز وجود ندارد (BR-1 گام ۴ و ۱۰).

---

## [0.3.1] — ۱۴۰۵/۰۹/۰۳ (2026-11-24)

### Changed — پاک‌سازی تکرار و تثبیت تک‌منبعی
هیچ محتوای جدیدی اضافه نشد؛ فقط ۷ سند از تکرار پاک شد و ارجاع گرفت:

| سند | تکرار حذف‌شده | مالک جدید |
|---|---|---|
| `Business-01/ROLE_WORKFLOW_MATRIX.md` | جدول ۱۱ نقش + جدول مجوزها/SoD | `USER_ROLES_AND_PERMISSIONS §2/§3` |
| `quality/MICRO_UX_STANDARDS.md` §2/§3 | جدول کامل تقویم و اعداد | `PERSIAN_UX_STANDARDS §3/§4` |
| `UX-03/DESIGN_SYSTEM.md` §6 | چک‌لیست کامل دسترس‌پذیری | `MICRO_UX_STANDARDS §8` |
| `Architecture-02/SYSTEM_ARCHITECTURE.md` §3/§4/§6 | فهرست جداول، قرارداد API، متن امنیت | `DATABASE_DESIGN` / `API_SPECIFICATION` / `SECURITY_ARCHITECTURE` |
| `Engineering-04/IMPLEMENTATION_PLAN.md` §4.1 | جدول ده‌گام BR-1 | `IMPLEMENTATION_START_PLAN §3` |
| `Engineering-04/TEST_STRATEGY.md` §9 | عدد بودجه LCP (تکرار عدد) | `MICRO_UX_STANDARDS §10` |
| `Business-01/BUSINESS_WORKFLOWS.md` | — (فقط مرز با `ROLE_SCENARIOS` روشن شد) | — |

### Added
- `Management-00/PROJECT_MASTER_CONTROL.md §4.2` — جدول **مالکیت محتوا** برای ۲۳ موضوع: هر واقعیت یک سند مالک دارد و بقیه فقط ارجاع می‌دهند.

### Verified
- جدول نقش‌ها: ۱ نسخه (قبلاً ۳) · جدول تاریخ/عدد: ۱ نسخه (قبلاً ۲) · چک‌لیست دسترس‌پذیری: ۱ نسخه (قبلاً ۲) · جدول ده‌گام BR-1: ۱ نسخه (قبلاً ۲).
- ممیزی نهایی: **صفر** خط تکرارشده با طول ≥۴۰ کاراکتر و **صفر** ردیف جدول تکراری بین ۳۴ سند؛ صفر ارجاع شکسته به اسناد موجود؛ صفر کاراکتر غیرفارسی سرگردان؛ پایان خط LF در همه اسناد.
- هر سند یک خط «مالک این سند» در سرصفحه دارد (۳۱ سند محتوایی).

---

## [0.3.0] — ۱۴۰۵/۰۹/۰۳ (2026-11-24)

### Added — تکمیل مجموعه اسناد طبق ساختار هدف
پوشه‌بندی شماره‌دار جایگزین پوشه‌های موضوعی قدیمی شد (D-08) و ۱۸ سند مفقود تولید شد:

| پوشه | سند | موضوع |
|---|---|---|
| `Management-00` | `PROJECT_MASTER_CONTROL.md` | منشور، اصول ۱۰گانه، فضای نام شناسه‌ها، گیت‌ها، قاعده شاهد |
| `Management-00` | `PROJECT_ROADMAP.md` | توالی فازها/برش‌ها، مسیر بحرانی، تعریف پیشرفت |
| `Management-00` | `DECISION_LOG.md` | فهرست واحد تصمیم‌ها (Q/ADR/D) و گزینه‌های رد‌شده |
| `Management-00` | `RISK_REGISTER.md` | R-01..R-22 با مالک، پاسخ و شاهد |
| `Management-00` | `CHANGELOG.md` | همین سند |
| `Business-01` | `BUSINESS_REQUIREMENTS.md` | الزامات کسب‌وکار `BRQ-*`، دامنه in/out، قواعد پذیرش |
| `Business-01` | `USER_ROLES_AND_PERMISSIONS.md` | کاتالوگ مجوز، ماتریس نقش×مجوز، SoD، آستانه تأیید |
| `Business-01` | `BUSINESS_WORKFLOWS.md` | `WF-01..WF-20` با وضعیت، سند، SLA، مسیر شکست |
| `Architecture-02` | `DATABASE_DESIGN.md` | اسکیما، جداول، قیدها، ایندکس، Migration، نگهداشت |
| `Architecture-02` | `API_SPECIFICATION.md` | قراردادها، کدهای خطا `FCO-*`، کاتالوگ endpoint |
| `Architecture-02` | `SECURITY_ARCHITECTURE.md` | مدل تهدید STRIDE، احراز هویت، رمزنگاری، آزمون امنیتی |
| `UX-03` | `DESIGN_SYSTEM.md` | توکن‌ها، مؤلفه‌ها و حالت‌ها، RTL، دسترس‌پذیری |
| `UX-03` | `PERSIAN_UX_STANDARDS.md` | زبان، لحن، واژه‌نامه، تاریخ/عدد، قالب پیام و فاکتور |
| `UX-03` | `ADMIN_PANEL_SPECIFICATION.md` | IA، کاتالوگ صفحه، صف کار، صفحه اسکن، مجوزها |
| `Engineering-04` | `IMPLEMENTATION_PLAN.md` | ساختار مخزن، استک، ترتیب BR، CI، DoD |
| `Engineering-04` | `TEST_STRATEGY.md` | سطوح آزمون، داده، آزمون هم‌زمانی/امنیت/بازیابی، گیت‌ها |
| `Engineering-04` | `DEPLOYMENT_GUIDE.md` | محیط‌ها، نصب، TLS، Migration، انتشار، Rollback |
| `Engineering-04` | `BACKUP_AND_RECOVERY.md` | لایه‌های پشتیبان، رمزنگاری offsite، رویه Restore و DR |

### Changed
- ساختار اسناد: `business/` → `Business-01/`، `architecture/` → `Architecture-02/`، `operations/IMPLEMENTATION_START_PLAN.md` → `Engineering-04/`.
- `docs/README.md` بازنویسی شد (فهرست واحد ۲۰ سندی + نقشه نگاشت مسیر قدیم/جدید).
- `README.md` ریشه به مسیرهای جدید ارجاع می‌دهد.
- اصلاح تایپی: `بدوn` → `بدون` (`product/CAPABILITY_MAP.md`)، `ففقط` → `فقط` (`quality/FAILURE_MODE_ANALYSIS.md`).

### Decisions
- D-08 ساختار پوشه شماره‌دار؛ D-09 سرویس S3 اختیاری در استک پایه؛ D-11 سرصفحه اجباری در هر سند.

---

## [0.2.0] — ۱۴۰۵/۰۹/۰۲

### Added
- ADR-008 (صف روی PostgreSQL)، ADR-009 (FIFO + لایه هزینه)، ADR-010 (نگهداشت سه‌لایه)
- `product/OPEN_DECISIONS.md` با پذیرش Q-02/Q-04/Q-06/Q-11

### Changed
- `Architecture-02/SYSTEM_ARCHITECTURE.md` بخش ADRها و نگاشت برش‌ها به‌روزرسانی شد.

---

## [0.1.1] — ۱۴۰۵/۰۹/۰۲

### Added
- اسکلت مخزن: `apps/{shop,admin}`، `packages/{domain,application,infrastructure,integrations,ui,formatting,config,testing}`، `infra/{compose,deploy,backup,monitoring}`، `scripts/`
- `infra/compose/docker-compose.yml` (PostgreSQL 16، Redis 7، MinIO) + healthcheck
- سیاست‌های مخزن: `.gitignore`، `.gitattributes` (LF)، `.editorconfig`، `.env.example`

### Verified
- `docker compose config --quiet` → exit 0

---

## [0.1.0] — ۱۴۰۵/۰۹/۰۲

### Added
- مخزن Git (شاخه `main`)، کامیت اول `d33c5c4`
- ۱۰ خروجی طراحی فاز ۰ (شناخت، قابلیت‌ها، بلوپرینت عملیات، سناریوهای نقش، معماری، Micro-UX، FMEA، برنامه نسخه‌ها، ماتریس نقش، برنامه شروع)

### Known limitations
- `bun` روی محیط توسعه خراب است → مدیر بسته npm (D-05)
- `psql` نصب نیست → دستورات DB با `docker exec` (D-10)
- تصویر MinIO در دسترس نبود → راه‌اندازی استک پایه در گام بعد (D-09، R-17)

---

## قواعد به‌روزرسانی این سند

1. هر تغییر رفتار/دامنه/ساختار = یک ورودی؛ تغییر تایپی خرد = جمع‌شده در `Changed`.
2. «Added» فقط چیز واقعی موجود در مخزن، نه برنامه.
3. نسخه‌بندی: `MAJOR` تغییر دامنه یا ساختار بنیادین · `MINOR` سند/قابلیت جدید · `PATCH` اصلاح.
4. هیچ ورودی بدون شاهد (فایل/کامیت/خروجی دستور).
