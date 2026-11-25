# طراحی پایگاه داده (Database Design)

> **وضعیت:** تأییدشده (G0) · **نسخه:** v1.1 · **تاریخ:** ۱۴۰۵/۰۹/۰۳
> **مرجع بالادست:** `Architecture-02/SYSTEM_ARCHITECTURE.md §3` · **تصمیم‌ها:** ADR-002، ADR-003، ADR-005، ADR-006، ADR-008، ADR-009، ADR-010، Q-02
> **دامنه:** PostgreSQL 16 · یک دیتابیس، چند schema منطقی · **هیچ کد محصولی هنوز نوشته نشده؛ این سند طرح است، نه گزارش پیاده‌سازی.**
> **مالک اسکیما، قید، ایندکس، Migration و نگهداشت داده.** `SYSTEM_ARCHITECTURE §3` فقط اصل‌ها را می‌گوید.

---

## ۱. اصول حاکم

| # | اصل | پیاده‌سازی |
|---|---|---|
| ۱ | پول = عدد صحیح | `BIGINT` ریال؛ هیچ `float`/`numeric` برای مبلغ. واحد نمایش تومان با فیلد `currency` |
| ۲ | زمان = UTC | `TIMESTAMPTZ`؛ `timezone = 'UTC'` در سرور؛ `Asia/Tehran` فقط در لایه نمایش |
| ۳ | مقدار = عدد صحیح در واحد پایه | گرم، میلی‌متر، عدد — بدون اعشار شناور |
| ۴ | تغییرناپذیری دفترها | `inv_stock_ledger`، `fin_journal_line`، `audit_log`، `sys_outbox` فقط `INSERT` (REVOKE UPDATE/DELETE + تریگر محافظ) |
| ۵ | شناسه | `UUID` (v7 ترجیحی) برای کلید عمومی؛ `BIGSERIAL` فقط برای ترتیب داخلی؛ شماره انسانی جدا (`order_number`, `invoice_number`) |
| ۶ | حذف | موجودیت مرجع: `archived_at`؛ حذف واقعی فقط داده موقت طبق ADR-010 |
| ۷ | هم‌زمانی | `version INT` روی رکوردهای قابل‌ویرایش + `If-Match` در API (`409`) |
| ۸ | چند‌انباره از روز اول | هر موجودی/گردش/رزرو/رسید `warehouse_id` دارد (Q-02) |
| ۹ | هیچ لیست بدون `LIMIT` | صفحه‌بندی سرور؛ ایندکس برای مسیرهای اصلی |
| ۱۰ | هر تغییر مالی/انباری = سند | قید و تریگر؛ موجودی «ویرایش» نمی‌شود |

### ۱.۱ نام‌گذاری
`<schema>.<entity>` با snake_case جمع‌بسته‌نشده: `oms.orders`، `inv.stock_ledger`. ستون‌های استاندارد روی همه جداول دامنه:

```sql
id             uuid primary key default gen_random_uuid(),
created_at     timestamptz not null default now(),
updated_at     timestamptz,
created_by     uuid references iam.users(id),
updated_by     uuid references iam.users(id),
version        integer not null default 1
```

---

## ۲. Schemaها

