-- =============================================================================
-- 0012_catalog_usecases — BR-2 گام ۲: use-case محصول/تنوع + رفع شکاف‌های ۰۰۱۱
-- مالک طرح: docs/Business-01/BUSINESS_WORKFLOWS.md (WF-01)
--           docs/Business-01/USER_ROLES_AND_PERMISSIONS.md §3.2، §4
--           docs/Architecture-02/DATABASE_DESIGN.md §1.1، §3.2، §3.3، §3.4
--
-- بازبینی گام ۱ (این Migration اصلاح می‌کند، ۰۰۱۱ را ویرایش نمی‌کند):
--   ۱) `cat.variants` نسخه نداشت؛ هر ویرایش بدون کنترل تعارض انجام می‌شد.
--   ۲) `inv.stock_balance.version` هرگز افزایش نمی‌یافت و `updated_at` تازه نمی‌شد.
--   ۳) `prices.superseded_by` می‌توانست به قیمت تنوع/کانال دیگر یا بازه قبلی
--      اشاره کند؛ هیچ قیدی نبود.
--   ۴) `cat.products.attributes` می‌توانست آرایه/عدد باشد، نه شیء.
--   ۵) قید `sku = upper(sku)` یک سخت‌گیری اختراعی بود (سند فقط یکتایی و
--      غیرخالی‌بودن می‌خواهد) و SKUهای واردشده با حروف کوچک را رد می‌کرد.
--
-- use-caseها (همه security definer، مجوز + Audit در همان تراکنش):
--   * `cat.product_create` / `cat.product_update` (به‌روزرسانی خوش‌بینانه)
--   * `cat.variant_create` / `cat.variant_update` (همان الگو)
-- انتشار محصول عمداً اینجا نیست: قواعد BRQ-02 (رسانه هر رنگ) و BRQ-04
-- (قیمت فعال) هنوز پیاده نشده‌اند و انتشار بدون آن‌ها یک قاعده تقلبی می‌ساخت.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- مجوزهای کاتالوگ (USER_ROLES §3.2 و ماتریس §4: R-SALES)
-- -----------------------------------------------------------------------------
insert into iam.permissions (key, domain, description) values
  ('catalog.product.write', 'catalog', 'ایجاد/ویرایش محصول'),
  ('catalog.variant.write', 'catalog', 'ایجاد/ویرایش تنوع، SKU و بارکد')
on conflict (key) do nothing;

insert into iam.role_permissions (role_id, permission_id)
select r.id, p.id
from (values
  ('R-SALES', 'catalog.product.write'),
  ('R-SALES', 'catalog.variant.write')
) as m(role_key, permission_key)
join iam.roles r on r.key = m.role_key
join iam.permissions p on p.key = m.permission_key
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- رفع شکاف ۱ و ۵: نسخه تنوع + قید واقعی SKU
-- -----------------------------------------------------------------------------
alter table cat.variants
  add column version integer not null default 1 check (version >= 1);

alter table cat.variants
  drop constraint variants_sku_check;

alter table cat.variants
  add constraint variants_sku_check check (btrim(sku) <> '');

comment on column cat.variants.version is
  'نسخه برای کنترل تعارض هم‌زمان؛ هر ویرایش +۱ می‌شود';

-- -----------------------------------------------------------------------------
-- رفع شکاف ۴: attributes باید شیء JSON باشد
-- -----------------------------------------------------------------------------
alter table cat.products
  add constraint products_attributes_object
  check (jsonb_typeof(attributes) = 'object');

-- -----------------------------------------------------------------------------
-- رفع شکاف ۲: نسخه و زمان تجمیع موجودی با هر به‌روزرسانی
-- -----------------------------------------------------------------------------
create function inv.stock_balance_bump_version() returns trigger
language plpgsql as $$
begin
  new.version := old.version + 1;
  new.updated_at := now();
  return new;
end $$;

create trigger stock_balance_bump_version
  before update on inv.stock_balance
  for each row execute function inv.stock_balance_bump_version();

comment on function inv.stock_balance_bump_version() is
  'هر UPDATE روی تجمیع، version را +۱ و updated_at را تازه می‌کند';

-- -----------------------------------------------------------------------------
-- رفع شکاف ۳: جانشین قیمت باید همان تنوع/کانال و بازه بعدی باشد
-- -----------------------------------------------------------------------------
create function pricing.prices_supersede_guard() returns trigger
language plpgsql as $$
declare
  v_variant uuid;
  v_channel text;
  v_from    timestamptz;
  v_super   uuid;
