-- =============================================================================
-- 0020_reservation_expiry_failure_single_row_negative — BR-2 (بازبینی چهارم)
-- مالک انتظارها: docs/Engineering-04/TEST_STRATEGY.md §4.1 (T-INV-08)
--
-- اجرا:
--   docker exec -i fco-postgres psql -U fco -d fco -v ON_ERROR_STOP=1 -f - \
--     < packages/infrastructure/tests/0020_reservation_expiry_failure_single_row_negative.sql
--
-- شکاف مورد آزمون: در 0019 نگهداشت با «هرس داخل بلوک exception» انجام می‌شد؛
-- خطای همان DELETE کل دسته را برمی‌گرداند و Job را failed می‌کرد، دامنه هرس
-- فقط رزروهای همان دور بود و سقف ۲۴ عددی اختراعی که سیگنال «چند بار شکست
-- خورد» را هم از بین می‌برد. 0020 نگهداشت را به ساختار داده برد: یک ردیف
-- برای هر رزرو + شمارنده شکست.
--
-- پوشش: بازنشستگی تنظیم (هیچ تابعی نمی‌خواندش)؛ یکتایی `reservation_id`؛
--       ۲۷ slot پیوسته ⇒ یک ردیف با `failures=27` و آخرین `run_id`؛ دست‌نخورده
--       ماندن ردیف رزرو دیگر؛ حفظ اولویت صف 0018؛ و برنامه اجرایی واقعی در حجم
--       (۱۵۰۰ رزرو منقضی و ۱۲۰۰ ردیف خطا) بدون خاموش‌کردن join/seqscan.
-- همه‌چیز در یک تراکنش است و با rollback پاک می‌شود.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

insert into iam.users (id, mobile, full_name, status, password_hash) values
  ('73000000-0000-0000-0000-000000000001', '09120000101', 'سرپرست انبار آزمون یک‌ردیف', 'active', 'fixture-hash-0101'),
  ('73000000-0000-0000-0000-000000000002', '09120000102', 'کارشناس فروش آزمون یک‌ردیف', 'active', 'fixture-hash-0102'),
  ('73000000-0000-0000-0000-000000000003', '09120000103', 'مدیر سیستم آزمون یک‌ردیف', 'active', 'fixture-hash-0103');

insert into iam.user_roles (user_id, role_id)
select '73000000-0000-0000-0000-000000000001'::uuid, id from iam.roles where key = 'R-WH';
insert into iam.user_roles (user_id, role_id)
select '73000000-0000-0000-0000-000000000002'::uuid, id from iam.roles where key = 'R-SALES';
insert into iam.user_roles (user_id, role_id)
select '73000000-0000-0000-0000-000000000003'::uuid, id from iam.roles where key = 'R-SYS';

insert into cat.brands (id, slug, title) values
  ('b6000000-0000-0000-0000-000000000001', 'one-brand', 'برند آزمون یک‌ردیف');
insert into cat.products (id, slug, title, brand_id, status, published_at) values
  ('a6000000-0000-0000-0000-000000000001', 'one-product', 'محصول آزمون یک‌ردیف',
   'b6000000-0000-0000-0000-000000000001', 'published', now());
insert into cat.variants (id, product_id, sku) values
  ('e6000000-0000-0000-0000-000000000001', 'a6000000-0000-0000-0000-000000000001', 'ONE-SKU-A'),
  ('e6000000-0000-0000-0000-000000000002', 'a6000000-0000-0000-0000-000000000001', 'ONE-SKU-B');
insert into inv.warehouses (id, code, title) values
  ('96000000-0000-0000-0000-000000000001', 'ONE-WH', 'انبار آزمون یک‌ردیف');

do $$
declare
  v_wh_user uuid := '73000000-0000-0000-0000-000000000001';
  v_wh      uuid := '96000000-0000-0000-0000-000000000001';
