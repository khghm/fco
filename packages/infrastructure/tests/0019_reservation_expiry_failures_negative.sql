-- =============================================================================
-- 0019_reservation_expiry_failures_negative — BR-2 (ادغام سه گام بازبینی)
-- مالک انتظارها: docs/Engineering-04/TEST_STRATEGY.md §4.1 (T-INV-08، T-INV-09)
--
-- اجرا:
--   docker exec -i fco-postgres psql -U fco -d fco -v ON_ERROR_STOP=1 -f - \
--     < packages/infrastructure/tests/0019_reservation_expiry_failures_negative.sql
--
-- این سوئیت جای دو سوئیت قبلی (0020 و 0021) را می‌گیرد، چون Migrationها در یکی
-- ادغام شدند. شکاف‌هایی که می‌سنجد:
--   ۱) نگهداشت: هر شکست یک ردیف می‌گذاشت و نگهداشت به cascade‌ای تکیه داشت که
--      اجرا نمی‌شود ⇒ رشد بی‌مرز. حالا یک ردیف برای هر رزرو با شمارنده شکست.
--   ۲) کد بیمصرف: سقف پیکربندی `failure_keep`، کد خطای `FCO-1079` و کلید
--      تکراری `max_failures` نباید هیچ اثری داشته باشند.
--   ۳) زمان: `now()` ابتدای تراکنش است، پس «نخستین/آخرین شکست» با آن قابل
--      تفکیک نیست؛ `clock_timestamp()` و بازنویسی‌نشدن `first_failed_at` سنجیده می‌شود.
--   ۴) دیده‌شدن: `sys.health_report` باید اعداد دقیق همین جدول را بدهد.
--   ۵) اولویت صف 0018 باید با یک ردیف هم برقرار بماند و هرس/حذفی در کار نباشد.
--   ۶) بازگشت داده: ردیف‌های per-slot قدیمی (وضعیت 0017) به یک ردیف جمع می‌شوند و
--      هیچ پیش‌فرضی روی `failures`/`first_failed_at` نمی‌ماند.
-- همه‌چیز در یک تراکنش است و با rollback پاک می‌شود.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

insert into iam.users (id, mobile, full_name, status, password_hash) values
  ('75000000-0000-0000-0000-000000000001', '09120000121', 'سرپرست انبار آزمون شکست', 'active', 'fixture-hash-0121'),
  ('75000000-0000-0000-0000-000000000002', '09120000122', 'کارشناس فروش آزمون شکست', 'active', 'fixture-hash-0122'),
  ('75000000-0000-0000-0000-000000000003', '09120000123', 'مدیر سیستم آزمون شکست', 'active', 'fixture-hash-0123'),
  -- کاربر معتبر بدون هیچ نقشی: برای سنجش مجوز خواندن گزارش
  ('75000000-0000-0000-0000-000000000004', '09120000124', 'کاربر بدون نقش آزمون شکست', 'active', 'fixture-hash-0124');

insert into iam.user_roles (user_id, role_id)
select '75000000-0000-0000-0000-000000000001'::uuid, id from iam.roles where key = 'R-WH';
insert into iam.user_roles (user_id, role_id)
select '75000000-0000-0000-0000-000000000002'::uuid, id from iam.roles where key = 'R-SALES';
insert into iam.user_roles (user_id, role_id)
select '75000000-0000-0000-0000-000000000003'::uuid, id from iam.roles where key = 'R-SYS';

insert into cat.brands (id, slug, title) values
  ('b8000000-0000-0000-0000-000000000001', 'fail-brand', 'برند آزمون شکست');
insert into cat.products (id, slug, title, brand_id, status, published_at) values
  ('a8000000-0000-0000-0000-000000000001', 'fail-product', 'محصول آزمون شکست',
   'b8000000-0000-0000-0000-000000000001', 'published', now());
insert into cat.variants (id, product_id, sku) values
  ('e8000000-0000-0000-0000-000000000001', 'a8000000-0000-0000-0000-000000000001', 'FAIL-SKU-A'),
  ('e8000000-0000-0000-0000-000000000002', 'a8000000-0000-0000-0000-000000000001', 'FAIL-SKU-B');
insert into inv.warehouses (id, code, title) values
  ('98000000-0000-0000-0000-000000000001', 'FAIL-WH', 'انبار آزمون شکست');

