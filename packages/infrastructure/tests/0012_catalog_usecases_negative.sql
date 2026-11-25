-- =============================================================================
-- 0012_catalog_usecases_negative — BR-2 گام ۲
-- مالک انتظارها: docs/Business-01/BUSINESS_WORKFLOWS.md (WF-01)
--                docs/Engineering-04/TEST_STRATEGY.md §4.1/§6
--
-- اجرا:
--   docker exec -i fco-postgres psql -U fco -d fco -v ON_ERROR_STOP=1 -f - \
--     < packages/infrastructure/tests/0012_catalog_usecases_negative.sql
--
-- پوشش: مجوز use-case، اعتبارسنجی ورودی، slug/SKU/بارکد تکراری، کنترل تعارض
--       نسخه، محصول آرشیوشده، Audit خودکار، رفع شکاف‌های ۰۰۱۱ (نسخه تنوع و
--       تجمیع، سازگاری جانشین قیمت، نوع attributes، SKU با حروف کوچک).
-- همه‌چیز در یک تراکنش است و با rollback پاک می‌شود.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

insert into iam.users (id, mobile, full_name, status, password_hash) values
  ('50000000-0000-0000-0000-000000000001', '09120000051', 'کارشناس کاتالوگ', 'active', 'fixture-hash-0051'),
  ('50000000-0000-0000-0000-000000000002', '09120000052', 'اپراتور بدون مجوز کاتالوگ', 'active', 'fixture-hash-0052');

insert into iam.user_roles (user_id, role_id)
select '50000000-0000-0000-0000-000000000001'::uuid, id from iam.roles where key = 'R-SALES';
insert into iam.user_roles (user_id, role_id)
select '50000000-0000-0000-0000-000000000002'::uuid, id from iam.roles where key = 'R-OP';

insert into cat.brands (id, slug, title) values
  ('b1000000-0000-0000-0000-000000000001', 'usecase-brand', 'برند use-case');
insert into cat.categories (id, slug, title) values
  ('c1000000-0000-0000-0000-000000000001', 'usecase-cat', 'دسته use-case');

-- --- ایجاد محصول: مجوز، اعتبارسنجی، Audit -----------------------------------
do $$
declare
  v_seller uuid := '50000000-0000-0000-0000-000000000001';
  v_op     uuid := '50000000-0000-0000-0000-000000000002';
  v_brand  uuid := 'b1000000-0000-0000-0000-000000000001';
  v_cat    uuid := 'c1000000-0000-0000-0000-000000000001';
  v_pid    uuid;
  v_status text;
  v_audit  integer;