begin
  perform inv.apply_movement(v_wh_user, v_wh, 'e6000000-0000-0000-0000-000000000001'::uuid,
                             20, 'grn', 'grn', gen_random_uuid(), 'موجودی پایه آزمون یک‌ردیف');
  perform inv.apply_movement(v_wh_user, v_wh, 'e6000000-0000-0000-0000-000000000002'::uuid,
                             20, 'grn', 'grn', gen_random_uuid(), 'موجودی پایه آزمون یک‌ردیف');
end $$;

do $$
declare
  v_sales    uuid := '73000000-0000-0000-0000-000000000002';
  v_admin    uuid := '73000000-0000-0000-0000-000000000003';
  v_wh       uuid := '96000000-0000-0000-0000-000000000001';
  v_a        uuid := 'e6000000-0000-0000-0000-000000000001';
  v_b        uuid := 'e6000000-0000-0000-0000-000000000002';
  v_slot     timestamptz := '2026-11-30 08:00:00+00';
  v_n        integer;
  v_cnt      integer;
  v_idx      integer;
  v_plan     text := '';
  v_line     text;
  v_shape    text;
  v_exec     text := 'n/a';
  v_loops    integer;
  v_fl       bigint;
  v_first_at timestamptz;
  v_last_at  timestamptz;
  v_run      record;
  v_last_run bigint;
  r_broken   uuid;
  r_other    uuid;
  r_healthy  uuid;
  i          integer;
