# مشخصات API (API Specification)

> **وضعیت:** تأییدشده (G0) · **نسخه:** v1.2 · **تاریخ:** ۱۴۰۵/۰۹/۰۵
> **مرجع بالادست:** `Architecture-02/SYSTEM_ARCHITECTURE.md §4` · **مجوزها:** `Business-01/USER_ROLES_AND_PERMISSIONS.md §3`
> **قاعده:** OpenAPI تک‌منبع در `packages/contracts/openapi.yaml` تولید می‌شود؛ این سند **قرارداد رفتاری** است، OpenAPI **قرارداد شکلی**. اختلاف = باگ.
> **وضعیت پیاده‌سازی:** برش نخست BR-2 شامل `GET /products` و صفحهٔ عمومی کاتالوگ است؛ جزئیات محصول، پنل مدیریت و سایر endpointها هنوز پیاده‌سازی نشده‌اند. این برش هنوز برای انتشار Production کامل نیست.
> **مالک قرارداد API و کدهای `FCO-*`.** `SYSTEM_ARCHITECTURE §4` فقط خلاصه معماری است.

---

## ۱. قراردادهای عمومی

| موضوع | قاعده |
|---|---|
| Base | `/api/v1` — نسخه در مسیر؛ تغییر شکننده = `/v2` |
| سبک | REST + endpointهای دستوری برای گذار وضعیت (`POST /orders/{id}/transitions`) |
| قالب | `application/json; charset=utf-8`؛ پاسخ‌ها همیشه JSON، حتی خطا |
| نام‌گذاری | مسیر جمع (`/orders`)، فیلد `snake_case`، مقدار enum `snake_case` |
| شناسه | `uuid` در مسیر؛ شماره انسانی فقط برای نمایش (`order_number`) |
| احراز هویت | کوکی نشست `HttpOnly; Secure; SameSite=Lax` (`ADR-007`)؛ API داخلی بدون Bearer توکن در مرورگر |
| CSRF | بررسی `Origin`/`Sec-Fetch-Site` برای همه متدهای غیر `GET` |
| زمان | ISO-8601 UTC (`2026-11-24T08:30:00Z`)؛ ورودی‌های تاریخ‌دار شمسی فقط در لایه UI و به‌صورت `date` میلادی ارسال می‌شود |
| پول | عدد صحیح ریال در فیلد `*_rial`؛ هرگز رشته یا اعشار |
| صفحه‌بندی | `?page=1&page_size=50` (سقف ۲۰۰) + `meta.total`؛ فید حجیم با `?cursor=` |
| مرتب‌سازی | `?sort=placed_at:desc` با whitelist ستون؛ ستون ناشناخته ⇒ `400` |
| فیلتر | فقط فیلدهای whitelist؛ فیلتر ناشناخته نادیده گرفته **نمی‌شود** (`400`) |
| هم‌زمانی | `If-Match: "<version>"` روی `PATCH`؛ تعارض ⇒ `409` + بدنه فعلی |
| Idempotency | هدر `Idempotency-Key` اجباری برای `POST`های مالی/سفارش/استرداد |
| Correlation | `X-Request-Id` ورودی پذیرفته یا تولید می‌شود؛ در همه لاگ‌ها و پاسخ خطا |
| نرخ | per-IP و per-user؛ سقف جدا برای `auth`, `otp`, `payment`, `search`, `export` |
| فایل | `multipart/form-data` با نوع/حجم مجاز؛ ذخیره خصوصی؛ دانلود با URL موقت امضاشده |
| حذف | `DELETE` فقط برای داده موقت؛ موجودیت مرجع ⇒ `POST /{id}/archive` |

### ۱.۱ پوشش پاسخ‌ها
```json
{ "data": {...}, "meta": { "request_id": "..." } }
{ "data": [...], "meta": { "page": 1, "page_size": 50, "total": 1234, "request_id": "..." } }
```

---

## ۲. احراز هویت و نشست

