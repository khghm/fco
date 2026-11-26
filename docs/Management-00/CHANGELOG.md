# تغییرات (CHANGELOG)

> **وضعیت:** زنده · **نسخه:** v1.21 · **آخرین به‌روزرسانی:** ۱۴۰۵/۰۹/۰۵
> قالب بر پایه Keep a Changelog، تاریخ‌ها شمسی + ISO. هر تغییر در **رفتار، دامنه یا ساختار اسناد** یک ردیف اینجا دارد.
> شاهد هر نسخه: `git show --stat <commit>`.
> **مالک تاریخ تغییرات اسناد و مخزن.**

---

## [Unreleased]

### Planned
- BR-2 گام ۵ به بعد: رندر صفحات عمومی پس از اسکلت اپ (D-05) و پنل محصول/قیمت

---

## [0.20.5] — ۱۴۰۵/۰۹/۰۵ (2026-11-26)

### Changed (بازبینی تازه روی `feea3f2`: سنجه‌های گزارش رصد)
- **انتظارهای `health_report` به مقایسه دقیق رسید:** `expiry_failures`، `expiry_failures_open`، `max_failures` و `oldest_first_failed_at` حالا با همان کوئری‌هایی که آزمون از جدول می‌گیرد مقایسه می‌شوند و تاریخ‌های `top_failures` باید عیناً برابر جدول باشند (پیش‌تر نبودنشان و «بزرگ‌تر از صفر بودن» سنجیده می‌شد).
- فیکسچر سوئیت `0021` یک رزرو «شکست‌خورده و سپس رفع‌شده» گرفت، پس `expiry_failures_open` از `expiry_failures` تفکیک‌شدنی است و `status=released` هم در فهرست دیده می‌شود.
- هیچ Migration‌ای در این بازبینی تغییر نکرد؛ تنها سوئیت و اسناد. (کد بی‌مصرفی که در دو Migration منتشرنشده یافت شد — `max_failures` تکراری با `top_failures[0].failures` و تنظیم بازنشسته `failure_keep` از 0019 — به تصمیم ادغام 0019–0021 گره خورده است.)

### Verified
- `CI PASS | lint · typecheck · test · migration · build` · `PASS 21 Migration` · `PASS 15 مجموعه آزمون سبز` · `build_fingerprint = bundle_fingerprint = 33|57|21|6c484cd5426d87060cbefdbb5f4c53c4` (exit 0؛ بدون تغییر Migration، پس fingerprint مثل 0.20.4 مانده).
- سوئیت 0021 روی دیتابیس تازه با ۲۱ Migration: `PASS HEALTH | کل/باز/بیشینه دقیقاً 2/1/3`، `PASS TIME`، `PASS PERM`.
- قرمز عمدی D–G (هر چهار exit 3): برداشتن فیلتر `status='active'` ⇒ `FAIL HEALTH: expiry_failures_open=2 (انتظار 1)`؛ `max`→`min` ⇒ `max_failures=1 (انتظار 3)`؛ `occurred_at` جای `first_failed_at` ⇒ `FAIL HEALTH: first_failed_at گزارش … (جدول …)`؛ `order by failures asc` ⇒ `FAIL HEALTH: فهرست top_failures با بیشترین شکست مرتب نشده است`.

## [0.20.4] — ۱۴۰۵/۰۹/۰۵ (2026-11-26)

### Fixed (بازبینی پنجم: زمان شکست و دیده‌شدن شکست‌های مکرر)
- **`first_failed_at` حالا واقعاً «نخستین» است:** در 0020 زمان شکست با `now()` نوشته می‌شد که ابتدای تراکنش است؛ سه slot پیوسته یک لحظه می‌گرفتند و بررسی «تاریخ نخستین شکست حفظ شد» در سوئیت 0020 تشریفاتی بود (فقط `<=` سنجیده می‌شد). `0021_reservation_expiry_failure_visibility` زمان واقعی را با `clock_timestamp()` می‌نویسد و `first_failed_at` را در `on conflict` بازنویسی نمی‌کند؛ سوئیت 0020 حالا نخستین را پس از شکست بیست‌وهشتم دست‌نخورده و `occurred_at` را اکیداً صعودی می‌سنجد.
- **شکست‌های مکرر انقضا دیده می‌شوند:** `sys.health_report` بخش `reservations` گرفت — `expiry_failures` (شمار رزروهای شکست‌خورده)، `expiry_failures_open` (از آن‌ها که هنوز `active`اند و موجودی رزروشده را قفل نگه داشته‌اند)، `max_failures`، `oldest_first_failed_at` و `top_failures` (۱۰ رزرو بدتر با `failures`، تاریخ نخستین/آخرین شکست، `sqlstate`، `status` و انبار/تنوع). مجوز همان `platform.health.read` است.