begin
  -- ۱) --------------------- تنظیم بازنشسته: هیچ کدی آن را نمی‌خواند
  select count(*) into v_n from pg_proc where prosrc like '%failure_keep%';
  if v_n <> 0 then
    raise exception 'FAIL RETIRED: % تابع هنوز تنظیم بازنشسته failure_keep را می‌خواند', v_n;
  end if;
  if not exists (select 1 from sys.setting_versions
                  where key = 'job.reservation_expiry.failure_keep') then
    raise exception 'FAIL RETIRED: تاریخچه تنظیم پاک شده است (0005/D-12)';
  end if;
  raise notice 'PASS RETIRED | سقف پیکربندی حذف شد و هیچ تابعی failure_keep را نمی‌خواند';

  -- ۲) -------------------------------- یکتایی: حداکثر یک ردیف برای هر رزرو
  select count(*) into v_idx
    from pg_index i
    join pg_class c     on c.oid = i.indexrelid
    join pg_namespace n on n.oid = c.relnamespace
    join pg_attribute a on a.attrelid = i.indrelid and a.attnum = i.indkey[0]
   where n.nspname = 'inv'
     and c.relname = 'reservation_expiry_failures_reservation_uidx'
     and a.attname = 'reservation_id'
     and i.indisunique;
  if v_idx <> 1 then
    raise exception 'FAIL INDEX: ایندکس یکتای reservation_id موجود نیست';
  end if;
  raise notice 'PASS INDEX | ایندکس یکتای reservation_expiry_failures_reservation_uidx روی reservation_id است';

  -- ۳) --------------------- ۲۷ slot پیوسته ⇒ یک ردیف با شمارنده ۲۷
  r_broken := inv.reserve(v_sales, 'd6000000-0000-0000-0000-000000000001', v_wh, v_b, 3, 30);
  update inv.reservations set created_at = now() - interval '30 minutes',
                              expires_at = now() - interval '10 minutes'
   where id = r_broken;
  -- رزرو می‌ماند ولی reserved صفر است ⇒ آزادسازی با check (reserved >= 0) می‌شکند
  update inv.stock_balance set reserved = 0 where warehouse_id = v_wh and variant_id = v_b;

  for i in 1 .. 27 loop
    select * into v_run from inv.expire_reservations(v_admin, v_slot + (i - 1) * interval '1 hour', 1);
    if v_run.outcome <> 'ran' or v_run.expired <> 0 or v_run.failed <> 1 then
      raise exception 'FAIL SINGLE: دور % ⇒ %/%/% (انتظار ran/0/1)',
        i, v_run.outcome, v_run.expired, v_run.failed;
    end if;
  end loop;
  v_last_run := v_run.run_id;

  select count(*), max(failures) into v_n, v_cnt
    from inv.reservation_expiry_failures where reservation_id = r_broken;
  if v_n <> 1 then
    raise exception 'FAIL SINGLE: برای یک رزرو % ردیف ثبت شد (انتظار ۱)', v_n;
  end if;
  if v_cnt <> 27 then
    raise exception 'FAIL SINGLE: failures=% (انتظار ۲۷ تلاش ناموفق)', v_cnt;
  end if;
  select run_id, first_failed_at, occurred_at into v_fl, v_first_at, v_last_at
    from inv.reservation_expiry_failures where reservation_id = r_broken;
  if v_fl <> v_last_run then
    raise exception 'FAIL SINGLE: run_id=% (انتظار آخرین دور %)', v_fl, v_last_run;
  end if;
  if v_first_at is null or v_last_at is null or v_first_at > v_last_at then
    raise exception 'FAIL SINGLE: بازه تاریخ شکست معتبر نیست (first=% last=%)', v_first_at, v_last_at;
  end if;
  raise notice 'PASS SINGLE | ۲۷ slot ⇒ ۱ ردیف، failures=27 و run_id آخرین دور؛ رشد جدول به slot وابسته نیست';

  -- ۴) ------------------------------------- دامنه: ردیف رزرو دیگر دست‌نخورده
  r_other := inv.reserve(v_sales, 'd6000000-0000-0000-0000-000000000002', v_wh, v_a, 2, 600);
  insert into inv.reservation_expiry_failures
    (run_id, reservation_id, error_sqlstate, message, failures, first_failed_at, occurred_at)
  values (v_last_run, r_other, '23514', 'ردیف آزمون دامنه', 9,
          now() - interval '2 hours', now() - interval '1 hour');
  select occurred_at into v_last_at from inv.reservation_expiry_failures where reservation_id = r_other;

  select * into v_run from inv.expire_reservations(v_admin, v_slot + interval '30 hours', 1);
  if v_run.outcome <> 'ran' or v_run.failed <> 1 then
    raise exception 'FAIL SCOPE: %/% (انتظار ran/1)', v_run.outcome, v_run.failed;
  end if;
  select failures, occurred_at into v_cnt, v_first_at
    from inv.reservation_expiry_failures where reservation_id = r_other;
  if v_cnt <> 9 or v_first_at <> v_last_at then
    raise exception 'FAIL SCOPE: ردیف رزرو دیگر تغییر کرد (failures=% occurred_at=%)', v_cnt, v_first_at;
  end if;
  select failures into v_cnt from inv.reservation_expiry_failures where reservation_id = r_broken;
  if v_cnt <> 28 then
    raise exception 'FAIL SCOPE: شمارنده رزرو خراب % است (انتظار ۲۸)', v_cnt;
  end if;
  raise notice 'PASS SCOPE | شکست یک رزرو، ردیف و شمارنده رزرو دیگر را لمس نمی‌کند';

  -- ۵) ------------------------------- اولویت صف 0018 با یک ردیف هم برقرار است
  r_healthy := inv.reserve(v_sales, 'd6000000-0000-0000-0000-000000000003', v_wh, v_a, 1, 600);
  update inv.reservations set created_at = now() - interval '30 minutes',
                              expires_at = now() - interval '5 minutes'
   where id = r_healthy;   -- تازه‌تر از رزرو خراب (-۱۰ دقیقه) است

  select * into v_run from inv.expire_reservations(v_admin, v_slot + interval '72 hours', 1);
  if v_run.outcome <> 'ran' or v_run.expired <> 1 or v_run.failed <> 0 then
    raise exception 'FAIL ORDER: %/%/% — رزرو خراب جلوی رزرو سالم را گرفت',
      v_run.outcome, v_run.expired, v_run.failed;
  end if;
  if (select status from inv.reservations where id = r_healthy) <> 'released' then
    raise exception 'FAIL ORDER: رزرو سالم آزاد نشد';
  end if;
  if (select status from inv.reservations where id = r_broken) <> 'active' then
    raise exception 'FAIL ORDER: رزرو خراب نباید آزاد شود';
  end if;
  raise notice 'PASS ORDER | رزرو سابقه‌دار آخر صف است و صف سالم همچنان اولویت دارد';

  -- ۶) ------------------ برنامه اجرایی واقعی در حجم، با تنظیمات پیش‌فرض
  insert into inv.reservations
    (warehouse_id, variant_id, order_line_id, quantity, status, expires_at, created_at)
  select v_wh, v_a, gen_random_uuid(), 1, 'active',
         now() - interval '2 minutes' - (g || ' seconds')::interval,
         now() - interval '3 hours'
    from generate_series(1, 1500) g;

  insert into inv.reservation_expiry_failures
    (run_id, reservation_id, error_sqlstate, message, failures, first_failed_at, occurred_at)
  select v_last_run, s.id, '23514', 'شکست حجمی آزمون', 7,
         now() - interval '3 hours', now() - interval '1 hour'
    from (select r.id from inv.reservations r
           where r.warehouse_id = v_wh and r.variant_id = v_a and r.status = 'active'
           order by r.expires_at
           limit 1200) s;

  execute 'analyze inv.reservations';
  execute 'analyze inv.reservation_expiry_failures';

  -- هیچ join/seqscan خاموش نمی‌شود؛ برنامه‌ای که پلنر واقعاً در این حجم می‌سازد.
  for v_line in execute $q$
    explain (analyze, format text)
    select res.id
      from inv.reservations res
     where res.status = 'active' and res.expires_at <= now()
     order by exists (select 1 from inv.reservation_expiry_failures f
                       where f.reservation_id = res.id),
              res.expires_at
     limit 500
     for update skip locked
  $q$ loop
    v_plan := v_plan || v_line || ' | ';
    if position('Execution Time' in v_line) > 0 then
      v_exec := v_line;
    end if;
    if position('Seq Scan on inv.reservation_expiry_failures' in v_line) > 0 then
      v_loops := coalesce(substring(v_line from 'loops=([0-9]+)')::integer, 1);
      if v_loops > 1 then
        raise exception 'FAIL PLAN: اسکن ترتیبی جدول خطا % بار تکرار شد (O(rows×rows)): %',
          v_loops, v_line;
      end if;
    end if;
  end loop;

  -- شکل برنامه همان است که پلنر در این حجم انتخاب می‌کند، نه چیزی که با خاموش‌کردن
  -- گزینه‌ها به زور ساخته شود. هر سه شکل زیر پذیرفته‌اند و هر سه یک‌بار (نه به‌ازای
  -- هر ردیف) به جدول خطا می‌رسند:
  if position('reservation_expiry_failures' in v_plan) = 0 then
    raise exception 'FAIL PLAN: جدول خطا اصلاً در برنامه نیست: %', v_plan;
  elsif position('reservation_expiry_failures_reservation_uidx' in v_plan) > 0 then
    v_shape := 'nested loop با ایندکس یکتای reservation_id';
  elsif position('hashed SubPlan' in v_plan) > 0 then
    v_shape := 'hashed SubPlan: یک‌بار اسکن جدول خطا و هش کردن، سپس جست‌وجوی هر رزرو در هش';
  elsif position('Hash Semi Join' in v_plan) > 0 or position('Hash Left Join' in v_plan) > 0 then
    v_shape := 'hash semi join با یک‌بار اسکن جدول خطا';
  else
    raise exception 'FAIL PLAN: جدول خطا با هیچ روش شناخته‌شده‌ای در برنامه نیست: %', v_plan;
  end if;
  raise notice 'PASS PLAN | حجم ۱۵۰۰ رزرو منقضی و ۱۲۰۰ ردیف خطا ⇒ % | %', v_shape, v_exec;
end $$;

-- --- شاهد نهایی ------------------------------------------------------------
select 'ALL STEP-BR2-3C-SINGLE-ROW NEGATIVE CASES PASSED' as result;
rollback;
