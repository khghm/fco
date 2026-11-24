# مستندات پروژه — Fashion Commerce OS

> **وضعیت:** فاز ۰ بسته (G0 ✅) · **نسخه:** v1.1 · **تاریخ:** ۱۴۰۵/۰۹/۰۳ (۲۰۲۶-۱۱-۲۴)
> دامنه: پلتفرم یکپارچه تجارت و مدیریت کسب‌وکار پوشاک · Self-hosted · فارسی/RTL · Production-grade
> **نقطه شروع مطالعه:** [`Management-00/PROJECT_MASTER_CONTROL.md`](Management-00/PROJECT_MASTER_CONTROL.md)

---

## ۱. ساختار

```
docs/
├─ Management-00/    کنترل پروژه: منشور، نقشه راه، تصمیم، ریسک، تغییرات
├─ Business-01/      چرا و چه چیزی: شناخت، الزامات، نقش‌ها، جریان‌ها، عملیات
├─ Architecture-02/  چگونه: معماری، داده، API، امنیت، ADRها
├─ UX-03/            تجربه: دیزاین‌سیستم، استانداردهای فارسی، پنل مدیریت
├─ Engineering-04/   ساخت و بهره‌برداری: پلان، آزمون، استقرار، پشتیبان
├─ product/          پشتیبان تصمیم: قابلیت‌ها، سناریوها، نسخه‌ها، تصمیم‌های باز
└─ quality/          پشتیبان کیفیت: Micro-UX، کاتالوگ شکست
```

---

## ۱.۱ قاعده تک‌منبعی (چرا تکرار ممنوع است)

هر موضوع **یک سند مالک** دارد و هر سند در سرصفحه مالکیت خودش را اعلام می‌کند؛ فهرست کامل ۲۳ موضوع در [`Management-00/PROJECT_MASTER_CONTROL.md §4.2`](Management-00/PROJECT_MASTER_CONTROL.md) است.
اگر موضوعی مالک دارد، اسناد دیگر فقط **ارجاع** یا **خلاصه یک‌خطی** می‌آورند؛ جدول کامل، تعریف دوباره یا فهرست تکراری = نقص بازبینی.
ممیزی تکرار (v0.3.1): صفر خط تکرارشده با طول ≥۴۰ کاراکتر بین اسناد؛ جدول نقش‌ها، قاعده تاریخ/عدد، چک‌لیست دسترس‌پذیری، جزئیات داده/API/امنیت و جدول ده‌گام BR-1 هرکدام فقط یک نسخه دارند.

## ۲. Management-00 — کنترل پروژه

| سند | محتوا |
|---|---|
| [`PROJECT_MASTER_CONTROL.md`](Management-00/PROJECT_MASTER_CONTROL.md) | منشور، ده اصل غیرقابل‌مذاکره، **فضای نام شناسه‌ها**، گیت‌ها، قاعده شاهد، کنترل تغییر |
| [`PROJECT_ROADMAP.md`](Management-00/PROJECT_ROADMAP.md) | توالی فازها و برش‌ها، مسیر بحرانی، تعریف «پیشرفت» |
| [`DECISION_LOG.md`](Management-00/DECISION_LOG.md) | فهرست واحد تصمیم‌ها (Q/ADR/D)، گزینه‌های رد‌شده، تصمیم‌های معلق |
| [`RISK_REGISTER.md`](Management-00/RISK_REGISTER.md) | R-01..R-22 با مالک، پاسخ، شاهد کاهش، ماتریس ریسک |
| [`CHANGELOG.md`](Management-00/CHANGELOG.md) | تغییرات اسناد/مخزن با تاریخ و شاهد |

## ۳. Business-01 — کسب‌وکار

| سند | محتوا |
|---|---|
| [`PROJECT_DISCOVERY_REPORT.md`](Business-01/PROJECT_DISCOVERY_REPORT.md) | مأموریت، فرض‌ها (A-*)، ریسک‌ها (R-*)، وضعیت محیط، تصمیم‌های موقت |
| [`BUSINESS_REQUIREMENTS.md`](Business-01/BUSINESS_REQUIREMENTS.md) | الزامات `BRQ-01..47`، اهداف، دامنه in/out، قواعد `BRL-*` |
| [`USER_ROLES_AND_PERMISSIONS.md`](Business-01/USER_ROLES_AND_PERMISSIONS.md) | نقش‌ها (R-*)، کاتالوگ مجوز، ماتریس نقش×مجوز، SoD، آستانه‌های تأیید |
| [`BUSINESS_WORKFLOWS.md`](Business-01/BUSINESS_WORKFLOWS.md) | `WF-01..20` با وضعیت، سند، SLA و مسیر شکست |
| [`BUSINESS_OPERATIONS_BLUEPRINT.md`](Business-01/BUSINESS_OPERATIONS_BLUEPRINT.md) | ایستگاه‌های زنجیره ارزش S1..S12 و اثر مالی/انباری هر یک |
| [`ROLE_WORKFLOW_MATRIX.md`](Business-01/ROLE_WORKFLOW_MATRIX.md) | نقش ↔ ایستگاه ↔ قابلیت ↔ ریسک ↔ معیار پذیرش |

