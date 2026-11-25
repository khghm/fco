# تغییرات (CHANGELOG)

> **وضعیت:** زنده · **نسخه:** v1.10 · **آخرین به‌روزرسانی:** ۱۴۰۵/۰۹/۰۴
> قالب بر پایه Keep a Changelog، تاریخ‌ها شمسی + ISO. هر تغییر در **رفتار، دامنه یا ساختار اسناد** یک ردیف اینجا دارد.
> شاهد هر نسخه: `git show --stat <commit>`.
> **مالک تاریخ تغییرات اسناد و مخزن.**

---

## [Unreleased]

### Planned
- BR-2: آداپتور پیامک، صفحه Audit، UI مشتری، فرایند Worker

---

## [0.14.0] — ۱۴۰۵/۰۹/۰۴ (2026-11-25)

### Added
- `scripts/m1-chain.sh` — سناریوی پذیرش M1 روی دو دیتابیس یکبارمصرف: ورود، Audit، Job/Outbox تا DLQ، و `pg_dump`/`pg_restore` با مقایسه اثر انگشت.
- `packages/infrastructure/scenarios/m1_chain.sql` — زنجیره با نقش `fco_app`، پنج آزمون منفی و شاهد پایانی `ALL M1 CHAIN STEPS PASSED`.

### Changed
- `IMPLEMENTATION_START_PLAN §4/§5.۱۱` (v1.8)، `TEST_STRATEGY §6` (`T-M1-01`)، `DECISION_LOG` D-20.

### Verified
- `M1 CHAIN PASS | login → audit → job → dlq → restore (43s)`؛ اثر انگشت منبع و بازیابی برابر: `2|2|1|1|10|35fb5897e171d075d9e650906671fb5b`.
- قرمز عمدی: برداشتن گاردِ نوشتن مستقیم Audit ⇒ `FAIL AUDIT: نوشتن مستقیم روی sys.audit_log مجاز بود` و `FAIL: سناریوی M1 قرمز شد (exit 3)`؛ پس از بازگردانی، سناریو سبز شد.
- پشتیبان مخدوش و کوئری‌های بدون مجوز (`platform.job.run`، `iam.audit.read`، `platform.dlq.inspect`) رد شدند؛ کوئری `fco_app` روی دیتابیس بازیابی `1|1|false` داد.

---

## [0.13.0] — ۱۴۰۵/۰۹/۰۳ (2026-11-24)

### Added
- `scripts/ci.sh` — پنج مرحله `lint`، `typecheck`، `test`، `migration`، `build` روی دیتابیس‌های یکبارمصرف؛ `PSQL` برای اجرای مستقیم در CI و پیش‌فرض `docker exec` محلی.
- `.github/workflows/ci.yml` — همان مراحل با سرویس `postgres:16` و بارگذاری آرتیفکت `dist/`.
- `dist/fco-schema.sql` + `dist/manifest.json` (ساخت‌شده، gitignore) — بسته schema خودکفا که روی دیتابیس تازه با fingerprint برابر تأیید می‌شود.

### Changed
- `IMPLEMENTATION_START_PLAN §5.۱۰` (اجرا با شاهد واقعی)، `TEST_STRATEGY §6`، `DECISION_LOG` D-19، هدرهای نسخه.
- `$ bash scripts/ci.sh all` کامل: `CI PASS | lint · typecheck · test · migration · build` در ۴ دقیقه و ۴۲ ثانیه محلی.

### Fixed
- مرحله Migration روی کانتینر موقت اجرا می‌شود، چون `down all` نقش مشترک `fco_app` را حذف می‌کند و با شیءهای وابسته در `fco` شکست می‌خورد.
- آمادگی کانتینر با دو کوئری موفق پایدار سنجیده می‌شود؛ `pg_isready` به سرور موقت مرحله init پاسخ می‌داد و سپس خاموش می‌شد.

### Verified
- هر پنج مرحله سبز؛ قرمزهای عمدی: CRLF در اسناد → lint، Migration معیوب → typecheck، `grant insert on iam.sessions` → test (exit 3)، تغییر فایل اعمال‌شده → مرحله migration.
- `build_fingerprint = bundle_fingerprint = 20|38|10|9ae0a0bf2a2c33eeb73e5d5417d6f3e8`.

---

## [0.12.0] — ۱۴۰۵/۰۹/۰۳ (2026-11-24)

### Added
- `packages/infrastructure/migrations/0010_job_limits.sql` (+ `.down.sql`) — سقف `job.max_attempts` (عبور → `FCO-1042`)، آستانه `job.stuck_after_minutes` و `jobs.stuck`/`stuck_runs`/`exhausted_24h` در `health_report`.
- آزمون‌های `PASS CAP`، ماندگاری شکست Job و `PASS HEALTH | stuck/exhausted` در `tests/0010_ops_negative.sql`.

