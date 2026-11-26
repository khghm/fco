# فروشگاه FCO

فروشگاه عمومی فارسی/RTL. در حال حاضر صفحهٔ کاتالوگ و `GET /api/v1/products` پیاده‌سازی شده‌اند؛ جزئیات محصول، تصاویر و خرید هنوز آماده نیستند.

## اجرای محلی

از ریشهٔ مخزن وابستگی‌ها را نصب کنید و `.env.example` را به `apps/shop/.env.local` کپی کنید. سپس سرویس‌های محلی PostgreSQL را با راهنمای ریشه اجرا کرده و:

```powershell
npm run dev:shop
```

فروشگاه روی `http://localhost:3000` در دسترس است. برای بررسی برش فعلی:

```powershell
npm test
npm run lint
npm run typecheck
npm run build
```

API به دیتابیسی نیاز دارد که Migrationهای کاتالوگ را داشته باشد؛ مقدارهای محلی را در فایل `.env.local` تنظیم کنید و آن را commit نکنید.
