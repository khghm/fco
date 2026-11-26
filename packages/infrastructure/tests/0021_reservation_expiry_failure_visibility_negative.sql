-- =============================================================================
-- 0021_reservation_expiry_failure_visibility_negative — BR-2 (دیده‌شدن شکست‌ها)
-- مالک انتظارها: docs/Engineering-04/TEST_STRATEGY.md §4.1 (T-INV-08)
--
-- اجرا:
--   docker exec -i fco-postgres psql -U fco -d fco -v ON_ERROR_STOP=1 -f - \
--     < packages/infrastructure/tests/0021_reservation_expiry_failure_visibility_negative.sql
--
-- شکاف مورد آزمون:
--   ۱) `first_failed_at`/`occurred_at` با `now()` نوشته می‌شدند؛ `now()` ابتدای
--      تراکنش است، پس سه slot پیوسته یک لحظه می‌گرفتند و «نگه‌داشتن تاریخ
--      نخستین شکست» قابل سنجش نبود. حالا `clock_timestamp()` زمان واقعی است و
--      این سوئیت نشان می‌دهد نخستین می‌ماند و آخرین جلو می‌رود.
--   ۲) رزروهایی که مکرراً در انقضا شکست می‌خورند هیچ‌جا دیده نمی‌شدند.
--      `sys.health_report` بخش `reservations` را دارد.
--
-- پوشش: سه slot با سه لحظه واقعی (نخستین ثابت، آخرین صعودی، failures=3)؛
--       گزارش رصد شامل شمار/بیشینه/قدیمی‌ترین و فهرست ده رزرو بدتر با
--       `status` و `sqlstate`؛ نبودن رزرو سالم در فهرست؛ مرتب‌بودن فهرست؛
--       و رد شدن خواندن گزارش بدون `platform.health.read`.
-- همه‌چیز در یک تراکنش است و با rollback پاک می‌شود.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

insert into iam.users (id, mobile, full_name, status, password_hash) values
  ('74000000-0000-0000-0000-000000000001', '09120000111', 'سرپرست انبار آزمون دید', 'active', 'fixture-hash-0111'),
  ('74000000-0000-0000-0000-000000000002', '09120000112', 'کارشناس فروش آزمون دید', 'active', 'fixture-hash-0112'),
  ('74000000-0000-0000-0000-000000000003', '09120000113', 'مدیر سیستم آزمون دید', 'active', 'fixture-hash-0113'),
  -- کاربر معتبر بدون هیچ نقشی: برای سنجش مجوز خواندن گزارش
  ('74000000-0000-0000-0000-000000000004', '09120000114', 'کاربر بدون نقش آزمون دید', 'active', 'fixture-hash-0114');

insert into iam.user_roles (user_id, role_id)
select '74000000-0000-0000-0000-000000000001'::uuid, id from iam.roles where key = 'R-WH';
insert into iam.user_roles (user_id, role_id)
select '74000000-0000-0000-0000-000000000002'::uuid, id from iam.roles where key = 'R-SALES';
insert into iam.user_roles (user_id, role_id)
select '74000000-0000-0000-0000-000000000003'::uuid, id from iam.roles where key = 'R-SYS';

insert into cat.brands (id, slug, title) values
  ('b7000000-0000-0000-0000-000000000001', 'see-brand', 'برند آزمون دید');
insert into cat.products (id, slug, title, brand_id, status, published_at) values
  ('a7000000-0000-0000-0000-000000000001', 'see-product', 'محصول آزمون دید',
   'b7000000-0000-0000-0000-000000000001', 'published', now());
insert into cat.variants (id, product_id, sku) values
  ('e7000000-0000-0000-0000-000000000001', 'a7000000-0000-0000-0000-000000000001', 'SEE-SKU-A'),
  ('e7000000-0000-0000-0000-000000000002', 'a7000000-0000-0000-0000-000000000001', 'SEE-SKU-B');
insert into inv.warehouses (id, code, title) values
  ('97000000-0000-0000-0000-000000000001', 'SEE-WH', 'انبار آزمون دید');

