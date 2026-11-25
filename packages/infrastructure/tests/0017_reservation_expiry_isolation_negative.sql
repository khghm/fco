-- =============================================================================
-- 0017_reservation_expiry_isolation_negative — BR-2 (بازبینی گام ۳)
-- مالک انتظارها: docs/Engineering-04/TEST_STRATEGY.md §4.1 (T-INV-04، T-INV-07)
--
-- اجرا:
--   docker exec -i fco-postgres psql -U fco -d fco -v ON_ERROR_STOP=1 -f - \
--     < packages/infrastructure/tests/0017_reservation_expiry_isolation_negative.sql
--
-- پوشش: یک رزرو خراب (reserved ناهم‌خوان) در وسط دسته، بقیه رزروها را متوقف
--       نمی‌کند؛ خطا با run_id/sqlstate در inv.reservation_expiry_failures ثبت
--       می‌شود؛ رزرو خراب active می‌ماند و Audit برایش نوشته نمی‌شود؛ Job
--       'succeeded' با یادداشت شکست جزئی؛ اجرای دوباره slot بی‌اثر؛ پس از رفع
--       داده همان رزرو در slot بعدی آزاد می‌شود؛ و نقش اپ نمی‌تواند ردیف خطا جعل کند.
-- همه‌چیز در یک تراکنش است و با rollback پاک می‌شود.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

insert into iam.users (id, mobile, full_name, status, password_hash) values
  ('70000000-0000-0000-0000-000000000001', '09120000071', 'سرپرست انبار آزمون انقضا', 'active', 'fixture-hash-0071'),
  ('70000000-0000-0000-0000-000000000002', '09120000072', 'کارشناس فروش آزمون انقضا', 'active', 'fixture-hash-0072'),
  ('70000000-0000-0000-0000-000000000003', '09120000073', 'مدیر سیستم آزمون انقضا', 'active', 'fixture-hash-0073');

insert into iam.user_roles (user_id, role_id)
select '70000000-0000-0000-0000-000000000001'::uuid, id from iam.roles where key = 'R-WH';
insert into iam.user_roles (user_id, role_id)
select '70000000-0000-0000-0000-000000000002'::uuid, id from iam.roles where key = 'R-SALES';
insert into iam.user_roles (user_id, role_id)
select '70000000-0000-0000-0000-000000000003'::uuid, id from iam.roles where key = 'R-SYS';

insert into cat.brands (id, slug, title) values
  ('b3000000-0000-0000-0000-000000000001', 'exp-brand', 'برند انقضا');
insert into cat.products (id, slug, title, brand_id, status, published_at) values
  ('a3000000-0000-0000-0000-000000000001', 'exp-product', 'محصول انقضا',
   'b3000000-0000-0000-0000-000000000001', 'published', now());
insert into cat.variants (id, product_id, sku) values
  ('e3000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-000000000001', 'EXP-SKU-A'),
  ('e3000000-0000-0000-0000-000000000002', 'a3000000-0000-0000-0000-000000000001', 'EXP-SKU-B');
insert into inv.warehouses (id, code, title) values
  ('93000000-0000-0000-0000-000000000001', 'EXP-WH', 'انبار انقضا');

-- موجودی پایه: ۲۰ برای هر تنوع
do $$
declare
  v_wh_user uuid := '70000000-0000-0000-0000-000000000001';
  v_wh      uuid := '93000000-0000-0000-0000-000000000001';
begin
  perform inv.apply_movement(v_wh_user, v_wh, 'e3000000-0000-0000-0000-000000000001'::uuid,
                             20, 'grn', 'grn', gen_random_uuid(), 'موجودی پایه انقضا');
  perform inv.apply_movement(v_wh_user, v_wh, 'e3000000-0000-0000-0000-000000000002'::uuid,
                             20, 'grn', 'grn', gen_random_uuid(), 'موجودی پایه انقضا');
end $$;

-- --- رزرو خراب واقعاً خطای DB می‌دهد (نه خطای تزریقی) ------------------------
do $$
declare
  v_admin uuid := '70000000-0000-0000-0000-000000000003';
  v_sales uuid := '70000000-0000-0000-0000-000000000002';
  v_wh    uuid := '93000000-0000-0000-0000-000000000001';
  v_b     uuid := 'e3000000-0000-0000-0000-000000000002';
  v_res   uuid;