### Added
- Migration `0021_reservation_expiry_failure_visibility` (+`.down.sql` که تعریف 0020 و `health_report` 0010 را عیناً برمی‌گرداند) و سوئیت `0021_reservation_expiry_failure_visibility_negative`: `PASS TIME`/`PASS HEALTH`/`PASS PERM`.

### Verified
- `CI PASS | lint · typecheck · test · migration · build` · `PASS 21 Migration` · `PASS 15 مجموعه آزمون سبز` · `build_fingerprint = bundle_fingerprint = 33|57|21|6c484cd5426d87060cbefdbb5f4c53c4` (exit 0).
- سوئیت 0021: `PASS TIME` (سه slot ⇒ نخستین شکست ثابت، آخرین شکست اکیداً جلو، `failures=3`)، `PASS HEALTH` (رزرو خراب با `failures=3`/`status=active`/`23514` در `top_failures`؛ رزرو سالم نیامد؛ فهرست مرتب) و `PASS PERM` (`FCO-1003`).
- سوئیت‌های `0010` (که `health_report` را می‌سنجد)، `0017`، `0018` و `0020` روی 0021 سبز ماندند.
- قرمز عمدی A: بازگرداندن `now()` (بدنه 0020) ⇒ `FAIL SINGLE: نخستین و آخرین شکست از هم تفکیک نشدند (...)` (exit 3).
- قرمز عمدی B: افزودن `first_failed_at = v_failed_at` به `on conflict` ⇒ `FAIL TIME: تاریخ نخستین شکست در دور 2 بازنویسی شد` (exit 3).
- قرمز عمدی C: حذف بخش `reservations` از `health_report` ⇒ `FAIL HEALTH: بخش reservations در گزارش نیست` (exit 3)، سپس بازگرداندن سبز.

## [0.20.3] — ۱۴۰۵/۰۹/۰۵ (2026-11-26)

### Changed (بازبینی چهارم روی 0019: نگهداشت ساختاری، نه هرس)
- **هرس داخل بلوک `exception` حذف شد:** در 0019 نگهداشت در همان زیرتراکنشی اجرا می‌شد که خطای رزرو را مدیریت می‌کند؛ خطای همان `DELETE` به بلوک بیرونی می‌رسید، آزادسازی‌های موفق همان دسته را برمی‌گرداند و Job را `failed` می‌کرد — یعنی `job.max_attempts` را می‌سوزاند، همان چیزی که 0017 عمداً از آن پرهیز داشت. حالا هیچ `delete`ی در مسیر شکست نیست.
- **دامنه و سقف اختراعی حذف شد:** هرس فقط رزروهایی را می‌دید که در همان دور شکست می‌خوردند (رزرو رفع‌شده سابقه‌اش را برای همیشه نگه می‌داشت و کم‌کردن سقف ردیف‌های موجود را هرس نمی‌کرد) و عدد ۲۴ فقط «یک روز در آهنگ ساعتی» را رمز می‌کرد و سیگنال «چند بار شکست خورد» را با حذف ردیف‌ها از بین می‌برد.
- **نگهداشت ساختاری شد:** `0020_reservation_expiry_failure_single_row` یکتایی `reservation_id` را می‌گذارد (یک ردیف برای هر رزرو) و شکست را با `on conflict … do update` ثبت می‌کند: `run_id`/`sqlstate`/`message`/`occurred_at` آخرین شکست، `failures` شمارنده تلاش‌های ناموفق و `first_failed_at` تاریخ نخستین شکست. رشد جدول = تعداد رزروهای خراب تا امروز، نه تعداد slotها.
- تنظیم `job.reservation_expiry.failure_keep` بازنشسته شد: ردیفش به‌خاطر `on delete restrict` تاریخچه تنظیم‌ها می‌ماند، توضیحش بازنشستگی را اعلام می‌کند و هیچ تابعی نمی‌خواندش؛ `FCO-1079` و بررسی بازه‌اش حذف شد.
- **`PASS PLAN` واقعی شد:** قبلاً با خاموش‌کردن `enable_hashjoin`/`enable_mergejoin`/`enable_seqscan` مسیر ایندکس به زور ساخته می‌شد. حالا با ۱۵۰۰ رزرو منقضی و ۱۲۰۰ ردیف خطا و `analyze`، برنامه واقعی پلنر ثبت می‌شود؛ آزمون شکل‌های مجاز (ایندکس یکتا / `hashed SubPlan` / hash semi join) را می‌پذیرد و اسکن ترتیبی تکرارشده را رد می‌کند. اجرای واقعی: `hashed SubPlan` با `Execution Time: 1.772 ms`.

