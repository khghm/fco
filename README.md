# Fashion Commerce OS

پلتفرم یکپارچه تجارت و مدیریت کسب‌وکار پوشاک — Self-hosted · فارسی/RTL · Production-grade.

> **وضعیت پروژه:** فاز ۰ طراحی بسته شده (G0) و BR-1 با شاهد M1 پذیرفته شده است. BR-2 در حال اجراست: کاتالوگ عمومی و UI/API پنل محصول، قیمت و MFA در E2E محلی تأیید شده‌اند؛ push و اجرای CI برای تغییرات تازه و اتصال MinIO واقعی هنوز بازند.
> سامانه هنوز برای فروش واقعی کامل نیست: برخی کنترل‌های عملیاتی BR-2 بازند و BR-3 تا BR-5 پیاده نشده‌اند. وضعیت هر گام با شاهد در `docs/Engineering-04/IMPLEMENTATION_START_PLAN.md` ثبت می‌شود.

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
# راه‌اندازی سرویس‌های محلی (PostgreSQL و Redis)
docker compose -f infra/compose/docker-compose.yml up -d

# بررسی سلامت
docker compose -f infra/compose/docker-compose.yml ps
```

## وضعیت اتصال کاتالوگ

آزمون بازتولیدپذیر در [`catalog-e2e.sh`](scripts/catalog-e2e.sh) دیتابیس تازه‌ای با نام یکتای تولیدشده می‌سازد، همهٔ Migrationهای موجود (اکنون `0001..0021`) را اعمال می‌کند، [`catalog_e2e_seed.sql`](packages/infrastructure/tests/fixtures/catalog_e2e_seed.sql) را اجرا می‌کند، lint/typecheck/test/build را می‌سنجد و سرور production را روی loopback با پورت آزاد بالا می‌آورد. Redis باید در دسترس باشد؛ S3rver با bucket و تصویر fixture موقت توسط آزمون اجرا می‌شود. هیچ دیتابیس یا دادهٔ موجودی حذف/بازنویسی نمی‌شود و دیتابیس E2E برای بررسی نگه داشته می‌شود.

از ریشهٔ مخزن (با Git Bash در ویندوز) اجرا کنید:

```bash
DATABASE_URL=postgresql://fco:fco_local_dev_only@localhost:5432/fco \
  bash scripts/catalog-e2e.sh
```

هر دو job (`ci` و `Storefront catalog HTTP E2E`) برای برش عمومی اولیه روی commit `27ee1fa` در GitHub Actions #5 موفق شدند: [نتیجهٔ اجرا](https://github.com/khghm/fco/actions/runs/45842656947). پس از pin کردن Compose، هر دو job در CI #7 روی `44e21f3` نیز موفق شدند: [نتیجهٔ اجرا](https://github.com/khghm/fco/actions/runs/45844360646). شاهد محلی تاریخی این نسخه روی دیتابیس `fco_catalog_e2e_20261126143850_1796`، ۱۹ Migration و ۲۴ تست را گذراند؛ آزمون HTTP موارد زیر را تأیید کرد:

```text
GET /api/v1/products?q=FCO
200 | slug=e2e-shirt | price_rial=650000 | available_qty=4 | in_stock=true

GET /api/v1/products/e2e-shirt
200 | signed media URL TTL=900s | variants=1

GET <presigned media URL>
200 | image/png

GET /_next/image
200 | optimized image

GET /products/e2e-shirt
200 | image, title and variant rendered

GET /api/v1/products?page_size=61
400 | code=FCO-1001

GET /api/v1/products/not-a-published-product
404 | code=FCO-1004

GET /products/not-a-published-product
404