begin
  v_res := inv.reserve(v_sales, 'd3000000-0000-0000-0000-000000000003', v_wh, v_b, 2, 30);

  -- reserved ناهم‌خوان با رزرو فعال: آزادسازی باید قید reserved >= 0 را بشکند
  update inv.stock_balance set reserved = 0 where warehouse_id = v_wh and variant_id = v_b;

  begin
    perform inv.release(v_admin, v_res, 'expired');
    raise exception 'FAIL BROKEN: آزادسازی رزرو ناهم‌خوان پذیرفته شد';
  exception when check_violation then
    raise notice 'PASS BROKEN | آزادسازی رزرو ناهم‌خوان → %', sqlerrm;
  end;

  if (select status from inv.reservations where id = v_res) <> 'active' then
    raise exception 'FAIL BROKEN: رزرو پس از خطا active نماند';
  end if;

  -- به حالت اول برگردان تا رزرو خراب بخشی از سناریوی دسته باشد
  update inv.reservations set status = 'released', released_at = now() where id = v_res;
end $$;

-- --- دسته: رزرو خراب در وسط، بقیه باید آزاد شوند (T-INV-07) -----------------
do $$
declare
  v_sales   uuid := '70000000-0000-0000-0000-000000000002';
  v_admin   uuid := '70000000-0000-0000-0000-000000000003';
  v_wh      uuid := '93000000-0000-0000-0000-000000000001';
  v_a       uuid := 'e3000000-0000-0000-0000-000000000001';
  v_b       uuid := 'e3000000-0000-0000-0000-000000000002';
  v_slot    timestamptz := '2026-11-26 08:00:00+00';
  r1        uuid;
  r2        uuid;
  r3        uuid;
  v_run     record;
  v_again   record;
  v_reserved integer;
  v_status  text;
  v_fail    record;
  v_fail_n  integer;
  v_audit   integer;
  v_job     record;