### Added
- Migration `0020_reservation_expiry_failure_single_row` (+`.down.sql` که تعریف 0019 و ایندکس 0017 را برمی‌گرداند و ستون‌های تازه را می‌اندازد) و سوئیت `0020_reservation_expiry_failure_single_row_negative`: `PASS RETIRED`/`INDEX`/`SINGLE`/`SCOPE`/`ORDER`/`PLAN`. سوئیت 0019 (سقف ۲۴) حذف شد چون رفتاری که می‌سنجید دیگر وجود ندارد.
- سوئیت `0018` با مدل جدید هم‌خوان شد: `PASS RETRYQ` و `PASS HEAL` حالا به‌جای شمار ردیف، ردیف + مجموع `failures` را می‌سنجند.

### Verified
- `CI PASS | lint · typecheck · test · migration · build` · `PASS 20 Migration` · `PASS 14 مجموعه آزمون سبز` · `build_fingerprint = bundle_fingerprint = 33|57|20|0f523cdea5d874b5a09ec59f66b26946` (exit 0).
- سوئیت 0020 روی دیتابیس تازه با ۲۰ Migration: `PASS SINGLE` (۲۷ slot ⇒ ۱ ردیف، `failures=27`)، `PASS SCOPE`، `PASS ORDER`، `PASS PLAN` (`hashed SubPlan`، `Execution Time: 1.772 ms`).
- سوئیت‌های `0017` و `0018` بدون تغییر رفتار سبز ماندند (`ALL STEP-BR2-3B`/`3C`، exit 0).
- قرمز عمدی A: بازگرداندن بدنه 0019 ⇒ `FAIL RETIRED: 1 تابع هنوز تنظیم بازنشسته failure_keep را می‌خواند` (exit 3).
- قرمز عمدی B: upsert بدون شمارنده (`do nothing`) ⇒ `FAIL SINGLE: failures=1 (انتظار ۲۷ تلاش ناموفق)` (exit 3)، سپس بازگرداندن سبز.

### Limitation
- ردیف رزروِ رفع‌شده می‌ماند (یک ردیف، بدون تاریخچه per-slot) تا خود رزرو حذف شود؛ جاروی سنی/عمومی این جدول به یک Job نگهداشت `sys.job_runs` گره خورده که ADR-010 اعدادش را به پیکربندی سپرده است.

## [0.20.2] — ۱۴۰۵/۰۹/۰۵ (2026-11-26)

### Fixed (بازبینی سوم: ایندکس و نگهداشت `inv.reservation_expiry_failures`)
- **نگهداشت ادعا شده بود، نه اجرا:** 0.20.1 نگهداشت جدول خطا را به cascade `sys.job_runs` حواله داده بود، ولی هیچ Job یا Migration‌ای `sys.job_runs` را حذف نمی‌کند؛ پس cascade در عمل هرگز فعال نمی‌شد و رزروی که ساعت‌ها خراب می‌ماند در هر slot یک ردیف می‌گذاشت (۲۴ ردیف در روز برای هر رزرو) — رشد بی‌مرز. `0019_reservation_expiry_failure_retention` سقف نسخه‌دار `job.reservation_expiry.failure_keep` (پیش‌فرض ۲۴) را اضافه کرد و در همان slot ردیف‌های قدیمی‌تر همان رزرو را هرس می‌کند؛ حداقل/جدیدترین ردیف‌ها می‌مانند تا «سابقه‌دار بودن» — کلید اولویت صف 0018 — پاک نشود.
- **ایندکس کلید `exists` بازبینی و تثبیت شد:** `0017` از پیش `reservation_expiry_failures_reservation_idx (reservation_id, occurred_at desc)` را می‌سازد و ستون پیشروش همان کلید `exists` در 0018 است؛ Migration تازه ایندکسی نساخت، فقط `comment on index` را ثبت کرد تا بی‌مصرف شمرده و حذف نشود. شاهد: `PASS INDEX` (ستون پیشرو از `pg_index`) و `PASS PLAN` (نام ایندکس در برنامه اجرایی).

### Added
- Migration `0019_reservation_expiry_failure_retention` (+`.down.sql` که تعریف 0018 را عیناً برمی‌گرداند و توضیح ایندکس را پاک می‌کند) و سوئیت `0019_reservation_expiry_failure_retention_negative` — `T-INV-08`: `PASS CONFIG`/`INDEX`/`PLAN`/`CAP`/`SCOPE`/`ORDER`.
- خطای `FCO-1079` برای سقف نگهداشت خارج از بازه ۱..۱۰۰۰ (مثل `FCO-1077` برای دسته).

