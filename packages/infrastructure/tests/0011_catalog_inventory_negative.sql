-- =============================================================================
-- 0011_catalog_inventory_negative — BR-2 گام ۱
-- مالک انتظارها: docs/Engineering-04/TEST_STRATEGY.md §4.1
--   (T-INV-02 تغییرناپذیری دفتر؛ قیدهای یکتایی/بازه/موجودی)
--
-- اجرا:
--   docker exec -i fco-postgres psql -U fco -d fco -v ON_ERROR_STOP=1 -f - \
--     < packages/infrastructure/tests/0011_catalog_inventory_negative.sql
--
-- پوشش: یکتایی SKU/بارکد/slug، FK رسانه، عدم‌هم‌پوشانی و تغییرناپذیری قیمت،
--       قیدهای تجمیع موجودی، تغییرناپذیری دفتر گردش، رزرو فعال یکتا،
--       قیدهای لایه هزینه، و ممنوعیت نوشتن مستقیم برای نقش اپ.
-- همه‌چیز در یک تراکنش است و با rollback پاک می‌شود.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

insert into cat.brands (id, slug, title) values
  ('b0000000-0000-0000-0000-000000000001', 'm1-brand', 'برند آزمون');

insert into cat.categories (id, slug, title) values
  ('c0000000-0000-0000-0000-000000000001', 'm1-cat', 'دسته آزمون');

insert into cat.products (id, slug, title, brand_id, category_id, status, published_at) values
  ('a0000000-0000-0000-0000-000000000001', 'm1-product', 'محصول آزمون',
   'b0000000-0000-0000-0000-000000000001',
   'c0000000-0000-0000-0000-000000000001', 'published', now());

insert into cat.variants (id, product_id, sku, barcode) values
  ('e0000000-0000-0000-0000-000000000001', 'a0000000-0000-0000-0000-000000000001', 'M1-SKU-1', null),
  ('e0000000-0000-0000-0000-000000000002', 'a0000000-0000-0000-0000-000000000001', 'M1-SKU-2', '626000000001');

insert into inv.warehouses (id, code, title) values
  ('90000000-0000-0000-0000-000000000001', 'M1-WH', 'انبار آزمون'),
  ('90000000-0000-0000-0000-000000000002', 'M1-WH2', 'انبار دوم');

insert into inv.stock_balance (warehouse_id, variant_id, on_hand)
values ('90000000-0000-0000-0000-000000000001',
        'e0000000-0000-0000-0000-000000000001', 5);

-- --- یکتایی کاتالوگ ---------------------------------------------------------
do $$
begin
  begin
    insert into cat.variants (product_id, sku)
    values ('a0000000-0000-0000-0000-000000000001', 'M1-SKU-1');
    raise exception 'FAIL CATALOG: SKU تکراری پذیرفته شد';
  exception when unique_violation then
    raise notice 'PASS CATALOG | SKU تکراری رد شد';
  end;

  begin
    insert into cat.variants (product_id, sku, barcode) values
      ('a0000000-0000-0000-0000-000000000001', 'M1-SKU-3', '626000000001');
    raise exception 'FAIL CATALOG: بارکد تکراری پذیرفته شد';
  exception when unique_violation then
    raise notice 'PASS CATALOG | بارکد تکراری رد شد';
  end;

  begin
    insert into cat.products (slug, title, status)
    values ('m1-product', 'محصول تکراری', 'draft');
    raise exception 'FAIL CATALOG: slug تکراری پذیرفته شد';
  exception when unique_violation then
    raise notice 'PASS CATALOG | slug تکراری رد شد';
  end;

  begin
    insert into cat.products (slug, title, status, published_at)
    values ('m1-no-publish-date', 'بدون تاریخ انتشار', 'published', null);
    raise exception 'FAIL CATALOG: محصول published بدون published_at پذیرفته شد';
  exception when check_violation then
    raise notice 'PASS CATALOG | published بدون تاریخ انتشار رد شد';
  end;

  begin
    insert into cat.product_media (product_id, storage_key)
    values ('a0000000-0000-0000-0000-0000000000ff', 'm1/orphan.jpg');
    raise exception 'FAIL CATALOG: رسانه با محصول ناموجود پذیرفته شد';
  exception when foreign_key_violation then
    raise notice 'PASS CATALOG | رسانه بدون محصول رد شد';
  end;