GET /api/v1/products?q=FCO (request 21, E2E limit=20/min)
429 | code=FCO-1007 | Retry-After present
```

در پاسخ‌های API، `request_id` در body و header برابر است؛ هدرهای IP جعلی نیز در `TRUST_PROXY=false` سهمیه را دور نمی‌زنند. E2E از شبیه‌ساز S3rver استفاده می‌کند؛ اتصال به MinIO واقعی/Production هنوز جداگانه باید آزموده شود. Compose تصویر MinIO را روی `quay.io/minio/minio:RELEASE.2024-04-18T19-09-19Z` pin می‌کند، اما pull از Docker Hub در دسترس نبود و Quay برای این تگ `401` داد؛ بنابراین آزمون واقعی MinIO همچنان معوق است. دیتابیس توسعهٔ `fco` تغییر نمی‌کند.

### پنل مدیریت محصول، قیمت و امنیت حساب

صفحهٔ `/admin/products` فهرست، ایجاد و ویرایش نسخه‌دار محصول، ایجاد تنوع، ثبت قیمت تازه و تاریخچهٔ تغییر قیمت را ارائه می‌کند؛ `/admin/settings/security` وضعیت MFA را نشان می‌دهد و `/mfa/setup` راه‌اندازی QR/کلید دستی، تأیید TOTP و نمایش یک‌بارهٔ ۱۰ کد بازیابی با امکان کپی/دانلود را دارد. Login از TOTP یا کد بازیابی یک‌بارمصرف پشتیبانی می‌کند. مسیرهای حساس با نشست PostgreSQL، middleware، کنترل مجوز use-case و Audit دارای actor و `request_id` محافظت می‌شوند. ورود ادمین به ۵ تلاش در ۱۵ دقیقه محدود است و عبور از سقف `429 / FCO-1007` و `Retry-After` می‌دهد؛ Redis شمارندهٔ مشترک است و در قطعی Redis، fallback حافظه‌ای فقط همان نمونه را پوشش می‌دهد.

تأیید محلی تازهٔ HTTP E2E روی PostgreSQL واقعی با ۲۱ Migration و Redis سبز است: صفحات محصول/امنیت/setup، CRUD محصول، تنوع، قیمت نسخه‌دار و تاریخچه، MFA enrollment/TOTP، recovery code یک‌بارمصرف، رد RBAC، rate limit، Audit و خروج بررسی شدند. دیتابیس `fco_admin_e2e_20261127071614_1387` برای بررسی باقی است. workflow مستقل GitHub Actions اکنون Redis هم دارد؛ اجرای GitHub برای همین تغییرات تا push هنوز تأیید نشده است. چرخهٔ مجاز تعویض/ابطال عامل MFA در صورت گم‌شدن دستگاه هنوز پیاده نشده است.

تأیید رسانهٔ واقعی MinIO همچنان معوق است: pull تگ pin‌شده از Quay با `401` و pull تصویر رسمی از Docker Hub با خطای دسترسی رد شد. E2E رسانهٔ موجود از S3rver استفاده می‌کند و معادل اثبات MinIO واقعی نیست؛ دیتابیس توسعهٔ `fco` تغییر نمی‌کند. جزئیات قرارداد، endpointها و محدودیت‌ها در [`API_SPECIFICATION.md`](docs/Architecture-02/API_SPECIFICATION.md) آمده است.

برای اجرای دوبارهٔ همین برش از Git Bash روی Windows یا Bash روی Linux، `DATABASE_URL` را به دیتابیس مدیریتی PostgreSQL بدهید. اسکریپت `scripts/admin-api-e2e.sh` یک دیتابیس یکتا می‌سازد، Migrationها و fixtureهای موقت را اعمال می‌کند و دیتابیس را برای بررسی نگه می‌دارد:

```bash
DATABASE_URL=postgresql://fco:<password>@127.0.0.1:5432/fco \
  bash scripts/admin-api-e2e.sh
```

## قواعد غیرقابل‌مذاکره

1. تغییر موجودی و پول فقط با سند قابل‌ردیابی.
2. هیچ دکمه‌ای بدون عملکرد واقعی.
3. هیچ Mock به‌عنوان قابلیت Production.
4. هیچ عدد ظرفیت، عملکرد یا امنیت بدون آزمون ادعا نمی‌شود.
5. هیچ نرخ/قاعده قانونی هارد‌کد نمی‌شود (پیکربندی نسخه‌دار با تاریخ اعتبار).

جزئیات کامل: `docs/Management-00/PROJECT_MASTER_CONTROL.md` بخش ۲.
