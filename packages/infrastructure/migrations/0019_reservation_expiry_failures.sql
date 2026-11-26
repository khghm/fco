-- =============================================================================
-- 0019_reservation_expiry_failures — BR-2: نگهداشت و دیده‌شدن شکست‌های انقضا
-- مالک طرح: docs/Architecture-02/DATABASE_DESIGN.md §3.5
--           docs/Engineering-04/TEST_STRATEGY.md §4.1 (T-INV-07/08/09)
--           docs/Architecture-02/ADR/ADR-010-data-retention.md
--
-- این Migration سه گام بازبینی را در یک تغییر واحد جمع می‌کند (ادغام
-- 0019–0021 پیش از انتشار). ترتیب گام‌ها:
--   ۱) نگهداشت: 0017 برای هر شکست یک ردیف می‌گذاشت، پس رزروی که ساعت‌ها خراب
--      می‌ماند در هر slot یک ردیف اضافه می‌کرد و نگهداشتش فقط به cascade
--      `sys.job_runs` تکیه داشت که هیچ Jobی اجرایش نمی‌کند. راه‌حل هرس نبود؛
--      ساختار داده: یکتایی `reservation_id` ⇒ یک ردیف برای هر رزرو، با درج
--      `on conflict … do update`. پس هیچ `delete`ی در مسیر شکست نیست، دامنه
--      هرس بی‌معنا می‌شود و سقف پیکربندی وجود ندارد. رشد جدول = تعداد
--      رزروهایی که تا امروز شکست خورده‌اند، نه تعداد slotها.
--   ۲) سیگنال: `failures` شمار تلاش‌های ناموفق و `first_failed_at` تاریخ نخستین
--      شکست را نگه می‌دارد؛ ردیف‌های تکراری قبلی در همین Migration به یک ردیف
--      جمع می‌شوند (شمار = تعداد ردیف‌ها، تاریخ نخستین = قدیمی‌ترین).
--   ۳) زمان و دیده‌شدن: زمان شکست با `clock_timestamp()` نوشته می‌شود، نه
--      `now()` که ابتدای تراکنش است (وگرنه همه شکست‌های یک دسته یک لحظه‌اند و
--      «نخستین/آخرین» از هم جدا نمی‌شوند)؛ و `sys.health_report` بخش
--      `reservations` می‌گیرد تا رزروهایی که مکرراً شکست می‌خورند دیده شوند.
--
-- ایندکس: `exists` اولویت صف 0018 با `reservation_id` کار می‌کند؛ ایندکس یکتا
-- هم همان ستون پیشرو را پوشش می‌دهد و هم هدف `on conflict` است. ایندکس
-- `reservation_expiry_failures_run_idx` (0018) برای cascade می‌ماند.
-- =============================================================================

alter table inv.reservation_expiry_failures
  add column failures        integer not null default 1,
  add column first_failed_at timestamptz not null default now();

alter table inv.reservation_expiry_failures
  add constraint reservation_expiry_failures_failures_check check (failures >= 1);

-- ردیف‌های per-slot موجود (اگر 0017 در محیطی اجرا شده باشد) به یک ردیف برای هر
-- رزرو جمع می‌شوند: شمار = تعداد ردیف‌های قبلی، تاریخ نخستین = قدیمی‌ترین، و
-- ردیف جدیدترین (occurred_at/id) می‌ماند تا آخرین run_id و پیام حفظ شود.
with keep as (
  select reservation_id,
         count(*)::integer as total,
         min(occurred_at) as first_at,
         (array_agg(id order by occurred_at desc, id desc))[1] as keep_id
    from inv.reservation_expiry_failures
   group by reservation_id
)
update inv.reservation_expiry_failures f
   set failures = keep.total,
       first_failed_at = keep.first_at
  from keep
 where f.id = keep.keep_id;

delete from inv.reservation_expiry_failures f
 using (
   select reservation_id,
          (array_agg(id order by occurred_at desc, id desc))[1] as keep_id
     from inv.reservation_expiry_failures
    group by reservation_id
 ) d
 where f.reservation_id = d.reservation_id
   and f.id <> d.keep_id;

drop index if exists inv.reservation_expiry_failures_reservation_idx;

create unique index reservation_expiry_failures_reservation_uidx
  on inv.reservation_expiry_failures (reservation_id);

comment on index inv.reservation_expiry_failures_reservation_uidx is
  'یک ردیف برای هر رزرو: کلید exists اولویت صف (0018) و هدف on conflict (0019)';

