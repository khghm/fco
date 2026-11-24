# معماری فنی — Fashion Commerce OS

> **وضعیت:** تأییدشده (G0) · **نسخه:** v1.0 · **تاریخ:** ۱۴۰۵/۰۹/۰۲
> **خروجی ۵ از ۱۰** — طراحی، نه پیاده‌سازی. هر عدد ظرفیت صریحاً آزمون‌نشده است.

## ۰. قیود و نتیجه معماری

| قید | نتیجه |
|---|---|
| Self-hosted، تیم کوچک | **Modular Monolith** (ADR-001) در یک اپ + یک Worker |
| صحت موجودی/پول | دفتر گردش append-only، تراکنش اتمیک، Idempotency، Outbox |
| بازسازی تاریخی | Snapshot در سفارش/فاکتور + قیمت و قاعده نسخه‌دار |
| مقیاس نامعلوم | طراحی برای ۱۰×، جداسازی تحلیلی، صفحه‌بندی سروری |
| فارسی/RTL | لایه مشترک تاریخ/عدد/متن |
| سرویس بیرونی نامطمئن | Integration Hub + Circuit Breaker + صف بازبینی |

### سبک لایه‌بندی
```
[Interface] HTTP/UI/CLI ─> [Application] use-case + مجوز + تراکنش
                                  │
                                  ▼
                            [Domain] قواعد و وضعیت (بدون I/O)
                                  │
                                  ▼
                          [Infrastructure] DB / صف / آداپتور
```
Domain به هیچ لایه بیرونی وابسته نیست؛ Interface به Infrastructure دسترسی مستقیم ندارد.

## ۱. نمای استقرار

```
Internet ──TLS──> Reverse Proxy (HSTS, rate limit, static)
                      ├──> App (web/API, چند نمونه)
                      └──> Worker(s) (صف، گزارش، تطبیق، Job)
                                 │
        ┌────────────────────────┼─────────────────────────┐
   PostgreSQL            Redis (cache/queue/lock)     Object Storage (S3)
   (منبع حقیقت)                                          │
        ├── Analytics (schema جدا / جدول تجمیعی)
        └── Backup رمزگذاری‌شده offsite
   Observability: logs · metrics · errors
```

## ۲. مرز ماژول‌ها

| ماژول | مجاز به وابستگی | ممنوع |
|---|---|---|
| Identity | — | هر دامنه کسب‌وکار |
| Catalog | Identity | Order/Finance |
| Pricing | Catalog، پیکربندی | Order |
| Inventory | Catalog، Identity | Order (فقط پورت رزرو) |
| Commerce | Catalog، Pricing، Inventory، Identity | Finance مستقیم |
| OMS | Commerce (رویداد)، Inventory | حمل مستقیم |
| Fulfillment | OMS، Inventory | Finance |
| TMS | Fulfillment، Integration Hub | Pricing |
| Returns | OMS، Inventory، Finance (رویداد) | TMS مستقیم |
| Finance | رویدادها + پیکربندی | فراخوانی معکوس دامنه‌ها |
| CRM/Marketing | Commerce/OMS رویداد، Identity | تغییر سند مالی |
| Analytics | داده تجمیعی/رویداد | نوشتن در دامنه |
| Platform | همه (زیرساخت) | منطق دامنه‌ای |

قواعد: ارتباط هم‌زمان فقط از پورت/use-case؛ ناهم‌زمان از رویداد؛ هر ماژول schema خودش؛ فقط Finance سند مالی و فقط Inventory گردش موجودی می‌نویسد.

## ۳. مدل داده — اصول

| اصل | جزئیات |
|---|---|
| پول | `BIGINT` ریال؛ بدون float |
| زمان | `TIMESTAMPTZ` UTC؛ نمایش شمسی در UI |
| مقدار | عدد صحیح در واحد پایه (گرم/میلی‌متر) |
| تغییرناپذیری | دفتر گردش، دفتر کل، Audit، Outbox فقط INSERT |
| شناسه | UUID عمومی + شماره انسانی جداگانه |
| حذف | موجودیت مرجع: archived_at؛ حذف واقعی فقط داده موقت با سیاست |
| هم‌زمانی | `version` (Optimistic Lock) روی رکوردهای قابل‌ویرایش |
| چند‌انباره | همه موجودی/گردش/رزرو با warehouse_id |