### Changed
- `DATABASE_DESIGN §3.5` (بند نگهداشت جای ادعای cascade؛ ایندکس `exists`)، `TEST_STRATEGY §4.1` (`T-INV-08`)، `IMPLEMENTATION_PLAN §4.2`.

### Verified
- `CI PASS | lint · typecheck · test · migration · build` · `PASS 19 Migration` · `PASS 14 مجموعه آزمون سبز` · `build_fingerprint = bundle_fingerprint = 33|57|19|78a5e73aaca0899a873dbfb68bc3076f` (exit 0).
- سوئیت 0019: `PASS CAP` (۲۷ slot پیوسته ⇒ دقیقاً ۲۴ ردیف؛ قدیمی‌ترین هرس و ردیف جدیدترین slot مانده)، `PASS SCOPE` (۳۰ ردیف رزرو دیگر دست‌نخورده)، `PASS ORDER` (رزرو سالمِ تازه‌تر آزاد و سابقه‌دار خراب `active` ماند).
- سوئیت‌های `0017` و `0018` روی 0019 بدون تغییر سبز ماندند (`ALL STEP-BR2-3B`/`3C`، exit 0).
- قرمز عمدی: برداشتن بلوک هرس ⇒ `FAIL CAP: برای یک رزرو 27 ردیف ماند (انتظار 24 از 27 slot)` (exit 3)، سپس بازگرداندن سبز.

### Limitation
- سابقه رزروِ رفع‌شده هرس نمی‌شود (≤ `failure_keep` ردیف) و جاروی سنی/عمومی این جدول به یک Job نگهداشت `sys.job_runs` گره خورده که ADR-010 اعدادش را به پیکربندی سپرده است.

## [0.20.1] — ۱۴۰۵/۰۹/۰۵ (2026-11-25)

### Fixed (بازبینی تازه روی `f2a7c7c`)
- **گرسنگی صف انقضا:** رزرو خراب در `0017` عمداً `active` می‌ماند و دسته با `order by expires_at` پر می‌شد، پس رزرو خراب قدیمی همیشه سر صف بود؛ وقتی شمار رزروهای خراب به اندازه `job.reservation_expiry.batch` می‌رسید، هیچ رزرو سالمی آزاد نمی‌شد و موجودی رزروشده قفل می‌ماند — در حالی که Job `succeeded` گزارش می‌کرد. `0018_reservation_expiry_fairness` ترتیب دسته را دوکلیدی کرد (`exists` روی جدول خطا، سپس `expires_at`) تا رزرو سابقه‌دار آخر صف برود؛ هیچ رزروی نادیده گرفته نمی‌شود و در صف خالی بازآزمون می‌شود.
- ایندکس `inv.reservation_expiry_failures_run_idx` روی `run_id` (FK با `on delete cascade`، پیش‌تر هر حذف `sys.job_runs` کل جدول خطا را اسکن می‌کرد).

### Added
- Migration `0018_reservation_expiry_fairness` (+`.down.sql` که تعریف 0017 را برمی‌گرداند و ایندکس را می‌اندازد) و سوئیت `0018_reservation_expiry_fairness_negative` — `T-INV-07` (بازبینی دوم): `PASS SEED`/`PASS STARVE`/`PASS RETRYQ`/`PASS HEAL`/`PASS CLEAN`/`PASS INDEX`.
- پوشش اضافی در همان سوئیت: اجرای بدون شکست باید `sys.job_runs.error = NULL` بگذارد (پیش‌تر فقط وجود یادداشت در شکست جزئی آزموده شده بود).

### Changed
- `DATABASE_DESIGN §3.5` (اولویت صف + محدودیت باقی‌مانده)، `TEST_STRATEGY §4.1` (`T-INV-07` بازبینی دوم)، `IMPLEMENTATION_PLAN §4.2`.

### Verified
- `CI PASS | lint · typecheck · test · migration · build` · `PASS 18 Migration` · `PASS 13 مجموعه آزمون سبز` · `build_fingerprint = bundle_fingerprint = 33|57|18|736ec5c0c0d2da81e4746c51162c771b` (bundle=210507 bytes، exit 0).
- سوئیت 0018: `PASS SEED` (`expired=2`، `failed=2`)، `PASS STARVE` (دسته ۲، دو رزرو سالم آزاد، `failed=0`)، `PASS RETRYQ` (۴ ردیف `23514`)، `PASS HEAL`، `PASS CLEAN`، `PASS INDEX`.
- سوئیت 0017 روی 0018 بدون تغییر سبز ماند (`PASS BATCH`/`ISOLATION`/`LOG`/`AUDIT`/`JOB`/`SLOT`/`RETRY`/`APP-ROLE`).
- قرمز عمدی: برگرداندن ترتیب 0017 ⇒ `FAIL STARVE: expired=0 failed=2 — صف خراب جای رزرو سالم را گرفت` (exit 3)، سپس سبز مجدد.

