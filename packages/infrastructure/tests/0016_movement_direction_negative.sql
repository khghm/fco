-- =============================================================================
-- 0016_movement_direction_negative — جهت گردش بر پایه reason_code
-- مالک انتظارها: docs/Engineering-04/TEST_STRATEGY.md §4.1 (T-INV-06)
--
-- پوشش: رسید انبار/بازگشت منفی ممنوع، خروج فروش مثبت ممنوع، تعدیل دوطرفه مجاز،
--       reserve/release در دفتر ممنوع، و اینکه رد شدن گردش، تجمیع/دفتر/Audit را
--       دست‌نخورده می‌گذارد (خطا کل فراخوانی را برمی‌گرداند).
-- همه‌چیز در یک تراکنش است و با rollback پاک می‌شود.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

insert into iam.users (id, mobile, full_name, status, password_hash) values
  ('68000000-0000-0000-0000-000000000001', '09120000081', 'سرپرست انبار جهت', 'active', 'fixture-hash-0081'),
  ('68000000-0000-0000-0000-000000000002', '09120000082', 'اپراتور انبار جهت', 'active', 'fixture-hash-0082');
insert into iam.user_roles (user_id, role_id)
select '68000000-0000-0000-0000-000000000001'::uuid, id from iam.roles where key = 'R-WH';
insert into iam.user_roles (user_id, role_id)
select '68000000-0000-0000-0000-000000000002'::uuid, id from iam.roles where key = 'R-OP';

insert into cat.brands (id, slug, title) values
  ('b6000000-0000-0000-0000-000000000001', 'dir-brand', 'برند جهت');
insert into cat.products (id, slug, title, brand_id, status, published_at) values
  ('a6000000-0000-0000-0000-000000000001', 'dir-product', 'محصول جهت',
   'b6000000-0000-0000-0000-000000000001', 'published', now());
insert into cat.variants (id, product_id, sku) values
  ('e6000000-0000-0000-0000-000000000001', 'a6000000-0000-0000-0000-000000000001', 'DIR-SKU-1');
insert into inv.warehouses (id, code, title) values
  ('96000000-0000-0000-0000-000000000001', 'DIR-WH', 'انبار جهت');

do $$
declare
  v_wh_user  uuid := '68000000-0000-0000-0000-000000000001';
  v_op_user  uuid := '68000000-0000-0000-0000-000000000002';
  v_wh       uuid := '96000000-0000-0000-0000-000000000001';
  v_variant  uuid := 'e6000000-0000-0000-0000-000000000001';
  v_on_hand  integer;
  v_ledger   integer;
  v_audit    integer;
  v_ok       integer := 0;
