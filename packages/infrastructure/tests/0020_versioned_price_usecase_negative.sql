-- =============================================================================
-- 0020_versioned_price_usecase_negative — BR-2 price history use-case
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

insert into iam.users (id, mobile, full_name, status, password_hash) values
  ('52000000-0000-0000-0000-000000000001', '09120000061', 'مدیر فروش قیمت', 'active', 'fixture-hash-0061'),
  ('52000000-0000-0000-0000-000000000002', '09120000062', 'اپراتور بدون مجوز قیمت', 'active', 'fixture-hash-0062');

insert into iam.user_roles (user_id, role_id)
select '52000000-0000-0000-0000-000000000001'::uuid, id from iam.roles where key = 'R-SALES';
insert into iam.user_roles (user_id, role_id)
select '52000000-0000-0000-0000-000000000002'::uuid, id from iam.roles where key = 'R-OP';

insert into cat.brands (id, slug, title)
values ('b2000000-0000-0000-0000-000000000001', 'price-usecase-brand', 'برند قیمت');
insert into cat.categories (id, slug, title)
values ('c2000000-0000-0000-0000-000000000001', 'price-usecase-category', 'دسته قیمت');

do $$
declare
  v_actor uuid := '52000000-0000-0000-0000-000000000001';
  v_operator uuid := '52000000-0000-0000-0000-000000000002';
  v_product uuid;
  v_variant uuid;
  v_first uuid;
  v_second uuid;
  v_first_start timestamptz := clock_timestamp() - interval '1 minute';
  v_second_start timestamptz := clock_timestamp() + interval '1 hour';
  v_row_count integer;
  v_audit_count integer;
  v_audit_actor uuid;
  v_superseding uuid;
  v_amount bigint;
begin
  v_product := cat.product_create(
    v_actor, 'price-usecase-product', 'محصول آزمون قیمت',
    null, 'b2000000-0000-0000-0000-000000000001',
    'c2000000-0000-0000-0000-000000000001', '{}'::jsonb, 'req-price-product');
  v_variant := cat.variant_create(v_actor, v_product, 'price-usecase-sku');

  v_first := pricing.price_set(
    v_actor, v_variant, 650000, 800000, v_first_start, 'web', 'req-price-first');
  v_second := pricing.price_set(
    v_actor, v_variant, 700000, 850000, v_second_start, 'web', 'req-price-second',
    'افزایش برنامه‌ریزی‌شده');

  select count(*) into v_row_count
    from pricing.prices
   where variant_id = v_variant and channel = 'web';
  if v_row_count <> 2 then
    raise exception 'FAIL PRICE VERSION: تعداد رکورد تاریخچه % است، انتظار ۲', v_row_count;
  end if;

  select amount_rial, superseded_by
    into v_amount, v_superseding
    from pricing.prices where id = v_first;
  if v_amount <> 650000 or v_superseding <> v_second then
    raise exception 'FAIL PRICE VERSION: نسخه قبلی تغییر کرده یا به نسخه تازه وصل نیست';
  end if;
  if not exists (
    select 1 from pricing.prices
     where id = v_first and effective_to = v_second_start
  ) then
    raise exception 'FAIL PRICE VERSION: بازه نسخه قبلی بسته نشده است';
  end if;
  if not exists (
    select 1 from pricing.prices
     where id = v_second and amount_rial = 700000
       and created_by = v_actor and effective_from = v_second_start
  ) then
    raise exception 'FAIL PRICE VERSION: نسخه تازه یا عامل ایجاد ثبت نشد';
  end if;

  select count(*)
    into v_audit_count
    from sys.audit_log
   where action = 'price.set'
     and entity_type = 'prices'
     and entity_id = v_second
     and request_id = 'req-price-second'
     and permission = 'pricing.price.update';
  select actor_id
    into v_audit_actor
    from sys.audit_log
   where action = 'price.set'
     and entity_type = 'prices'
     and entity_id = v_second
     and request_id = 'req-price-second'
     and permission = 'pricing.price.update';
  if v_audit_count <> 1 or v_audit_actor <> v_actor then
    raise exception 'FAIL PRICE AUDIT: رکورد یکتای Audit با actor_id مدیر ثبت نشد';
  end if;
  raise notice 'PASS PRICE VERSION | رکورد قدیمی حفظ، بازه بسته و نسخه جدید درج شد';
  raise notice 'PASS PRICE AUDIT | شناسه مدیر، مجوز و request_id ثبت شد';

  begin
    perform pricing.price_set(
      v_operator, v_variant, 900000, null, v_second_start + interval '1 hour',
      'web', 'req-price-denied');
    raise exception 'FAIL PRICE ACCESS: کاربر بدون مجوز قیمت ثبت کرد';
  exception when insufficient_privilege then
    raise notice 'PASS PRICE ACCESS | نقش بدون pricing.price.update رد شد';
  end;

  begin
    perform pricing.price_set(
      v_actor, v_variant, 900000, null, v_second_start, 'web', 'req-price-backdated');
    raise exception 'FAIL PRICE ORDER: تاریخ نامتوالی پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS PRICE ORDER | تاریخ غیرمتوالی رد شد';
  end;

  begin
    perform pricing.price_set(
      v_actor, v_variant, -1, null, v_second_start + interval '1 hour',
      'web', 'req-price-negative');
    raise exception 'FAIL PRICE INPUT: مبلغ منفی پذیرفته شد';
  exception when sqlstate '22023' then
    raise notice 'PASS PRICE INPUT | مبلغ منفی رد شد';
  end;

  select count(*) into v_row_count
    from pricing.prices
   where variant_id = v_variant and channel = 'web';
  if v_row_count <> 2 then
    raise exception 'FAIL PRICE ATOMICITY: درخواست ردشده تاریخچه را تغییر داد';
  end if;
end $$;

do $$ begin
  raise notice 'ALL STEP-PRICE PASS';
end $$;
rollback;