| متد | مسیر | مجوز | توضیح |
|---|---|---|---|
| POST | `/auth/staff/login` | — | موبایل/ایمیل + رمز؛ پاسخ: `mfa_required` یا نشست |
| POST | `/auth/staff/mfa/verify` | — | تأیید TOTP؛ نرخ‌محدود |
| POST | `/auth/staff/logout` | نشست | ابطال نشست جاری |
| GET | `/auth/session` | نشست | کاربر، نقش‌ها، مجوزها، `mfa_verified` |
| POST | `/auth/customer/otp/request` | — | ارسال OTP؛ پاسخ یکسان برای موبایل موجود/غیرموجود |
| POST | `/auth/customer/otp/verify` | — | ورود/ثبت‌نام مشتری |
| POST | `/auth/password/forgot` | — | همیشه `202` (بدون افشای وجود حساب) |
| POST | `/auth/password/reset` | — | با توکن یک‌بارمصرف |
| GET | `/iam/sessions` | `iam.session.revoke` | نشست‌های کاربر |
| DELETE | `/iam/sessions/{id}` | `iam.session.revoke` | ابطال راه‌دور |

---

## ۳. کاتالوگ endpointها (فاز ۱)

### ۳.۱ کاتالوگ
| متد | مسیر | مجوز |
|---|---|---|
| GET | `/products` | عمومی (فقط `published` و قیمت فعال) |
| GET | `/products/{slug}` | عمومی |
| GET | `/search?q=` | عمومی، نرخ‌محدود |
| GET | `/categories` | عمومی |
| POST | `/admin/products` | `catalog.product.write` |
| PATCH | `/admin/products/{id}` | `catalog.product.write` + `If-Match` |
| POST | `/admin/products/{id}/publish` | `catalog.product.publish` |
| POST | `/admin/products/{id}/variants` | `catalog.variant.write` |
| PATCH | `/admin/variants/{id}` | `catalog.variant.write` |
| POST | `/admin/media` | `catalog.media.write` |
| POST | `/admin/imports` | `catalog.import` (Dry-Run اجباری پیش از Commit) |

#### قرارداد پیاده‌سازی‌شده: `GET /api/v1/products`

پارامترهای پشتیبانی‌شده: `q` (حداکثر ۱۰۰ نویسه)، `category` و `brand` (slug)، `page` (پیش‌فرض ۱) و `page_size` (پیش‌فرض ۲۴، سقف ۶۰). پارامتر ناشناخته یا تکراری، مقدار نامعتبر و offset بیش از ۵۰۰۰ با `400 / FCO-1001` رد می‌شود.

پاسخ موفق، `data` را به‌صورت آرایهٔ محصولات و `meta` شامل `page`، `page_size`، `total` و `request_id` برمی‌گرداند؛ همان شناسه در هدر `X-Request-Id` نیز قرار می‌گیرد. خطای دسترس‌ناپذیری دیتابیس `503 / FCO-1010` و خطای پیش‌بینی‌نشده `500 / FCO-3001` است. این endpoint در نقش `fco_app` تابع `cat.search_products` را می‌خواند.

**محدودیت‌های فعلی:** محدودیت نرخ، صفحهٔ جزئیات محصول، تصاویر/رسانه و endpointهای مدیریت هنوز پیاده‌سازی نشده‌اند. آزمون خودکار فعلی فقط smoke test این endpoint در برابر PostgreSQL واقعی است و معیار پذیرش کامل BR-2 یا آمادگی Production را ثابت نمی‌کند.

### ۳.۲ قیمت و تخفیف
| متد | مسیر | مجوز | نکته |
|---|---|---|---|
| GET | `/admin/variants/{id}/prices` | `pricing.price.read` | تاریخچه نسخه‌ها |
| POST | `/admin/variants/{id}/prices` | `pricing.price.update` | `effective_from` اجباری؛ هم‌پوشانی ⇒ `422` |
| POST | `/admin/prices/bulk` | `pricing.bulk.update` | ابتدا `?dry_run=true` |
| POST | `/admin/promotions` | `promotion.rule.write` | |
| GET | `/admin/promotions/preview` | `promotion.rule.write` | پیش‌نمایش اثر تخفیف |
| POST | `/checkout/quote` | عمومی | قیمت/تخفیف/مالیات/ارسال محاسبه‌شده سرور |