| Schema | مسئولیت | جداول کلیدی |
|---|---|---|
| `iam` | هویت، نقش، نشست | `users`, `roles`, `permissions`, `role_permissions`, `user_roles`, `sessions`, `mfa_factors`, `otp_requests`, `password_resets` |
| `cat` | کاتالوگ | `products`, `variants`, `product_media`, `categories`, `brands`, `collections`, `attributes`, `size_scales` |
| `pricing` | قیمت و تخفیف | `prices`, `price_versions`, `promotions`, `coupons`, `coupon_redemptions`, `shipping_rates` |
| `inv` | موجودی | `warehouses`, `stock_ledger`, `stock_balance`, `reservations`, `stock_counts`, `stock_count_lines`, `grn`, `grn_lines`, `cost_layers`, `cost_layer_consumption` |
| `proc` | خرید | `suppliers`, `purchase_orders`, `po_lines`, `supplier_invoices`, `supplier_payments` |
| `oms` | سفارش | `carts`, `cart_items`, `orders`, `order_lines`, `order_snapshots`, `order_events`, `order_notes` |
| `pay` | پرداخت | `transactions`, `refunds`, `reconciliations`, `webhook_events` |
| `ful` | بسته‌بندی | `pick_lists`, `pick_lines`, `packages`, `package_items` |
| `tms` | حمل | `shipments`, `shipment_events`, `manifests`, `carrier_invoices` |
| `rma` | مرجوعی | `requests`, `request_items`, `inspections`, `resolutions` |
| `fin` | مالی | `accounts`, `journals`, `journal_lines`, `periods`, `tax_rules`, `invoices`, `event_mappings` |
| `crm` | مشتری | `customers`, `addresses`, `consents`, `tickets`, `ticket_messages` |
| `mkt` | بازاریابی | `campaigns`, `workflows`, `message_log` |
| `sys` | پلتفرم | `outbox`, `inbox_events`, `idempotency_keys`, `job_runs`, `settings`, `setting_versions`, `feature_flags`, `audit_log`, `files` |
| `an` | تحلیل | `daily_sales_fact`, `stock_snapshot_daily`، viewهای مادی (فاز ۳) |

**قاعده:** هیچ join مستقیم بین `fin` و `oms` در خواندن گزارش‌های سنگین؛ از `fin.event_mappings` و جدول‌های تجمیعی.

---

## ۳. جداول محوری (طرح ستون‌ها)

### ۳.۱ هویت
```sql
iam.users(
  id uuid pk, mobile varchar(11) unique, email citext unique,
  password_hash text,        -- Argon2id
  status text check (status in ('active','locked','disabled')),
  mfa_required boolean not null default false,
  must_change_password boolean not null default false,
  last_login_at timestamptz, failed_attempts int not null default 0,
  locked_until timestamptz, archived_at timestamptz, ...
)
iam.sessions(id uuid pk, user_id uuid not null, token_hash bytea unique,
  ip inet, user_agent text, created_at, last_seen_at, expires_at,
  revoked_at timestamptz, revoke_reason text)
iam.otp_requests(id, mobile, code_hash, purpose, attempts int, expires_at,
  consumed_at, request_ip inet)  -- ایندکس (mobile, created_at)
iam.mfa_factors(id, user_id, kind in ('totp','recovery_code'),
  secret_ciphertext bytea, label, confirmed_at, last_used_at, disabled_at)
  -- یک TOTP فعال در هر لحظه؛ راز رمزنگاری‌شده، نه خام
iam.sod_role_conflicts(rule_code, role_a, role_b)  -- ترکیب نقش ممنوع (SoD-7)
```
- `0002` (BR-1 گام ۵) این دو جدول و پرچم `roles.requires_mfa` را اضافه کرد؛ ورود بدون MFA تأییدشده برای نقش حساس در تابع `iam.start_session` مسدود است.
- تفکیک Maker/Checker در DB با `sys.assert_separation` و تریگر ترکیب نقش؛ جدول تأییدهای دامنه در BR-2.
- `iam.otp_requests` در هر لحظه فقط یک کد فعال برای هر (موبایل، هدف) دارد؛ TTL، سقف تلاش و نرخ از `setting_versions` می‌آید و کد خام فقط در `sys.otp_spool` توسعه (D-13، پیش‌فرض خاموش) دیده می‌شود.
- `token_hash` هرگز توکن خام نیست؛ نشست با هش جست‌وجو می‌شود.
- `failed_attempts`/`locked_until` برای قفل تدریجی (`FR-1-07`).

### ۳.۲ کاتالوگ
```sql
cat.products(id, slug unique, title, description, brand_id, category_id,
  status in ('draft','published','archived'), published_at, attributes jsonb)
cat.variants(id, product_id, sku varchar(32) unique not null,
  barcode varchar(32) unique, color_id, size_id, weight_g int,
  is_active boolean, archived_at)
cat.product_media(id, product_id, variant_id null, storage_key, alt_text,
  sort_order int, width int, height int)
```
- `sku` و `barcode` **یکتا در سطح کل** (`BRQ-01`، `FM-O-07`).
- `variant` تنها سطحی است که موجودی/قیمت روی آن است.