### Fixed
- `run_session_cleanup` دیگر در exception `raise` نمی‌کند (که کل تراکنش و رکورد `failed` را برمی‌گرداند)؛ شکست با `outcome='failed'` ثبت و برگردانده می‌شود.
- Drill: کوئری `fco_app` روی منبع و بازیابی زده و مقایسه می‌شود؛ برابری + پسوند ثابت، حفظ GRANTها و سخت‌گیری دسترسی را با هم اثبات می‌کند.

### Verified
- `down all` → `up`: ۱۰ Migration؛ هر پنج مجموعه سبز؛ `verify` سبز؛ Drill با schema 0010.
- `restore_seconds=40`، `app_query_source=app_query_restored=11|false|false|true`، پشتیبان مخدوش رد شد، `exit 0`.
- اثبات منفی: `job_begin` بی‌سقف ⇒ `FAIL CAP`؛ `run_session_cleanup` قدیمی ⇒ `FCO-1041` بدون رکورد شکست؛ `health_report` قدیمی ⇒ `FAIL HEALTH: stuck_runs شامل stuck_probe نیست`.

---

## [0.11.0] — ۱۴۰۵/۰۹/۰۳ (2026-11-24)

### Added
- `packages/infrastructure/migrations/0009_job_retry.sql` (+ `.down.sql`) — slot `failed` با `attempt+1` دوباره `running` می‌شود؛ slot `succeeded`/`running` همچنان مسدود است.
- `tests/0010_ops_negative.sql` — `PASS RETRY` برای بازشدن slot شکست‌خورده، بسته‌ماندن slot در حال اجرا و slot موفق.

### Changed
- `scripts/db-backup-restore-drill.sh` — GRANTها بازیابی می‌شوند (حذف `--no-privileges`) و پس از Restore کوئری واقعی با `set role fco_app` اجرا و ارزیابی می‌شود.
- `BACKUP_AND_RECOVERY §7.1`، `DECISION_LOG` D-16/D-17، `DATABASE_DESIGN §3.11`، `TEST_STRATEGY §6`، `IMPLEMENTATION_START_PLAN §5.۹`.

### Verified
- `up` از صفر: ۹ Migration؛ هر پنج مجموعه سبز؛ `verify` سبز.
- Drill: اثر انگشت برابر، `app_query=11|false|false|true`، `PASS grants`، پشتیبان مخدوش رد شد، `restore_seconds=43`، `exit 0`.
- اثبات آزمون retry: بازگرداندن `job_begin` قبلی ⇒ `FAIL RETRY: slot شکست‌خورده دوباره باز نشد` و `exit 3`؛ پس از `0009` سبز.

---

## [0.10.0] — ۱۴۰۵/۰۹/۰۳ (2026-11-24)

### Added
- `packages/infrastructure/migrations/0008_ops_monitoring.sql` (+ `.down.sql`) — `sys.job_begin`/`job_finish` (یک اجرا در هر slot)، `sys.purge_expired_sessions` (با grace و دسته محدود)، `sys.run_session_cleanup` (Job ایدم‌پوتنت با ثبت `job_runs`) و `sys.health_report` (عمق/سن صف، DLQ، نشست، کاربران قفل، Jobهای ناموفق) با مجوز `platform.health.read`.
- `packages/infrastructure/tests/0010_ops_negative.sql` — Job slot، پایان دوباره، اندازه دسته، حذف فقط نشست منقضی، idempotency پاک‌سازی، مجوز و محتوای گزارش سلامت.
- `scripts/db-backup-restore-drill.sh` — تمرین تکرارپذیر پشتیبان/بازیابی: کلون دیتابیس، داده نمونه، `pg_dump -Fc`، بازیابی در دیتابیس جدا، مقایسه اثر انگشت، و آزمون منفی پشتیبان مخدوش.

### Changed
- `BACKUP_AND_RECOVERY §7.1` — اولین Drill واقعی ثبت شد (schema 0008، ۳۴ ثانیه روی همین میزبان، اثر انگشت برابر).
- `DECISION_LOG` D-16، `DATABASE_DESIGN §3.11`، `TEST_STRATEGY §6`، `IMPLEMENTATION_START_PLAN §3/§5.۹/§7`.

### Verified
- `down all` → `up` از صفر: ۸ Migration؛ `verify` سبز؛ هر پنج مجموعه آزمون سبز.
- `0010` → `ALL STEP-9 NEGATIVE CASES PASSED`؛ Drill → `PASS restore` و `PASS negative`، `exit 0`، ۳۴ ثانیه.
- اثبات آزمون: گرانت `DELETE` روی `iam.sessions` به `fco_app` ⇒ `FAIL APP-ROLE` و `exit 3`؛ پس از `revoke` سبز.

### Known gaps
- فرایند Worker (Node)، Endpoint/متریک پایش و Job پاک‌سازی نشست در زمان‌بند واقعی هنوز نیست.
- پشتیبان offsite و رمزنگاری منتظر Q-11؛ Drill فعلی روی همان میزبان است و RTO آن Production نیست.