do $$
declare
  v_wh_user uuid := '74000000-0000-0000-0000-000000000001';
  v_wh      uuid := '97000000-0000-0000-0000-000000000001';
begin
  perform inv.apply_movement(v_wh_user, v_wh, 'e7000000-0000-0000-0000-000000000001'::uuid,
                             20, 'grn', 'grn', gen_random_uuid(), 'موجودی پایه آزمون دید');
  perform inv.apply_movement(v_wh_user, v_wh, 'e7000000-0000-0000-0000-000000000002'::uuid,
                             20, 'grn', 'grn', gen_random_uuid(), 'موجودی پایه آزمون دید');
end $$;

do $$
declare
  v_sales   uuid := '74000000-0000-0000-0000-000000000002';
  v_admin   uuid := '74000000-0000-0000-0000-000000000003';
  v_wh      uuid := '97000000-0000-0000-0000-000000000001';
  v_a       uuid := 'e7000000-0000-0000-0000-000000000001';
  v_b       uuid := 'e7000000-0000-0000-0000-000000000002';
  v_slot    timestamptz := '2026-12-01 08:00:00+00';
  v_run     record;
  v_report  jsonb;
  v_row     jsonb;
  v_first   timestamptz;
  v_last    timestamptz;
  v_first2  timestamptz;
  v_last2   timestamptz;
  v_cnt     integer;
  v_total   integer;
  v_open    integer;
  v_max     integer;
  v_oldest  timestamptz;
  r_broken  uuid;
  r_healed  uuid;
  r_healthy uuid;
  i         integer;
