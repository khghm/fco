-- =============================================================================
-- 0019_reservation_expiry_failure_retention_negative — BR-2 (بازبینی سوم)
-- مالک انتظارها: docs/Engineering-04/TEST_STRATEGY.md §4.1 (T-INV-08)
--
-- اجرا:
--   docker exec -i fco-postgres psql -U fco -d fco -v ON_ERROR_STOP=1 -f - \
--     < packages/infrastructure/tests/0019_reservation_expiry_failure_retention_negative.sql
--
-- شکاف مورد آزمون:
--   ۱) `exists` اولویت صف (0018) با `reservation_id` کار می‌کند؛ باید ثابت شود
--      ایندکسی با ستون پیشرو `reservation_id` هست و برنامه اجرایی هم از آن
--      استفاده می‌کند (نه اینکه فقط «یک ایندکس وجود دارد»).
--   ۲) جدول خطا با هر slot برای هر رزرو خراب یک ردیف می‌گرفت و نگهداشتش فقط
--      به cascade `sys.job_runs` تکیه داشت — که هیچ Jobی اجرایش نمی‌کند. پس
--      رشد بی‌مرز بود. `0019` سقف `job.reservation_expiry.failure_keep` را
--      در همان slot هرس می‌کند.
--
-- پوشش: وجود سابقه نسخه‌دار تنظیم؛ ایندکس با ستون پیشرو و استفاده واقعی در
--       برنامه؛ ۲۷ slot پیوسته برای یک رزرو خراب ⇒ دقیقاً `failure_keep` ردیف
--       و هرس قدیمی‌ترین؛ هرس فقط همان رزرو (ردیف‌های رزرو دیگر دست‌نخورده)؛
--       سابقه‌دار ماندن رزرو (اولویت صف 0018 پس از هرس هم برقرار است).
-- همه‌چیز در یک تراکنش است و با rollback پاک می‌شود.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

insert into iam.users (id, mobile, full_name, status, password_hash) values
  ('72000000-0000-0000-0000-000000000001', '09120000091', 'سرپرست انبار آزمون نگهداشت', 'active', 'fixture-hash-0091'),
  ('72000000-0000-0000-0000-000000000002', '09120000092', 'کارشناس فروش آزمون نگهداشت', 'active', 'fixture-hash-0092'),
  ('72000000-0000-0000-0000-000000000003', '09120000093', 'مدیر سیستم آزمون نگهداشت', 'active', 'fixture-hash-0093');

insert into iam.user_roles (user_id, role_id)
select '72000000-0000-0000-0000-000000000001'::uuid, id from iam.roles where key = 'R-WH';
insert into iam.user_roles (user_id, role_id)
select '72000000-0000-0000-0000-000000000002'::uuid, id from iam.roles where key = 'R-SALES';
insert into iam.user_roles (user_id, role_id)
select '72000000-0000-0000-0000-000000000003'::uuid, id from iam.roles where key = 'R-SYS';

insert into cat.brands (id, slug, title) values
  ('b5000000-0000-0000-0000-000000000001', 'keep-brand', 'برند آزمون نگهداشت');
insert into cat.products (id, slug, title, brand_id, status, published_at) values
  ('a5000000-0000-0000-0000-000000000001', 'keep-product', 'محصول آزمون نگهداشت',
   'b5000000-0000-0000-0000-000000000001', 'published', now());
insert into cat.variants (id, product_id, sku) values
  ('e5000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000001', 'KEEP-SKU-A'),
  ('e5000000-0000-0000-0000-000000000002', 'a5000000-0000-0000-0000-000000000001', 'KEEP-SKU-B');
insert into inv.warehouses (id, code, title) values
  ('95000000-0000-0000-0000-000000000001', 'KEEP-WH', 'انبار آزمون نگهداشت');

do $$
declare
  v_wh_user uuid := '72000000-0000-0000-0000-000000000001';
  v_wh      uuid := '95000000-0000-0000-0000-000000000001';
begin
  perform inv.apply_movement(v_wh_user, v_wh, 'e5000000-0000-0000-0000-000000000001'::uuid,
                             20, 'grn', 'grn', gen_random_uuid(), 'موجودی پایه آزمون نگهداشت');
  perform inv.apply_movement(v_wh_user, v_wh, 'e5000000-0000-0000-0000-000000000002'::uuid,
                             20, 'grn', 'grn', gen_random_uuid(), 'موجودی پایه آزمون نگهداشت');