begin
  perform inv.apply_movement(v_wh_user, v_wh, v_variant, 10, 'grn',
                             'grn', gen_random_uuid(), 'رسید آزمون جهت');

  select on_hand into v_on_hand from inv.stock_balance
   where warehouse_id = v_wh and variant_id = v_variant;
  select count(*) into v_ledger from inv.stock_ledger
   where warehouse_id = v_wh and variant_id = v_variant;
  select count(*) into v_audit from sys.audit_log where action = 'stock.movement';
  if v_on_hand <> 10 or v_ledger <> 1 or v_audit <> 1 then
    raise exception 'FAIL SETUP: on_hand=% ledger=% audit=%', v_on_hand, v_ledger, v_audit;
  end if;

  -- رسید انبار با مقدار منفی: همان مجوز، جهت اشتباه
  begin
    perform inv.apply_movement(v_wh_user, v_wh, v_variant, -1, 'grn',
                               'grn', gen_random_uuid());
    raise exception 'FAIL DIRECTION: grn منفی پذیرفته شد (کاهش موجودی با مجوز رسید)';
  exception when sqlstate '22023' then
    if sqlerrm not like 'FCO-1078%' then raise; end if;
    v_ok := v_ok + 1;
  end;

  -- بازگشت به انبار با مقدار منفی
  begin
    perform inv.apply_movement(v_wh_user, v_wh, v_variant, -2, 'return_restock',
                               'inspection', gen_random_uuid());
    raise exception 'FAIL DIRECTION: return_restock منفی پذیرفته شد';
  exception when sqlstate '22023' then
    if sqlerrm not like 'FCO-1078%' then raise; end if;
    v_ok := v_ok + 1;
  end;

  -- خروج فروش با مقدار مثبت
  begin
    perform inv.apply_movement(v_op_user, v_wh, v_variant, 5, 'sale_ship',
                               'shipment', gen_random_uuid());
    raise exception 'FAIL DIRECTION: sale_ship مثبت پذیرفته شد';
  exception when sqlstate '22023' then
    if sqlerrm not like 'FCO-1078%' then raise; end if;
    v_ok := v_ok + 1;
  end;

  if v_ok <> 3 then
    raise exception 'FAIL DIRECTION: % حالت از ۳ حالت رد شد', v_ok;
  end if;

  -- رد شدن باید کل فراخوانی را برگرداند: تجمیع، دفتر و Audit دست‌نخورده
  select on_hand into v_on_hand from inv.stock_balance
   where warehouse_id = v_wh and variant_id = v_variant;
  select count(*) into v_ledger from inv.stock_ledger
   where warehouse_id = v_wh and variant_id = v_variant;
  select count(*) into v_audit from sys.audit_log where action = 'stock.movement';
  if v_on_hand <> 10 or v_ledger <> 1 or v_audit <> 1 then
    raise exception 'FAIL ROLLBACK: پس از ردها on_hand=% ledger=% audit=%', v_on_hand, v_ledger, v_audit;
  end if;
  raise notice 'PASS DIRECTION | grn/return منفی و sale_ship مثبت → FCO-1078 بدون اثر روی تجمیع/دفتر/Audit';

  -- مسیرهای مجاز
  perform inv.apply_movement(v_op_user, v_wh, v_variant, -3, 'sale_ship',
                             'shipment', gen_random_uuid());
  perform inv.apply_movement(v_wh_user, v_wh, v_variant, -2, 'adjust',
                             'adjust', gen_random_uuid());
  select on_hand into v_on_hand from inv.stock_balance
   where warehouse_id = v_wh and variant_id = v_variant;
  if v_on_hand <> 5 then
    raise exception 'FAIL ALLOWED: on_hand=% پس از خروج ۳ و تعدیل −۲', v_on_hand;
  end if;
  raise notice 'PASS ALLOWED | sale_ship منفی و adjust دوطرفه انجام شد (on_hand=5)';
end $$;

-- --- reserve/release در دفتر گردش مجاز نیستند (حتی برای مالک) --------------
do $$
declare v_blocked integer := 0;
begin
  begin
    insert into inv.stock_ledger
      (warehouse_id, variant_id, quantity_delta, balance_after, reason_code,
       document_type, document_id)
    values ('96000000-0000-0000-0000-000000000001',
            'e6000000-0000-0000-0000-000000000001', 1, 999, 'reserve',
            'reserve', gen_random_uuid());
    raise exception 'FAIL REASON: reserve در دفتر گردش پذیرفته شد';
  exception when sqlstate '22023' then
    if sqlerrm not like 'FCO-1078%' then raise; end if;
    v_blocked := 1;
  end;
  if v_blocked <> 1 then
    raise exception 'FAIL REASON: گارد reason_code اعمال نشد';
  end if;
  raise notice 'PASS REASON | reserve/release در دفتر گردش → FCO-1078';
end $$;

-- --- شاهد نهایی: دفتر = تجمیع ----------------------------------------------
do $$
declare v_on_hand integer; v_sum bigint;
begin
  select on_hand,
         (select coalesce(sum(quantity_delta), 0) from inv.stock_ledger
           where warehouse_id = '96000000-0000-0000-0000-000000000001'
             and variant_id = 'e6000000-0000-0000-0000-000000000001')
    into v_on_hand, v_sum
    from inv.stock_balance
   where warehouse_id = '96000000-0000-0000-0000-000000000001'
     and variant_id = 'e6000000-0000-0000-0000-000000000001';
  if v_on_hand <> v_sum or v_on_hand <> 5 then
    raise exception 'FAIL EVIDENCE: on_hand=% جمع دفتر=%', v_on_hand, v_sum;
  end if;
  raise notice 'PASS EVIDENCE | on_hand = جمع دفتر = %', v_on_hand;
end $$;

select 'ALL STEP-BR2-5 NEGATIVE CASES PASSED' as result;
rollback;