begin
  r1 := inv.reserve(v_sales, 'd3000000-0000-0000-0000-000000000001', v_wh, v_a, 2, 30);
  r3 := inv.reserve(v_sales, 'd3000000-0000-0000-0000-000000000002', v_wh, v_b, 2, 30);
  r2 := inv.reserve(v_sales, 'd3000000-0000-0000-0000-000000000004', v_wh, v_a, 3, 30);

  -- ترتیب دسته: r1 (قدیمی‌تر)، r3 (خراب)، r2 — پس ادامه‌یافتن يعني r2 آزاد شود
  update inv.reservations
     set created_at = now() - interval '20 minutes', expires_at = now() - interval '9 minutes'
   where id = r1;
  update inv.reservations
     set created_at = now() - interval '20 minutes', expires_at = now() - interval '8 minutes'
   where id = r3;
  update inv.reservations
     set created_at = now() - interval '20 minutes', expires_at = now() - interval '7 minutes'
   where id = r2;

  -- رزرو خراب: reserved انبار B صفر می‌شود (رزروهای A دست‌نخورده: ۵)
  update inv.stock_balance set reserved = 0 where warehouse_id = v_wh and variant_id = v_b;

  select * into v_run from inv.expire_reservations(v_admin, v_slot, 10);

  if v_run.outcome <> 'ran' then
    raise exception 'FAIL BATCH: خطای یک رزرو Job را % کرد', v_run.outcome;
  end if;
  if v_run.expired <> 2 or v_run.failed <> 1 then
    raise exception 'FAIL BATCH: expired=% failed=% (انتظار ۲/۱)', v_run.expired, v_run.failed;
  end if;
  raise notice 'PASS BATCH | یک رزرو خراب ثبت شد و دو رزرو سالم آزاد شدند (outcome=ran)';

  -- ادامه دسته: رزروی که بعد از رزرو خراب بود هم آزاد شد
  select status into v_status from inv.reservations where id = r2;
  if v_status <> 'released' then
    raise exception 'FAIL ISOLATION: رزرو بعد از رزرو خراب % ماند', v_status;
  end if;
  if (select status from inv.reservations where id = r1) <> 'released' then
    raise exception 'FAIL ISOLATION: رزرو قبل از رزرو خراب آزاد نشد';
  end if;
  select reserved into v_reserved
    from inv.stock_balance where warehouse_id = v_wh and variant_id = v_a;
  if v_reserved <> 0 then
    raise exception 'FAIL ISOLATION: reserved انبار A پس از دسته % است', v_reserved;
  end if;
  raise notice 'PASS ISOLATION | رزروهای سالم دسته (قبل و بعد از رزرو خراب) آزاد شدند';

  -- رزرو خراب: دست‌نخورده و active
  if (select status from inv.reservations where id = r3) <> 'active' then
    raise exception 'FAIL ISOLATION: رزرو خراب وضعیتش عوض شد';
  end if;

  -- ثبت خطا با run_id و sqlstate
  select count(*) into v_fail_n from inv.reservation_expiry_failures where reservation_id = r3;
  if v_fail_n <> 1 then
    raise exception 'FAIL LOG: برای رزرو خراب % ردیف خطا ثبت شد', v_fail_n;
  end if;
  select * into v_fail from inv.reservation_expiry_failures where reservation_id = r3;
  if v_fail.run_id is distinct from v_run.run_id or v_fail.error_sqlstate <> '23514'
     or v_fail.message not like '%stock_balance%' then
    raise exception 'FAIL LOG: run=% sqlstate=% message=%',
      v_fail.run_id, v_fail.error_sqlstate, v_fail.message;
  end if;
  raise notice 'PASS LOG | خطا با run_id=%، sqlstate=% و پیام قید ثبت شد',
    v_fail.run_id, v_fail.error_sqlstate;

  -- رزرو خراب Audit ندارد (زیرتراکنش خودش برگشت خورد)
  select count(*) into v_audit from sys.audit_log
   where action = 'stock.release' and entity_id = r3;
  if v_audit <> 0 then
    raise exception 'FAIL AUDIT: برای رزرو ناموفق % رکورد Audit نوشته شد', v_audit;
  end if;
  raise notice 'PASS AUDIT | رزرو ناموفق Audit ننوشت (اثر نیمه‌کاره صفر)';

  -- Job شکست جزئی را در job_runs نشان می‌دهد ولی slot را نمی‌سوزاند
  select status, error into v_job from sys.job_runs where id = v_run.run_id;
  if v_job.status <> 'succeeded' or v_job.error is null
     or v_job.error not like '%reservation_expiry_failures%' then
    raise exception 'FAIL JOB: status=% error=%', v_job.status, v_job.error;
  end if;
  raise notice 'PASS JOB | status=succeeded با یادداشت شکست جزئی؛ slot بسته نشد';

  -- اجرای دوباره همان slot بی‌اثر است
  select * into v_again from inv.expire_reservations(v_admin, v_slot, 10);
  if v_again.outcome <> 'already_ran' or v_again.expired <> 0 or v_again.failed <> 0 then
    raise exception 'FAIL SLOT: اجرای دوباره %/%/%', v_again.outcome, v_again.expired, v_again.failed;
  end if;
  raise notice 'PASS SLOT | اجرای دوباره همان slot => already_ran';

  -- رفع داده و اجرای slot بعدی: همان رزرو آزاد می‌شود، خطای قبلی دست‌نخورده می‌ماند
  update inv.stock_balance set reserved = 2 where warehouse_id = v_wh and variant_id = v_b;

  select * into v_run from inv.expire_reservations(v_admin, v_slot + interval '1 hour', 10);
  if v_run.outcome <> 'ran' or v_run.expired <> 1 or v_run.failed <> 0 then
    raise exception 'FAIL RETRY: slot بعدی %/%/%', v_run.outcome, v_run.expired, v_run.failed;
  end if;
  if (select status from inv.reservations where id = r3) <> 'released' then
    raise exception 'FAIL RETRY: رزرو پس از رفع داده آزاد نشد';
  end if;
  select count(*) into v_fail_n from inv.reservation_expiry_failures;
  if v_fail_n <> 1 then
    raise exception 'FAIL RETRY: ردیف‌های خطا از ۱ به % تغییر کرد', v_fail_n;
  end if;
  raise notice 'PASS RETRY | پس از رفع داده همان رزرو آزاد شد و تاریخ خطا حفظ شد';
end $$;

-- --- نقش اپ نمی‌تواند ردیف خطا جعل یا پاک کند --------------------------------
set local role fco_app;

do $$
begin
  begin
    insert into inv.reservation_expiry_failures
      (run_id, reservation_id, error_sqlstate, message)
    values (1, gen_random_uuid(), 'XX000', 'جعل');
    raise exception 'FAIL APP-ROLE: درج ردیف خطا از نقش اپ مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS APP-ROLE | درج ردیف خطا از نقش اپ مسدود است';
  end;

  begin
    delete from inv.reservation_expiry_failures where message = 'جعل';
    raise exception 'FAIL APP-ROLE: حذف ردیف خطا از نقش اپ مجاز بود';
  exception when insufficient_privilege then
    raise notice 'PASS APP-ROLE | تغییر ردیف‌های خطا از نقش اپ مسدود است';
  end;
end $$;

reset role;

-- --- شاهد نهایی ------------------------------------------------------------
select 'ALL STEP-BR2-3B NEGATIVE CASES PASSED' as result;
rollback;