begin
  v_pid := cat.product_create(v_seller, 'usecase-product', 'محصول گام دو',
                              'توضیح', v_brand, v_cat,
                              '{"season":"autumn"}'::jsonb, 'req-p1');

  select status into v_status from cat.products where id = v_pid;
  if v_status <> 'draft' then
    raise exception 'FAIL PRODUCT: وضعیت اولیه % است، انتظار draft', v_status;
  end if;

  select count(*) into v_audit from sys.audit_log
   where action = 'product.create' and entity_id = v_pid and actor_id = v_seller;
  if v_audit <> 1 then
    raise exception 'FAIL PRODUCT: Audit ایجاد محصول % رکورد داد', v_audit;
  end if;
  raise notice 'PASS PRODUCT | ایجاد draft با Audit و مجوز R-SALES';

  begin
    perform cat.product_create(v_op, 'usecase-denied', 'بدون مجوز');
    raise exception 'FAIL PRODUCT: اپراتور بدون مجوز محصول ساخت';
  exception when insufficient_privilege then
    raise notice 'PASS PRODUCT | بدون catalog.product.write → %', sqlerrm;
  end;

  begin
    perform cat.product_create(v_seller, 'Bad Slug', 'عنوان');
    raise exception 'FAIL PRODUCT: slug نامعتبر پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS PRODUCT | slug نامعتبر → %', sqlerrm;
  end;

  begin
    perform cat.product_create(v_seller, 'usecase-empty-title', '   ');
    raise exception 'FAIL PRODUCT: عنوان خالی پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS PRODUCT | عنوان خالی → %', sqlerrm;
  end;

  begin
    perform cat.product_create(v_seller, 'usecase-array-attrs', 'عنوان',
                              null, null, null, '[1,2]'::jsonb);
    raise exception 'FAIL PRODUCT: attributes آرایه‌ای پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS PRODUCT | attributes غیرشیء → %', sqlerrm;
  end;

  begin
    perform cat.product_create(v_seller, 'usecase-bad-brand', 'عنوان',
                              null, 'b1000000-0000-0000-0000-0000000000ff');
    raise exception 'FAIL PRODUCT: برند ناموجود پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS PRODUCT | برند ناموجود → %', sqlerrm;
  end;

  begin
    perform cat.product_create(v_seller, 'usecase-product', 'تکراری');
    raise exception 'FAIL PRODUCT: slug تکراری پذیرفته شد';
  exception when unique_violation then
    if sqlerrm not like 'FCO-1062%' then
      raise exception 'FAIL PRODUCT: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS PRODUCT | slug تکراری → %', sqlerrm;
  end;

  -- --- ویرایش با کنترل تعارض ------------------------------------------------
  begin
    perform cat.product_update(v_seller, v_pid, 'عنوان جدید', null,
                               v_brand, v_cat, '{}'::jsonb, 99, 'req-p2');
    raise exception 'FAIL UPDATE: نسخه نادرست پذیرفته شد';
  exception when sqlstate '40001' then
    raise notice 'PASS UPDATE | تعارض نسخه → %', sqlerrm;
  end;

  if cat.product_update(v_seller, v_pid, 'عنوان جدید', 'توضیح دوم',
                        v_brand, v_cat, '{}'::jsonb, 1, 'req-p3') <> 2 then
    raise exception 'FAIL UPDATE: نسخه پس از ویرایش ۲ نشد';
  end if;

  select count(*) into v_audit from sys.audit_log
   where action = 'product.update' and entity_id = v_pid;
  if v_audit <> 1 then
    raise exception 'FAIL UPDATE: Audit ویرایش % رکورد داد', v_audit;
  end if;
  raise notice 'PASS UPDATE | ویرایش با expected_version و Audit ثبت شد';

  update cat.products set status = 'archived' where id = v_pid;
  begin
    perform cat.product_update(v_seller, v_pid, 'عنوان سوم', null,
                               v_brand, v_cat, '{}'::jsonb, 2, 'req-p4');
    raise exception 'FAIL UPDATE: محصول آرشیوشده ویرایش شد';
  exception when sqlstate '22023' then
    raise notice 'PASS UPDATE | محصول آرشیوشده → %', sqlerrm;
  end;

  begin
    perform cat.product_update(v_seller, 'a1000000-0000-0000-0000-0000000000ff',
                               'عنوان', null, null, null, '{}'::jsonb, 1, null);
    raise exception 'FAIL UPDATE: محصول ناموجود پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS UPDATE | محصول ناموجود → %', sqlerrm;
  end;
end $$;

-- --- تنوع: ایجاد/ویرایش، یکتایی و SKU با حروف کوچک -------------------------
do $$
declare
  v_seller uuid := '50000000-0000-0000-0000-000000000001';
  v_op     uuid := '50000000-0000-0000-0000-000000000002';
  v_brand  uuid := 'b1000000-0000-0000-0000-000000000001';
  v_cat    uuid := 'c1000000-0000-0000-0000-000000000001';
  v_pid    uuid;
  v_arch   uuid;
  v_v1     uuid;
  v_v2     uuid;
  v_version integer;