### ۳.۳ موجودی
| متد | مسیر | مجوز |
|---|---|---|
| GET | `/admin/inventory` | `inventory.read` (فیلتر `warehouse_id`, `variant_id`) |
| GET | `/admin/inventory/{variant_id}/ledger` | `inventory.read` |
| POST | `/admin/inventory/adjustments` | `inventory.adjust` (دلیل اجباری؛ بالای آستانه ⇒ `202 pending_approval`) |
| POST | `/admin/inventory/adjustments/{id}/approve` | تأیید دوم (SoD-3) |
| POST | `/admin/inventory/counts` | `inventory.count.submit` |
| POST | `/admin/inventory/counts/{id}/approve` | `inventory.count.approve` |
| POST | `/admin/grn` | `warehouse.grn.create` (`purchase_order_id` اجباری) |

### ۳.۴ سبد و سفارش
| متد | مسیر | مجوز |
|---|---|---|
| POST | `/carts` | عمومی (مهمان) |
| POST | `/carts/{id}/items` | عمومی / مالک سبد |
| PATCH | `/carts/{id}/items/{item_id}` | مالک |
| POST | `/checkout/place-order` | عمومی + **`Idempotency-Key` اجباری** |
| GET | `/orders/{order_number}` | مالک یا `order.read` |
| GET | `/orders/track/{code}` | عمومی — فقط وضعیت، بدون PII |
| POST | `/admin/orders/{id}/transitions` | `order.assign` / `order.cancel` + گذار مجاز |
| POST | `/admin/orders/{id}/notes` | `order.note.write` |
| POST | `/admin/orders/{id}/cancel` | `order.cancel` (قواعد مالی/انباری) |

**نمونه `place-order`:**
```http
POST /api/v1/checkout/place-order
Idempotency-Key: 8b1f0c2e-...-a7
Content-Type: application/json

{ "cart_id": "...", "shipping_address": {...}, "shipping_method": "standard",
  "payment_method": "gateway" }
```
```json
201 Created
{ "data": { "order_number": "FCO-1405-000123", "status": "awaiting_payment",
            "total_rial": 12500000, "payment_redirect_url": "https://..." } }
```
درخواست دوم با همان کلید ⇒ همان `201` و همان سفارش، بدون سفارش دوم (`BRQ-19`).

### ۳.۵ پرداخت
| متد | مسیر | مجوز | نکته |
|---|---|---|---|
| POST | `/payments/{order_id}/initiate` | مالک/`order.read` | `Idempotency-Key` |
| POST | `/payments/callback/{provider}` | — | **امضا + `provider_ref` یکتا + ضد بازپخش** |
| GET | `/admin/payments/unknown` | `payment.reconcile` | صف حالت Unknown با مهلت |
| POST | `/admin/payments/{id}/reconcile` | `payment.reconcile` | ثبت نتیجه و بستن مغایرت |

### ۳.۶ انبار، بسته‌بندی، ارسال
| متد | مسیر | مجوز |
|---|---|---|
| GET | `/admin/pick-lists` | `warehouse.pick.execute` |
| POST | `/admin/pick-lists/{id}/scan` | `warehouse.pick.execute` (اسکن نامرتبط ⇒ `422` + توقف) |
| POST | `/admin/pick-lists/{id}/complete` | `warehouse.pick.execute` |
| POST | `/admin/packages` | `warehouse.pack` (وزن، نوع بسته) |
| POST | `/admin/shipments` | `shipment.create` |
| POST | `/admin/shipments/{id}/handover` | `shipment.manifest` (کاهش موجودی با سند ارسال) |
| POST | `/admin/manifests` | `shipment.manifest` |
| POST | `/admin/shipments/{id}/tracking` | `shipment.tracking.manual` |
| POST | `/webhooks/carrier/{provider}` | امضا + idempotency |

### ۳.۷ مرجوعی
| متد | مسیر | مجوز |
|---|---|---|
| POST | `/returns` | `returns.request.create` / مشتری مالک سفارش |
| GET | `/returns/{id}` | مالک یا `order.read` |
| POST | `/admin/returns/{id}/inspection` | `returns.inspection.record` |
| POST | `/admin/returns/{id}/refund-request` | `returns.refund.request` |
| POST | `/admin/returns/{id}/refund-approve` | `returns.refund.approve` (SoD-2) |
| POST | `/admin/returns/{id}/exchange` | `returns.resolve.exchange` |