end $$;

-- --- قیمت: بازه، تغییرناپذیری و supersede -----------------------------------
do $$
declare
  v_p1 uuid;
  v_p2 uuid;
begin
  insert into pricing.prices (variant_id, channel, amount_rial, effective_from, effective_to)
  values ('e0000000-0000-0000-0000-000000000001', 'web', 1000000,
          '2026-01-01 00:00:00+00', '2026-03-01 00:00:00+00')
  returning id into v_p1;

  begin
    insert into pricing.prices (variant_id, channel, amount_rial, effective_from)
    values ('e0000000-0000-0000-0000-000000000001', 'web', 1200000,
            '2026-02-01 00:00:00+00');
    raise exception 'FAIL PRICE: بازه هم‌پوشان پذیرفته شد';
  exception when exclusion_violation then
    raise notice 'PASS PRICE | بازه هم‌پوشان رد شد';
  end;

  insert into pricing.prices (variant_id, channel, amount_rial, effective_from)
  values ('e0000000-0000-0000-0000-000000000001', 'web', 1200000,
          '2026-03-01 00:00:00+00')
  returning id into v_p2;
  raise notice 'PASS PRICE | قیمت جدید پس از پایان بازه قبلی پذیرفته شد';

  begin
    update pricing.prices set amount_rial = 999 where id = v_p1;
    raise exception 'FAIL PRICE: ویرایش مبلغ قیمت مجاز بود';
  exception when insufficient_privilege then
    if sqlerrm not like 'FCO-1050%' then
      raise exception 'FAIL PRICE: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS PRICE | ویرایش قیمت → %', sqlerrm;
  end;

  update pricing.prices set superseded_by = v_p2 where id = v_p1;
  raise notice 'PASS PRICE | superseded_by یک‌بار ثبت شد';

  begin
    delete from pricing.prices where id = v_p1;
    raise exception 'FAIL PRICE: حذف قیمت مجاز بود';
  exception when insufficient_privilege then
    if sqlerrm not like 'FCO-1051%' then
      raise exception 'FAIL PRICE: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS PRICE | حذف قیمت → %', sqlerrm;
  end;

  begin
    insert into pricing.prices (variant_id, channel, amount_rial, effective_from)
    values ('e0000000-0000-0000-0000-000000000002', 'web', -1, now());
    raise exception 'FAIL PRICE: مبلغ منفی پذیرفته شد';
  exception when check_violation then
    raise notice 'PASS PRICE | مبلغ منفی رد شد';
  end;
end $$;

-- --- تجمیع موجودی -----------------------------------------------------------
do $$
begin
  begin
    update inv.stock_balance set on_hand = -1
     where warehouse_id = '90000000-0000-0000-0000-000000000001'
       and variant_id = 'e0000000-0000-0000-0000-000000000001';
    raise exception 'FAIL BALANCE: موجودی منفی پذیرفته شد';
  exception when check_violation then
    raise notice 'PASS BALANCE | موجودی منفی رد شد';
  end;

  begin
    update inv.stock_balance set reserved = 6
     where warehouse_id = '90000000-0000-0000-0000-000000000001'
       and variant_id = 'e0000000-0000-0000-0000-000000000001';
    raise exception 'FAIL BALANCE: reserved بیشتر از on_hand پذیرفته شد';
  exception when check_violation then
    raise notice 'PASS BALANCE | رزرو بیشتر از موجودی رد شد';
  end;

  update inv.stock_balance set reserved = 2, quarantined = 1
   where warehouse_id = '90000000-0000-0000-0000-000000000001'
     and variant_id = 'e0000000-0000-0000-0000-000000000001';
  raise notice 'PASS BALANCE | رزرو و قرنطینه در محدوده پذیرفته شد';
end $$;

