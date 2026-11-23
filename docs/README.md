# مستندات پروژه — Fashion Commerce OS

> وضعیت: مرحله صفر (کشف و طراحی) — خروجی‌های ۱ تا ۱۰ + یادداشت‌های تصمیم
> تاریخ: ۱۴۰۵/۰۹/۰۲ (۲۰۲۶-۱۱-۲۳)
> دامنه پروژه: پلتفرم یکپارچه تجارت و مدیریت کسب‌وکار پوشاک · Self-hosted · فارسی/RTL · Production-grade

## نقشه مستندات موجود

| # | سند | محتوا |
|---|---|---|
| ۱ | [`business/PROJECT_DISCOVERY_REPORT.md`](business/PROJECT_DISCOVERY_REPORT.md) | مأموریت، فرض‌ها، محدودیت‌ها، ریسک‌ها، وضعیت محیط، تصمیم‌های موقت |
| ۲ | [`product/CAPABILITY_MAP.md`](product/CAPABILITY_MAP.md) | ۱۶ دامنه، ۱۱۰+ قابلیت با شناسه FR، اولویت P0..P3، وابستگی |
| ۳ | [`business/BUSINESS_OPERATIONS_BLUEPRINT.md`](business/BUSINESS_OPERATIONS_BLUEPRINT.md) | از تأمین تا تسویه و مرجوعی: ایستگاه‌های S1..S12 |
| ۴ | [`product/ROLE_SCENARIOS.md`](product/ROLE_SCENARIOS.md) | سناریوهای نقش‌محور و روزهای خاص |
| ۵ | [`architecture/SYSTEM_ARCHITECTURE.md`](architecture/SYSTEM_ARCHITECTURE.md) | معماری کلان، مدل داده، API، رویداد، امنیت، زیرساخت، استقرار |
| ۶ | [`quality/MICRO_UX_STANDARDS.md`](quality/MICRO_UX_STANDARDS.md) | فارسی/RTL، تقویم شمسی، اعداد، جدول، فرم، دسترس‌پذیری |
| ۷ | [`quality/FAILURE_MODE_ANALYSIS.md`](quality/FAILURE_MODE_ANALYSIS.md) | کاتالوگ ریسک و سناریوهای شکست (FMEA) |
| ۸ | [`product/RELEASE_PLAN.md`](product/RELEASE_PLAN.md) | فازها، گیت‌ها، BR-1..BR-5، معیار پذیرش |
| ۹ | [`business/ROLE_WORKFLOW_MATRIX.md`](business/ROLE_WORKFLOW_MATRIX.md) | نقش ↔ فرایند ↔ قابلیت ↔ ریسک |
| ۱۰ | [`operations/IMPLEMENTATION_START_PLAN.md`](operations/IMPLEMENTATION_START_PLAN.md) | برنامه شروع پیاده‌سازی و گام‌های BR-1 |
| — | [`product/OPEN_DECISIONS.md`](product/OPEN_DECISIONS.md) | تصمیم‌های Q-02/04/06/11 (پذیرفته‌شده) |
| — | [`architecture/ADR/`](architecture/ADR/) | ADR-008 صف، ADR-009 ارزش‌گذاری، ADR-010 نگهداشت داده |

## مستندات برنامه‌ریزی‌شده (در فازهای بعد)

`business/PROCESS_CATALOG.md` · `architecture/DOMAIN_BOUNDARIES.md` · `architecture/DATA_ARCHITECTURE.md` · `architecture/INTEGRATION_ARCHITECTURE.md` · `quality/EDGE_CASE_CATALOG.md` · `quality/REQUIREMENTS_TRACEABILITY_MATRIX.md` · `quality/ACCEPTANCE_CRITERIA.md` · `quality/TEST_STRATEGY.md` · `quality/ACCESSIBILITY_AUDIT.md` · `quality/PERFORMANCE_BUDGETS.md` · `quality/SECURITY_CHECKLIST.md` · `quality/DATA_RETENTION_POLICY.md` · `quality/MASTER_QUALITY_STANDARDS.md` · `operations/DEPLOYMENT_GUIDE.md` · `operations/OBSERVABILITY_PLAN.md` · `operations/DISASTER_RECOVERY_PLAN.md` · `operations/INCIDENT_RESPONSE_PLAN.md` · `operations/RUNBOOK.md` · `operations/BACKUP_RESTORE_GUIDE.md` · `operations/USER_GUIDE.md` · `operations/ADMIN_GUIDE.md` · `operations/DEVELOPER_GUIDE.md`

## قواعد حاکم بر این پوشه

1. هر سند در سرصفحه نسخه، تاریخ و وضعیت دارد: `پیش‌نویس` / `برای بازبینی` / `تأییدشده` / `منقضی`.
2. ارجاع متقابل فقط با شناسه: `FR-4-02`، `FM-O-01`، `E-07`، `S-08`، `R-03`، `ADR-009`، `BR-3`، `Q-02`.
3. هیچ سندی «انجام شد» نمی‌گوید بدون شاهد قابل‌بازبینی.
4. مستند قدیمی‌شده = نقص، نه یادگار. هر تغییر رفتاری در کد باید در همان تغییر، مستند مربوط را به‌روز کند.