begin
  v_pid := cat.product_create(v_seller, 'usecase-variant-host', 'میزبان تنوع',
                              null, v_brand, v_cat, '{}'::jsonb, 'req-v1');

  -- قید ۰۰۱۱ که در ۰۰۱۲ اصلاح شد: SKU با حروف کوچک باید پذیرفته شود
  v_v1 := cat.variant_create(v_seller, v_pid, 'm1-lower-01', '626100000001', 250, 'req-v2');
  select version into v_version from cat.variants where id = v_v1;
  if v_version <> 1 then
    raise exception 'FAIL VARIANT: نسخه اولیه % است', v_version;
  end if;
  raise notice 'PASS VARIANT | SKU با حروف کوچک و نسخه ۱ پذیرفته شد';

  begin
    perform cat.variant_create(v_seller, v_pid, 'm1-lower-01');
    raise exception 'FAIL VARIANT: SKU تکراری پذیرفته شد';
  exception when unique_violation then
    if sqlerrm not like 'FCO-1065%' then
      raise exception 'FAIL VARIANT: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS VARIANT | SKU تکراری → %', sqlerrm;
  end;

  begin
    perform cat.variant_create(v_op, v_pid, 'm1-denied');
    raise exception 'FAIL VARIANT: اپراتور بدون مجوز تنوع ساخت';
  exception when insufficient_privilege then
    raise notice 'PASS VARIANT | بدون catalog.variant.write → %', sqlerrm;
  end;

  v_arch := cat.product_create(v_seller, 'usecase-archived-host', 'محصول آرشیو');
  update cat.products set status = 'archived' where id = v_arch;
  begin
    perform cat.variant_create(v_seller, v_arch, 'm1-archived-sku');
    raise exception 'FAIL VARIANT: برای محصول آرشیوشده تنوع ساخته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS VARIANT | محصول آرشیوشده → %', sqlerrm;
  end;

  -- ویرایش تنوع: تعارض نسخه و یکتایی بارکد
  v_v2 := cat.variant_create(v_seller, v_pid, 'm1-lower-02', '626100000002', 300, 'req-v3');

  begin
    perform cat.variant_update(v_seller, v_v1, '626100000009', 250, true, 9, 'req-v4');
    raise exception 'FAIL VARIANT: نسخه نادرست تنوع پذیرفته شد';
  exception when sqlstate '40001' then
    raise notice 'PASS VARIANT | تعارض نسخه تنوع → %', sqlerrm;
  end;

  if cat.variant_update(v_seller, v_v1, '626100000009', 260, true, 1, 'req-v5') <> 2 then
    raise exception 'FAIL VARIANT: نسخه پس از ویرایش ۲ نشد';
  end if;
  raise notice 'PASS VARIANT | ویرایش تنوع با نسخه ۲ ثبت شد';

  begin
    perform cat.variant_update(v_seller, v_v2, '626100000009', 300, true, 1, 'req-v6');
    raise exception 'FAIL VARIANT: بارکد تکراری پذیرفته شد';
  exception when unique_violation then
    if sqlerrm not like 'FCO-1065%' then
      raise exception 'FAIL VARIANT: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS VARIANT | بارکد تکراری → %', sqlerrm;
  end;

  begin
    perform cat.variant_update(v_seller, 'e1000000-0000-0000-0000-0000000000ff',
                               null, null, true, 1, null);
    raise exception 'FAIL VARIANT: تنوع ناموجود پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS VARIANT | تنوع ناموجود → %', sqlerrm;
  end;
end $$;

-- --- شکاف ۲: نسخه تجمیع موجودی --------------------------------------------
do $$
declare
  v_brand uuid := 'b1000000-0000-0000-0000-000000000001';
  v_cat   uuid := 'c1000000-0000-0000-0000-000000000001';
  v_seller uuid := '50000000-0000-0000-0000-000000000001';
  v_pid   uuid;
  v_vid   uuid;
  v_wh    uuid;
  v_before timestamptz;
  v_version integer;
