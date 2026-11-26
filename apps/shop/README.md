# فروشگاه FCO

فروشگاه عمومی فارسی/RTL با فهرست و جزئیات محصول، نمایش تصویر از S3-compatible storage با URL امضاشدهٔ ۱۵ دقیقه‌ای و محدودیت عمومی نرخ. پنل مدیریت، خرید و احراز هویت عملیاتی هنوز پیاده‌سازی نشده‌اند.

## اجرای محلی

از ریشهٔ مخزن وابستگی‌ها را نصب کنید و `.env.example` را به `apps/shop/.env.local` کپی کنید. برای اجرای محلی، PostgreSQL و Redis را بالا بیاورید؛ برای نمایش رسانه باید یک S3-compatible storage با تنظیمات همان فایل در دسترس باشد:

```powershell
docker compose -f infra/compose/docker-compose.yml up -d postgres redis
npm run dev:shop
```

فروشگاه روی `http://localhost:3000` در دسترس است. سرور سفارشی Node، IP اتصال را برای rate limiter به‌صورت امن فراهم می‌کند؛ برای Production باید `npm run start --workspace @fco/shop` اجرا شود، نه `next start`.

در Production، `TRUST_PROXY=true` را فقط وقتی تنظیم کنید که reverse proxy شناخته‌شده، `X-Real-IP`/`X-Forwarded-For` ورودی را حذف و خودش بازنویسی کند. در غیر این صورت مقدار `false` بماند. سقف پیش‌فرض کاتالوگ ۱۰۰ درخواست در دقیقه برای هر IP است؛ fallback حافظه‌ای هنگام قطعی Redis فقط بین پردازه‌های همان نمونه مشترک است.

آزمون HTTP بازتولیدپذیر با دیتابیس و Redis محلی؛ S3rver با bucket موقت و فایل fixture در خود آزمون اجرا می‌شود:

```bash
DATABASE_URL=postgresql://fco:fco_local_dev_only@localhost:5432/fco bash scripts/catalog-e2e.sh
```

این آزمون از bucket موقت `fco-catalog-e2e`، سقف ۲۰ درخواست/دقیقه و fixture تصویری یک‌پیکسلی استفاده می‌کند؛ درخواست بیست‌ویکم باید با `429` پاسخ دهد. API به دیتابیسی نیاز دارد که Migrationهای کاتالوگ را داشته باشد؛ مقدارهای محلی را تنظیم و فایل `.env.local` را commit نکنید. S3rver فقط شبیه‌ساز E2E است؛ Production باید S3/MinIO واقعی داشته باشد.