## [0.20.0] — ۱۴۰۵/۰۹/۰۴ (2026-11-25)

### Added
- `0017_reservation_expiry_isolation` — جدول `inv.reservation_expiry_failures` (`run_id`، `reservation_id`، `error_sqlstate`، `message`، `occurred_at`) و بازسازی `inv.expire_reservations` با خروجی `(outcome, expired, run_id, failed)`.
- سوئیت `0017_reservation_expiry_isolation_negative` — `T-INV-07`: رزرو خراب در وسط دسته، ثبت خطا با `run_id`/`sqlstate`، بی‌اثر بودن شکست روی Audit و `job_runs`، بازآزمون پس از رفع داده و ممنوعیت جعل ردیف خطا از نقش اپ.

### Fixed
- `inv.expire_reservations` یک `begin … exception` دور **کل دسته** داشت؛ در PL/pgSQL هر بلوک exception یک زیرتراکنش است، پس خطای یک رزرو همه آزادسازی‌های همان دسته را برمی‌گرداند و Job را `failed` می‌کرد. حالا زیرتراکنش به‌ازای هر رزرو است: خطا فقط همان رزرو را برمی‌گرداند، در جدول خطا ثبت می‌شود و بقیه دسته آزاد می‌شوند.
- انتخاب دسته با `FOR UPDATE SKIP LOCKED` انجام می‌شود تا رزرو قفل‌شده کل Job را معطل نکند؛ رزرو خراب `active` می‌ماند و در slot بعدی دوباره تلاش می‌شود (شکست پایدار دیده می‌شود، پنهان نمی‌شود).
- `EXECUTE` تابع از `PUBLIC` گرفته شد و فقط `fco_app` مجاز است (همان درس `0015`).
- فاصله انتهایی در `tests/0015_catalog_search_fixes_negative.sql` که مرحله lint را قرمز می‌کرد.

### Changed
- Job با شکست جزئی `succeeded` می‌ماند و `error` همان رکورد شمار شکست و نام جدول خطا را می‌برد؛ `failed` نمی‌شود تا `job.max_attempts` بی‌دلیل نسوزد.
- `DATABASE_DESIGN §3.4`، `TEST_STRATEGY §4.1` (`T-INV-07`)، `IMPLEMENTATION_PLAN §4.2`.

### Verified
- `CI PASS | lint · typecheck · test · migration · build` · `PASS 17 Migration` · `PASS 12 مجموعه آزمون سبز` · `build_fingerprint = bundle_fingerprint = 33|57|17|92094430912f932eeab96bf67f9e25fc` (bundle=204179 bytes).
- `tests/0017_reservation_expiry_isolation_negative.sql`: `PASS BATCH` (`expired=2`، `failed=1`، `outcome=ran`)، `PASS ISOLATION` (رزرو بعد از رزرو خراب هم آزاد شد)، `PASS LOG` (`sqlstate=23514`، `run_id=1`)، `PASS AUDIT`/`PASS JOB`/`PASS SLOT`/`PASS RETRY`/`PASS APP-ROLE`.
- قرمز عمدی: برداشتن زیرتراکنش هر رزرو ⇒ `FAIL BATCH: خطای یک رزرو Job را failed کرد` (exit 3)، سپس سبز مجدد.

## [0.19.0] — ۱۴۰۵/۰۹/۰۴ (2026-11-25)

### Added
- `0016_movement_direction` — تریگر `stock_ledger_direction_guard` جهت `quantity_delta` را به `reason_code` گره می‌زند: `grn`/`return_restock` فقط مثبت، `sale_ship` فقط منفی، `adjust` دوطرفه و `reserve`/`release` در دفتر گردش ممنوع (`FCO-1078`). گارد روی دفتر گذاشته شد، نه در تابع، تا هر نویسنده آینده هم مشمول باشد.
- سوئیت `0016_movement_direction_negative` — `T-INV-06`: جهت‌های نامجاز، بی‌اثر بودن رد روی تجمیع/دفتر/Audit، مسیرهای مجاز و درج مستقیم `reserve`.
- سوئیت `0015_catalog_search_fixes_negative` — `T-CAT-04`/`T-CAT-05`.