### ۳.۳ قیمت (نسخه‌دار، `ADR-005`/Q-04)
```sql
pricing.prices(id, variant_id, channel text not null default 'web',
  amount_rial bigint not null check (amount_rial >= 0),
  compare_at_rial bigint,
  effective_from timestamptz not null, effective_to timestamptz,
  created_by, created_at, superseded_by uuid)
-- قید: بازه‌های فعال یک variant+channel نباید هم‌پوشانی داشته باشند
EXCLUDE USING gist (variant_id WITH =, channel WITH =,
                    tstzrange(effective_from, coalesce(effective_to,'infinity')) WITH &&)
```
- قیمت **حذف/ویرایش نمی‌شود**؛ نسخه جدید + `superseded_by`.
- انتخاب قیمت مؤثر: بازه شامل `now()` با `ORDER BY effective_from DESC LIMIT 1`.

### ۳.۴ موجودی — دفتر + تجمیع (`ADR-003`)
```sql
inv.stock_ledger(
  id uuid pk, warehouse_id uuid not null, variant_id uuid not null,
  quantity_delta int not null check (quantity_delta <> 0),
  balance_after int not null,
  reason_code text not null,        -- 'grn','sale_ship','return_restock','adjust','reserve','release'
  document_type text not null, document_id uuid not null,
  actor_id uuid, note text, created_at timestamptz not null default now()
)
inv.stock_balance(
  warehouse_id uuid, variant_id uuid,
  on_hand int not null default 0 check (on_hand >= 0),
  reserved int not null default 0 check (reserved >= 0),
  quarantined int not null default 0 check (quarantined >= 0),
  version int not null default 1,
  primary key (warehouse_id, variant_id),
  check (reserved <= on_hand - quarantined)
)
inv.reservations(id, warehouse_id, variant_id, order_line_id, quantity int,
  status in ('active','committed','released','expired'),
  expires_at timestamptz not null, created_at,
  unique (order_line_id, variant_id) where status = 'active')
```

**قواعد سخت:**
1. هر درج در `stock_ledger` در **همان تراکنش** `stock_balance` را به‌روز می‌کند (تابع `inv.apply_movement(...)`).
2. `balance_after` باید برابر `on_hand` جدید باشد؛ تریگر بررسی می‌کند (`FM-O-02`).
3. `available = on_hand - reserved - quarantined` (محاسبه‌شده، ذخیره‌نشده تا اختلاف ممکن نباشد).
4. رزرو با `SELECT ... FOR UPDATE` روی `stock_balance` و بررسی `available >= qty` → تضمین oversell صفر (`BRQ-14`، `T-INV-01`).
5. `REVOKE UPDATE, DELETE ON inv.stock_ledger FROM app_user` + تریگر `raise exception` برای اطمینان دو‌لایه.

### ۳.۵ لایه هزینه (`ADR-009`)
```sql
inv.cost_layers(id, warehouse_id, variant_id, grn_line_id,
  qty_received int, qty_remaining int check (qty_remaining >= 0),
  unit_cost_rial bigint not null, received_at timestamptz not null)
inv.cost_layer_consumption(id, layer_id, order_line_id, qty int,
  unit_cost_rial bigint, consumed_at)
```
- مصرف FIFO: `SELECT ... WHERE variant_id=$1 AND qty_remaining>0 ORDER BY received_at, id FOR UPDATE` → کاهش `qty_remaining` و درج مصرف، در همان تراکنش ارسال.
- COGS هر قلم در `oms.order_lines.unit_cogs_rial` **Snapshot** می‌شود (`BRQ-33`، `FM-F-08`).

