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

در ۲۰۲۶-۱۱-۲۶، دیتابیس جداگانهٔ `fco_catalog_e2e_20261126` با ۱۹ Migration موجود ساخته و با یک محصول آزمایشی seed شد؛ دیتابیس توسعهٔ `fco` دست‌نخورده ماند. آزمون opt-in در [`route.integration.test.ts`](apps/shop/src/app/api/v1/products/route.integration.test.ts) مستقیماً handler را با PostgreSQL واقعی صدا می‌زند و پاسخ موفق (قیمت ۶۵۰٬۰۰۰ ریال، موجودی قابل‌فروش ۴) و خطای ورودی `400 / FCO-1001` را می‌سنجد:

```powershell
$env:FCO_E2E_DATABASE_URL = "<connection string for the isolated E2E database>"
npm test
```

آزمون handler با اتصال واقعی سبز است؛ بررسی HTTP از طریق سرور Next.js هنوز انجام نشده، چون محیط در تلاش برای listen روی loopback با `EACCES` پاسخ داد. جزئیات محصول، رسانه و سایر محدودیت‌های برش در `docs/Architecture-02/API_SPECIFICATION.md` ثبت شده‌اند.

## قواعد غیرقابل‌مذاکره

1. تغییر موجودی و پول فقط با سند قابل‌ردیابی.
2. هیچ دکمه‌ای بدون عملکرد واقعی.
3. هیچ Mock به‌عنوان قابلیت Production.
4. هیچ عدد ظرفیت، عملکرد یا امنیت بدون آزمون ادعا نمی‌شود.
5. هیچ نرخ/قاعده قانونی هارد‌کد نمی‌شود (پیکربندی نسخه‌دار با تاریخ اعتبار).

جزئیات کامل: `docs/Management-00/PROJECT_MASTER_CONTROL.md` بخش ۲.