begin
  -- یک رزرو که شکست می‌خورد و بعد داده‌اش رفع می‌شود: ردیفش می‌ماند ولی دیگر
  -- `open` نیست؛ همین ردیف است که «شمار کل» را از «باز» تفکیک می‌کند.
  r_healed := inv.reserve(v_sales, 'd7000000-0000-0000-0000-000000000003', v_wh, v_a, 2, 30);
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

  r_broken := inv.reserve(v_sales, 'd7000000-0000-0000-0000-000000000001', v_wh, v_b, 3, 30);
  update inv.reservations set created_at = now() - interval '30 minutes',
                              expires_at = now() - interval '10 minutes'
   where id = r_broken;
  -- رزرو می‌ماند ولی reserved صفر است ⇒ آزادسازی با check (reserved >= 0) می‌شکند
  update inv.stock_balance set reserved = 0 where warehouse_id = v_wh and variant_id = v_b;

  -- ۱) --------------------------------- سه slot، سه لحظه واقعی
  for i in 1 .. 3 loop
    select * into v_run from inv.expire_reservations(v_admin, v_slot + (i - 1) * interval '1 hour', 1);
    if v_run.outcome <> 'ran' or v_run.expired <> 0 or v_run.failed <> 1 then
      raise exception 'FAIL TIME: دور % ⇒ %/%/% (انتظار ran/0/1)',
        i, v_run.outcome, v_run.expired, v_run.failed;
    end if;

    select first_failed_at, occurred_at into v_first2, v_last2
      from inv.reservation_expiry_failures where reservation_id = r_broken;

    if i = 1 then
      v_first := v_first2;
    else
      if v_first2 <> v_first then
        raise exception 'FAIL TIME: تاریخ نخستین شکست در دور % بازنویسی شد (% ⇒ %)', i, v_first, v_first2;
      end if;
      if v_last2 <= v_last then
        raise exception 'FAIL TIME: زمان آخرین شکست در دور % جلو نرفت (% ⇒ %)', i, v_last, v_last2;
      end if;
    end if;
    v_last := v_last2;
  end loop;

  if v_first >= v_last then
    raise exception 'FAIL TIME: نخستین و آخرین شکست یک لحظه‌اند (first=% last=%)', v_first, v_last;
  end if;

  select failures into v_cnt from inv.reservation_expiry_failures where reservation_id = r_broken;
  if v_cnt <> 3 then
    raise exception 'FAIL TIME: failures=% (انتظار ۳)', v_cnt;
  end if;
  raise notice 'PASS TIME | سه slot ⇒ نخستین شکست % ماند و آخرین شکست % جلو رفت (failures=3)', v_first, v_last;

  -- ۲) ------------------------------------ گزارش رصد: رزروهای مکرراً خراب
  r_healthy := inv.reserve(v_sales, 'd7000000-0000-0000-0000-000000000002', v_wh, v_a, 1, 600);

  -- انتظارها از خود جدول خوانده می‌شوند تا مقایسه دقیق باشد، نه «بزرگ‌تر از صفر».
  select count(*) into v_total from inv.reservation_expiry_failures;
  select count(*) into v_open
    from inv.reservation_expiry_failures f
    join inv.reservations r on r.id = f.reservation_id
   where r.status = 'active';
  select max(f.failures), min(f.first_failed_at) into v_max, v_oldest
    from inv.reservation_expiry_failures f;

  if v_total <> 2 or v_open <> 1 or v_max <> 3 then
    raise exception 'FAIL HEALTH: داده آزمون نامنتظر است (total=% open=% max=%)',
      v_total, v_open, v_max;
  end if;

  v_report := sys.health_report(v_admin);
  if v_report -> 'reservations' is null then
    raise exception 'FAIL HEALTH: بخش reservations در گزارش نیست: %', v_report;
  end if;

  if (v_report -> 'reservations' ->> 'expiry_failures')::integer <> v_total then
    raise exception 'FAIL HEALTH: expiry_failures=% (انتظار %)',
      v_report -> 'reservations' ->> 'expiry_failures', v_total;
  end if;

  if (v_report -> 'reservations' ->> 'expiry_failures_open')::integer <> v_open then
    raise exception 'FAIL HEALTH: expiry_failures_open=% (انتظار %) — رزرو رفع‌شده نباید open شمرده شود',
      v_report -> 'reservations' ->> 'expiry_failures_open', v_open;
  end if;

  if (v_report -> 'reservations' ->> 'max_failures')::integer <> v_max then
    raise exception 'FAIL HEALTH: max_failures=% (انتظار %)',
      v_report -> 'reservations' ->> 'max_failures', v_max;
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
  if (v_row ->> 'failures')::integer <> 3 then
    raise exception 'FAIL HEALTH: failures در فهرست % است (انتظار ۳)', v_row ->> 'failures';
  end if;
  if v_row ->> 'status' <> 'active' then
    raise exception 'FAIL HEALTH: وضعیت رزرو در فهرست % است (انتظار active)', v_row ->> 'status';
  end if;
  if v_row ->> 'error_sqlstate' <> '23514' then
    raise exception 'FAIL HEALTH: sqlstate در فهرست % است (انتظار 23514)', v_row ->> 'error_sqlstate';
  end if;
  -- تاریخ‌های گزارش باید همان تاریخ‌های جدول باشند، نه فقط پر شده.
  if (v_row ->> 'first_failed_at')::timestamptz <> v_first then
    raise exception 'FAIL HEALTH: first_failed_at گزارش % است (جدول %)',
      v_row ->> 'first_failed_at', v_first;
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
  raise notice 'PASS HEALTH | کل/باز/بیشینه دقیقاً %/%/% خوانده شد، تاریخ‌های گزارش برابر جدول‌اند و رزرو رفع‌شده با status=released در فهرست است',
    v_total, v_open, v_max;

  -- ۳) ------------------------------------------- گزارش بدون مجوز خوانده نشود
  begin
    perform sys.health_report('74000000-0000-0000-0000-000000000004'::uuid);
    raise exception 'FAIL PERM: گزارش بدون مجوز خوانده شد';
  exception when insufficient_privilege then
    if sqlerrm not like 'FCO-1003%' then
      raise exception 'FAIL PERM: کد خطای نامنتظر: %', sqlerrm;
    end if;
    raise notice 'PASS PERM | بدون platform.health.read → %', sqlerrm;
  end;
end $$;

-- --- شاهد نهایی ------------------------------------------------------------
select 'ALL STEP-BR2-3C-VISIBILITY NEGATIVE CASES PASSED' as result;
rollback;