---

## [0.9.0] — ۱۴۰۵/۰۹/۰۳ (2026-11-24)

### Added
- `packages/infrastructure/migrations/0006_password_change_actor.sql` (+ `.down.sql`) — عامل واقعی تغییر رمز پارامتر جداست و `actor_id` در Audit همان عامل است؛ کاربر هدف در `entity_id` و `after.target_user_id` می‌ماند.
- `packages/infrastructure/migrations/0007_outbox_queue.sql` (+ `.down.sql`) — `sys.outbox_emit`، `sys.outbox_claim` (SKIP LOCKED + lease)، `sys.outbox_complete`/`fail` (انتقال به DLQ پس از سقف)، `sys.inbox_consume` ایدم‌پوتنت و `sys.dlq_list` با مجوز.
- `packages/infrastructure/tests/0009_outbox_negative.sql` — اعتبارسنجی رویداد، lease/ضدتحویل هم‌زمان، مسیر شکست تا DLQ، مصرف دوباره و مجوز DLQ.

### Changed
- دو تنظیم نسخه‌دار `outbox.lease_seconds` و `outbox.max_attempts` (بدون عدد هارد‌کد در کد).
- `tests/0008` — دو سناریوی جدید برای actor واقعی و self-service تغییر رمز + عامل ناموجود.
- `DECISION_LOG` D-15، `DATABASE_DESIGN §3.11`، `TEST_STRATEGY §6`، `IMPLEMENTATION_START_PLAN §3/§5.۸/§7`.

### Fixed
- Audit تغییر رمز، عامل عملیات را ثبت می‌کند نه کاربر هدف؛ پیش از این بازنشانی رمز توسط مدیر به نام خود کارمند ثبت می‌شد.

### Verified
- `down all` → `up` از صفر: ۷ Migration؛ `verify` سبز.
- هر چهار مجموعه `0005/0007/0008/0009` سبز؛ `0009` → `ALL STEP-8 NEGATIVE CASES PASSED`.
- اثبات آزمون: گرانت `INSERT` روی `sys.outbox` به `fco_app` ⇒ `FAIL APP-ROLE` و `exit 3`؛ پس از `revoke` سبز.

### Known gaps
- فرایند Worker (Node)، پایش عمق/سن صف و Job پاک‌سازی نشست در گام ۹.
- بازگشت `0007` تاریخچه تنظیم `outbox.*` را حفظ می‌کند (حذف نسخه ممنوع)؛ بذر آن فقط در نبود نسخه اجرا می‌شود.

---

## [0.8.0] — ۱۴۰۵/۰۹/۰۳ (2026-11-24)

### Added
- `packages/infrastructure/migrations/0005_audit_and_settings.sql` (+ `.down.sql`) — `sys.audit_write` (actor/request_id/before-after اجباری)، `sys.audit_search` (مجوز `iam.audit.read`، سقف ۱۰۰)، `sys.setting_set` (مجوز، دلیل، تاریخ اعتبار غیرگذشته، Audit هم‌تراکنش)، تریگر تغییرناپذیری/ترتیب `setting_versions`، و Audit خودکار `iam.grant_role`/`iam.set_password_hash`.
- `packages/infrastructure/tests/0008_audit_settings_negative.sql` — ۱۸ سناریوی منفی/مثبت برای Audit و تنظیم نسخه‌دار، از جمله سقف صفحه، بازنویسی تاریخچه و نسخه خارج از ترتیب.

### Changed
- INSERT مستقیم `fco_app` روی `sys.audit_log` لغو شد؛ آزمون گام ۵ به مسیر `sys.audit_write` منتقل شد (۳۲ PASS).
- `DECISION_LOG` — D-14 (نوشتن Audit/تنظیم فقط از تابع) و ردیف اثر آن.
- `DATABASE_DESIGN §3.11`، `SECURITY_ARCHITECTURE §13`، `TEST_STRATEGY §6`، `IMPLEMENTATION_START_PLAN §3/§5.۷/§7` با شاهدهای واقعی گام ۷.

### Verified
- `down all` → `up` از صفر: ۵ Migration؛ `verify` سبز.
- `tests/0008` → `ALL STEP-7 NEGATIVE CASES PASSED`، `exit 0`؛ `tests/0005` → ۳۲ PASS؛ `tests/0007` سبز.
- اثبات آزمون: غیرفعال‌کردن `setting_versions_guard` ⇒ `FAIL SETTING` و `exit 3`؛ پس از بازگردانی، سبز.

### Known gaps
- تلاش‌های ردشده (۴۰۳/۴۲۹) Audit نمی‌شوند (Exception تراکنش را بازمی‌گرداند) — رفع با Logger/Outbox بیرونی در گام ۸.
- صفحه Audit، Export و جست‌وجوی متنی در BR-2/BR-3؛ `T-SEC-02/04/07` باز.

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