do $$
declare
  v_wh_user uuid := '75000000-0000-0000-0000-000000000001';
  v_wh      uuid := '98000000-0000-0000-0000-000000000001';
begin
  perform inv.apply_movement(v_wh_user, v_wh, 'e8000000-0000-0000-0000-000000000001'::uuid,
                             20, 'grn', 'grn', gen_random_uuid(), 'موجودی پایه آزمون شکست');
  perform inv.apply_movement(v_wh_user, v_wh, 'e8000000-0000-0000-0000-000000000002'::uuid,
                             20, 'grn', 'grn', gen_random_uuid(), 'موجودی پایه آزمون شکست');
end $$;

do $$
declare
  v_sales   uuid := '75000000-0000-0000-0000-000000000002';
  v_admin   uuid := '75000000-0000-0000-0000-000000000003';
  v_norole  uuid := '75000000-0000-0000-0000-000000000004';
  v_wh      uuid := '98000000-0000-0000-0000-000000000001';
  v_a       uuid := 'e8000000-0000-0000-0000-000000000001';
  v_b       uuid := 'e8000000-0000-0000-0000-000000000002';
  v_slot    timestamptz := '2026-12-02 08:00:00+00';
  v_n       integer;
  v_cnt     integer;
  v_idx     integer;
  v_plan    text := '';
  v_line    text;
  v_shape   text;
  v_exec    text := 'n/a';
  v_loops   integer;
  v_fl      bigint;
  v_last_run bigint;
  v_first   timestamptz;
  v_last    timestamptz;
  v_first2  timestamptz;
  v_last2   timestamptz;
  v_first_saved    timestamptz;
  v_occurred_saved timestamptz;
  v_total   integer;
  v_open    integer;
  v_max     integer;
  v_oldest  timestamptz;
  v_row     jsonb;
  v_report  jsonb;
  v_run     record;
  v_bf_rows integer;
  v_bf_fail integer;
  v_bf_run  bigint;
  v_bf_1    bigint;
  v_bf_2    bigint;
  v_bf_3    bigint;
  v_bf_sql  text;
  v_bf_msg  text;
  v_bf_from timestamptz;
  v_bf_to   timestamptz;
  r_legacy  uuid;
  r_broken  uuid;
  r_healed  uuid;
  r_other   uuid;
  r_healthy uuid;
  i         integer;
