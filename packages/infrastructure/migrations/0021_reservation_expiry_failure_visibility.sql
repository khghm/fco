-- =============================================================================
-- 0021_reservation_expiry_failure_visibility — BR-2: شکست‌های مکرر انقضا دیده شوند
-- مالک طرح: docs/Architecture-02/DATABASE_DESIGN.md §3.5 و §۳.۹
--           docs/Engineering-04/TEST_STRATEGY.md §4.1 (T-INV-08، T-OPS)
--           docs/Engineering-04/OBSERVABILITY_PLAN.md (برنامه‌ریزی‌شده)
--
-- دو شکاف دیده‌شدن (observability) که بازبینی 0020 نشان داد:
--   ۱) `first_failed_at` و `occurred_at` با `now()` نوشته می‌شدند. `now()`
--      زمانِ ابتدای تراکنش است، پس در یک اجرای Job همه شکست‌ها (و حتی شکست‌های
--      پشت‌سرهم یک دسته طولانی) یک لحظه ثبت می‌شدند: «نخستین شکست» و «آخرین
--      شکست» از هم قابل تفکیک نبود و آزمون هم فقط می‌توانست `<=` را بسنجد —
--      یعنی بررسی‌اش تشریفاتی بود. حالا `clock_timestamp()` زمان واقعی شکست
--      را می‌نویسد و «نخستین» در `on conflict` بازنویسی نمی‌شود.
--   ۲) هیچ‌جا دیده نمی‌شد کدام رزروها مکرراً در انقضا شکست می‌خورند؛ تنها اثرشان
--      یک یادداشت شمارشی روی `sys.job_runs.error` بود. `sys.health_report` حالا
--      بخش `reservations.expiry_failures` را دارد: شمار رزروهای خراب، شمار
--      رزروهایی که هنوز `active` هستند (یعنی موجودی رزروشده قفل مانده)، بیشترین
--      شمار شکست، قدیمی‌ترین تاریخ نخستین شکست و ۱۰ رزرو بدترین.
-- =============================================================================

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
  'outcome: ran | already_ran | failed؛ شکست هر رزرو در یک ردیف upsert با زمان واقعی (clock_timestamp) و شمار شکست ثبت می‌شود، رزروهای سابقه‌دار آخر صف‌اند';

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
      'max_failures', coalesce((select max(f.failures)
                                  from inv.reservation_expiry_failures f), 0),
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
