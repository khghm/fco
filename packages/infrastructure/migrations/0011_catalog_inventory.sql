-- =============================================================================
-- 0011_catalog_inventory — BR-2 گام ۱: کاتالوگ، قیمت، موجودی و لایه هزینه
-- مالک طرح: docs/Architecture-02/DATABASE_DESIGN.md §1.1، §3.2، §3.3، §3.4، §3.5
--           docs/Architecture-02/ADR/ADR-003 (دفتر + تجمیع)، ADR-005/ADR-009
--           docs/Engineering-04/TEST_STRATEGY.md §4.1 (T-INV-02 تا حد امکان)
--
-- محدوده این Migration:
--   * schemaهای `cat`، `pricing`، `inv`
--   * کاتالوگ: brand/category/product/variant/media با یکتایی SKU و بارکد
--   * قیمت نسخه‌دار با قید عدم‌هم‌پوشانی بازه (GiST Exclusion) و ممنوعیت ویرایش/حذف
--   * موجودی: انبار، تجمیع، دفتر گردش تغییرناپذیر، رزرو، لایه هزینه FIFO
--   * تنظیم نسخه‌دار TTL رزرو (هیچ عددی در کد هارد‌کد نمی‌شود)
--
-- خارج از این Migration (عمداً، گام‌های بعدی BR-2):
--   * `inv.apply_movement`، رزرو/آزادسازی اتمیک و Job انقضا → گام ۳
--   * use-case/Repository و صفحات محصول → گام ۲ و ۴
--   * جست‌وجوی فارسی GIN تا ساخت پیکربندی `fco_fa` → گام ۴
--   * `oms.order_lines` هنوز وجود ندارد؛ `reservations.order_line_id` و
--     `cost_layer_consumption.order_line_id` یوآی‌دی بدون FK می‌مانند تا BR-3
--   * `cat.attributes`/`cat.size_scales`: `variants.color_id/size_id` فعلاً
--     بدون FK و با یادداشت می‌مانند
-- =============================================================================

-- Exclusion روی برابری uuid/text به btree_gist نیاز دارد
create extension if not exists btree_gist;

create schema if not exists cat;
create schema if not exists pricing;
create schema if not exists inv;

comment on schema cat is 'کاتالوگ: محصول، تنوع، رسانه (DATABASE_DESIGN §3.2)';
comment on schema pricing is 'قیمت نسخه‌دار و مؤثر بر بازه (DATABASE_DESIGN §3.3)';
comment on schema inv is 'انبار، دفتر گردش، تجمیع، رزرو و لایه هزینه (DATABASE_DESIGN §3.4/§3.5)';

insert into sys.settings (key, value, description) values
  ('inv.reservation_ttl_minutes', '30'::jsonb, 'عمر رزرو موجودی پیش از آزادسازی توسط Job')
on conflict (key) do nothing;

insert into sys.setting_versions (key, value, effective_from, reason)
select v.key, v.value, v.effective_from, v.reason
from (values
  ('inv.reservation_ttl_minutes', '30'::jsonb,
   '2026-01-01 00:00:00+00'::timestamptz, 'مقدار اولیه BR-2')
) as v(key, value, effective_from, reason)
where not exists (select 1 from sys.setting_versions s where s.key = v.key);