-- --- دفتر گردش: تغییرناپذیری (T-INV-02) -----------------------------------
do $$
declare v_ledger uuid;
begin
  insert into inv.stock_ledger
    (warehouse_id, variant_id, quantity_delta, balance_after, reason_code,
     document_type, document_id)
  values ('90000000-0000-0000-0000-000000000001',
          'e0000000-0000-0000-0000-000000000001', 5, 5, 'grn',
          'grn', gen_random_uuid())
  returning id into v_ledger;

  begin
    update inv.stock_ledger set note = 'دستکاری' where id = v_ledger;
    raise exception 'FAIL LEDGER: UPDATE مستقیم مجاز بود';
  exception when insufficient_privilege then
    if sqlerrm not like 'FCO-DB-001%' then
      raise exception 'FAIL LEDGER: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS LEDGER | UPDATE مستقیم → %', sqlerrm;
  end;

  begin
    delete from inv.stock_ledger where id = v_ledger;
    raise exception 'FAIL LEDGER: DELETE مستقیم مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS LEDGER | DELETE مستقیم → %', sqlerrm;
  end;

  begin
    insert into inv.stock_ledger
      (warehouse_id, variant_id, quantity_delta, balance_after, reason_code,
       document_type, document_id)
    values ('90000000-0000-0000-0000-000000000001',
            'e0000000-0000-0000-0000-000000000001', 0, 5, 'adjust',
            'adjust', gen_random_uuid());
    raise exception 'FAIL LEDGER: گردش با delta=0 پذیرفته شد';
  exception when check_violation then
    raise notice 'PASS LEDGER | گردش با delta=0 رد شد';
  end;

  begin
    insert into inv.stock_ledger
      (warehouse_id, variant_id, quantity_delta, balance_after, reason_code,
       document_type, document_id)
    values ('90000000-0000-0000-0000-000000000001',
            'e0000000-0000-0000-0000-000000000001', -1, -1, 'adjust',
            'adjust', gen_random_uuid());
    raise exception 'FAIL LEDGER: موجودی منفی در گردش پذیرفته شد';
  exception when check_violation then
    raise notice 'PASS LEDGER | balance_after منفی رد شد';
  end;
end $$;

-- --- رزرو ------------------------------------------------------------------
do $$
declare v_r1 uuid;
begin
  insert into inv.reservations (warehouse_id, variant_id, order_line_id, quantity, expires_at)
  values ('90000000-0000-0000-0000-000000000001',
          'e0000000-0000-0000-0000-000000000001',
          'd0000000-0000-0000-0000-000000000001', 2, now() + interval '30 minutes')
  returning id into v_r1;

  begin
    insert into inv.reservations (warehouse_id, variant_id, order_line_id, quantity, expires_at)
    values ('90000000-0000-0000-0000-000000000001',
            'e0000000-0000-0000-0000-000000000001',
            'd0000000-0000-0000-0000-000000000001', 1, now() + interval '30 minutes');
    raise exception 'FAIL RESERVE: رزرو فعال تکراری پذیرفته شد';
  exception when unique_violation then
    raise notice 'PASS RESERVE | رزرو فعال تکراری رد شد';
  end;

  update inv.reservations
     set status = 'released', released_at = now()
   where id = v_r1;

  insert into inv.reservations (warehouse_id, variant_id, order_line_id, quantity, expires_at)
  values ('90000000-0000-0000-0000-000000000001',
          'e0000000-0000-0000-0000-000000000001',
          'd0000000-0000-0000-0000-000000000001', 1, now() + interval '30 minutes');
  raise notice 'PASS RESERVE | رزرو جدید پس از آزادسازی پذیرفته شد';

  begin
    insert into inv.reservations (warehouse_id, variant_id, order_line_id, quantity, expires_at)
    values ('90000000-0000-0000-0000-000000000002',
            'e0000000-0000-0000-0000-000000000001',
            'd0000000-0000-0000-0000-000000000002', 1, now() + interval '30 minutes');
    raise exception 'FAIL RESERVE: رزرو بدون ردیف موجودی پذیرفته شد';
  exception when foreign_key_violation then
    raise notice 'PASS RESERVE | رزرو بدون تجمیع موجودی رد شد';
  end;

  begin
    insert into inv.reservations (warehouse_id, variant_id, order_line_id, quantity, expires_at)
    values ('90000000-0000-0000-0000-000000000001',
            'e0000000-0000-0000-0000-000000000001',
            'd0000000-0000-0000-0000-000000000003', 0, now() + interval '30 minutes');
    raise exception 'FAIL RESERVE: رزرو با مقدار صفر پذیرفته شد';
  exception when check_violation then
    raise notice 'PASS RESERVE | رزرو با مقدار صفر رد شد';
  end;
