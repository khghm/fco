# Fashion Commerce OS

پلتفرم یکپارچه تجارت و مدیریت کسب‌وکار پوشاک — Self-hosted · فارسی/RTL · Production-grade.

> **وضعیت پروژه:** فاز ۰ طراحی بسته شده (G0) و BR-1 با شاهد M1 پذیرفته شده است. BR-2 در حال اجراست: مدل و منطق کاتالوگ/موجودی و لایهٔ خواندن عمومی در دیتابیس وجود دارند؛ رابط‌های فروشگاه و مدیریت تازه در حال ساخته‌شدن‌اند.
> سامانه هنوز برای فروش واقعی کامل نیست: BR-2 باید از مسیر UI/API end-to-end بسته شود و BR-3 تا BR-5 پیاده نشده‌اند. وضعیت هر گام با شاهد در `docs/Engineering-04/IMPLEMENTATION_START_PLAN.md` ثبت می‌شود.

## مستندات

نقطه شروع: [`docs/README.md`](docs/README.md) · منشور و قواعد: [`docs/Management-00/PROJECT_MASTER_CONTROL.md`](docs/Management-00/PROJECT_MASTER_CONTROL.md)

| سند | موضوع |
|---|---|
| `docs/Management-00/PROJECT_MASTER_CONTROL.md` | منشور، اصول، فضای نام شناسه‌ها، گیت‌ها |
| `docs/Management-00/PROJECT_ROADMAP.md` | توالی فازها و مسیر بحرانی |
| `docs/Management-00/DECISION_LOG.md` | تصمیم‌ها (Q/ADR/D) و گزینه‌های رد‌شده |
| `docs/Management-00/RISK_REGISTER.md` | ریسک‌ها با مالک و شاهد کاهش |
| `docs/Management-00/CHANGELOG.md` | تغییرات اسناد و مخزن |
| `docs/Business-01/PROJECT_DISCOVERY_REPORT.md` | مأموریت، فرض‌ها، ریسک‌ها |
| `docs/Business-01/BUSINESS_REQUIREMENTS.md` | الزامات BRQ، دامنه in/out، قواعد |
| `docs/Business-01/USER_ROLES_AND_PERMISSIONS.md` | نقش‌ها، مجوزها، تفکیک وظایف |
| `docs/Business-01/BUSINESS_WORKFLOWS.md` | جریان‌های کاری WF با SLA و مسیر شکست |
| `docs/Business-01/BUSINESS_OPERATIONS_BLUEPRINT.md` | از تأمین تا تسویه و مرجوعی (S1..S12) |
| `docs/Business-01/ROLE_WORKFLOW_MATRIX.md` | نقش ↔ فرایند ↔ قابلیت ↔ ریسک |
| `docs/Architecture-02/SYSTEM_ARCHITECTURE.md` | معماری کلان، مرز ماژول‌ها، مدل داده |
| `docs/Architecture-02/DATABASE_DESIGN.md` | جداول، قیدها، ایندکس، Migration |
| `docs/Architecture-02/API_SPECIFICATION.md` | قرارداد API، کدهای خطا، endpointها |
| `docs/Architecture-02/SECURITY_ARCHITECTURE.md` | مدل تهدید، احراز هویت، رمزنگاری |
| `docs/UX-03/DESIGN_SYSTEM.md` | توکن‌ها، مؤلفه‌ها، RTL، دسترس‌پذیری |
| `docs/UX-03/PERSIAN_UX_STANDARDS.md` | لحن، واژه‌نامه، تاریخ شمسی، مبلغ، پیام‌ها |
| `docs/UX-03/ADMIN_PANEL_SPECIFICATION.md` | صفحه‌ها، صف کار، مجوزها |
| `docs/Engineering-04/IMPLEMENTATION_PLAN.md` | استک، ساختار، ترتیب اجرا، CI |
| `docs/Engineering-04/IMPLEMENTATION_START_PLAN.md` | گام‌های BR-1 + شاهد اجرا |
| `docs/Engineering-04/TEST_STRATEGY.md` | سطوح آزمون، آزمون قاعده‌محور |
| `docs/Engineering-04/DEPLOYMENT_GUIDE.md` | محیط‌ها، نصب، انتشار، Rollback |
| `docs/Engineering-04/BACKUP_AND_RECOVERY.md` | پشتیبان، Restore، DR |
| `docs/product/CAPABILITY_MAP.md` | ۱۶ دامنه، قابلیت‌های FR با اولویت |
| `docs/product/ROLE_SCENARIOS.md` | سناریوهای نقش‌محور |
| `docs/product/RELEASE_PLAN.md` | فازها، گیت‌ها، معیار پذیرش |
| `docs/product/OPEN_DECISIONS.md` | تصمیم‌های Q-02/04/06/11 |
| `docs/quality/MICRO_UX_STANDARDS.md` | جدول، فرم، بازخورد، دسترس‌پذیری |
| `docs/quality/FAILURE_MODE_ANALYSIS.md` | کاتالوگ شکست (FMEA) |
| `docs/Architecture-02/ADR/` | ADR-001..012 |