### ۳.۸ مالی
| متد | مسیر | مجوز |
|---|---|---|
| GET | `/admin/finance/journals` | `finance.journal.read` |
| POST | `/admin/finance/journals` | `finance.journal.post` (ناتراز ⇒ `422`) |
| POST | `/admin/finance/journals/{id}/reverse` | `finance.journal.post` |
| GET | `/admin/finance/reports/trial-balance` | `finance.report.read` |
| GET | `/admin/finance/reports/pnl` | `finance.report.read` |
| GET | `/admin/finance/tax-rules` | `finance.report.read` |
| POST | `/admin/finance/tax-rules` | `finance.tax.rule.write` |
| POST | `/admin/finance/periods/{id}/close` | `finance.period.close` |
| POST | `/admin/finance/invoices` | `finance.invoice.issue` |

### ۳.۹ مشتری، پشتیبانی، بازاریابی
| متد | مسیر | مجوز |
|---|---|---|
| GET | `/admin/customers/{id}` | `crm.customer.read` (PII ماسک‌شده) |
| GET | `/admin/customers/{id}/pii` | `crm.customer.pii.read` + تفسیر دلیل |
| GET | `/admin/tickets` | `crm.ticket.reply` (فقط دامنه مجاز) |
| POST | `/admin/tickets/{id}/reply` | `crm.ticket.reply` |
| POST | `/admin/consents` | `crm.consent.write` |
| POST | `/admin/campaigns` | `marketing.campaign.write` |
| POST | `/admin/campaigns/{id}/send` | `marketing.message.send` |

### ۳.۱۰ پلتفرم
| متد | مسیر | مجوز |
|---|---|---|
| GET | `/health` | عمومی (بدون جزئیات داخلی) |
| GET | `/health/ready` | داخلی |
| GET | `/metrics` | شبکه داخلی فقط |
| GET | `/admin/settings` | `platform.setting.read` |
| POST | `/admin/settings` | `platform.setting.write` (نسخه‌دار + دلیل) |
| GET | `/admin/audit` | `iam.audit.read` |
| GET | `/admin/jobs` | `platform.health.read` |
| POST | `/admin/jobs/{id}/retry` | `platform.job.run` |
| GET | `/admin/outbox/dead-letters` | `platform.dlq.inspect` |
| POST | `/admin/exports` | `export.data` / `export.pii` |
| GET | `/admin/attachments/{id}/download` | مجوز منبع + لینک موقت |

---

## ۴. گذار وضعیت (الگوی دستوری)

```http
POST /api/v1/admin/orders/{id}/transitions
If-Match: "7"

{ "to": "allocated", "reason": "تخصیص خودکار" }
```
- بررسی: گذار در جدول مجاز است؟ مجوز دارد؟ پیش‌شرط داده‌ای برقرار است (موجودی، پرداخت)؟
- خطاها: `409` (تعارض نسخه/وضعیت)، `422` (گذار مجاز نیست)، `403` (مجوز)

---

## ۵. کدهای خطا (`FCO-*`)

قالب پاسخ:
```json
{ "error": { "code": "FCO-1003", "message": "این عملیات با وضعیت فعلی سفارش سازگار نیست.",
             "request_id": "6f1c...", "details": { "current_status": "shipped" } } }
```
**ممنوع:** Stack Trace، نام جدول/ستون، پیام خام درگاه، مسیر فایل.