### Fixed (بازبینی گام ۴)
- `0015_catalog_search_fixes`: فهرست قیمت را از تنوع آرشیوشده هم می‌گرفت (ارزان‌ترین قیمت می‌توانست از کالای آرشیوشده باشد)؛ حالا قیمت و موجودی فقط از تنوع فعال می‌آید.
- `compare_at_rial` با `min()` مستقل انتخاب می‌شد و می‌توانست «قیمت قبل» تنوعی دیگر باشد؛ حالا از همان قیمت کمینه می‌آید.
- پیکربندی تغییرپذیر `cat.fa` (نسخه‌ای از `simple` بدون رفتار اضافه) حذف شد؛ `ALTER` آن می‌توانست ایندکس GIN را بی‌سروصدا کهنه کند. جست‌وجو با `simple` + یکسان‌سازی و بازسازی ایندکس انجام می‌شود.
- دسترسی: `grant ... to fco_app` در 0014 چیزی را محدود نمی‌کرد چون PostgreSQL به‌طور پیش‌فرض `EXECUTE` را به `PUBLIC` می‌دهد؛ حالا `PUBLIC` برداشته شده، فقط اپ مجاز است و `cat.public_product_ids` (بدون `LIMIT`) هیچ grant‌ای ندارد.
- سقف طول عبارت به `cat.search_query` منتقل شد تا هر مسیر (نه فقط `search_products`) محافظت شود.

### Changed
- `scripts/ci.sh` وجود گارد جهت گردش را در typecheck بررسی می‌کند.
- `DATABASE_DESIGN §3.2/§3.4/§4`، `TEST_STRATEGY §4.1/§4.1.1`، `IMPLEMENTATION_PLAN §4.2`، `IMPLEMENTATION_START_PLAN §7`.
- سوئیت 0014: بررسی پیکربندی حذف‌شده `cat.fa` جای خود را به سالم‌بودن بردار جست‌وجو داد.

### Verified
- `CI PASS | lint · typecheck · test · migration · build` · `PASS 16 Migration` · `PASS 11 مجموعه آزمون سبز` · `build_fingerprint = bundle_fingerprint = 32|57|16|1c00d554bfa9ae623d5617b414a92aff` (bundle=197378 bytes).
- `tests/0015_catalog_search_fixes_negative.sql`: `PASS ARCHIVED` (۴۰۰۰۰۰ نه ۱۰۰۰۰۰؛ `compare_at=NULL`؛ موجودی ۶)، `PASS CONFIG/INDEX`، `PASS GUARD`، `PASS ACL`/`PASS APP-ROLE`. قرمز عمدی ⇒ `FAIL ARCHIVED: قیمت فهرست=100000` (exit 3)، سپس سبز مجدد.
- `tests/0016_movement_direction_negative.sql`: `PASS DIRECTION`/`PASS ALLOWED`/`PASS REASON`/`PASS EVIDENCE` (`on_hand = جمع دفتر = 5`). قرمز عمدی با `drop trigger stock_ledger_direction_guard` ⇒ `FAIL DIRECTION: grn منفی پذیرفته شد` (exit 3)، سپس سبز مجدد.
- تست هم‌زمانی `T-INV-01` پس از تغییرات: `5|95|0` در ۳ دور و `overlap=99`.

## [0.18.0] — ۱۴۰۵/۰۹/۰۴ (2026-11-25)

### Added
- `0014_catalog_public_search` — لایه خواندن عمومی گام ۴: `cat.normalize_text` (ی/ي، ک/ك، همزه، ة/ۀ، ZWNJ، ارقام فارسی/عربی)، پیکربندی `cat.fa`، GIN روی `cat.search_vector(title, description)`، `cat.search_query` (تبدیل امن عبارت کاربر به `tsquery`)، `cat.public_product_ids` (تنها منبع فیلتر `published` + `published_at <= now()`)، `cat.search_products` (صفحه‌بندی سرور، قیمت مؤثر کانال، موجودی قابل‌فروش، `total_count`)، `cat.public_product` (JSON صفحه محصول) و `cat.category_path` (breadcrumb).
- چهار تنظیم نسخه‌دار `cat.search.*` (اندازه صفحه، سقف، طول عبارت، سقف offset)؛ هیچ عددی در تابع هارد‌کد نیست.
- سوئیت `0014_catalog_public_search_negative` — `T-CAT-01..03` به‌همراه صفحه‌بندی، سقف‌های ورودی (`FCO-1081`)، جزئیات تنوع و اجرا از نقش `fco_app`.