**پیاده‌سازی (۱۴۰۵/۰۹/۰۴):** `0011_catalog_inventory` سه schema `cat`/`pricing`/`inv` را می‌سازد: یکتایی SKU/بارکد/slug، بازه قیمت با Exclusion GiST و ممنوعیت ویرایش/حذف، `stock_balance` با قید `reserved <= on_hand - quarantined`، دفتر گردش تغییرناپذیر (تریگر `sys.reject_mutation` + نبود GRANT)، رزرو فعال یکتا و لایه هزینه FIFO. `variants.color_id/size_id`، `reservations.order_line_id` و `grn_line_id` تا Migration جدول‌های مربوط (BR-2 گام ۲ / BR-3 / BR-4) بدون FK می‌مانند. تابع `inv.apply_movement` و رزرو اتمیک در گام ۳ همین BR می‌آید.

**use-case کاتالوگ (۱۴۰۵/۰۹/۰۴):** `0012_catalog_usecases` چهار use-case امنیتی `cat.product_create`/`product_update` و `cat.variant_create`/`variant_update` را اضافه می‌کند (مجوز + Audit در همان تراکنش، کنترل تعارض با `expected_version`). همان Migration پنج شکاف ۰۰۱۱ را می‌بندد: نسخه و `updated_at` برای تنوع و `stock_balance`، سازگاری `superseded_by` با تنوع/کانال/بازه بعدی، قید شیء‌بودن `attributes`، و حذف قید اختراعی `sku = upper(sku)`.

### ۳.۶ سفارش
```sql
oms.orders(id, order_number text unique not null, customer_id null,
  guest_email citext, status text not null,           -- ماشین وضعیت §3.7
  warehouse_id uuid not null, currency char(3) default 'IRR',
  subtotal_rial bigint not null, discount_rial bigint not null default 0,
  shipping_rial bigint not null default 0, tax_rial bigint not null default 0,
  total_rial bigint not null,
  payment_status text not null default 'pending',
  placed_at timestamptz, cancelled_at, cancel_reason,
  shipping_address_snapshot jsonb not null,
  correlation_id uuid not null, version int not null default 1,
  check (total_rial = subtotal_rial - discount_rial + shipping_rial + tax_rial))
oms.order_lines(id, order_id, variant_id, sku_snapshot, title_snapshot,
  color_snapshot, size_snapshot, quantity int check (quantity > 0),
  unit_price_rial bigint not null, discount_rial bigint not null default 0,
  tax_rial bigint not null default 0, unit_cogs_rial bigint,
  price_version_id uuid, tax_rule_version_id uuid)
oms.order_events(id, order_id, from_status, to_status, actor_id,
  reason, metadata jsonb, created_at)
```

**قیدهای کلیدی:** `total` باید با جمع اقلام بخواند (قید سطح جدول یا تریگر)؛ هیچ ستون قیمتی پس از `placed_at` قابل تغییر نیست (تریگر `BEFORE UPDATE`).

### ۳.۷ ماشین وضعیت سفارش (تک‌منبع)

```
draft ─> awaiting_payment ─> paid ─> allocated ─> picking ─> packed
             │                 │           │                     │
             ├─> cancelled     ├─> cancelled                    ▼
             └─> expired       └─> refund_pending          shipped ─> delivered ─> completed
                                                                  │
                                         returned ←── return_requested
```
گذارهای مجاز در جدول `oms.status_transitions(from, to, permission)` نگه داشته می‌شود؛ گذار غیرمجاز `409`/`422` (`FR-7-01`).

### ۳.۸ پرداخت و Idempotency
```sql
pay.transactions(id, order_id, provider, provider_ref unique,
  amount_rial bigint not null, status in ('initiated','succeeded','failed','unknown','reconciled'),
  idempotency_key text, raw_request jsonb, raw_response jsonb,
  verified_at, created_at, unique (provider, provider_ref))
sys.idempotency_keys(key text pk, scope text not null, request_hash text not null,
  response_status int, response_body jsonb, created_at, expires_at)
```
- کلید یکتا در سطح `(scope, key)`؛ درخواست با همان کلید و همان `request_hash` → پاسخ ذخیره‌شده بازگردانده می‌شود (`FR-6-05`).
- `provider_ref` یکتا = ضد بازپخش Callback (`FM-S-02`).