begin
  -- ۱) ------------------- کد بیمصرف: هیچ اثری از سقف، هرس و FCO-1079
  select count(*) into v_n from pg_proc where prosrc like '%failure_keep%';
  if v_n <> 0 then
    raise exception 'FAIL ABSENT: % تابع تنظیم failure_keep را می‌خواند', v_n;
  end if;
  select count(*) into v_n from pg_proc where prosrc like '%FCO-1079%';
  if v_n <> 0 then
    raise exception 'FAIL ABSENT: کد خطای بی‌مصرف FCO-1079 در % تابع مانده است', v_n;
  end if;
  select count(*) into v_n from sys.settings where key = 'job.reservation_expiry.failure_keep';
  if v_n <> 0 then
    raise exception 'FAIL ABSENT: تنظیم بازنشسته failure_keep در sys.settings مانده است';
  end if;
  select count(*) into v_n from sys.setting_versions where key = 'job.reservation_expiry.failure_keep';
  if v_n <> 0 then
    raise exception 'FAIL ABSENT: تاریخچه تنظیم failure_keep مانده است';
  end if;
  raise notice 'PASS ABSENT | نه سقف نگهداشت، نه FCO-1079 و نه تنظیم بازنشسته: همه در ادغام حذف شدند';

  -- ۲) --------------------------------- یکتایی: یک ردیف برای هر رزرو
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

  -- ۳) ------- بازگشت داده: ردیف‌های per-slot قدیمی به یک ردیف جمع می‌شوند
  -- وضعیت پیش از 0019 بازسازی می‌شود: ایندکس یکتا (همان قید «یک ردیف برای هر
  -- رزرو») در همین تراکنش موقتاً برداشته می‌شود، برای یک رزرو سه ردیف per-slot
  -- درج می‌شود و بعد همان دو گزاره‌ای اجرا می‌شود که Migration برای جمع‌کردن
  -- دارد. اگر آن بلوک در Migration عوض شود، این گام هم باید عوض شود.
  drop index inv.reservation_expiry_failures_reservation_uidx;

  r_legacy := 'db000000-0000-0000-0000-000000000001';
  insert into inv.reservations
    (id, warehouse_id, variant_id, order_line_id, quantity, status, expires_at, created_at)
  values (r_legacy, v_wh, v_a, gen_random_uuid(), 1, 'active',
          now() - interval '5 minutes', now() - interval '10 minutes');

  v_bf_1 := sys.job_begin('reservation_expiry', date_trunc('hour', now()) - interval '3 hours');
  v_bf_2 := sys.job_begin('reservation_expiry', date_trunc('hour', now()) - interval '2 hours');
  v_bf_3 := sys.job_begin('reservation_expiry', date_trunc('hour', now()) - interval '1 hour');
  -- مقدار `failures`/`first_failed_at` دقیقاً همان است که `add column … default`
  -- پیش از 0019 روی ردیف‌های قدیمی می‌گذاشت (یک و لحظه Migration)؛ جمع‌کردن باید
  -- هر دو را با داده واقعی جایگزین کند.
  insert into inv.reservation_expiry_failures
    (run_id, reservation_id, error_sqlstate, message, failures, first_failed_at, occurred_at)
  values (v_bf_1, r_legacy, '23514', 'قدیمی', 1, now(), now() - interval '3 hours'),
         (v_bf_2, r_legacy, '23505', 'میانی', 1, now(), now() - interval '2 hours'),
         (v_bf_3, r_legacy, 'XX000', 'جدید',  1, now(), now() - interval '1 hour');

  update inv.reservation_expiry_failures f
     set failures       = s.total,
         first_failed_at = s.first_at
    from (select reservation_id,
                 count(*)::integer as total,
                 min(occurred_at)  as first_at
            from inv.reservation_expiry_failures
           group by reservation_id) s
   where f.reservation_id = s.reservation_id;

  delete from inv.reservation_expiry_failures
   where id in (
     select ranked.id
       from (select id,
                    row_number() over (partition by reservation_id
                                           order by occurred_at desc, id desc) as rn
               from inv.reservation_expiry_failures) ranked
      where ranked.rn > 1);

  select count(*) into v_bf_rows
    from inv.reservation_expiry_failures where reservation_id = r_legacy;
  if v_bf_rows <> 1 then
    raise exception 'FAIL BACKFILL: % ردیف برای یک رزرو ماند (انتظار ۱)', v_bf_rows;
  end if;

  select failures, error_sqlstate, message, run_id, first_failed_at, occurred_at
    into v_bf_fail, v_bf_sql, v_bf_msg, v_bf_run, v_bf_from, v_bf_to
    from inv.reservation_expiry_failures where reservation_id = r_legacy;
  if v_bf_fail <> 3 then
    raise exception 'FAIL BACKFILL: failures=% (انتظار ۳ ردیف قبلی)', v_bf_fail;
  end if;
  if v_bf_sql <> 'XX000' or v_bf_msg <> 'جدید' or v_bf_run <> v_bf_3 then
    raise exception 'FAIL BACKFILL: ردیف جدیدترین نماند (sqlstate=% message=% run_id=%، انتظار %/جدید/%)',
      v_bf_sql, v_bf_msg, v_bf_run, 'XX000', v_bf_3;
  end if;
  -- تاریخ‌ها از ردیف‌های seed می‌آیند، پس با بازه سنجیده می‌شوند (now() این جمله
  -- با now() زمان درج یکی نیست).
  if not (v_bf_from between now() - interval '3 hours 5 minutes'
                        and now() - interval '3 hours' + interval '5 minutes') then
    raise exception 'FAIL BACKFILL: نخستین شکست قدیمی‌ترین ردیف نیست (%)', v_bf_from;
  end if;
  if not (v_bf_to between now() - interval '1 hour 5 minutes'
                      and now() - interval '1 hour' + interval '5 minutes') then
    raise exception 'FAIL BACKFILL: آخرین شکست جدیدترین ردیف نیست (%)', v_bf_to;
  end if;

  create unique index reservation_expiry_failures_reservation_uidx
    on inv.reservation_expiry_failures (reservation_id);
  raise notice 'PASS BACKFILL | ۳ ردیف per-slot ⇒ ۱ ردیف با failures=3، پیام/run_id جدیدترین و first_failed_at قدیمی‌ترین';

  -- ۴) --- پیش‌فرضی روی ستون‌ها نمانده: درج ناقص باید صریحاً بشکند
  select count(*) into v_n
    from information_schema.columns
   where table_schema = 'inv' and table_name = 'reservation_expiry_failures'
     and column_name in ('failures', 'first_failed_at')
     and column_default is not null;
  if v_n <> 0 then
    raise exception 'FAIL DEFAULT: % ستون پیش‌فرض دارد (پیش‌فرض پیش از 0019 بازگشته است)', v_n;
  end if;
  begin
    insert into inv.reservation_expiry_failures
      (run_id, reservation_id, error_sqlstate, message)
    values (v_bf_run, r_legacy, 'XX000', 'بدون ستون‌ها');
    raise exception 'FAIL DEFAULT: درج بدون failures/first_failed_at پذیرفته شد';
  exception when not_null_violation then
    null;
  end;
  raise notice 'PASS DEFAULT | ستون‌ها پیش‌فرض ندارند و درج ناقص با not_null_violation رد می‌شود';

  -- شاهد بازگشت داده پاک می‌شود تا شمارش‌های گام‌های بعدی دست‌نخورده بمانند.
  delete from inv.reservation_expiry_failures where reservation_id = r_legacy;
  delete from inv.reservations where id = r_legacy;

  -- ۵) --------- یک رزرو شکست می‌خورد و رفع می‌شود (برای تفکیک open از کل)
  r_healed := inv.reserve(v_sales, 'd8000000-0000-0000-0000-000000000003', v_wh, v_a, 2, 30);
  update inv.reservations set created_at = now() - interval '40 minutes',
                              expires_at = now() - interval '20 minutes'
   where id = r_healed;
  update inv.stock_balance set reserved = 0 where warehouse_id = v_wh and variant_id = v_a;

  select * into v_run from inv.expire_reservations(v_admin, v_slot - interval '2 hours', 1);
  if v_run.outcome <> 'ran' or v_run.failed <> 1 then
    raise exception 'FAIL SEED: رزرو رفع‌شدنی شکست نخورد (%/%/%)',
      v_run.outcome, v_run.expired, v_run.failed;
  end if;

  update inv.stock_balance set reserved = 2 where warehouse_id = v_wh and variant_id = v_a;
  select * into v_run from inv.expire_reservations(v_admin, v_slot - interval '1 hour', 1);
  if v_run.outcome <> 'ran' or v_run.expired <> 1 or v_run.failed <> 0 then
    raise exception 'FAIL SEED: رزرو رفع‌شده آزاد نشد (%/%/%)',
      v_run.outcome, v_run.expired, v_run.failed;
  end if;

  -- ۶) ------------------- ۲۷ slot پیوسته ⇒ یک ردیف با شمارنده ۲۷
  r_broken := inv.reserve(v_sales, 'd8000000-0000-0000-0000-000000000001', v_wh, v_b, 3, 30);
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

    select first_failed_at, occurred_at, failures into v_first2, v_last2, v_cnt
      from inv.reservation_expiry_failures where reservation_id = r_broken;

    -- شمارنده باید هر slot یکی بالا برود (نه یک‌بار در کل).
    if v_cnt <> i then
      raise exception 'FAIL SINGLE: شمارنده شکست در دور % برابر % است (انتظار %)', i, v_cnt, i;
    end if;

    if i = 1 then
      v_first := v_first2;
    else
      if v_first2 <> v_first then
        raise exception 'FAIL SINGLE: تاریخ نخستین شکست در دور % بازنویسی شد (% ⇒ %)', i, v_first, v_first2;
      end if;
      if v_last2 <= v_last then
        raise exception 'FAIL SINGLE: زمان آخرین شکست در دور % جلو نرفت (% ⇒ %)', i, v_last, v_last2;
      end if;
    end if;
    v_last := v_last2;
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
  select run_id into v_fl from inv.reservation_expiry_failures where reservation_id = r_broken;
  if v_fl <> v_last_run then
    raise exception 'FAIL SINGLE: run_id=% (انتظار آخرین دور %)', v_fl, v_last_run;
  end if;
  if v_first >= v_last then
    raise exception 'FAIL SINGLE: نخستین و آخرین شکست از هم تفکیک نشدند (first=% last=%)',
      v_first, v_last;
  end if;
  v_first_saved := v_first;
  v_occurred_saved := v_last;
  raise notice 'PASS SINGLE | ۲۷ slot ⇒ ۱ ردیف با failures=27؛ نخستین شکست % و آخرین شکست % دو لحظه جدا هستند',
    v_first_saved, v_occurred_saved;

  -- ۷) ----------------- دامنه: ردیف رزرو دیگر دست‌نخورده، هرسی در کار نیست
  r_other := inv.reserve(v_sales, 'd8000000-0000-0000-0000-000000000002', v_wh, v_a, 2, 600);
  insert into inv.reservation_expiry_failures
    (run_id, reservation_id, error_sqlstate, message, failures, first_failed_at, occurred_at)
  values (v_last_run, r_other, '23514', 'ردیف آزمون دامنه', 9,
          now() - interval '2 hours', now() - interval '1 hour');
  select occurred_at into v_last2 from inv.reservation_expiry_failures where reservation_id = r_other;

  select * into v_run from inv.expire_reservations(v_admin, v_slot + interval '30 hours', 1);
  if v_run.outcome <> 'ran' or v_run.failed <> 1 then
    raise exception 'FAIL SCOPE: %/% (انتظار ran/1)', v_run.outcome, v_run.failed;
  end if;
  select failures, occurred_at into v_cnt, v_first2
    from inv.reservation_expiry_failures where reservation_id = r_other;
  if v_cnt <> 9 or v_first2 <> v_last2 then
    raise exception 'FAIL SCOPE: ردیف رزرو دیگر تغییر کرد (failures=% occurred_at=%)', v_cnt, v_first2;
  end if;
  select failures, first_failed_at, occurred_at into v_cnt, v_first2, v_last2
    from inv.reservation_expiry_failures where reservation_id = r_broken;
  if v_cnt <> 28 then
    raise exception 'FAIL SCOPE: شمارنده رزرو خراب % است (انتظار ۲۸)', v_cnt;
  end if;
  -- «نگهداشتن تاریخ نخستین»: شکست تازه نباید first_failed_at را بازنویسی کند.
  if v_first2 <> v_first_saved then
    raise exception 'FAIL SCOPE: تاریخ نخستین شکست بازنویسی شد (% ⇒ %)', v_first_saved, v_first2;
  end if;
  if v_last2 <= v_occurred_saved then
    raise exception 'FAIL SCOPE: زمان آخرین شکست جلو نرفت (% ⇒ %)', v_occurred_saved, v_last2;
  end if;
  v_last := v_last2;
  raise notice 'PASS SCOPE | شکست تازه first_failed_at را دست نزد، occurred_at جلو رفت و ردیف رزرو دیگر لمس نشد';

  -- ۸) ------------------------------- اولویت صف 0018 با یک ردیف هم برقرار است
  r_healthy := inv.reserve(v_sales, 'd8000000-0000-0000-0000-000000000004', v_wh, v_a, 1, 600);
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

  -- ۹) ------------------- گزارش رصد: اعداد دقیقاً از همین جدول
  select count(*) into v_total from inv.reservation_expiry_failures;
  select count(*) into v_open
    from inv.reservation_expiry_failures f
    join inv.reservations r on r.id = f.reservation_id
   where r.status = 'active';
  select max(f.failures), min(f.first_failed_at) into v_max, v_oldest
    from inv.reservation_expiry_failures f;

  if v_total <> 3 or v_open <> 2 or v_max <> 28 then
    raise exception 'FAIL HEALTH: داده آزمون نامنتظر است (total=% open=% max=%)',
      v_total, v_open, v_max;
  end if;

  v_report := sys.health_report(v_admin);
  if v_report -> 'reservations' is null then
    raise exception 'FAIL HEALTH: بخش reservations در گزارش نیست: %', v_report;
  end if;
  if v_report -> 'reservations' ? 'max_failures' then
    raise exception 'FAIL HEALTH: کلید تکراری max_failures حذف نشده است: %',
      v_report -> 'reservations';
  end if;

  if (v_report -> 'reservations' ->> 'expiry_failures')::integer <> v_total then
    raise exception 'FAIL HEALTH: expiry_failures=% (انتظار %)',
      v_report -> 'reservations' ->> 'expiry_failures', v_total;
  end if;
  if (v_report -> 'reservations' ->> 'expiry_failures_open')::integer <> v_open then
    raise exception 'FAIL HEALTH: expiry_failures_open=% (انتظار %) — رزرو رفع‌شده نباید open شمرده شود',
      v_report -> 'reservations' ->> 'expiry_failures_open', v_open;
  end if;
  if (v_report -> 'reservations' ->> 'oldest_first_failed_at')::timestamptz <> v_oldest then
    raise exception 'FAIL HEALTH: oldest_first_failed_at=% (انتظار %)',
      v_report -> 'reservations' ->> 'oldest_first_failed_at', v_oldest;
  end if;

  select e into v_row
    from jsonb_array_elements(v_report -> 'reservations' -> 'top_failures') e
   where e ->> 'reservation_id' = r_broken::text;
  if v_row is null then
    raise exception 'FAIL HEALTH: رزرو شکست‌خورده در top_failures نیست: %',
      v_report -> 'reservations' -> 'top_failures';
  end if;
  if (v_row ->> 'failures')::integer <> 28 then
    raise exception 'FAIL HEALTH: failures در فهرست % است (انتظار ۲۸)', v_row ->> 'failures';
  end if;
  if v_row ->> 'status' <> 'active' then
    raise exception 'FAIL HEALTH: وضعیت رزرو در فهرست % است (انتظار active)', v_row ->> 'status';
  end if;
  if v_row ->> 'error_sqlstate' <> '23514' then
    raise exception 'FAIL HEALTH: sqlstate در فهرست % است (انتظار 23514)', v_row ->> 'error_sqlstate';
  end if;
  -- تاریخ‌های گزارش باید همان تاریخ‌های جدول باشند، نه فقط پر شده.
  if (v_row ->> 'first_failed_at')::timestamptz <> v_first_saved then
    raise exception 'FAIL HEALTH: first_failed_at گزارش % است (جدول %)',
      v_row ->> 'first_failed_at', v_first_saved;
  end if;
  if (v_row ->> 'occurred_at')::timestamptz <> v_last then
    raise exception 'FAIL HEALTH: occurred_at گزارش % است (جدول %)',
      v_row ->> 'occurred_at', v_last;
  end if;

  -- رزرو رفع‌شده با وضعیت خودش در فهرست می‌ماند، ولی open شمرده نمی‌شود.
  select count(*) into v_cnt
    from jsonb_array_elements(v_report -> 'reservations' -> 'top_failures') e
   where e ->> 'reservation_id' = r_healed::text
     and e ->> 'status' = 'released';
  if v_cnt <> 1 then
    raise exception 'FAIL HEALTH: رزرو رفع‌شده با status=released در فهرست نیست: %',
      v_report -> 'reservations' -> 'top_failures';
  end if;

  if exists (
    select 1 from jsonb_array_elements(v_report -> 'reservations' -> 'top_failures') e
     where e ->> 'reservation_id' = r_healthy::text
  ) then
    raise exception 'FAIL HEALTH: رزرو سالم در فهرست شکست‌ها آمد';
  end if;

  if (select (e ->> 'failures')::integer
        from jsonb_array_elements(v_report -> 'reservations' -> 'top_failures') e limit 1) <> v_max then
    raise exception 'FAIL HEALTH: فهرست top_failures با بیشترین شکست مرتب نشده است';
  end if;
  raise notice 'PASS HEALTH | کل/باز دقیقاً %/% خوانده شد، بیشینه %، تاریخ‌های گزارش برابر جدول و رزرو رفع‌شده با status=released در فهرست است',
    v_total, v_open, v_max;

  -- ۱۰) ------------------ برنامه اجرایی واقعی در حجم، با تنظیمات پیش‌فرض
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
  -- گزینه‌ها ساخته شود. هر سه شکل زیر پذیرفته‌اند و هر سه یک‌بار (نه به‌ازای هر
  -- ردیف) به جدول خطا می‌رسند.
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

  -- ۱۱) ------------------------------------------- گزارش بدون مجوز خوانده نشود
  begin
    perform sys.health_report(v_norole);
    raise exception 'FAIL PERM: گزارش بدون مجوز خوانده شد';
  exception when insufficient_privilege then
    if sqlerrm not like 'FCO-1003%' then
      raise exception 'FAIL PERM: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS PERM | بدون platform.health.read → %', sqlerrm;
  end;
end $$;

-- --- شاهد نهایی ------------------------------------------------------------
select 'ALL STEP-BR2-3C-FAILURES NEGATIVE CASES PASSED' as result;
rollback;
