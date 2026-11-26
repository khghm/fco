-- =============================================================================
-- 0019_reservation_expiry_failures.down — بازگشت مستقیم به وضعیت 0017
-- یک ردیف per-slot از دست می‌رود (شمار و تاریخ نخستین شکست هم)، ایندکس یکتا
-- جایش را به ایندکس 0017 می‌دهد، تعریف `expire_reservations` و
-- `sys.health_report` عیناً به 0017/0010 برمی‌گردد و ستون‌های تازه می‌روند.
-- هیچ تنظیمی در این Migration ساخته نشده بود که بازگردانی لازم داشته باشد.
-- =============================================================================

drop index if exists inv.reservation_expiry_failures_reservation_uidx;

create index reservation_expiry_failures_reservation_idx
  on inv.reservation_expiry_failures (reservation_id, occurred_at desc);

create or replace function inv.expire_reservations(
  p_actor uuid,
  p_scheduled_for timestamptz default date_trunc('hour', now()),
  p_limit integer default null
) returns table (outcome text, expired integer, run_id bigint, failed integer)
language plpgsql security definer set search_path = inv, sys, iam, pg_catalog as $$
declare
  v_batch  integer := coalesce(p_limit, sys.setting_int('job.reservation_expiry.batch'));
  v_run    bigint;
  v_count  integer := 0;
  v_failed integer := 0;
  r        record;
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
      select id from inv.reservations
       where status = 'active' and expires_at <= now()
       order by expires_at
       limit v_batch
       for update skip locked
    loop
      begin
        if inv.release(p_actor, r.id, 'expired') then
          v_count := v_count + 1;
        end if;
      exception when others then
        -- زیرتراکنش همین رزرو برگشت خورد؛ ثبت خطا بیرون آن است تا پایدار بماند
        -- و بقیه دسته ادامه یابد.
        v_failed := v_failed + 1;
        insert into inv.reservation_expiry_failures
          (run_id, reservation_id, error_sqlstate, message)
        values (v_run, r.id, sqlstate, sqlerrm);
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
  'outcome: ran | already_ran | failed؛ هر رزرو زیرتراکنش مستقل دارد، شکست‌ها در inv.reservation_expiry_failures ثبت و بقیه دسته آزاد می‌شوند';

-- EXECUTE به‌طور پیش‌فرض به PUBLIC داده می‌شود؛ مجوز فقط برای اپ (D-19).
revoke all on function inv.expire_reservations(uuid, timestamptz, integer) from public;
grant execute on function inv.expire_reservations(uuid, timestamptz, integer) to fco_app;

create or replace function sys.health_report(p_caller uuid)
returns jsonb
language plpgsql stable security definer set search_path = sys, iam, pg_catalog as $$
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
  'گزارش JSON رصد؛ شامل صف، نشست، Jobهای گیرکرده (job.stuck_after_minutes) و تلاش‌های تمام‌شده';

alter table inv.reservation_expiry_failures
  drop column if exists failures,
  drop column if exists first_failed_at;

comment on table inv.reservation_expiry_failures is
  'رزروهایی که Job انقضا نتوانست آزاد کند؛ هر ردیف یک شکست با run_id و sqlstate (T-INV-07)';