| کد | HTTP | معنا | نمونه |
|---|---|---|---|
| `FCO-1001` | 400 | درخواست نامعتبر | فیلد ناشناخته/نوع نادرست |
| `FCO-1002` | 401 | عدم احراز هویت | نشست منقضی |
| `FCO-1003` | 403 | عدم مجوز | مجوز ناکافی |
| `FCO-1004` | 404 | منبع یافت نشد | یا منبع غیرمالک (برای عدم افشا) |
| `FCO-1005` | 409 | تعارض نسخه/وضعیت | `If-Match` کهنه |
| `FCO-1006` | 422 | نقض قاعده دامنه | گذار غیرمجاز، مالیات نامعتبر |
| `FCO-1007` | 429 | محدودیت نرخ | OTP/جست‌وجو |
| `FCO-1008` | 413 | فایل بیش از حد | آپلود |
| `FCO-1009` | 415 | نوع فایل نامجاز | تصویر SVG/اجرایی |
| `FCO-1010` | 503 | سرویس وابسته در دسترس نیست | درگاه/پیامک (Circuit باز) |
| `FCO-2001` | 422 | موجودی کافی نیست | رزرو |
| `FCO-2002` | 422 | قیمت مؤثر موجود نیست | محصول بدون قیمت |
| `FCO-2003` | 409 | Idempotency با بدنه متفاوت | همان کلید، `request_hash` دیگر |
| `FCO-2004` | 422 | سند ناتراز | دفتر مالی |
| `FCO-2005` | 422 | دوره مالی بسته است | ثبت سند |
| `FCO-2006` | 409 | استرداد قبلاً انجام شده | RMA |
| `FCO-2007` | 422 | اسکن نامرتبط | بسته‌بندی |
| `FCO-2008` | 422 | نقض تفکیک وظایف | تأیید توسط خود |
| `FCO-3001` | 500 | خطای پیش‌بینی‌نشده | با `request_id` فقط |

> کدها **پایدار** هستند: معنا تغییر نمی‌کند؛ کد جدید اضافه می‌شود، کد قدیمی حذف نمی‌شود.

---

## ۶. Webhookها و Callback

| موضوع | قاعده |
|---|---|
| امضا | HMAC روی بدنه خام + timestamp؛ عدم تطابق ⇒ `401` بدون پردازش |
| پنجره زمانی | timestamp قدیمی‌تر از ۵ دقیقه ⇒ رد (`FM-S-10`) |
| بازپخش | کلید یکتای رویداد در `sys.inbox_events` ⇒ پردازش یک‌بار |
| ذخیره خام | بدنه خام در `pay.webhook_events`/`shipment_events` برای بازبینی |
| پاسخ | `2xx` سریع؛ پردازش سنگین در صف (نه در مسیر Callback) |
| خطا | هرگز `200` برای خطای پردازش برنگردانید (باعث گم‌شدن رویداد می‌شود) |
| ناشناخته | رویداد با نوع ناشناخته ⇒ ذخیره + صف بازبینی، نه دور ریختن |

---

## ۷. محدودیت نرخ (پیش‌فرض، پیکربندی‌شده)

| مسیر | کلید | سقف اولیه (تثبیت پس از اندازه‌گیری) |
|---|---|---|
| `/auth/staff/login` | IP + حساب | ۵ تلاش/۱۵ دقیقه |
| `/auth/customer/otp/request` | موبایل + IP | ۳/۱۰ دقیقه |
| `/search` | IP | ۳۰/دقیقه |
| `/payments/*/initiate` | سفارش | ۳/۱۰ دقیقه |
| `/admin/exports` | کاربر | ۵/ساعت |
| عمومی | IP | سقف پایه |

---

## ۸. سیاست نسخه‌بندی و سازگاری

- حذف فیلد = تغییر شکننده ⇒ فقط در نسخه اصلی بعدی.
- افزودن فیلد اختیاری = سازگار.
- تغییر معنا = نسخه جدید.
- هر endpoint جدید باید در همین سند + OpenAPI + آزمون قرارداد ظاهر شود؛ endpoint بدون آزمون منتشر نمی‌شود.

---

## ۹. شکاف‌های باز

1. مسیرهای فاز ۲ (خرید، CRM کامل، CMS، گزارش‌ساز) فقط در سطح دامنه طراحی شده‌اند.
2. قرارداد دقیق آداپتور درگاه و شرکت حمل به‌انتخاب ارائه‌دهنده بسته است (Q-06).
3. سقف‌های نرخ عدد آزمون‌نشده‌اند (اصل ۴).
4. الگوی دقیق پاسخ برای Export حجیم (نوع job + لینک) در BR-2 تثبیت می‌شود.