### جداول کلیدی
`iam_user/role/permission/session` · `catalog_product/variant/media` · `pricing_price` · `promotion_rule/coupon/redemption` · `inv_stock_ledger` · `inv_stock_balance` · `inv_reservation` · `proc_supplier/purchase_order/po_line/grn/grn_line/supplier_invoice` · `oms_order/order_line/order_snapshot/order_event` · `pay_transaction` · `pay_reconciliation` · `ful_pick/package/package_item` · `tms_shipment/shipment_event/carrier_invoice` · `rma_request/item/inspection/resolution` · `fin_account/journal/journal_line/period` · `fin_event_mapping` · `fin_tax_rule` · `crm_customer/consent/ticket/loyalty_*` · `mkt_campaign/workflow/message_log` · `sys_outbox/inbox_event/idempotency_key/job_run` · `audit_log` · `sys_setting`

### سه تصمیم داده تعیین‌کننده
1. **گردش + تجمیع با هم** در یک تراکنش؛ گزارش از تجمیع، حسابرسی از گردش.
2. **Snapshot در قلم سفارش**: قیمت، سهم تخفیف، سهم مالیات، COGS.
3. **Idempotency Key به‌عنوان جدول**.

### ایندکس (فرضیه تا آزمون)
`(warehouse_id, variant_id)` · `(status, created_at)` · `(customer_id, placed_at)` · GIN روی ستون نرمال‌شده فارسی · keyset برای عمق زیاد · هیچ لیست بدون LIMIT.

## ۴. قرارداد API

| موضوع | تصمیم |
|---|---|
| سبک | REST + endpoint دستوری برای گذار وضعیت (`POST /orders/{id}/transitions`) |
| نسخه | `/api/v1` |
| احراز هویت | کوکی نشست امن (HttpOnly/Secure/SameSite) |
| مجوز | بررسی سرور در هر endpoint |
| صفحه‌بندی | page/pageSize برای جدول + cursor برای فید حجیم |
| مرتب‌سازی | `sort=field:asc` با whitelist |
| هم‌زمانی | `If-Match`/version → `409` با داده فعلی |
| Idempotency | هدر `Idempotency-Key` در POSTهای حساس |
| خطا | `{code, message(fa), requestId, details}` بدون Stack Trace |
| نرخ | per-IP/per-user برای احراز هویت، پرداخت، جست‌وجو، پیام |
| فایل | نوع/حجم مجاز، ذخیره خصوصی، دانلود با لینک موقت |
| مستندسازی | OpenAPI تک‌منبع + نمونه خطا |

## ۵. رویداد و یکپارچگی

| جزء | طراحی |
|---|---|
| تولید | در همان تراکنش، ردیف `sys_outbox` |
| انتشار | Worker با قفل، batch، retry نمایی، DLQ |
| مصرف | idempotent با `sys_inbox_event(event_id)` یکتا |
| نسخه | `event_name.v1`؛ تغییر معنا = نسخه جدید |
| همبستگی | `correlationId` تا آخر زنجیره |
| پایش | عمق صف، نرخ خطا، سن پیام، DLQ |
| آداپتور | Timeout، Circuit Breaker، Rate Limit، امضای Webhook، ذخیره رویداد خام |

هیچ فراخوانی بیرونی در میانه تراکنش DB انجام نمی‌شود.

## ۶. امنیت

هویت: Argon2id/bcrypt، MFA، OTP محدود · نشست: کوکی امن، چرخش، ابطال · دسترسی: RBAC + مالکیت منبع + آزمون منفی · ورودی: schema validation، پارامتری‌سازی، رمزگذاری خروجی، ضد SSRF · CSRF: SameSite + بررسی Origin · فایل: نوع واقعی، نام تصادفی، عدم اجرا · اسرار: خارج از مخزن، چرخش · لاگ: Redaction PII + requestId · DB: حداقل دسترسی، پشتیبان رمزگذاری‌شده · وابستگی: قفل نسخه + اسکن + آینه · Audit: append-only، دسترسی محدود.

**مدل تهدید اولیه:** BOLA/IDOR، دستکاری قیمت کلاینت، بازپخش Callback، ارسال انبوه، نشت داده در Export، افزایش موجودی با فراخوانی مستقیم.

## ۷. زیرساخت Self-hosted