### ۳.۹ مرجوعی و استرداد
```sql
rma.requests(id, order_id, status, reason_code, requested_by, created_at, sla_due_at)
rma.request_items(id, request_id, order_line_id, quantity, condition)
rma.inspections(id, request_item_id, result in ('sellable','quarantine','scrap'),
  inspector_id, notes, created_at)
rma.resolutions(id, request_id, type in ('refund','exchange','reject'),
  amount_rial bigint, refund_id uuid unique,      -- یکتایی = ضد استرداد دوباره
  approved_by uuid, created_at)
```
- `refund_id UNIQUE` + `status` گذار یک‌طرفه ⇒ استرداد تکراری ناممکن (`BRQ-28`، `T-RMA-02`).

### ۳.۱۰ مالی
```sql
fin.accounts(id, code unique, name, type, parent_id, is_active)
fin.journals(id, journal_number text unique, period_id, entry_date date,
  source_type text, source_id uuid, status in ('draft','posted','reversed'),
  created_by, posted_by, check (posted_by is null or posted_by <> created_by))
fin.journal_lines(id, journal_id, account_id, debit_rial bigint default 0,
  credit_rial bigint default 0, description,
  check (debit_rial >= 0 and credit_rial >= 0),
  check ((debit_rial = 0) <> (credit_rial = 0)))
fin.periods(id, year int, month int, status in ('open','closed'), closed_by, closed_at)
fin.tax_rules(id, code, rate_bp int not null,     -- basis points: 900 = 9%
  effective_from date not null, effective_to date, version int,
  config jsonb, created_by, created_at)
```
- **قید تراز:** تریگر `AFTER INSERT` روی `journal_lines` در پایان تراکنش بررسی می‌کند `SUM(debit)=SUM(credit)`؛ ناتراز ⇒ `raise exception` (`FM-F-05`).
- `posted` قابل ویرایش/حذف نیست؛ اصلاح = `reversed` + سند جدید (`BRQ-32`).
- سند در دوره `closed` ثبت نمی‌شود (`FM-H-05`).

### ۳.۱۱ پلتفرم
```sql
sys.outbox(id bigserial pk, aggregate_type, aggregate_id uuid, event_name text,
  payload jsonb not null, headers jsonb, occurred_at timestamptz not null default now(),
  available_at timestamptz not null default now(), attempts int default 0,
  processed_at timestamptz, dead_lettered_at timestamptz, last_error text)
-- ایندکس: (processed_at, available_at) WHERE processed_at IS NULL
sys.inbox_events(event_id text pk, consumer text, processed_at)   -- ایدم‌پوتنسی مصرف
sys.job_runs(id, job_name text, scheduled_for timestamptz, started_at, finished_at,
  status in ('running','succeeded','failed'), attempt int, error text,
  unique (job_name, scheduled_for))                                -- ضد اجرای دوبار
sys.settings(key text, value jsonb, description)
sys.setting_versions(id, key, value jsonb, effective_from timestamptz,
  changed_by, reason, created_at)                                  -- نسخه‌دار (اصل ۳)
sys.audit_log(id bigserial, actor_id uuid, actor_ip inet, action text,
  entity_type text, entity_id uuid, before jsonb, after jsonb, reason text,
  request_id text, permission text, created_at timestamptz default now())
```

**مسیرهای مجاز (BR-1 گام ۷):** نوشتن Audit فقط با `sys.audit_write` (actor معتبر، request_id اجباری، حداقل یکی از before/after) و جست‌وجو با `sys.audit_search` (مجوز `iam.audit.read`، سقف ۱۰۰ ردیف)؛ تغییر تنظیم فقط با `sys.setting_set` (مجوز `platform.setting.write`، دلیل و تاریخ اعتبار غیرگذشته، Audit هم‌تراکنش). `setting_versions` فقط‌افزودنی و ترتیبی است: نسخه جدید بازه قبلی را می‌بندد و تغییر مقدار/حذف نسخه با تریگر رد می‌شود.