### Changed
- `scripts/inv-concurrency-test.sh` بازنویسی و سخت‌تر شد (بازبینی گام ۳): ۳ دور پیش‌فرض، شمارش کامل `ok+stock+other`، اثبات هم‌پوشانی از بازه ثبت‌شده در دیتابیس (`overlap ≥ 50`) و پنجره شروع، و حالت قرمز خودتزریق `FCO_INV_BREAK=1` که به دیتابیس دستی نیاز ندارد. `FCO_INV_REUSE_DB` حذف شد.
- `scripts/ci.sh` توابع خواندن/جست‌وجوی عمومی را هم در سطح API بررسی می‌کند (۱۰ تابع `cat`).
- `DATABASE_DESIGN §3.2/§4`، `TEST_STRATEGY §4.1/§4.1.1`، `IMPLEMENTATION_PLAN §4.2`، `IMPLEMENTATION_START_PLAN §7`.

### Fixed
- `scripts/ci.sh` آمادگی Postgres یکبارمصرف را با `pg_isready` روی TCP می‌سنجد. پیش از این پروب می‌توانست به سرور موقت مرحله init پاسخ دهد که بعداً خاموش می‌شود و مرحله Migration را با «database system is shutting down» می‌شکست.
- بازگشت `0014` دیگر `sys.settings`/`setting_versions` را حذف نمی‌کند؛ تاریخچه تنظیمات فقط‌افزودنی است (`FCO-1025`) — همان الگوی `0011`/`0013`.

### Verified
- `CI PASS | lint · typecheck · test · migration · build` · `PASS 14 Migration` · `PASS 9 مجموعه آزمون سبز` · `build_fingerprint = bundle_fingerprint = 32|56|14|f266f624358b5001c558a215c3c4536d` (bundle=183487 bytes).
- `T-INV-01` سبز در ۳ دور: `ok|stock|other|spread_ms|overlap=5|95|0|365|99`، `active|on_hand|reserved|available|ledger=5|5|5|0|5`؛ درخواست ۱۰۱ → `FCO-1071`.
- قرمز عمدی بدون دیتابیس دستی: `FCO_INV_BREAK=1` ⇒ `100|0|0` و `RED CONFIRMED` (exit 1).
- سوئیت گام ۴ روی دیتابیس تازه سبز: `VISIBILITY` (۴ از ۷)، `SEARCH`، `CATEGORY`، `PRICE/STOCK`، `PAGING/GUARDS`، `DETAIL`، `PATH`، `APP-ROLE`، `INDEX`. قرمز عمدی با برداشتن گارد انتشار ⇒ `FAIL VISIBILITY: 6 محصول عمومی برگشت` (exit 3).

## [0.17.0] — ۱۴۰۵/۰۹/۰۴ (2026-11-25)

### Added
- `0013_inventory_movement` — `inv.apply_movement` اتمیک (درج دفتر + تجمیع در یک تراکنش، `balance_after` از `on_hand` جدید)، `inv.reserve` با `FOR UPDATE` و بررسی `available`، `inv.release`، و `inv.expire_reservations` با `sys.job_begin`/`job_finish`.
- مجوز اجباری در مسیر گردش، نگاشت‌شده از `reason_code`: `grn`→`warehouse.grn.create`، `sale_ship`→`warehouse.pick.execute`، `return_restock`→`returns.inspection.record`، `adjust`→`inventory.adjust`؛ `reserve`/`release` به‌عنوان delta ممنوع (`FCO-1070`).
- سوئیت `0013_inventory_movement_negative` — مجوز/ورودی/انبار/تنوع/رزرو/انقضا و ۱۰۰۰ گردش با تجمیع برابر.
- `scripts/inv-concurrency-test.sh` — `T-INV-01` با ۱۰۰ کلاینت هم‌زمان pgbench (نه ۱۰۰ پروسه `docker exec`) و شمارش نتیجه از دیتابیس.

### Fixed
- Job انقضای رزرو در آزمون با عقب‌بردن `expires_at` بدون `created_at` رد می‌شد؛ هر دو به گذشته برده می‌شوند تا قید `expires_at > created_at` معتبر بماند.

### Changed
- `DATABASE_DESIGN §3.4`، `TEST_STRATEGY §4.1`، `IMPLEMENTATION_PLAN §4.2`، `IMPLEMENTATION_START_PLAN §7`.

### Verified
- `CI PASS | lint · typecheck · test · migration · build` · `PASS 13 Migration` · `PASS 8 مجموعه آزمون سبز` · `build_fingerprint = bundle_fingerprint = 32|49|13|714166be01d3644a9f0e6423952575fc` (bundle=166301 bytes).
- `PASS RECONCILE | پس از ۱۰۰۰ گردش، جمع دفتر = تجمیع` · `PASS EVIDENCE | 1005 گردش و 1009 رکورد Audit`.
- `T-INV-01`: `success=5 rejected=95 stock_rejected=95`، `active_reservations|on_hand|reserved|available|ledger_sum=5|5|5|0|5`، درخواست ۱۰۱ → `FCO-1071`.
- قرمز عمدی: حذف `FOR UPDATE` و قید `stock_balance_available_nonnegative` با پنجره ۵۰ms ⇒ `ok|stock_rejected|other_rejected=100|0|0` و `FAIL` (exit 1)؛ سپس Migration دست‌نخورده دوباره سبز.