## ۴. Architecture-02 — معماری

| سند | محتوا |
|---|---|
| [`SYSTEM_ARCHITECTURE.md`](Architecture-02/SYSTEM_ARCHITECTURE.md) | معماری کلان، مرز ماژول‌ها، مدل داده، قرارداد API، رویداد، زیرساخت |
| [`DATABASE_DESIGN.md`](Architecture-02/DATABASE_DESIGN.md) | اسکیماها و جداول، قیدها، ایندکس، Migration، نگهداشت، قیدهای ضد‌باگ |
| [`API_SPECIFICATION.md`](Architecture-02/API_SPECIFICATION.md) | قراردادها، کدهای خطا `FCO-*`، کاتالوگ endpoint، Webhook، نرخ‌محدود |
| [`SECURITY_ARCHITECTURE.md`](Architecture-02/SECURITY_ARCHITECTURE.md) | مدل تهدید STRIDE، احراز هویت، رمزنگاری، امنیت عملیات، آزمون امنیتی |
| [`ADR/`](Architecture-02/ADR/) | ADR-001..012: Monolith، PostgreSQL، دفتر گردش، Outbox، پول، زمان، نشست، **صف**، **ارزش‌گذاری**، **نگهداشت**، مالیات فاز ۲، جست‌وجو |

## ۵. UX-03 — تجربه و رابط

| سند | محتوا |
|---|---|
| [`DESIGN_SYSTEM.md`](UX-03/DESIGN_SYSTEM.md) | توکن‌ها، کاتالوگ مؤلفه‌ها و حالت‌ها، RTL، شبکه، دسترس‌پذیری، مالکیت کد |
| [`PERSIAN_UX_STANDARDS.md`](UX-03/PERSIAN_UX_STANDARDS.md) | لحن، واژه‌نامه اصطلاحات، تاریخ شمسی، اعداد/مبلغ، قالب خطا، پیامک، فاکتور |
| [`ADMIN_PANEL_SPECIFICATION.md`](UX-03/ADMIN_PANEL_SPECIFICATION.md) | IA، کاتالوگ صفحه با مجوز، صف کار، صفحه اسکن، Approval Inbox، پذیرش |

## ۶. Engineering-04 — ساخت و بهره‌برداری

| سند | محتوا |
|---|---|
| [`IMPLEMENTATION_PLAN.md`](Engineering-04/IMPLEMENTATION_PLAN.md) | استک، ساختار مخزن، ترتیب BR-1..BR-5، استاندارد کد، CI، DoD، بدهی فنی |
| [`IMPLEMENTATION_START_PLAN.md`](Engineering-04/IMPLEMENTATION_START_PLAN.md) | ده گام BR-1 + **ثبت شاهد واقعی اجرا** |
| [`TEST_STRATEGY.md`](Engineering-04/TEST_STRATEGY.md) | هرم آزمون، `T-*` قاعده‌محور، هم‌زمانی، امنیت، Migration، DR، عملکرد |
| [`DEPLOYMENT_GUIDE.md`](Engineering-04/DEPLOYMENT_GUIDE.md) | محیط‌ها، پیش‌نیاز، توپولوژی، نصب، TLS، انتشار، Rollback، چک‌لیست |
| [`BACKUP_AND_RECOVERY.md`](Engineering-04/BACKUP_AND_RECOVERY.md) | لایه‌های پشتیبان، رمزنگاری offsite، رویه Restore/PITR، Drill، سناریوهای DR |

## ۷. پشتیبان‌های تصمیم و کیفیت

| سند | محتوا |
|---|---|
| [`product/CAPABILITY_MAP.md`](product/CAPABILITY_MAP.md) | ۱۶ دامنه (D1..D16)، ۱۱۰+ قابلیت `FR-*` با اولویت P0..P3 |
| [`product/ROLE_SCENARIOS.md`](product/ROLE_SCENARIOS.md) | سناریوهای نقش‌محور و روزهای خاص (فروش ویژه، پایان ماه، قطعی) |
| [`product/RELEASE_PLAN.md`](product/RELEASE_PLAN.md) | فازها، گیت‌ها، معیار پذیرش BR-1..BR-5 و E2-* |
| [`product/OPEN_DECISIONS.md`](product/OPEN_DECISIONS.md) | Q-02/Q-04/Q-06/Q-11 پذیرفته‌شده + جدول بازبینی |
| [`quality/MICRO_UX_STANDARDS.md`](quality/MICRO_UX_STANDARDS.md) | قانون تعامل: جدول، فیلتر، فرم، بازخورد، دسترس‌پذیری |
| [`quality/FAILURE_MODE_ANALYSIS.md`](quality/FAILURE_MODE_ANALYSIS.md) | کاتالوگ شکست `FM-*` (انسانی/مالی/عملیاتی/فنی/امنیتی/زیرساخت/خاموش) |