begin
  v_pid := cat.product_create(v_seller, 'usecase-balance-host', 'میزبان موجودی',
                              null, v_brand, v_cat, '{}'::jsonb, 'req-b1');
  v_vid := cat.variant_create(v_seller, v_pid, 'm1-balance-sku', null, null, 'req-b2');
  insert into inv.warehouses (id, code, title)
  values ('91000000-0000-0000-0000-000000000001', 'M1-BAL', 'انبار گام دو')
  returning id into v_wh;

  insert into inv.stock_balance (warehouse_id, variant_id, on_hand)
  values (v_wh, v_vid, 5);

  select version, updated_at into v_version, v_before
    from inv.stock_balance where warehouse_id = v_wh and variant_id = v_vid;
  update inv.stock_balance set on_hand = 7
   where warehouse_id = v_wh and variant_id = v_vid;
  select version into v_version
    from inv.stock_balance where warehouse_id = v_wh and variant_id = v_vid;

  if v_version <> 2 then
    raise exception 'FAIL BALANCE: نسخه پس از به‌روزرسانی % است، انتظار ۲', v_version;
  end if;
  raise notice 'PASS BALANCE | نسخه تجمیع با هر به‌روزرسانی افزایش یافت';
end $$;

-- --- شکاف ۳: سازگاری جانشین قیمت ------------------------------------------
do $$
declare
  v_brand uuid := 'b1000000-0000-0000-0000-000000000001';
  v_cat   uuid := 'c1000000-0000-0000-0000-000000000001';
  v_seller uuid := '50000000-0000-0000-0000-000000000001';
  v_pid   uuid;
  v_a     uuid;
  v_b     uuid;
  v_p1    uuid;
  v_p2    uuid;
  v_p3    uuid;
begin
  v_pid := cat.product_create(v_seller, 'usecase-price-host', 'میزبان قیمت',
                              null, v_brand, v_cat, '{}'::jsonb, 'req-pr1');
  v_a := cat.variant_create(v_seller, v_pid, 'm1-price-a', null, null, 'req-pr2');
  v_b := cat.variant_create(v_seller, v_pid, 'm1-price-b', null, null, 'req-pr3');

  insert into pricing.prices (variant_id, amount_rial, effective_from, effective_to)
  values (v_a, 1000000, '2026-01-01 00:00:00+00', '2026-03-01 00:00:00+00')
  returning id into v_p1;
  insert into pricing.prices (variant_id, amount_rial, effective_from)
  values (v_a, 1200000, '2026-03-01 00:00:00+00')
  returning id into v_p2;
  insert into pricing.prices (variant_id, amount_rial, effective_from)
  values (v_b, 900000, '2026-01-01 00:00:00+00')
  returning id into v_p3;

  begin
    update pricing.prices set superseded_by = v_p3 where id = v_p1;
    raise exception 'FAIL PRICE: جانشین از تنوع دیگر پذیرفته شد';
  exception when sqlstate '22023' then
    if sqlerrm not like 'FCO-1052%' then
      raise exception 'FAIL PRICE: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS PRICE | جانشین تنوع دیگر → %', sqlerrm;
  end;

  update pricing.prices set superseded_by = v_p2 where id = v_p1;
  raise notice 'PASS PRICE | جانشین همان تنوع و بازه بعدی پذیرفته شد';
end $$;

-- --- نقش اپ: فقط از مسیر use-case -----------------------------------------
set local role fco_app;

do $$
begin
  begin
    insert into cat.products (slug, title, status)
    values ('usecase-app-direct', 'نوشتن مستقیم', 'draft');
    raise exception 'FAIL APP-ROLE: درج مستقیم محصول مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS APP-ROLE | درج مستقیم محصول مسدود است';
  end;
end $$;

select cat.product_create('50000000-0000-0000-0000-000000000001'::uuid,
                          'usecase-via-app', 'ساخت از مسیر اپ')
       is not null as app_create_ok;

reset role;

-- --- شاهد نهایی ------------------------------------------------------------
do $$
declare v_count integer;
begin
  select count(*) into v_count from sys.audit_log
   where action in ('product.create', 'product.update', 'variant.create', 'variant.update');
  if v_count < 4 then
    raise exception 'FAIL EVIDENCE: فقط % Audit از use-caseها ثبت شد', v_count;
  end if;
  raise notice 'PASS EVIDENCE | % رکورد Audit از use-caseهای کاتالوگ ثبت شد', v_count;
end $$;

select 'ALL STEP-BR2-2 NEGATIVE CASES PASSED' as result;
rollback;