end $$;

do $$
declare
  v_sales    uuid := '72000000-0000-0000-0000-000000000002';
  v_admin    uuid := '72000000-0000-0000-0000-000000000003';
  v_wh       uuid := '95000000-0000-0000-0000-000000000001';
  v_a        uuid := 'e5000000-0000-0000-0000-000000000001';
  v_b        uuid := 'e5000000-0000-0000-0000-000000000002';
  v_slot     timestamptz := '2026-11-29 08:00:00+00';
  v_keep     integer;
  v_n        integer;
  v_idx      integer;
  v_plan     text := '';
  v_line     text;
  v_first    bigint;
  v_last_run bigint;
  v_run      record;
  r_broken   uuid;
  r_hist     uuid;
  r_healthy  uuid;
  i          integer;
begin
  -- ۱) ------------------------------------------------ سقف نگهداشت نسخه‌دار
  v_keep := sys.setting_int('job.reservation_expiry.failure_keep');
  if v_keep is null or v_keep <> 24 then
    raise exception 'FAIL CONFIG: failure_keep=% (انتظار ۲۴)', v_keep;
  end if;
  if not exists (select 1 from sys.setting_versions
                  where key = 'job.reservation_expiry.failure_keep') then
    raise exception 'FAIL CONFIG: نسخه تنظیم در sys.setting_versions ثبت نشده';
  end if;
  raise notice 'PASS CONFIG | سقف نگهداشت نسخه‌دار است (failure_keep=%)', v_keep;

  -- ۲) --------------------------------- ایندکس با ستون پیشرو reservation_id
  select count(*) into v_idx
    from pg_index i
    join pg_class c   on c.oid = i.indexrelid
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = i.indkey[0]
   where n.nspname = 'inv'
     and c.relname = 'reservation_expiry_failures_reservation_idx'
     and a.attname = 'reservation_id';
  if v_idx <> 1 then
    raise exception 'FAIL INDEX: ایندکسی با ستون پیشرو reservation_id برای کلید exists موجود نیست';
  end if;
  raise notice 'PASS INDEX | ایندکس reservation_expiry_failures_reservation_idx ستون پیشرو reservation_id دارد';

  -- ۳) -------------------------------- برنامه اجرایی really از همین ایندکس
  set local enable_seqscan = off;
  set local enable_hashjoin = off;
  set local enable_mergejoin = off;
  for v_line in execute $q$
    explain (format text)
    select res.id
      from inv.reservations res
     where res.status = 'active' and res.expires_at <= now()
     order by exists (select 1 from inv.reservation_expiry_failures f
                       where f.reservation_id = res.id),
              res.expires_at
     limit 5
  $q$ loop
    v_plan := v_plan || v_line || ' ';
  end loop;
  if position('reservation_expiry_failures_reservation_idx' in v_plan) = 0 then
    raise exception 'FAIL PLAN: کلید exists از ایندکس reservation_id استفاده نمی‌کند: %', v_plan;
  end if;
  raise notice 'PASS PLAN | کلید exists روی ایندکس reservation_id اجرا می‌شود';

  -- ۴) ------------------------------- سقف نگهداشت در slotهای پیوسته یک رزرو
  r_broken := inv.reserve(v_sales, 'd5000000-0000-0000-0000-000000000001', v_wh, v_b, 3, 30);
  update inv.reservations set created_at = now() - interval '30 minutes',
                              expires_at = now() - interval '10 minutes'
   where id = r_broken;
  -- رزرو می‌ماند ولی reserved صفر است ⇒ آزادسازی با check (reserved >= 0) می‌شکند
  update inv.stock_balance set reserved = 0 where warehouse_id = v_wh and variant_id = v_b;

  for i in 1 .. (v_keep + 3) loop
    select * into v_run from inv.expire_reservations(v_admin, v_slot + (i - 1) * interval '1 hour', 1);
    if v_run.outcome <> 'ran' or v_run.failed <> 1 or v_run.expired <> 0 then
      raise exception 'FAIL CAP: دور % ⇒ %/%/% (انتظار ran/0/1)',
        i, v_run.outcome, v_run.expired, v_run.failed;
    end if;
    if i = 1 then
      select min(id) into v_first from inv.reservation_expiry_failures
       where reservation_id = r_broken;
    end if;
  end loop;
  v_last_run := v_run.run_id;

  select count(*) into v_n from inv.reservation_expiry_failures where reservation_id = r_broken;
  if v_n <> v_keep then
    raise exception 'FAIL CAP: برای یک رزرو % ردیف ماند (انتظار % از % slot)', v_n, v_keep, v_keep + 3;
  end if;
  if exists (select 1 from inv.reservation_expiry_failures where id = v_first) then
    raise exception 'FAIL CAP: قدیمی‌ترین ردیف هرس نشد';
  end if;
  if not exists (select 1 from inv.reservation_expiry_failures
                  where reservation_id = r_broken and run_id = v_last_run) then
    raise exception 'FAIL CAP: ردیف جدیدترین slot هرس شد (باید بماند)';
  end if;
  raise notice 'PASS CAP | پس از % slot دقیقاً % ردیف ماند؛ قدیمی‌ترین هرس و جدیدترین حفظ شد',
    v_keep + 3, v_n;

  -- ۵) ----------------------------------------- دامنه هرس: فقط همان رزرو
  r_hist := inv.reserve(v_sales, 'd5000000-0000-0000-0000-000000000002', v_wh, v_a, 2, 600);
  insert into inv.reservation_expiry_failures (run_id, reservation_id, error_sqlstate, message)
  select v_last_run, r_hist, '23514', 'ردیف تاریخی آزمون دامنه هرس'
    from generate_series(1, v_keep + 6);

  select * into v_run from inv.expire_reservations(v_admin, v_slot + interval '48 hours', 1);
  if v_run.outcome <> 'ran' or v_run.failed <> 1 then
    raise exception 'FAIL SCOPE: %/% (انتظار ran/1)', v_run.outcome, v_run.failed;
  end if;
  select count(*) into v_n from inv.reservation_expiry_failures where reservation_id = r_hist;
  if v_n <> v_keep + 6 then
    raise exception 'FAIL SCOPE: هرس، ردیف‌های رزرو دیگر را هم زد (% ماند، انتظار %)', v_n, v_keep + 6;
  end if;
  select count(*) into v_n from inv.reservation_expiry_failures where reservation_id = r_broken;
  if v_n <> v_keep then
    raise exception 'FAIL SCOPE: رزرو خراب پس از هرس بعدی % ردیف دارد (انتظار %)', v_n, v_keep;
  end if;
  raise notice 'PASS SCOPE | هرس فقط رزرو شکست‌خورده را می‌زند و ردیف‌های رزرو دیگر دست‌نخورده‌اند';

  -- ۶) --------------------- هرس، «سابقه‌دار بودن» و اولویت صف 0018 را نمی‌شکند
  r_healthy := inv.reserve(v_sales, 'd5000000-0000-0000-0000-000000000003', v_wh, v_a, 1, 600);
  update inv.reservations set created_at = now() - interval '30 minutes',
                              expires_at = now() - interval '5 minutes'
   where id = r_healthy;   -- تازه‌تر از رزرو خراب (‎-۱۰ دقیقه) است

  select * into v_run from inv.expire_reservations(v_admin, v_slot + interval '72 hours', 1);
  if v_run.outcome <> 'ran' or v_run.expired <> 1 or v_run.failed <> 0 then
    raise exception 'FAIL ORDER: %/%/% — رزرو خراب پس از هرس دوباره سر صف آمد',
      v_run.outcome, v_run.expired, v_run.failed;
  end if;
  if (select status from inv.reservations where id = r_healthy) <> 'released' then
    raise exception 'FAIL ORDER: رزرو سالم آزاد نشد';
  end if;
  if (select status from inv.reservations where id = r_broken) <> 'active' then
    raise exception 'FAIL ORDER: رزرو خراب نباید آزاد شود';
  end if;
  raise notice 'PASS ORDER | سابقه‌دار ماندن رزرو حفظ شد؛ صف سالم همچنان اولویت دارد';
end $$;

-- --- شاهد نهایی ------------------------------------------------------------
select 'ALL STEP-BR2-3C-RETENTION NEGATIVE CASES PASSED' as result;
rollback;