comment on table inv.reservation_expiry_failures is
  'هر رزروی که Job انقضا نتوانست آزاد کند: یک ردیف با آخرین run_id/sqlstate، شمار شکست‌ها و تاریخ نخستین شکست (T-INV-07/08/09)';
comment on column inv.reservation_expiry_failures.failures is
  'شمار تلاش‌های ناموفق آزادسازی این رزرو (نه تعداد ردیف)';
comment on column inv.reservation_expiry_failures.occurred_at is
  'زمان آخرین شکست';
comment on column inv.reservation_expiry_failures.first_failed_at is
  'زمان نخستین شکست همین رزرو';

-- -----------------------------------------------------------------------------
-- expire_reservations: شکست هر رزرو در یک ردیف upsert
-- -----------------------------------------------------------------------------
create or replace function inv.expire_reservations(
  p_actor uuid,
  p_scheduled_for timestamptz default date_trunc('hour', now()),
  p_limit integer default null
) returns table (outcome text, expired integer, run_id bigint, failed integer)
language plpgsql security definer set search_path = inv, sys, iam, pg_catalog as $$
declare
  v_batch     integer := coalesce(p_limit, sys.setting_int('job.reservation_expiry.batch'));
  v_run       bigint;
  v_count     integer := 0;
  v_failed    integer := 0;
  v_failed_at timestamptz;
  r           record;
begin
  perform iam.authorize(p_actor, 'platform.job.run');

  if v_batch is null or v_batch < 1 or v_batch > 1000 then
    raise exception 'FCO-1077: اندازه دسته باید بین ۱ و ۱۰۰۰ باشد (%)', coalesce(v_batch, -1)
      using errcode = '22023';
  end if;

  v_run := sys.job_begin('reservation_expiry', p_scheduled_for);
  if v_run is null then
    return query select 'already_ran'::text, 0, null::bigint, 0;
    return;
  end if;

  begin
    for r in
      select res.id
        from inv.reservations res
       where res.status = 'active' and res.expires_at <= now()
       -- رزروهای سابقه‌دار به انتهای صف؛ رزرو خرابِ همیشگی نباید دسته را پر کند.
       order by exists (
                  select 1 from inv.reservation_expiry_failures f
                   where f.reservation_id = res.id
                ),
                res.expires_at
       limit v_batch
       for update skip locked
    loop
      begin
        if inv.release(p_actor, r.id, 'expired') then
          v_count := v_count + 1;
        end if;
      exception when others then
        -- زیرتراکنش همین رزرو برگشت خورد؛ ثبت خطا بیرون آن است تا پایدار بماند
        -- و بقیه دسته ادامه یابد. یک ردیف برای هر رزرو، شمار شکست بالا می‌رود.
        v_failed := v_failed + 1;
        -- زمان واقعی شکست، نه `now()` که ابتدای تراکنش است؛ وگرنه همه شکست‌های
        -- یک دسته یک لحظه ثبت می‌شوند و «نخستین/آخرین» از هم جدا نمی‌شوند.
        v_failed_at := clock_timestamp();
        insert into inv.reservation_expiry_failures
          (run_id, reservation_id, error_sqlstate, message, failures, first_failed_at, occurred_at)
        values (v_run, r.id, sqlstate, sqlerrm, 1, v_failed_at, v_failed_at)
        on conflict (reservation_id) do update
           set run_id         = excluded.run_id,
               error_sqlstate = excluded.error_sqlstate,
               message        = excluded.message,
               occurred_at    = v_failed_at,
               failures       = inv.reservation_expiry_failures.failures + 1;
        -- `first_failed_at` عمداً در این فهرست نیست: تاریخ نخستین شکست می‌ماند.
      end;
    end loop;

    perform sys.job_finish(
      v_run, 'succeeded',
      case when v_failed > 0
           then format('%s رزرو آزاد نشد؛ جزئیات در inv.reservation_expiry_failures (run %s)',
                       v_failed, v_run)
      end);
    return query select 'ran'::text, v_count, v_run, v_failed;
  exception when others then
    -- شکست خود Job (نه یک رزرو): ثبت و برگرداندن، مثل 0010 — بدون rollback
    -- رکورد `failed` که سقف تلاش را فعال می‌کند.
    perform sys.job_finish(v_run, 'failed', sqlerrm);
    return query select 'failed'::text, v_count, v_run, v_failed;
  end;
end $$;

comment on function inv.expire_reservations(uuid, timestamptz, integer) is
  'outcome: ran | already_ran | failed؛ شکست هر رزرو در یک ردیف upsert با زمان واقعی و شمار شکست ثبت می‌شود، رزروهای سابقه‌دار آخر صف‌اند';

