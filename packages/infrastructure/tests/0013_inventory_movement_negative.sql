-- =============================================================================
-- 0013_inventory_movement_negative — BR-2 گام ۳
-- مالک انتظارها: docs/Engineering-04/TEST_STRATEGY.md §4.1
--   (T-INV-02/03/04؛ پایه T-INV-01 در scripts/inv-concurrency-test.sh)
--
-- اجرا:
--   docker exec -i fco-postgres psql -U fco -d fco -v ON_ERROR_STOP=1 -f - \
--     < packages/infrastructure/tests/0013_inventory_movement_negative.sql
--
-- پوشش: مجوز بر پایه reason_code، رد delta صفر، موجودی منفی و موجودی رزروشده،
--       رزرو اتمیک/تکراری، آزادسازی ایدمپوتنت، Job انقضا یک‌بار در slot،
--       و تطابق جمع دفتر با تجمیع پس از ۱۰۰۰ گردش.
-- همه‌چیز در یک تراکنش است و با rollback پاک می‌شود.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

insert into iam.users (id, mobile, full_name, status, password_hash) values
  ('60000000-0000-0000-0000-000000000001', '09120000061', 'سرپرست انبار آزمون', 'active', 'fixture-hash-0061'),
  ('60000000-0000-0000-0000-000000000002', '09120000062', 'اپراتور انبار آزمون', 'active', 'fixture-hash-0062'),
  ('60000000-0000-0000-0000-000000000003', '09120000063', 'کارشناس فروش (بدون مجوز تعدیل)', 'active', 'fixture-hash-0063'),
  ('60000000-0000-0000-0000-000000000004', '09120000064', 'مدیر سیستم آزمون', 'active', 'fixture-hash-0064');

insert into iam.user_roles (user_id, role_id)
select '60000000-0000-0000-0000-000000000001'::uuid, id from iam.roles where key = 'R-WH';
insert into iam.user_roles (user_id, role_id)
select '60000000-0000-0000-0000-000000000002'::uuid, id from iam.roles where key = 'R-OP';
insert into iam.user_roles (user_id, role_id)
select '60000000-0000-0000-0000-000000000003'::uuid, id from iam.roles where key = 'R-SALES';
insert into iam.user_roles (user_id, role_id)
select '60000000-0000-0000-0000-000000000004'::uuid, id from iam.roles where key = 'R-SYS';

insert into cat.brands (id, slug, title) values
  ('b2000000-0000-0000-0000-000000000001', 'inv-brand', 'برند موجودی');
insert into cat.products (id, slug, title, brand_id, status, published_at) values
  ('a2000000-0000-0000-0000-000000000001', 'inv-product', 'محصول موجودی',
   'b2000000-0000-0000-0000-000000000001', 'published', now());
insert into cat.variants (id, product_id, sku) values
  ('e2000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000001', 'INV-SKU-1');
insert into inv.warehouses (id, code, title) values
  ('92000000-0000-0000-0000-000000000001', 'INV-WH', 'انبار گردش');

-- --- گردش: مجوز، مقدار، سند و Audit -----------------------------------------
do $$
declare
  v_wh_user  uuid := '60000000-0000-0000-0000-000000000001';
  v_op_user  uuid := '60000000-0000-0000-0000-000000000002';
  v_sales    uuid := '60000000-0000-0000-0000-000000000003';
  v_wh       uuid := '92000000-0000-0000-0000-000000000001';
  v_variant  uuid := 'e2000000-0000-0000-0000-000000000001';
  v_ledger   uuid;
  v_on_hand  integer;
  v_reserved integer;
  v_audit    integer;
begin
  v_ledger := inv.apply_movement(v_wh_user, v_wh, v_variant, 10, 'grn',
                                 'grn', gen_random_uuid(), 'رسید آزمون', 'req-m1');

  select on_hand, reserved into v_on_hand, v_reserved
    from inv.stock_balance where warehouse_id = v_wh and variant_id = v_variant;
  if v_on_hand <> 10 or v_reserved <> 0 then
    raise exception 'FAIL MOVEMENT: پس از رسید on_hand=% reserved=%', v_on_hand, v_reserved;
  end if;

  select count(*) into v_audit from sys.audit_log
   where action = 'stock.movement' and entity_id = v_ledger;
  if v_audit <> 1 then
    raise exception 'FAIL MOVEMENT: Audit گردش % رکورد داد', v_audit;
  end if;
  raise notice 'PASS MOVEMENT | رسید +۱۰ با دفتر و Audit ثبت شد';

  begin
    perform inv.apply_movement(v_sales, v_wh, v_variant, -1, 'adjust',
                               'adjust', gen_random_uuid());
    raise exception 'FAIL MOVEMENT: تعدیل بدون مجوز انجام شد';
  exception when insufficient_privilege then
    raise notice 'PASS MOVEMENT | تعدیل بدون inventory.adjust → %', sqlerrm;
  end;

  begin
    perform inv.apply_movement(v_wh_user, v_wh, v_variant, -1, 'reserve',
                               'reserve', gen_random_uuid());
    raise exception 'FAIL MOVEMENT: reason_code نامجاز پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS MOVEMENT | reason_code نامجاز → %', sqlerrm;
  end;

  begin
    perform inv.apply_movement(v_wh_user, v_wh, v_variant, 0, 'adjust',
                               'adjust', gen_random_uuid());
    raise exception 'FAIL MOVEMENT: گردش صفر پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS MOVEMENT | گردش صفر → %', sqlerrm;
  end;

  perform inv.apply_movement(v_op_user, v_wh, v_variant, -4, 'sale_ship',
                             'shipment', gen_random_uuid(), null, 'req-m2');
  select on_hand into v_on_hand
    from inv.stock_balance where warehouse_id = v_wh and variant_id = v_variant;
  if v_on_hand <> 6 then
    raise exception 'FAIL MOVEMENT: پس از ارسال on_hand=%، انتظار ۶', v_on_hand;
  end if;
  raise notice 'PASS MOVEMENT | ارسال -۴ با مجوز اپراتور انجام شد';

  begin
    perform inv.apply_movement(v_op_user, v_wh, v_variant, -7, 'sale_ship',
                               'shipment', gen_random_uuid());
    raise exception 'FAIL MOVEMENT: موجودی منفی پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS MOVEMENT | موجودی منفی → %', sqlerrm;
  end;