**جمع:** ۲۰ سند ساختار هدف + ۳ سند پشتیبان (`PROJECT_DISCOVERY_REPORT`، `ROLE_WORKFLOW_MATRIX`، `IMPLEMENTATION_START_PLAN`) + ۶ سند تصمیم/کیفیت (`product/`، `quality/`) + ۴ فایل ADR.

---

## ۸. نگاشت مسیرها (پیش از v1.1 → v1.1)

| مسیر قدیم | مسیر جدید |
|---|---|
| `docs/business/PROJECT_DISCOVERY_REPORT.md` | `docs/Business-01/PROJECT_DISCOVERY_REPORT.md` |
| `docs/business/BUSINESS_OPERATIONS_BLUEPRINT.md` | `docs/Business-01/BUSINESS_OPERATIONS_BLUEPRINT.md` |
| `docs/business/ROLE_WORKFLOW_MATRIX.md` | `docs/Business-01/ROLE_WORKFLOW_MATRIX.md` |
| `docs/architecture/SYSTEM_ARCHITECTURE.md` | `docs/Architecture-02/SYSTEM_ARCHITECTURE.md` |
| `docs/architecture/ADR/` | `docs/Architecture-02/ADR/` |
| `docs/operations/IMPLEMENTATION_START_PLAN.md` | `docs/Engineering-04/IMPLEMENTATION_START_PLAN.md` |
| `docs/quality/TEST_STRATEGY.md` (برنامه‌ریزی‌شده) | `docs/Engineering-04/TEST_STRATEGY.md` (ساخته‌شده) |
| `docs/operations/DEPLOYMENT_GUIDE.md` (برنامه‌ریزی‌شده) | `docs/Engineering-04/DEPLOYMENT_GUIDE.md` (ساخته‌شده) |
| `docs/operations/BACKUP_RESTORE_GUIDE.md` (برنامه‌ریزی‌شده) | `docs/Engineering-04/BACKUP_AND_RECOVERY.md` (ساخته‌شده) |

`product/` و `quality/` در جای خود ماندند: محتوای یگانه‌ای دارند (نقشه قابلیت، FMEA، Micro-UX) که در ساختار شماره‌دار تصویر نبود ولی منبع ارجاع همه اسناد است.

---

## ۹. اسناد باقی‌مانده (فازهای بعد، عمداً ساخته نشده‌اند)

`quality/REQUIREMENTS_TRACEABILITY_MATRIX.md` · `quality/ACCEPTANCE_CRITERIA.md` · `quality/PERFORMANCE_BUDGETS.md` · `quality/SECURITY_CHECKLIST.md` · `quality/DATA_RETENTION_POLICY.md` · `Architecture-02/DOMAIN_BOUNDARIES.md` · `Architecture-02/INTEGRATION_ARCHITECTURE.md` · `Engineering-04/OBSERVABILITY_PLAN.md` · `Engineering-04/RUNBOOK.md` · `Engineering-04/INCIDENT_RESPONSE_PLAN.md` · `Engineering-04/ADMIN_GUIDE.md` · `Engineering-04/USER_GUIDE.md` · `Engineering-04/DEVELOPER_GUIDE.md`

> این‌ها وقتی ساخته می‌شوند که محتوای واقعی (اندازه‌گیری، تصمیم، یا کد) داشته باشند؛ سند بدون شاهد، بدهی است.

---

## ۱۰. قواعد حاکم بر این پوشه

1. هر سند سرصفحه `وضعیت · نسخه · تاریخ` دارد: `پیش‌نویس` / `برای بازبینی` / `تأییدشده` / `منقضی`.
2. ارجاع متقابل فقط با شناسه: `FR-4-02`، `BRQ-13`، `FM-O-01`، `WF-06`، `S-08`→`S8`، `R-02` (ریسک) / `R-FIN` (نقش)، `ADR-009`، `BR-3`، `Q-02`، `FCO-1005`، `T-INV-01`. جدول کامل در `Management-00/PROJECT_MASTER_CONTROL.md §3`.
3. هیچ سند «انجام شد» نمی‌گوید بدون شاهد قابل‌بازبینی (قاعده شاهد §6 همان سند).
4. سند قدیمی‌شده = نقص، نه یادگار؛ تغییر رفتاری در همان تغییر، سند را به‌روز می‌کند.
5. تناقض را حل کن، نه تکرار: ترتیب اعتبار `PROJECT_MASTER_CONTROL` → `DECISION_LOG` → ADR → سند دامنه.