**تحویل Outbox (BR-1 گام ۸):** `sys.outbox_claim` با `FOR UPDATE SKIP LOCKED` و lease نسخه‌دار (`outbox.lease_seconds`) تحویل می‌دهد و `attempts` را همان‌جا +۱ می‌کند؛ `sys.outbox_fail` تا `outbox.max_attempts` تلاش می‌دهد و سپس `dead_lettered_at` را پر می‌کند؛ `sys.inbox_consume` با کلید `event_id` اثر تکراری را حذف می‌کند. رصد و نگهداشت (گام ۹) با `sys.health_report` (عمق/سن صف، DLQ، نشست، Job) و `sys.run_session_cleanup` (یک‌بار در هر `job_runs` slot) انجام می‌شود؛ حذف نشست فقط پس از `session.purge_grace_hours` و در دسته محدود. تلاش دوباره همان slot تا سقف `job.max_attempts` (سپس `FCO-1042`)؛ اجرای `running` قدیمی‌تر از `job.stuck_after_minutes` در `jobs.stuck`/`jobs.stuck_runs` گزارش می‌شود و شکست Job با `outcome='failed'` ماندگار است.

**Outbox (ADR-008):** Worker با
```sql
UPDATE sys.outbox SET attempts = attempts + 1
WHERE id IN (SELECT id FROM sys.outbox
             WHERE processed_at IS NULL AND dead_lettered_at IS NULL
               AND available_at <= now()
             ORDER BY id LIMIT $1 FOR UPDATE SKIP LOCKED)
RETURNING *;
```
پس از `attempts >= max` ⇒ `dead_lettered_at` + هشدار (`FM-T-08`).

---

## ۴. ایندکس‌ها (فرضیه تا اندازه‌گیری)

| جدول | ایندکس | دلیل |
|---|---|---|
| `inv.stock_balance` | PK `(warehouse_id, variant_id)` | رزرو/تخصیص |
| `inv.stock_ledger` | `(variant_id, created_at DESC)`، `(document_type, document_id)` | کارت کالا و بازبینی سند |
| `oms.orders` | `(status, placed_at DESC)`، `(customer_id, placed_at DESC)`، `(order_number)` | صف‌ها و پروفایل |
| `oms.order_lines` | `(order_id)`، `(variant_id)` | جزئیات و گزارش |
| `pricing.prices` | GiST روی بازه + `(variant_id, channel, effective_from DESC)` | قیمت مؤثر |
| `sys.outbox` | partial `(available_at) WHERE processed_at IS NULL` | Worker |
| `sys.audit_log` | `(entity_type, entity_id, created_at DESC)`، `(actor_id, created_at DESC)` | حسابرسی |
| `cat.products` | GIN روی `to_tsvector('fco_fa', title || description)` | جست‌وجوی فارسی |
| `crm.tickets` | `(assignee_id, status, sla_due_at)` | صف پشتیبانی |

**قواعد:** هیچ ایندکس بدون کوئری متناظر · ایندکس روی ستون کم‌انتخاب ممنوع · قبل/بعد هر ایندکس جدید، `EXPLAIN (ANALYZE, BUFFERS)` ثبت شود.

---

## ۵. Migration

| قاعده | جزئیات |
|---|---|
| ابزار | فایل SQL نسخه‌دار در `packages/infrastructure/migrations` با نام `NNNN_slug.sql` + `NNNN_slug.down.sql`؛ اجرا با `scripts/db-migrate.sh` (D-12) |
| ثبت وضعیت | `sys.schema_migrations` (version، name، checksum، applied_at)؛ هر Migration در یک تراکنش (`--single-transaction`) |
| تغییر تاریخی ممنوع | اجرای فایلِ اعمال‌شده با چک‌سام متفاوت رد می‌شود؛ اصلاح = Migration جدید، نه ویرایش گذشته |
| دستورها | `up` · `down [n|all]` · `status` · `verify` (تشخیص drift) |
| سبک | **Expand → Migrate → Contract**؛ هر مرحله جدا و قابل‌اجرا روی نسخه قبل |
| ممنوع | `DROP COLUMN` در همان انتشاری که کد قدیمی حذف می‌شود؛ قفل طولانی؛ بازنویسی جدول بزرگ |
| الزام | هر Migration باید `up` **و** مسیر بازگشت/سازگاری داشته باشد؛ روی داده واقعی‌نما آزمون شود |
| شاهد | اجرای زنجیره از صفر + اجرای روی نسخه قبل + `T-MIG-01/02` |
| دسترسی | کاربر Migration ≠ کاربر اپ؛ اپ فقط DML روی schemaهای مجاز |