## ساختار مخزن

```
apps/shop      فروشگاه مشتری (RTL)
apps/admin     پنل مدیریت و عملیات
packages/      domain · application · infrastructure · integrations · ui · formatting · config · testing
infra/compose  محیط توسعه محلی (PostgreSQL/Redis/S3-compatible)
scripts/       اسکریپت‌های عملیاتی
docs/          مستندات (منبع حقیقت دانش پروژه)
```

## محیط توسعه

- Node.js 24 · **npm** (مدیر بسته انتخابی؛ `bun` روی این ماشین خراب است) — وضعیت اندازه‌گیری‌شده: `docs/Engineering-04/IMPLEMENTATION_START_PLAN.md §1`
- Docker برای سرویس‌های محلی
- `psql` نصب نیست → از `docker exec` استفاده کنید
- workspaceهای npm: `npm install`، سپس `npm run dev:shop` یا `npm run dev:admin`
- برای اجرای فروشگاه، `.env.example` را به `apps/shop/.env.local` کپی کنید؛ مقادیر محلی را با محیط خود تنظیم کنید.

```bash
# راه‌اندازی سرویس‌های محلی
docker compose -f infra/compose/docker-compose.yml up -d

# بررسی سلامت
docker compose -f infra/compose/docker-compose.yml ps
```

## وضعیت اتصال کاتالوگ

آزمون بازتولیدپذیر در [`catalog-e2e.sh`](scripts/catalog-e2e.sh) دیتابیس تازه‌ای با نام یکتای تولیدشده می‌سازد، ۱۹ Migration را اعمال می‌کند، [`catalog_e2e_seed.sql`](packages/infrastructure/tests/fixtures/catalog_e2e_seed.sql) را اجرا می‌کند، lint/typecheck/test/build را می‌سنجد و سپس سرور production را روی loopback با پورت آزاد بالا می‌آورد. اسکریپت هیچ دیتابیسی را حذف یا بازنویسی نمی‌کند؛ نام دیتابیس را چاپ می‌کند و آن را برای بررسی نگه می‌دارد.

از ریشهٔ مخزن (با Git Bash در ویندوز) اجرا کنید:

```bash
DATABASE_URL=postgresql://fco:fco_local_dev_only@localhost:5432/fco \
  bash scripts/catalog-e2e.sh
```

job مستقل `Storefront catalog HTTP E2E` در [ci.yml](.github/workflows/ci.yml) با PostgreSQL 16 در GitHub Actions اجرا شد. **وضعیت: E2E محلی سبز؛ هر دو job یعنی `ci` و `Storefront catalog HTTP E2E` در اجرای [GitHub Actions #1](https://github.com/khghm/fco/actions/runs/45830968091) برای commit `d9c4e41` سبز شدند.** اجرای محلی موفق در دیتابیسِ خودکارنام‌گذاری‌شدهٔ `fco_catalog_e2e_20261126131901_1641` همهٔ ۱۹ Migration، ۱۳ تست، lint، typecheck و build هر دو اپ را گذراند؛ هیچ آزمون یا seedای به این نام وابسته نیست:

```text
GET /api/v1/products?q=FCO
200 | slug=e2e-shirt | price_rial=650000 | available_qty=4 | in_stock=true

GET /api/v1/products?page_size=61
400 | code=FCO-1001
```

در هر دو پاسخ، `request_id` در body و header برابر بود. دیتابیس توسعهٔ `fco` تغییر نکرد. صفحهٔ جزئیات، رسانه و سایر محدودیت‌های برش در `docs/Architecture-02/API_SPECIFICATION.md` آمده‌اند.

## قواعد غیرقابل‌مذاکره

1. تغییر موجودی و پول فقط با سند قابل‌ردیابی.
2. هیچ دکمه‌ای بدون عملکرد واقعی.
3. هیچ Mock به‌عنوان قابلیت Production.
4. هیچ عدد ظرفیت، عملکرد یا امنیت بدون آزمون ادعا نمی‌شود.
5. هیچ نرخ/قاعده قانونی هارد‌کد نمی‌شود (پیکربندی نسخه‌دار با تاریخ اعتبار).

جزئیات کامل: `docs/Management-00/PROJECT_MASTER_CONTROL.md` بخش ۲.
