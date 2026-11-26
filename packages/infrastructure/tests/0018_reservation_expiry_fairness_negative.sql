-- =============================================================================
-- 0018_reservation_expiry_fairness_negative — BR-2 (بازبینی 0017)
-- مالک انتظارها: docs/Engineering-04/TEST_STRATEGY.md §4.1 (T-INV-07)
--
-- اجرا:
--   docker exec -i fco-postgres psql -U fco -d fco -v ON_ERROR_STOP=1 -f - \
--     < packages/infrastructure/tests/0018_reservation_expiry_fairness_negative.sql
--
-- شکاف مورد آزمون: در 0017 رزرو خراب `active` می‌ماند و دسته با
-- `order by expires_at` پر می‌شد؛ پس رزرو خراب قدیمی همیشه سر صف بود و با رسیدن
-- شمارش به اندازه دسته، رزروهای سالم هیچ‌وقت آزاد نمی‌شدند (Job همان‌جا
-- `succeeded` هم گزارش می‌کرد).
--
-- پوشش: دور ۱ شکست دو رزرو خراب را ثبت می‌کند؛ در دور ۲ که دو رزرو سالمِ
--       تازه (دیرتر منقضی‌شده) و دو رزرو خرابِ سابقه‌دار با دسته ۲ رقابت دارند،
--       سالم‌ها آزاد می‌شوند و شکست جدیدی ثبت نمی‌شود؛ در صف خالی همان رزروهای
--       خراب بازآزمون (و دوباره ثبت) می‌شوند؛ پس از رفع داده آزاد می‌شوند و
--       تاریخ خطا می‌ماند؛ اجرای سالم `error=NULL` می‌گذارد؛ ایندکس `run_id` موجود است.
-- همه‌چیز در یک تراکنش است و با rollback پاک می‌شود.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

insert into iam.users (id, mobile, full_name, status, password_hash) values
  ('71000000-0000-0000-0000-000000000001', '09120000081', 'سرپرست انبار آزمون صف', 'active', 'fixture-hash-0081'),
  ('71000000-0000-0000-0000-000000000002', '09120000082', 'کارشناس فروش آزمون صف', 'active', 'fixture-hash-0082'),
  ('71000000-0000-0000-0000-000000000003', '09120000083', 'مدیر سیستم آزمون صف', 'active', 'fixture-hash-0083');

insert into iam.user_roles (user_id, role_id)
select '71000000-0000-0000-0000-000000000001'::uuid, id from iam.roles where key = 'R-WH';
insert into iam.user_roles (user_id, role_id)
select '71000000-0000-0000-0000-000000000002'::uuid, id from iam.roles where key = 'R-SALES';
insert into iam.user_roles (user_id, role_id)
select '71000000-0000-0000-0000-000000000003'::uuid, id from iam.roles where key = 'R-SYS';

insert into cat.brands (id, slug, title) values
  ('b4000000-0000-0000-0000-000000000001', 'fair-brand', 'برند آزمون صف');
insert into cat.products (id, slug, title, brand_id, status, published_at) values
  ('a4000000-0000-0000-0000-000000000001', 'fair-product', 'محصول آزمون صف',
   'b4000000-0000-0000-0000-000000000001', 'published', now());
insert into cat.variants (id, product_id, sku) values
  ('e4000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000001', 'FAIR-SKU-A'),
  ('e4000000-0000-0000-0000-000000000002', 'a4000000-0000-0000-0000-000000000001', 'FAIR-SKU-B');
insert into inv.warehouses (id, code, title) values
  ('94000000-0000-0000-0000-000000000001', 'FAIR-WH', 'انبار آزمون صف');

do $$
declare
  v_wh_user uuid := '71000000-0000-0000-0000-000000000001';
  v_wh      uuid := '94000000-0000-0000-0000-000000000001';
begin
  perform inv.apply_movement(v_wh_user, v_wh, 'e4000000-0000-0000-0000-000000000001'::uuid,
                             20, 'grn', 'grn', gen_random_uuid(), 'موجودی پایه آزمون صف');
  perform inv.apply_movement(v_wh_user, v_wh, 'e4000000-0000-0000-0000-000000000002'::uuid,
                             20, 'grn', 'grn', gen_random_uuid(), 'موجودی پایه آزمون صف');
end $$;