begin
  if new.superseded_by is null
     or new.superseded_by is not distinct from old.superseded_by then
    return new;
  end if;

  select variant_id, channel, effective_from, superseded_by
    into v_variant, v_channel, v_from, v_super
    from pricing.prices
   where id = new.superseded_by;

  if not found then
    raise exception 'FCO-1052: قیمت جانشین % وجود ندارد', new.superseded_by
      using errcode = '23503';
  end if;
  if v_variant <> old.variant_id or v_channel <> old.channel then
    raise exception 'FCO-1052: جانشین باید همان تنوع و کانال باشد'
      using errcode = '22023';
  end if;
  if v_from <= old.effective_from then
    raise exception 'FCO-1052: جانشین باید بازه بعدی باشد'
      using errcode = '22023';
  end if;
  if v_super is not null then
    raise exception 'FCO-1052: قیمت جانشین خودش supersede شده است'
      using errcode = '22023';
  end if;

  return new;
end $$;

create trigger prices_supersede_guard
  before update on pricing.prices
  for each row execute function pricing.prices_supersede_guard();

comment on function pricing.prices_supersede_guard() is
  'superseded_by فقط به قیمت بعدی همان تنوع/کانال اشاره می‌کند';

-- -----------------------------------------------------------------------------
-- use-case: ایجاد محصول
-- -----------------------------------------------------------------------------
create function cat.product_create(
  p_actor uuid,
  p_slug text,
  p_title text,
  p_description text default null,
  p_brand_id uuid default null,
  p_category_id uuid default null,
  p_attributes jsonb default '{}'::jsonb,
  p_request_id text default null
) returns uuid
language plpgsql security definer set search_path = cat, sys, iam, pg_catalog as $$
declare
  v_id         uuid;
  v_attributes jsonb := coalesce(p_attributes, '{}'::jsonb);
begin
  perform iam.authorize(p_actor, 'catalog.product.write');

  if p_slug is null or p_slug !~ '^[a-z0-9]+(-[a-z0-9]+)*$' or length(p_slug) > 120 then
    raise exception 'FCO-1060: slug باید با حروف کوچک/عدد و خط تیره و حداکثر ۱۲۰ کاراکتر باشد (%)',
      coalesce(p_slug, 'null') using errcode = '22023';
  end if;
  if p_title is null or btrim(p_title) = '' then
    raise exception 'FCO-1060: عنوان محصول الزامی است' using errcode = '22023';
  end if;
  if jsonb_typeof(v_attributes) <> 'object' then
    raise exception 'FCO-1060: attributes باید شیء JSON باشد' using errcode = '22023';
  end if;
  if p_brand_id is not null and not exists (select 1 from cat.brands b where b.id = p_brand_id) then
    raise exception 'FCO-1061: برند % وجود ندارد', p_brand_id using errcode = '22023';
  end if;
  if p_category_id is not null
     and not exists (select 1 from cat.categories c where c.id = p_category_id) then
    raise exception 'FCO-1061: دسته % وجود ندارد', p_category_id using errcode = '22023';
  end if;

  begin
    insert into cat.products
      (slug, title, description, brand_id, category_id, attributes, created_by, updated_by)
    values
      (p_slug, btrim(p_title), p_description, p_brand_id, p_category_id,
       v_attributes, p_actor, p_actor)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'FCO-1062: محصولی با slug % وجود دارد', p_slug using errcode = '23505';
  end;

  perform sys.audit_write(
    p_actor       => p_actor,
    p_action      => 'product.create',
    p_entity_type => 'products',
    p_entity_id   => v_id,
    p_after       => jsonb_build_object(
                       'slug', p_slug, 'title', btrim(p_title), 'status', 'draft',
                       'brand_id', p_brand_id, 'category_id', p_category_id,
                       'description', p_description, 'attributes', v_attributes),
    p_permission  => 'catalog.product.write',
    p_request_id  => coalesce(p_request_id, 'fn:product_create'));

  return v_id;
end $$;

comment on function cat.product_create(uuid, text, text, text, uuid, uuid, jsonb, text) is
  'ایجاد محصول draft؛ مجوز catalog.product.write و Audit در همان تراکنش';

-- -----------------------------------------------------------------------------
-- use-case: ویرایش محصول با کنترل تعارض
-- -----------------------------------------------------------------------------
create function cat.product_update(
  p_actor uuid,
  p_product_id uuid,
  p_title text,
  p_description text,
  p_brand_id uuid,
  p_category_id uuid,
  p_attributes jsonb,
  p_expected_version integer,
  p_request_id text default null
) returns integer
language plpgsql security definer set search_path = cat, sys, iam, pg_catalog as $$
declare
  v_version    integer;
  v_status     text;
  v_attributes jsonb := coalesce(p_attributes, '{}'::jsonb);
  v_before     jsonb;