end $$;

-- --- رزرو، رزرو تکراری و موجودی رزروشده ------------------------------------
do $$
declare
  v_sales   uuid := '60000000-0000-0000-0000-000000000003';
  v_op      uuid := '60000000-0000-0000-0000-000000000002';
  v_wh      uuid := '92000000-0000-0000-0000-000000000001';
  v_variant uuid := 'e2000000-0000-0000-0000-000000000001';
  v_line    uuid := 'd2000000-0000-0000-0000-000000000001';
  v_res     uuid;
  v_reserved integer;
begin
  v_res := inv.reserve(v_sales, v_line, v_wh, v_variant, 3, 30);

  select reserved into v_reserved
    from inv.stock_balance where warehouse_id = v_wh and variant_id = v_variant;
  if v_reserved <> 3 then
    raise exception 'FAIL RESERVE: reserved=%، انتظار ۳', v_reserved;
  end if;
  raise notice 'PASS RESERVE | رزرو ۳ از ۶ زیر قفل انجام شد';

  begin
    perform inv.reserve(v_sales, v_line, v_wh, v_variant, 1, 30);
    raise exception 'FAIL RESERVE: رزرو فعال تکراری پذیرفته شد';
  exception when unique_violation then
    if sqlerrm not like 'FCO-1073%' then
      raise exception 'FAIL RESERVE: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS RESERVE | رزرو تکراری → %', sqlerrm;
  end;

  begin
    perform inv.reserve(v_sales, gen_random_uuid(), v_wh, v_variant, 99, 30);
    raise exception 'FAIL RESERVE: رزرو بیش از موجودی پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS RESERVE | رزرو بیش از موجودی → %', sqlerrm;
  end;

  begin
    perform inv.reserve(v_sales, gen_random_uuid(), v_wh, v_variant, 0, 30);
    raise exception 'FAIL RESERVE: رزرو صفر پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS RESERVE | رزرو صفر → %', sqlerrm;
  end;

  -- موجودی رزروشده نباید به‌عنوان قابل‌فروش برداشت شود
  begin
    perform inv.apply_movement(v_op, v_wh, v_variant, -4, 'sale_ship',
                               'shipment', gen_random_uuid());
    raise exception 'FAIL MOVEMENT: برداشت از موجودی رزروشده پذیرفته شد';
  exception when sqlstate '22023' then
    if sqlerrm not like 'FCO-1076%' then
      raise exception 'FAIL MOVEMENT: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS MOVEMENT | برداشت از رزروشده → %', sqlerrm;
  end;

  perform inv.apply_movement(v_op, v_wh, v_variant, -2, 'sale_ship',
                             'shipment', gen_random_uuid());

  if not inv.release(v_sales, v_res, 'cart_abandoned') then
    raise exception 'FAIL RELEASE: آزادسازی اول false داد';
  end if;
  if inv.release(v_sales, v_res, 'again') then
    raise exception 'FAIL RELEASE: آزادسازی دوباره true داد';
  end if;

  select reserved into v_reserved
    from inv.stock_balance where warehouse_id = v_wh and variant_id = v_variant;
  if v_reserved <> 0 then
    raise exception 'FAIL RELEASE: reserved پس از آزادسازی % است', v_reserved;
  end if;
  raise notice 'PASS RELEASE | آزادسازی یک‌بار انجام شد و تکرار بی‌اثر بود';
end $$;

-- --- Job انقضا: یک‌بار در slot (T-INV-04) ---------------------------------
do $$
declare
  v_sales   uuid := '60000000-0000-0000-0000-000000000003';
  v_admin   uuid := '60000000-0000-0000-0000-000000000004';
  v_wh      uuid := '92000000-0000-0000-0000-000000000001';
  v_variant uuid := 'e2000000-0000-0000-0000-000000000001';
  v_res     uuid;
  v_reserved integer;
  v_run     record;
  v_again   record;