مؤلفه‌ها: Linux LTS، PostgreSQL، Reverse Proxy (TLS/HSTS/rate limit)، App، Worker، Redis، Object Storage، Backup Storage، Observability، Firewall/DNS.

محیط‌ها: Development (داده برچسب‌خورده) · Testing · Staging (بدون PII) · Production — اسرار و داده مجزا؛ هیچ محیطی به دیگری دسترسی ندارد.

پیکربندی: تنظیمات کسب‌وکار در DB با نسخه و تاریخ اعتبار؛ اسرار در سرویس مخفی؛ Feature Flag برای تغییر مخاطره‌آمیز (نرخ مالیات، روش ارسال جدید).

## ۸. CI/CD

Build قابل‌تکرار + قفل وابستگی → آزمون (unit/integration/migration) → بازبینی (lint، آسیب‌پذیری) → Migration افزودنی (Expand/Contract) → استقرار چند‌نمونه با Readiness → Smoke (ورود، محصول، سفارش آزمایشی، پنل، پرداخت Sandbox) → Rollback با برنامه → ثبت نسخه و Release Notes.

## ۹. پشتیبان و DR

پشتیبان روزانه کامل + WAL؛ فایل به مکان دوم؛ رمزگذاری با کلید جدا؛ چرخش روزانه/هفتگی/ماهانه؛ **آزمون Restore دوره‌ای روی محیط جدا**؛ RPO/RTO پس از آزمون تثبیت می‌شود؛ سناریوهای DR: از‌دست‌رفتن سرور، خرابی دیسک، حذف اشتباهی داده.

## ۱۰. مشاهده‌پذیری

API (نرخ خطا، p50/p95/p99) · DB (اتصال، Query کند، قفل) · صف (عمق، سن، DLQ) · Job (آخرین اجرای موفق) · یکپارچگی (نرخ خطای آداپتور، Circuit باز) · کسب‌وکار (سفارش مسدود، پرداخت Unknown، مغایرت باز) — هرکدام با هشدار.

## ۱۱. عملکرد

ممنوعیت N+1 · بارگذاری انتخابی ستون · صفحه‌بندی سروری/keyset · Cache فقط داده کم‌تغییر با باطل‌سازی صریح · گزارش پس‌زمینه · تبدیل تصویر در آپلود/لبه · محدودیت نرخ · آزمون بار با سناریوهای E1/E3/E15.

**هیچ عدد ظرفیتی در این سند ادعا نمی‌شود؛ پس از آزمون در Capacity Report ثبت می‌شود.**

## ۱۲. تست

Unit (قواعد دامنه) · Integration (DB + تراکنش + Outbox) · Contract (آداپتورها) · E2E (خرید، مرجوعی، بسته‌بندی) · Security (دسترسی منفی) · Migration (نسخه قبل→بعد) · Restore · Performance.

## ۱۳. ADRها

ADR-001 Monolith · 002 PostgreSQL+FTS · 003 دفتر گردش · 004 Outbox · 005 مدل پول · 006 زمان/تقویم · 007 احراز هویت کوکی · **008 صف** · **009 ارزش‌گذاری** · **010 نگهداشت داده** · 011 اتصال مالیاتی فاز ۲ · 012 لایه جست‌وجو. جزئیات: `Architecture-02/ADR/` و فهرست تصمیم‌ها در `Management-00/DECISION_LOG.md`.

## ۱۴. نگاشت به برش‌های اجرایی

| BR | مؤلفه‌های لازم |
|---|---|
| BR-1 | مخزن/CI، Migration، IAM، Audit، لاگ/Health، پشتیبان، Outbox |
| BR-2 | Catalog، Pricing نسخه‌دار، Ledger + تجمیع، رزرو، جست‌وجو، صفحات عمومی |
| BR-3 | Checkout، پرداخت + Idempotency، OMS، Snapshot |
| BR-4 | Fulfillment، اسکن، TMS، رهگیری، صف عملیاتی |
| BR-5 | RMA، استرداد، اسناد مالی اولیه، COGS |

## ۱۵. شکاف‌های باز

۱. سخت‌افزار/بودجه Production (Q-11 پذیرفته‌شده، اندازه واقعی نامشخص) ۲. روش ارزش‌گذاری نیازمند تأیید مالی ۳. الزام مالیاتی عملیاتی ۴. اعداد نگهداشت داده ۵. هیچ آزمون ظرفیتی انجام نشده.
