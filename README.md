# Fashion Commerce OS

پلتفرم یکپارچه تجارت و مدیریت کسب‌وکار پوشاک — Self-hosted · فارسی/RTL · Production-grade.

> **وضعیت پروژه:** مرحله صفر طراحی تأیید شده (G0)؛ در حال اجرای **BR-1** (پایه، هویت و اعتماد).
> هیچ قابلیت محصولی هنوز پیاده‌سازی نشده است. وضعیت هر گام در `docs/operations/IMPLEMENTATION_START_PLAN.md` ثبت می‌شود.

## مستندات

نقطه شروع: [`docs/README.md`](docs/README.md)

| سند | موضوع |
|---|---|
| `docs/business/PROJECT_DISCOVERY_REPORT.md` | مأموریت، فرض‌ها، ریسک‌ها، تصمیم‌ها |
| `docs/product/CAPABILITY_MAP.md` | ۱۶ دامنه، قابلیت‌های FR با اولویت |
| `docs/business/BUSINESS_OPERATIONS_BLUEPRINT.md` | از تأمین تا تسویه و مرجوعی (S1..S12) |
| `docs/product/ROLE_SCENARIOS.md` | سناریوهای نقش‌محور |
| `docs/business/ROLE_WORKFLOW_MATRIX.md` | نقش ↔ فرایند ↔ مجوز |
| `docs/architecture/SYSTEM_ARCHITECTURE.md` | مدل داده، API، رویداد، امنیت، زیرساخت |
| `docs/quality/MICRO_UX_STANDARDS.md` | فارسی/RTL، شمسی، اعداد، جدول، فرم |
| `docs/quality/FAILURE_MODE_ANALYSIS.md` | کاتالوگ شکست (FMEA) |
| `docs/product/RELEASE_PLAN.md` | فازها، گیت‌ها، معیار پذیرش |
| `docs/operations/IMPLEMENTATION_START_PLAN.md` | برنامه و شاهد گام‌های BR-1 |
| `docs/product/OPEN_DECISIONS.md` | تصمیم‌های Q-02/04/06/11 (پذیرفته‌شده) |
| `docs/architecture/ADR/` | ADR-008 صف، ADR-009 ارزش‌گذاری، ADR-010 نگهداشت داده |

## ساختار مخزن

```
apps/shop      فروشگاه مشتری (RTL)
apps/admin     پنل مدیریت و عملیات
packages/      domain · application · infrastructure · integrations · ui · formatting · config · testing
infra/compose  محیط توسعه محلی (PostgreSQL/Redis/MinIO)
scripts/       اسکریپت‌های عملیاتی
docs/          مستندات (منبع حقیقت دانش پروژه)
```

## محیط توسعه

- Node.js `v24.10.0` · **npm** (مدیر بسته انتخابی؛ `bun` روی این ماشین خراب است)
- Docker برای سرویس‌های محلی
- `psql` نصب نیست → از `docker exec` استفاده کنید

```bash
# راه‌اندازی سرویس‌های محلی
docker compose -f infra/compose/docker-compose.yml up -d

# بررسی سلامت
docker compose -f infra/compose/docker-compose.yml ps
```

## قواعد غیرقابل‌مذاکره

1. تغییر موجودی و پول فقط با سند قابل‌ردیابی.
2. هیچ دکمه‌ای بدون عملکرد واقعی.
3. هیچ Mock به‌عنوان قابلیت Production.
4. هیچ عدد ظرفیت، عملکرد یا امنیت بدون آزمون ادعا نمی‌شود.
5. هیچ نرخ/قاعده قانونی هارد‌کد نمی‌شود (پیکربندی نسخه‌دار با تاریخ اعتبار).

جزئیات: `docs/business/PROJECT_DISCOVERY_REPORT.md` بخش اصول.