end $$;

-- --- لایه هزینه FIFO -------------------------------------------------------
do $$
declare v_layer uuid;
begin
  insert into inv.cost_layers
    (warehouse_id, variant_id, qty_received, qty_remaining, unit_cost_rial)
  values ('90000000-0000-0000-0000-000000000001',
          'e0000000-0000-0000-0000-000000000001', 10, 10, 500000)
  returning id into v_layer;

  begin
    insert into inv.cost_layers
      (warehouse_id, variant_id, qty_received, qty_remaining, unit_cost_rial)
    values ('90000000-0000-0000-0000-000000000001',
            'e0000000-0000-0000-0000-000000000001', 10, 11, 500000);
    raise exception 'FAIL COST: باقی‌مانده بیشتر از دریافتی پذیرفته شد';
  exception when check_violation then
    raise notice 'PASS COST | باقی‌مانده بیشتر از دریافتی رد شد';
  end;

  begin
    insert into inv.cost_layers
      (warehouse_id, variant_id, qty_received, qty_remaining, unit_cost_rial)
    values ('90000000-0000-0000-0000-000000000001',
            'e0000000-0000-0000-0000-000000000001', 1, 1, -1);
    raise exception 'FAIL COST: بهای منفی پذیرفته شد';
  exception when check_violation then
    raise notice 'PASS COST | بهای منفی رد شد';
  end;

  begin
    insert into inv.cost_layer_consumption (layer_id, order_line_id, qty, unit_cost_rial)
    values (v_layer, 'd0000000-0000-0000-0000-000000000001', 0, 500000);
    raise exception 'FAIL COST: مصرف با مقدار صفر پذیرفته شد';
  exception when check_violation then
    raise notice 'PASS COST | مصرف با مقدار صفر رد شد';
  end;
end $$;

-- --- نقش اپ: خواندن مجاز، نوشتن مستقیم ممنوع -------------------------------
set local role fco_app;

do $$
declare v_count integer;
begin
  select count(*) into v_count from cat.products;
  if v_count < 1 then
    raise exception 'FAIL APP-ROLE: کاتالوگ برای اپ خواندنی نیست';
  end if;

  select count(*) into v_count from inv.stock_ledger;
  if v_count < 1 then
    raise exception 'FAIL APP-ROLE: دفتر گردش برای اپ خواندنی نیست';
  end if;
  raise notice 'PASS APP-ROLE | کاتالوگ و دفتر گردش خواندنی‌اند';

  begin
    insert into inv.stock_ledger
      (warehouse_id, variant_id, quantity_delta, balance_after, reason_code,
       document_type, document_id)
    values ('90000000-0000-0000-0000-000000000001',
            'e0000000-0000-0000-0000-000000000001', 1, 6, 'adjust',
            'adjust', gen_random_uuid());
    raise exception 'FAIL APP-ROLE: درج مستقیم در دفتر گردش مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS APP-ROLE | درج مستقیم در دفتر گردش → %', sqlerrm;
  end;

  begin
    insert into cat.products (slug, title, status)
    values ('m1-app-write', 'نوشتن اپ', 'draft');
    raise exception 'FAIL APP-ROLE: درج مستقیم محصول مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS APP-ROLE | درج مستقیم محصول رد شد (مسیر use-case گام ۲)';
  end;
end $$;

reset role;

select 'ALL STEP-BR2-1 NEGATIVE CASES PASSED' as result;
rollback;