---

## ۶. نگهداشت و حجم (ADR-010)

| لایه | داده | سیاست |
|---|---|---|
| مالی بلندمدت | `fin.*`، `fin.invoices`، `pricing.price_versions`، `inv.cost_layers` | نگهداشت بلندمدت، حذف ممنوع |
| عملیاتی میان‌مدت | `oms.order_events`، `pay.webhook_events`، `sys.job_runs`، `tms.shipment_events` | آرشیو دوره‌ای به جدول/پارتیشن سرد |
| PII حداقلی | `crm.customers`، `crm.addresses`، `oms.guest_email` | بی‌هویت‌سازی پس از دوره تعیین‌شده با تأیید LEG-EXT |
| موقت | `sys.idempotency_keys`، `iam.otp_requests`، `iam.sessions` | TTL و پاک‌سازی دوره‌ای |

- پارتیشن‌بندی بر پایه زمان برای `sys.audit_log`، `inv.stock_ledger`، `pay.webhook_events` در صورت رشد (پس از اندازه‌گیری).
- **هیچ عدد مدتی در کد هارد‌کد نمی‌شود؛** در `sys.settings` نسخه‌دار.
- حذف/بی‌هویت‌سازی باید Audit داشته باشد و گزارش «تعداد رکورد تحت تأثیر» تولید کند.

---

## ۷. یکپارچگی: قیدهایی که «باگ» را در DB می‌کشند

| قید | جدول | جلوگیری از |
|---|---|---|
| `check (on_hand >= 0)` | `inv.stock_balance` | موجودی منفی |
| `check (reserved <= on_hand - quarantined)` | `inv.stock_balance` | oversell |
| `unique (sku)`، `unique (barcode)` | `cat.variants` | FM-O-07 |
| `unique (order_line_id, variant_id) WHERE status='active'` | `inv.reservations` | رزرو تکراری |
| `check (SUM(debit)=SUM(credit))` تریگر | `fin.journal_lines` | سند ناتراز |
| `unique (refund_id)` | `rma.resolutions` | استرداد دوباره |
| `created_by <> approved_by` | پرداخت/تأییدها | نقض SoD |
| `unique (job_name, scheduled_for)` | `sys.job_runs` | اجرای دوبار (FM-T-02) |
| `unique (provider, provider_ref)` | `pay.transactions` | بازپخش Callback |
| `EXCLUDE` بازه قیمت | `pricing.prices` | دو قیمت فعال هم‌زمان |

---

## ۸. شکاف‌ها و تصمیم‌های باقی‌مانده

1. **UUIDv7:** پشتیبانی بومی PostgreSQL 16 ندارد؛ تصمیم: تولید در Application یا افزونه؟ (باز، اثر: ترتیب درج و ایندکس)
2. **پارتیشن‌بندی:** آستانه تعداد ردیف برای شروع پارتیشن‌بندی اندازه‌گیری نشده.
3. **محدوده `an`:** طرح جدول‌های تحلیلی نهایی نیست؛ در فاز ۳ با `FR-14-01` تثبیت می‌شود.
4. **مشخصات فنی روش تعویض مابه‌التفاوت** (دو سند یا یک سند) نیازمند تأیید ACC-EXT.
5. **زمان‌بندی بی‌هویت‌سازی PII** منتظر تأیید LEG-EXT (ADR-010).