revoke all on function inv.expire_reservations(uuid, timestamptz, integer) from public;
grant execute on function inv.expire_reservations(uuid, timestamptz, integer) to fco_app;

-- -----------------------------------------------------------------------------
-- health_report: شکست‌های مکرر انقضا در گزارش رصد
-- -----------------------------------------------------------------------------
create or replace function sys.health_report(p_caller uuid)
returns jsonb
language plpgsql stable security definer set search_path = sys, inv, iam, pg_catalog as $$
declare
  v_report jsonb;
  v_cap    integer := sys.setting_int('job.max_attempts');
  v_stuck  integer := sys.setting_int('job.stuck_after_minutes');
begin
  perform iam.authorize(p_caller, 'platform.health.read');

  select jsonb_build_object(
    'generated_at', now(),
    'queue', jsonb_build_object(
      'pending', (select count(*) from sys.outbox o
                   where o.processed_at is null and o.dead_lettered_at is null),
      'oldest_pending_seconds', coalesce((
        select extract(epoch from now() - min(o.occurred_at))::integer
          from sys.outbox o
         where o.processed_at is null and o.dead_lettered_at is null), 0),
      'dead_letter', (select count(*) from sys.outbox o
                       where o.dead_lettered_at is not null)
    ),
    'sessions', jsonb_build_object(
      'active', (select count(*) from iam.sessions s
                  where s.revoked_at is null and s.expires_at > now()),
      'expired', (select count(*) from iam.sessions s
                   where s.expires_at <= now())
    ),
    'users', jsonb_build_object(
      'locked', (select count(*) from iam.users u where u.status = 'locked'),
      'active', (select count(*) from iam.users u
                  where u.status = 'active' and u.archived_at is null)
    ),
    -- رزروهایی که آزادسازی‌شان مکرراً شکست می‌خورد: `open` یعنی موجودی
    -- رزروشده هنوز قفل است و باید داده اصلاح شود.
    'reservations', jsonb_build_object(
      'expiry_failures', (select count(*) from inv.reservation_expiry_failures),
      'expiry_failures_open', (select count(*)
                                 from inv.reservation_expiry_failures f
                                 join inv.reservations r on r.id = f.reservation_id
                                where r.status = 'active'),
      'oldest_first_failed_at', (select min(f.first_failed_at)
                                   from inv.reservation_expiry_failures f),
      'top_failures', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'reservation_id', x.reservation_id,
                 'failures', x.failures,
                 'first_failed_at', x.first_failed_at,
                 'occurred_at', x.occurred_at,
                 'error_sqlstate', x.error_sqlstate,
                 'status', x.status,
                 'warehouse_id', x.warehouse_id,
                 'variant_id', x.variant_id))
          from (select f.reservation_id, f.failures, f.first_failed_at, f.occurred_at,
                       f.error_sqlstate, r.status, r.warehouse_id, r.variant_id
                  from inv.reservation_expiry_failures f
                  join inv.reservations r on r.id = f.reservation_id
                 order by f.failures desc, f.occurred_at asc
                 limit 10) x), '[]'::jsonb)
    ),
    'jobs', jsonb_build_object(
      'failed_24h', (select count(*) from sys.job_runs j
                      where j.status = 'failed' and j.started_at > now() - interval '24 hours'),
      'running', (select count(*) from sys.job_runs j where j.finished_at is null),
      'stuck', (select count(*) from sys.job_runs j
                 where j.finished_at is null
                   and j.started_at < now() - make_interval(mins => v_stuck)),
      'stuck_runs', coalesce((
        select jsonb_agg(jsonb_build_object(
                 'job_name', x.job_name,
                 'scheduled_for', x.scheduled_for,
                 'attempt', x.attempt,
                 'started_at', x.started_at))
          from (select j.job_name, j.scheduled_for, j.attempt, j.started_at
                  from sys.job_runs j
                 where j.finished_at is null
                   and j.started_at < now() - make_interval(mins => v_stuck)
                 order by j.started_at
                 limit 10) x), '[]'::jsonb),
      'exhausted_24h', (select count(*) from sys.job_runs j
                         where j.status = 'failed'
                           and j.attempt >= v_cap
                           and j.started_at > now() - interval '24 hours')
    ),
    'schema_migrations', (select count(*) from sys.schema_migrations)
  ) into v_report;

  return v_report;
end $$;

comment on function sys.health_report(uuid) is
  'گزارش JSON رصد؛ صف، نشست، Jobهای گیرکرده و رزروهایی که مکرراً در انقضا شکست می‌خورند (reservations.expiry_failures)';