begin
  perform iam.authorize(p_actor, 'catalog.product.write');

  select version, status into v_version, v_status
    from cat.products where id = p_product_id for update;

  if not found then
    raise exception 'FCO-1063: محصول % وجود ندارد', p_product_id using errcode = '22023';
  end if;
  if v_status = 'archived' then
    raise exception 'FCO-1066: محصول آرشیوشده قابل ویرایش نیست' using errcode = '22023';
  end if;
  if p_expected_version is null or p_expected_version <> v_version then
    raise exception 'FCO-1064: نسخه محصول تغییر کرده است (فعلی: %، ارسالی: %)',
      v_version, coalesce(p_expected_version, -1) using errcode = '40001';
  end if;
  if p_title is null or btrim(p_title) = '' then
    raise exception 'FCO-1060: عنوان محصول الزامی است' using errcode = '22023';
  end if;
  if jsonb_typeof(v_attributes) <> 'object' then
    raise exception 'FCO-1060: attributes باید شیء JSON باشد' using errcode = '22023';
  end if;
  if p_brand_id is not null and not exists (select 1 from cat.brands b where b.id = p_brand_id) then
    raise exception 'FCO-1061: برند % وجود ندارد', p_brand_id using errcode = '22023';
  end if;
  if p_category_id is not null
     and not exists (select 1 from cat.categories c where c.id = p_category_id) then
    raise exception 'FCO-1061: دسته % وجود ندارد', p_category_id using errcode = '22023';
  end if;

  select jsonb_build_object('title', title, 'description', description, 'status', status,
                            'version', version, 'brand_id', brand_id,
                            'category_id', category_id, 'attributes', attributes)
    into v_before
    from cat.products where id = p_product_id;

  update cat.products
     set title = btrim(p_title),
         description = p_description,
         brand_id = p_brand_id,
         category_id = p_category_id,
         attributes = v_attributes,
         updated_by = p_actor,
         version = version + 1
   where id = p_product_id
  returning version into v_version;

  perform sys.audit_write(
    p_actor       => p_actor,
    p_action      => 'product.update',
    p_entity_type => 'products',
    p_entity_id   => p_product_id,
    p_before      => v_before,
    p_after       => jsonb_build_object('title', btrim(p_title), 'description', p_description,
                                        'version', v_version, 'brand_id', p_brand_id,
                                        'category_id', p_category_id, 'attributes', v_attributes),
    p_permission  => 'catalog.product.write',
    p_request_id  => coalesce(p_request_id, 'fn:product_update'));

  return v_version;
end $$;

comment on function cat.product_update(uuid, uuid, text, text, uuid, uuid, jsonb, integer, text) is
  'ویرایش محصول با expected_version؛ تعارض → FCO-1064 (40001)';

-- -----------------------------------------------------------------------------
-- use-case: ایجاد تنوع
-- -----------------------------------------------------------------------------
create function cat.variant_create(
  p_actor uuid,
  p_product_id uuid,
  p_sku text,
  p_barcode text default null,
  p_weight_g integer default null,
  p_request_id text default null
) returns uuid
language plpgsql security definer set search_path = cat, sys, iam, pg_catalog as $$
declare
  v_id     uuid;
  v_status text;
begin
  perform iam.authorize(p_actor, 'catalog.variant.write');

  select status into v_status from cat.products where id = p_product_id;
  if not found then
    raise exception 'FCO-1067: محصول % برای تنوع وجود ندارد', p_product_id
      using errcode = '22023';
  end if;
  if v_status = 'archived' then
    raise exception 'FCO-1067: محصول آرشیوشده تنوع جدید نمی‌پذیرد' using errcode = '22023';
  end if;

  if p_sku is null or btrim(p_sku) = '' or length(btrim(p_sku)) > 32 then
    raise exception 'FCO-1060: SKU الزامی و حداکثر ۳۲ کاراکتر است'
      using errcode = '22023';
  end if;
  if p_barcode is not null and length(btrim(p_barcode)) > 32 then
    raise exception 'FCO-1060: بارکد حداکثر ۳۲ کاراکتر است' using errcode = '22023';
  end if;
  if p_weight_g is not null and p_weight_g <= 0 then
    raise exception 'FCO-1060: وزن باید مثبت باشد' using errcode = '22023';
  end if;

  begin
    insert into cat.variants (product_id, sku, barcode, weight_g)
    values (p_product_id, btrim(p_sku), nullif(btrim(p_barcode), ''), p_weight_g)
    returning id into v_id;
  exception when unique_violation then
    raise exception 'FCO-1065: SKU یا بارکد تکراری است (sku=%, barcode=%)',
      btrim(p_sku), coalesce(p_barcode, 'null') using errcode = '23505';
  end;

  perform sys.audit_write(
    p_actor       => p_actor,
    p_action      => 'variant.create',
    p_entity_type => 'variants',
    p_entity_id   => v_id,
    p_after       => jsonb_build_object('product_id', p_product_id,
                                        'sku', btrim(p_sku),
                                        'barcode', nullif(btrim(p_barcode), '')),
    p_permission  => 'catalog.variant.write',
    p_request_id  => coalesce(p_request_id, 'fn:variant_create'));

  return v_id;