-- -----------------------------------------------------------------------------
-- cat — کاتالوگ
-- -----------------------------------------------------------------------------
create table cat.brands (
  id         uuid primary key default gen_random_uuid(),
  slug       text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  title      text not null check (btrim(title) <> ''),
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
create trigger brands_touch_updated_at before update on cat.brands
  for each row execute function sys.touch_updated_at();

create table cat.categories (
  id         uuid primary key default gen_random_uuid(),
  slug       text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  title      text not null check (btrim(title) <> ''),
  parent_id  uuid references cat.categories (id) on delete restrict,
  sort_order integer not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz,
  constraint categories_not_own_parent check (parent_id is null or parent_id <> id)
);
create index categories_parent_idx on cat.categories (parent_id);
create trigger categories_touch_updated_at before update on cat.categories
  for each row execute function sys.touch_updated_at();

create table cat.products (
  id           uuid primary key default gen_random_uuid(),
  slug         text not null unique check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  title        text not null check (btrim(title) <> ''),
  description  text,
  brand_id     uuid references cat.brands (id) on delete restrict,
  category_id  uuid references cat.categories (id) on delete restrict,
  status       text not null default 'draft'
                 check (status in ('draft', 'published', 'archived')),
  published_at timestamptz,
  attributes   jsonb not null default '{}'::jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz,
  created_by   uuid references iam.users (id),
  updated_by   uuid references iam.users (id),
  version      integer not null default 1 check (version >= 1),
  constraint products_published_at_required
    check (status <> 'published' or published_at is not null)
);
create index products_status_idx on cat.products (status) where status <> 'archived';
create index products_category_idx on cat.products (category_id);
create trigger products_touch_updated_at before update on cat.products
  for each row execute function sys.touch_updated_at();

comment on table cat.products is
  'محصول؛ تنها سطح تنوع (variant) موجودی و قیمت دارد (§3.2)';

create table cat.variants (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid not null references cat.products (id) on delete restrict,
  sku         varchar(32) not null unique check (sku = upper(sku) and btrim(sku) <> ''),
  barcode     varchar(32) unique check (barcode is null or btrim(barcode) <> ''),
  color_id    uuid,        -- FK پس از ساخت cat.attributes در گام ۲
  size_id     uuid,        -- FK پس از ساخت cat.size_scales در گام ۲
  weight_g    integer check (weight_g is null or weight_g > 0),
  is_active   boolean not null default true,
  archived_at timestamptz,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz
);
create index variants_product_idx on cat.variants (product_id);
create trigger variants_touch_updated_at before update on cat.variants
  for each row execute function sys.touch_updated_at();

comment on column cat.variants.color_id is
  'بدون FK تا Migration جدول رنگ/مشخصه در BR-2 گام ۲';
comment on column cat.variants.size_id is
  'بدون FK تا Migration جدول سایز در BR-2 گام ۲';

create table cat.product_media (
  id          uuid primary key default gen_random_uuid(),
  product_id  uuid not null references cat.products (id) on delete cascade,
  variant_id  uuid references cat.variants (id) on delete cascade,
  storage_key text not null unique check (btrim(storage_key) <> ''),
  alt_text    text,
  sort_order  integer not null default 0,
  width       integer check (width is null or width > 0),
  height      integer check (height is null or height > 0),
  created_at  timestamptz not null default now()
);
create index product_media_product_idx on cat.product_media (product_id, sort_order);

-- -----------------------------------------------------------------------------
-- pricing — قیمت نسخه‌دار (ADR-005/Q-04)
-- -----------------------------------------------------------------------------
create table pricing.prices (
  id              uuid primary key default gen_random_uuid(),
  variant_id      uuid not null references cat.variants (id) on delete restrict,
  channel         text not null default 'web' check (btrim(channel) <> ''),
  amount_rial     bigint not null check (amount_rial >= 0),
  compare_at_rial bigint check (compare_at_rial is null or compare_at_rial >= 0),
  effective_from  timestamptz not null default now(),
  effective_to    timestamptz,
  created_by      uuid references iam.users (id),
  created_at      timestamptz not null default now(),
  superseded_by   uuid references pricing.prices (id),
  constraint prices_range_valid
    check (effective_to is null or effective_to > effective_from),
  constraint prices_no_self_supersede check (superseded_by is null or superseded_by <> id),
  constraint prices_no_overlap exclude using gist (
    variant_id with =,
    channel with =,
    tstzrange(effective_from, coalesce(effective_to, 'infinity'::timestamptz)) with &&
  )
);

create index prices_effective_idx
  on pricing.prices (variant_id, channel, effective_from desc);

comment on table pricing.prices is
  'قیمت حذف/ویرایش نمی‌شود؛ نسخه جدید + superseded_by (§3.3)';

create function pricing.prices_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'DELETE' then
    raise exception 'FCO-1051: قیمت حذف نمی‌شود؛ نسخه جدید بسازید (id=%)', old.id
      using errcode = 'insufficient_privilege';
  end if;

  -- تنها تغییر مجاز: بستن بازه باز و ثبت جانشین (هر کدام فقط یک‌بار)
  if new.variant_id      is distinct from old.variant_id
     or new.channel        is distinct from old.channel
     or new.amount_rial    is distinct from old.amount_rial
     or new.compare_at_rial is distinct from old.compare_at_rial
     or new.effective_from is distinct from old.effective_from
     or new.created_by     is distinct from old.created_by
     or new.created_at     is distinct from old.created_at
     or (old.effective_to is not null and new.effective_to is distinct from old.effective_to)
     or (old.superseded_by is not null and new.superseded_by is distinct from old.superseded_by) then
    raise exception 'FCO-1050: قیمت ویرایش نمی‌شود؛ فقط بستن بازه و supersede مجاز است (id=%)', old.id
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end $$;

create trigger prices_guard
  before update or delete on pricing.prices
  for each row execute function pricing.prices_guard();

comment on function pricing.prices_guard() is
  'قیمت تغییرناپذیر است؛ فقط effective_to (بستن بازه) و superseded_by یک‌بار قابل تنظیم‌اند';

-- -----------------------------------------------------------------------------
-- inv — انبار، تجمیع، دفتر گردش، رزرو (ADR-003)
-- -----------------------------------------------------------------------------
create table inv.warehouses (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique check (code ~ '^[A-Z0-9][A-Z0-9_-]{1,15}$'),
  title      text not null check (btrim(title) <> ''),
  address    jsonb not null default '{}'::jsonb,
  is_active  boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz
);
create trigger warehouses_touch_updated_at before update on inv.warehouses
  for each row execute function sys.touch_updated_at();

create table inv.stock_balance (
  warehouse_id uuid not null references inv.warehouses (id) on delete restrict,
  variant_id   uuid not null references cat.variants (id) on delete restrict,
  on_hand      integer not null default 0 check (on_hand >= 0),
  reserved     integer not null default 0 check (reserved >= 0),
  quarantined  integer not null default 0 check (quarantined >= 0),
  version      integer not null default 1 check (version >= 1),
  updated_at   timestamptz not null default now(),
  primary key (warehouse_id, variant_id),
  -- available = on_hand - reserved - quarantined هرگز منفی نمی‌شود (oversell)
  constraint stock_balance_available_nonnegative
    check (reserved <= on_hand - quarantined)
);

comment on table inv.stock_balance is
  'تجمیع موجودی؛ available محاسبه‌شده است و ذخیره نمی‌شود (§3.4)';

create table inv.stock_ledger (
  id             uuid primary key default gen_random_uuid(),
  warehouse_id   uuid not null references inv.warehouses (id) on delete restrict,
  variant_id     uuid not null references cat.variants (id) on delete restrict,
  quantity_delta integer not null check (quantity_delta <> 0),
  balance_after  integer not null check (balance_after >= 0),
  reason_code    text not null
                   check (reason_code in ('grn', 'sale_ship', 'return_restock',
                                          'adjust', 'reserve', 'release')),
  document_type  text not null check (btrim(document_type) <> ''),
  document_id    uuid not null,
  actor_id       uuid references iam.users (id),
  note           text,
  created_at     timestamptz not null default now()
);
create index stock_ledger_variant_idx on inv.stock_ledger (variant_id, created_at desc);
create index stock_ledger_document_idx on inv.stock_ledger (document_type, document_id);

-- تغییرناپذیری دو‌لایه: نبود GRANT برای اپ + تریگر برای هر نویسنده دیگر
create trigger stock_ledger_immutable
  before update or delete on inv.stock_ledger
  for each row execute function sys.reject_mutation();

comment on table inv.stock_ledger is
  'دفتر گردش فقط‌افزودنی؛ UPDATE/DELETE حتی برای مالک هم ممنوع است (§3.4، T-INV-02)';

create table inv.reservations (
  id            uuid primary key default gen_random_uuid(),
  warehouse_id  uuid not null,
  variant_id    uuid not null,
  order_line_id uuid not null,     -- FK به oms.order_lines در BR-3
  quantity      integer not null check (quantity > 0),
  status        text not null default 'active'
                  check (status in ('active', 'committed', 'released', 'expired')),
  expires_at    timestamptz not null,
  created_at    timestamptz not null default now(),
  released_at   timestamptz,
  foreign key (warehouse_id, variant_id)
    references inv.stock_balance (warehouse_id, variant_id) on delete restrict,
  constraint reservations_expiry_after_creation check (expires_at > created_at)
);

create unique index reservations_one_active
  on inv.reservations (order_line_id, variant_id) where status = 'active';
create index reservations_stock_idx
  on inv.reservations (warehouse_id, variant_id, status);
create index reservations_expiry_idx
  on inv.reservations (expires_at) where status = 'active';

comment on column inv.reservations.order_line_id is
  'بدون FK تا ساخت oms.order_lines در BR-3؛ یکتایی رزرو فعال حفظ می‌شود';

-- -----------------------------------------------------------------------------
-- inv — لایه هزینه FIFO (ADR-009)
-- -----------------------------------------------------------------------------
create table inv.cost_layers (
  id             uuid primary key default gen_random_uuid(),
  warehouse_id   uuid not null references inv.warehouses (id) on delete restrict,
  variant_id     uuid not null references cat.variants (id) on delete restrict,
  grn_line_id    uuid,            -- FK به proc.grn_lines در BR-4
  qty_received   integer not null check (qty_received > 0),
  qty_remaining  integer not null check (qty_remaining >= 0),
  unit_cost_rial bigint not null check (unit_cost_rial >= 0),
  received_at    timestamptz not null default now(),
  constraint cost_layers_remaining_within_received
    check (qty_remaining <= qty_received)
);
create index cost_layers_fifo_idx
  on inv.cost_layers (variant_id, received_at, id) where qty_remaining > 0;

create table inv.cost_layer_consumption (
  id            uuid primary key default gen_random_uuid(),
  layer_id      uuid not null references inv.cost_layers (id) on delete restrict,
  order_line_id uuid not null,     -- FK به oms.order_lines در BR-3
  qty           integer not null check (qty > 0),
  unit_cost_rial bigint not null check (unit_cost_rial >= 0),
  consumed_at   timestamptz not null default now()
);
create index cost_layer_consumption_layer_idx
  on inv.cost_layer_consumption (layer_id);
create index cost_layer_consumption_order_idx
  on inv.cost_layer_consumption (order_line_id);

comment on table inv.cost_layer_consumption is
  'مصرف FIFO؛ COGS در oms.order_lines Snapshot می‌شود (§3.5، BRQ-33)';

-- -----------------------------------------------------------------------------
-- دسترسی نقش اپ: خواندن کاتالوگ/موجودی، بدون نوشتن مستقیم دفتر
-- -----------------------------------------------------------------------------
grant usage on schema cat, pricing, inv to fco_app;

grant select on
  cat.brands, cat.categories, cat.products, cat.variants, cat.product_media,
  pricing.prices,
  inv.warehouses, inv.stock_balance, inv.stock_ledger,
  inv.reservations, inv.cost_layers, inv.cost_layer_consumption
to fco_app;

revoke all on
  cat.brands, cat.categories, cat.products, cat.variants, cat.product_media,
  pricing.prices,
  inv.warehouses, inv.stock_balance, inv.stock_ledger,
  inv.reservations, inv.cost_layers, inv.cost_layer_consumption
from public;

-- نوشتن فقط از use-case/توابع گام‌های بعدی BR-2؛ دفتر گردش هرگز UPDATE/DELETE
revoke insert, update, delete on inv.stock_ledger from fco_app;
revoke create on schema cat, pricing, inv from fco_app;