begin
  v_res := inv.reserve(v_sales, 'd2000000-0000-0000-0000-000000000002', v_wh, v_variant, 2, 1);
  -- رزرو را به گذشته می‌بریم (created_at هم)، وگرنه قید expires_at > created_at می‌شکند
  update inv.reservations
     set created_at = now() - interval '5 minutes',
         expires_at = now() - interval '1 minute'
   where id = v_res;

  select * into v_run from inv.expire_reservations(v_admin, '2026-11-25 10:00:00+00', 10);
  if v_run.outcome <> 'ran' or v_run.expired <> 1 then
    raise exception 'FAIL EXPIRY: اجرای اول %/% بود', v_run.outcome, v_run.expired;
  end if;

  select * into v_again from inv.expire_reservations(v_admin, '2026-11-25 10:00:00+00', 10);
  if v_again.outcome <> 'already_ran' or v_again.expired <> 0 then
    raise exception 'FAIL EXPIRY: اجرای دوباره %/% بود', v_again.outcome, v_again.expired;
  end if;

  select reserved into v_reserved
    from inv.stock_balance where warehouse_id = v_wh and variant_id = v_variant;
  if v_reserved <> 0 then
    raise exception 'FAIL EXPIRY: reserved پس از انقضا % است', v_reserved;
  end if;
  raise notice 'PASS EXPIRY | رزرو منقضی یک‌بار آزاد شد و تکرار Job بی‌اثر بود';
end $$;

-- --- T-INV-03: جمع دفتر = تجمیع پس از ۱۰۰۰ گردش تصادفی ---------------------
do $$
declare
  v_wh_user uuid := '60000000-0000-0000-0000-000000000001';
  v_wh      uuid := '92000000-0000-0000-0000-000000000001';
  v_variant uuid := 'e2000000-0000-0000-0000-000000000001';
  v_on_hand integer;
  v_sum     bigint;
  i         integer;
begin
  perform inv.apply_movement(v_wh_user, v_wh, v_variant, 500, 'grn',
                             'grn', gen_random_uuid(), 'موجودی پایه آزمون');

  for i in 1..1000 loop
    perform inv.apply_movement(
      v_wh_user, v_wh, v_variant,
      case when random() < 0.5 then 1 else -1 end,
      'adjust', 'adjust', gen_random_uuid());
  end loop;

  select on_hand, (select coalesce(sum(quantity_delta), 0) from inv.stock_ledger
                    where warehouse_id = v_wh and variant_id = v_variant)
    into v_on_hand, v_sum
    from inv.stock_balance where warehouse_id = v_wh and variant_id = v_variant;

  if v_on_hand <> v_sum then
    raise exception 'FAIL RECONCILE: on_hand=% و جمع دفتر=%', v_on_hand, v_sum;
  end if;
  raise notice 'PASS RECONCILE | پس از ۱۰۰۰ گردش، جمع دفتر = تجمیع (%)', v_on_hand;
end $$;

-- --- نقش اپ: دفتر مستقیم ممنوع، گردش فقط از تابع ---------------------------
set local role fco_app;

do $$
begin
  begin
    insert into inv.stock_ledger
      (warehouse_id, variant_id, quantity_delta, balance_after, reason_code,
       document_type, document_id)
    values ('92000000-0000-0000-0000-000000000001',
            'e2000000-0000-0000-0000-000000000001', 1, 999, 'adjust',
            'adjust', gen_random_uuid());
    raise exception 'FAIL APP-ROLE: درج مستقیم دفتر مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS APP-ROLE | درج مستقیم دفتر مسدود است';
  end;
end $$;

select inv.apply_movement('60000000-0000-0000-0000-000000000001'::uuid,
                          '92000000-0000-0000-0000-000000000001'::uuid,
                          'e2000000-0000-0000-0000-000000000001'::uuid,
                          1, 'adjust', 'adjust', gen_random_uuid(),
                          'از مسیر اپ') is not null as app_movement_ok;

reset role;

-- --- شاهد نهایی ------------------------------------------------------------
do $$
declare v_audit integer; v_ledger integer;
begin
  select count(*) into v_audit from sys.audit_log where action in ('stock.movement', 'stock.reserve', 'stock.release');
  select count(*) into v_ledger from inv.stock_ledger
   where warehouse_id = '92000000-0000-0000-0000-000000000001'
     and variant_id = 'e2000000-0000-0000-0000-000000000001';
  if v_audit < 1000 or v_ledger < 1000 then
    raise exception 'FAIL EVIDENCE: audit=% ledger=%', v_audit, v_ledger;
  end if;
  raise notice 'PASS EVIDENCE | % گردش و % رکورد Audit ثبت شد', v_ledger, v_audit;
end $$;

select 'ALL STEP-BR2-3 NEGATIVE CASES PASSED' as result;
rollback;