end $$;

comment on function cat.variant_create(uuid, uuid, text, text, integer, text) is
  'ایجاد تنوع با SKU/بارکد یکتا؛ مجوز catalog.variant.write و Audit';

-- -----------------------------------------------------------------------------
-- use-case: ویرایش تنوع با کنترل تعارض
-- -----------------------------------------------------------------------------
create function cat.variant_update(
  p_actor uuid,
  p_variant_id uuid,
  p_barcode text,
  p_weight_g integer,
  p_is_active boolean,
  p_expected_version integer,
  p_request_id text default null
) returns integer
language plpgsql security definer set search_path = cat, sys, iam, pg_catalog as $$
declare
  v_version integer;
  v_before  jsonb;
begin
  perform iam.authorize(p_actor, 'catalog.variant.write');

  select version into v_version
    from cat.variants where id = p_variant_id for update;

  if not found then
    raise exception 'FCO-1068: تنوع % وجود ندارد', p_variant_id using errcode = '22023';
  end if;
  if p_expected_version is null or p_expected_version <> v_version then
    raise exception 'FCO-1069: نسخه تنوع تغییر کرده است (فعلی: %، ارسالی: %)',
      v_version, coalesce(p_expected_version, -1) using errcode = '40001';
  end if;
  if p_barcode is not null and length(btrim(p_barcode)) > 32 then
    raise exception 'FCO-1060: بارکد حداکثر ۳۲ کاراکتر است' using errcode = '22023';
  end if;
  if p_weight_g is not null and p_weight_g <= 0 then
    raise exception 'FCO-1060: وزن باید مثبت باشد' using errcode = '22023';
  end if;

  select jsonb_build_object('barcode', barcode, 'weight_g', weight_g,
                            'is_active', is_active, 'version', version)
    into v_before
    from cat.variants where id = p_variant_id;

  begin
    update cat.variants
       set barcode = nullif(btrim(p_barcode), ''),
           weight_g = p_weight_g,
           is_active = coalesce(p_is_active, is_active),
           version = version + 1
     where id = p_variant_id
    returning version into v_version;
  exception when unique_violation then
    raise exception 'FCO-1065: بارکد % برای تنوع دیگری ثبت شده است',
      coalesce(p_barcode, 'null') using errcode = '23505';
  end;

  perform sys.audit_write(
    p_actor       => p_actor,
    p_action      => 'variant.update',
    p_entity_type => 'variants',
    p_entity_id   => p_variant_id,
    p_before      => v_before,
    p_after       => jsonb_build_object('barcode', nullif(btrim(p_barcode), ''),
                                        'weight_g', p_weight_g,
                                        'is_active', coalesce(p_is_active, (v_before->>'is_active')::boolean),
                                        'version', v_version),
    p_permission  => 'catalog.variant.write',
    p_request_id  => coalesce(p_request_id, 'fn:variant_update'));

  return v_version;
end $$;

comment on function cat.variant_update(uuid, uuid, text, integer, boolean, integer, text) is
  'ویرایش تنوع با expected_version؛ تعارض → FCO-1069 (40001)';

-- -----------------------------------------------------------------------------
-- دسترسی: فقط از مسیر use-case
-- -----------------------------------------------------------------------------
grant execute on function
  cat.product_create(uuid, text, text, text, uuid, uuid, jsonb, text),
  cat.product_update(uuid, uuid, text, text, uuid, uuid, jsonb, integer, text),
  cat.variant_create(uuid, uuid, text, text, integer, text),
  cat.variant_update(uuid, uuid, text, integer, boolean, integer, text)
to fco_app;