-- --- صف خراب نباید صف سالم را گرسنه کند --------------------------------------
do $$
declare
  v_sales  uuid := '71000000-0000-0000-0000-000000000002';
  v_admin  uuid := '71000000-0000-0000-0000-000000000003';
  v_wh     uuid := '94000000-0000-0000-0000-000000000001';
  v_a      uuid := 'e4000000-0000-0000-0000-000000000001';
  v_b      uuid := 'e4000000-0000-0000-0000-000000000002';
  v_slot   timestamptz := '2026-11-27 08:00:00+00';
  b1       uuid;
  b2       uuid;
  a1       uuid;
  a2       uuid;
  a3       uuid;
  a4       uuid;
  v_run    record;
  v_job    record;
  v_fail_n integer;
  v_fail_sum integer;
  v_idx    integer;
begin
  b1 := inv.reserve(v_sales, 'd4000000-0000-0000-0000-000000000001', v_wh, v_b, 3, 30);
  b2 := inv.reserve(v_sales, 'd4000000-0000-0000-0000-000000000002', v_wh, v_b, 2, 30);
  a1 := inv.reserve(v_sales, 'd4000000-0000-0000-0000-000000000003', v_wh, v_a, 2, 30);
  a2 := inv.reserve(v_sales, 'd4000000-0000-0000-0000-000000000004', v_wh, v_a, 1, 30);

  -- رزروهای خراب عمداً قدیمی‌ترین‌اند
  update inv.reservations set created_at = now() - interval '30 minutes',
                              expires_at = now() - interval '10 minutes' where id = b1;
  update inv.reservations set created_at = now() - interval '30 minutes',
                              expires_at = now() - interval '9 minutes'  where id = b2;
  update inv.reservations set created_at = now() - interval '30 minutes',
                              expires_at = now() - interval '8 minutes'  where id = a1;
  update inv.reservations set created_at = now() - interval '30 minutes',
                              expires_at = now() - interval '7 minutes'  where id = a2;

  -- رزروهای B خراب می‌شوند: reserved صفر با رزرو فعال ناهم‌خوان است
  update inv.stock_balance set reserved = 0 where warehouse_id = v_wh and variant_id = v_b;

  -- دور ۱: دسته به اندازه کافی بزرگ است، پس همه دیده می‌شوند و دو خرابِ B سابقه پیدا می‌کنند
  select * into v_run from inv.expire_reservations(v_admin, v_slot, 10);
  if v_run.outcome <> 'ran' or v_run.expired <> 2 or v_run.failed <> 2 then
    raise exception 'FAIL SEED: %/%/% (انتظار ran/2/2)',
      v_run.outcome, v_run.expired, v_run.failed;
  end if;

  select status, error into v_job from sys.job_runs where id = v_run.run_id;
  if v_job.status <> 'succeeded' or v_job.error is null
     or v_job.error not like '%reservation_expiry_failures%' then
    raise exception 'FAIL SEED: status=% error=%', v_job.status, v_job.error;
  end if;
  raise notice 'PASS SEED | دور اول: ۲ آزاد و ۲ شکستِ ثبت‌شده (Job=succeeded با یادداشت)';

  -- دور ۲: دو رزرو سالمِ تازه منقضی می‌شوند؛ رزروهای خراب قدیمی‌ترند و در
  -- ترتیب 0017 (`order by expires_at`) هر دو جای دسته ۲ را می‌گرفتند.
  a3 := inv.reserve(v_sales, 'd4000000-0000-0000-0000-000000000005', v_wh, v_a, 2, 30);
  a4 := inv.reserve(v_sales, 'd4000000-0000-0000-0000-000000000006', v_wh, v_a, 1, 30);
  update inv.reservations set created_at = now() - interval '20 minutes',
                              expires_at = now() - interval '5 minutes' where id = a3;
  update inv.reservations set created_at = now() - interval '20 minutes',
                              expires_at = now() - interval '4 minutes' where id = a4;

  select * into v_run from inv.expire_reservations(v_admin, v_slot + interval '1 hour', 2);
  if v_run.outcome <> 'ran' then
    raise exception 'FAIL STARVE: outcome=% (انتظار ran)', v_run.outcome;
  end if;
  if v_run.expired <> 2 or v_run.failed <> 0 then
    raise exception 'FAIL STARVE: expired=% failed=% — صف خراب جای رزرو سالم را گرفت',
      v_run.expired, v_run.failed;
  end if;
  if (select status from inv.reservations where id = a3) <> 'released'
     or (select status from inv.reservations where id = a4) <> 'released' then
    raise exception 'FAIL STARVE: رزرو سالم آزاد نشد (a3=% a4=%)',
      (select status from inv.reservations where id = a3),
      (select status from inv.reservations where id = a4);
  end if;
  if (select status from inv.reservations where id = b1) <> 'active'
     or (select status from inv.reservations where id = b2) <> 'active' then
    raise exception 'FAIL STARVE: رزرو خراب وضعیتش عوض شد';
  end if;
  select count(*) into v_fail_n from inv.reservation_expiry_failures;
  if v_fail_n <> 2 then
    raise exception 'FAIL STARVE: شمار ردیف خطا از ۲ به % رسید', v_fail_n;
  end if;
  raise notice 'PASS STARVE | رزروهای سابقه‌دار انتهای صف رفتند و دو رزرو سالم آزاد شدند';

  -- شبکه اطمینان: وقتي صف سالم خالی شد، رزرو سابقه‌دار نادیده گرفته نمی‌شود
  select * into v_run from inv.expire_reservations(v_admin, v_slot + interval '2 hours', 2);
  if v_run.outcome <> 'ran' or v_run.expired <> 0 or v_run.failed <> 2 then
    raise exception 'FAIL RETRYQ: %/%/% (انتظار ran/0/2)',
      v_run.outcome, v_run.expired, v_run.failed;
  end if;
  -- از 0020 هر رزرو یک ردیف دارد و شمار شکست جدا شمرده می‌شود.
  select count(*), coalesce(sum(failures), 0) into v_fail_n, v_fail_sum
    from inv.reservation_expiry_failures
   where reservation_id in (b1, b2) and error_sqlstate = '23514';
  if v_fail_n <> 2 or v_fail_sum <> 4 then
    raise exception 'FAIL RETRYQ: % ردیف با % شکست ثبت شد (انتظار ۲ ردیف با ۴ شکست)',
      v_fail_n, v_fail_sum;
  end if;
  raise notice 'PASS RETRYQ | در صف خالی، رزرو سابقه‌دار بازآزمون و شکستش دوباره ثبت شد';

  -- رفع داده: رزروهای سابقه‌دار نباید برای همیشه عقب بمانند
  update inv.stock_balance set reserved = 5 where warehouse_id = v_wh and variant_id = v_b;
  select * into v_run from inv.expire_reservations(v_admin, v_slot + interval '3 hours', 2);
  if v_run.outcome <> 'ran' or v_run.expired <> 2 or v_run.failed <> 0 then
    raise exception 'FAIL HEAL: %/%/% (انتظار ran/2/0)',
      v_run.outcome, v_run.expired, v_run.failed;
  end if;
  if (select status from inv.reservations where id = b1) <> 'released'
     or (select status from inv.reservations where id = b2) <> 'released' then
    raise exception 'FAIL HEAL: رزرو سابقه‌دار پس از رفع داده آزاد نشد';
  end if;
  select count(*), coalesce(sum(failures), 0) into v_fail_n, v_fail_sum
    from inv.reservation_expiry_failures;
  if v_fail_n <> 2 or v_fail_sum <> 4 then
    raise exception 'FAIL HEAL: تاریخ خطا تغییر کرد (% ردیف با % شکست)', v_fail_n, v_fail_sum;
  end if;
  raise notice 'PASS HEAL | پس از رفع داده هر دو رزرو سابقه‌دار آزاد شدند و تاریخ خطا ماند';

  -- اجرای سالم یادداشت شکست روی رکورد Job نمی‌گذارد
  select status, error into v_job from sys.job_runs where id = v_run.run_id;
  if v_job.status <> 'succeeded' or v_job.error is not null then
    raise exception 'FAIL CLEAN: status=% error=% (انتظار succeeded/NULL)',
      v_job.status, v_job.error;
  end if;
  raise notice 'PASS CLEAN | اجرای بدون شکست، error=NULL در sys.job_runs گذاشت';

  -- ایندکس cascade روی run_id
  select count(*) into v_idx from pg_indexes
   where schemaname = 'inv' and tablename = 'reservation_expiry_failures'
     and indexname = 'reservation_expiry_failures_run_idx';
  if v_idx <> 1 then
    raise exception 'FAIL INDEX: ایندکس run_id موجود نیست';
  end if;
  raise notice 'PASS INDEX | ایندکس inv.reservation_expiry_failures_run_idx موجود است';
end $$;

-- --- شاهد نهایی ------------------------------------------------------------
select 'ALL STEP-BR2-3C NEGATIVE CASES PASSED' as result;
rollback;