## [0.16.0] — ۱۴۰۵/۰۹/۰۴ (2026-11-25)

### Added
- `0012_catalog_usecases` — use-caseهای `cat.product_create`/`product_update` و `cat.variant_create`/`variant_update` با مجوز، اعتبارسنجی، کنترل تعارض نسخه و Audit در همان تراکنش؛ مجوزهای `catalog.product.write` و `catalog.variant.write` برای `R-SALES`.
- سوئیت `0012_catalog_usecases_negative` — مجوز use-case، ورودی نامعتبر، یکتایی، تعارض نسخه، آرشیو و شاهد Audit.

### Fixed (بازبینی گام ۱)
- `cat.variants` نسخه گرفت و `inv.stock_balance` با هر به‌روزرسانی `version`/`updated_at` را تازه می‌کند.
- `pricing.prices.superseded_by` فقط به قیمت بعدی همان تنوع/کانال اشاره می‌کند (`FCO-1052`).
- `cat.products.attributes` باید شیء JSON باشد و قید اختراعی `sku = upper(sku)` حذف شد.
- Audit ویرایش محصول اکنون `description` و `attributes` را هم ثبت می‌کند.

### Changed
- `scripts/ci.sh` — آزمون وجود ۴ use-case کاتالوگ و fingerprint شامل توابع `cat`/`pricing`/`inv`.
- `DATABASE_DESIGN §3.5`، `TEST_STRATEGY §6`، `IMPLEMENTATION_PLAN §4.2`.

### Verified
- `PASS 12 Migration` · `PASS 7 مجموعه آزمون سبز` · `PASS ۴ use-case کاتالوگ` · `PASS بازگشت کامل و اجرای دوباره از صفر`.
- `build_fingerprint = bundle_fingerprint = 32|45|12|b4cacaae1efb3f94836cc61c56f57738` (bundle=150756 bytes).
- قرمز عمدی: حذف نگاشت `catalog.product.write` از `R-SALES` ⇒ `FCO-1003` در نخستین use-case (exit 3)؛ با Migration دست‌نخورده دوباره سبز شد.

## [0.15.0] — ۱۴۰۵/۰۹/۰۴ (2026-11-25)

### Added
- `0011_catalog_inventory` — schemaهای `cat`/`pricing`/`inv`: برند/دسته/محصول/تنوع/رسانه، قیمت نسخه‌دار با Exclusion GiST، انبار/تجمیع/دفتر گردش/رزرو، و لایه هزینه FIFO؛ تنظیم نسخه‌دار `inv.reservation_ttl_minutes`.
- سوئیت `0011_catalog_inventory_negative` — یکتایی کاتالوگ، بازه/تغییرناپذیری قیمت، قیدهای موجودی، ممنوعیت UPDATE/DELETE دفتر گردش، رزرو فعال یکتا، لایه هزینه و مرزهای نقش `fco_app`.

### Changed
- `scripts/ci.sh` — سوئیت‌های آزمون به‌صورت داینامیک شمرده می‌شوند (۶ مجموعه)، ۱۲ جدول جدید در سطح API، و fingerprint شامل `cat`/`pricing`/`inv`.
- `DATABASE_DESIGN §3.5`، `TEST_STRATEGY §6`، `IMPLEMENTATION_PLAN §4.2`.

### Fixed
- آمادگی کانتینر یکبارمصرف Migration با ثبات `pg_postmaster_start_time` سنجیده می‌شود؛ دو کوئری موفق قبلی می‌توانست به سرور موقت init بچسبد و اتصال بعدی با `terminating connection` قطع شود.

### Verified
- `PASS 11 Migration با فایل بازگشت` · `PASS 31 جدول کلیدی` · `PASS 6 مجموعه آزمون سبز` · `PASS بازگشت کامل و اجرای دوباره از صفر`.
- `build_fingerprint = bundle_fingerprint = 32|38|11|0bb1d8db128583840aaf61b6e801555f` (bundle=131599 bytes).
- قرمز عمدی: حذف تریگر `stock_ledger_immutable` ⇒ `FAIL LEDGER: UPDATE مستقیم مجاز بود` (exit 3)؛ با Migration دست‌نخورده دوباره سبز شد.

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
