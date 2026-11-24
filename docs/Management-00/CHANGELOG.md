# تغییرات (CHANGELOG)

> **وضعیت:** زنده · **نسخه:** v1.1 · **آخرین به‌روزرسانی:** ۱۴۰۵/۰۹/۰۳
> قالب بر پایه Keep a Changelog، تاریخ‌ها شمسی + ISO. هر تغییر در **رفتار، دامنه یا ساختار اسناد** یک ردیف اینجا دارد.
> شاهد هر نسخه: `git show --stat <commit>`.

---

## [Unreleased]

### Planned
- پیاده‌سازی BR-1 گام ۴: Migration پایه (IAM/Audit/Outbox/Setting)
- گام ۵: هویت و مجوز با آزمون منفی
- تأیید ADR-007 توسط TECH (مسدودکننده گام ۵)

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
