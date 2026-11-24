-- =============================================================================
-- 0010_job_limits.sql — سقف تلاش و نمایش Job گیرکرده
--
-- بازبینی گام ۹ شکاف‌های زیر را نشان داد:
--   ۱) `sys.job_begin` بی‌سقف بود: یک Job خراب می‌توانست در همان slot تا ابد
--      دوباره تلاش کند و صف/پاک‌سازی را در حلقه نگه دارد.
--   ۲) `sys.run_session_cleanup` در exception بلافاصله `raise` می‌کرد؛ در
--      Postgres این کار کل تراکنش را برمی‌گرداند، پس رکورد `failed` (و attempt)
--      هرگز ذخیره نمی‌شد و «تلاش دوباره» روی واقعیت تکیه نداشت.
--   ۳) `sys.health_report` اجرای گیرکرده (running قدیمی، معادل Worker مرده) را
--      از اجرای سالم تشخیص نمی‌داد.
--
-- تصمیم‌ها (DECISION_LOG D-18):
--   * `job.max_attempts` (پیش‌فرض ۳): تلاش بعد از رسیدن به سقف → FCO-1042
--   * `job.stuck_after_minutes` (پیش‌فرض ۳۰): running قدیمی‌تر = گیرکرده
--   * شکست Job در `run_session_cleanup` با outcome='failed' ثبت و برگردانده
--     می‌شود (بدون rollback) تا caller هشدار بدهد؛ سکوت ممنوع است.
-- هر دو آستانه تنظیم نسخه‌دارند، نه عدد هارد‌کد.
-- =============================================================================

insert into sys.settings (key, value, description) values
  ('job.max_attempts',        '3'::jsonb,  'سقف تلاش دوباره یک Job در همان slot'),
  ('job.stuck_after_minutes', '30'::jsonb, 'مدت اجرای running پیش از «گیرکرده» شمرده‌شدن')
on conflict (key) do nothing;

insert into sys.setting_versions (key, value, effective_from, reason)
select v.key, v.value, v.effective_from, v.reason
from (values
  ('job.max_attempts',        '3'::jsonb,  '2026-01-01 00:00:00+00'::timestamptz, 'مقدار اولیه BR-1'),
  ('job.stuck_after_minutes', '30'::jsonb, '2026-01-01 00:00:00+00'::timestamptz, 'مقدار اولیه BR-1')
) as v(key, value, effective_from, reason)
where not exists (select 1 from sys.setting_versions s where s.key = v.key);

-- -----------------------------------------------------------------------------
-- job_begin: تلاش دوباره با سقف
-- -----------------------------------------------------------------------------
create or replace function sys.job_begin(
  p_job_name text,
  p_scheduled_for timestamptz default now()
) returns bigint
language plpgsql security definer set search_path = sys, pg_catalog as $$
declare
  v_id      bigint;
  v_status  text;
  v_attempt integer;
  v_cap     integer := sys.setting_int('job.max_attempts');
begin
  if p_job_name is null or btrim(p_job_name) = '' then
    raise exception 'FCO-1041: نام Job الزامی است' using errcode = '22023';
  end if;

  insert into sys.job_runs (job_name, scheduled_for, started_at)
  values (btrim(p_job_name), p_scheduled_for, now())
  on conflict (job_name, scheduled_for) do nothing
  returning id into v_id;

  if v_id is not null then
    return v_id;   -- slot تازه
  end if;

  select id, status, attempt into v_id, v_status, v_attempt
    from sys.job_runs
   where job_name = btrim(p_job_name)
     and scheduled_for = p_scheduled_for
   for update;

  if v_status = 'succeeded' or v_status = 'running' then
    return null;   -- کاری نمانده / اجرای هم‌زمان
  end if;

  if v_attempt >= v_cap then
    raise exception 'FCO-1042: سقف تلاش % برای Job % در slot % پر شده است',
      v_cap, btrim(p_job_name), p_scheduled_for
      using errcode = '22023';
  end if;

  update sys.job_runs
     set attempt = attempt + 1,
         started_at = now(),
         finished_at = null,
         status = 'running',
         error = null
   where id = v_id;

  return v_id;
end $$;

comment on function sys.job_begin(text, timestamptz) is
  'slot تازه یا شکست‌خورده (تا سقف job.max_attempts) شناسه می‌گیرد؛ موفق/درحال‌اجرا NULL؛ سقف → FCO-1042';

-- -----------------------------------------------------------------------------
-- run_session_cleanup: شکست ثبت می‌شود (بدون rollback)
-- -----------------------------------------------------------------------------
create or replace function sys.run_session_cleanup(
  p_scheduled_for timestamptz default date_trunc('hour', now()),
  p_limit integer default null
) returns table (outcome text, purged integer, run_id bigint)
language plpgsql security definer set search_path = sys, pg_catalog as $$
declare
  v_run  bigint;
  v_rows integer;
begin
  v_run := sys.job_begin('session_cleanup', p_scheduled_for);

  if v_run is null then
    return query select 'already_ran'::text, 0, null::bigint;
    return;
  end if;

  begin
    v_rows := sys.purge_expired_sessions(p_limit);
    perform sys.job_finish(v_run, 'succeeded');
    return query select 'ran'::text, v_rows, v_run;
  exception when others then
    -- ثبت شکست و بازگرداندن آن؛ اگر اینجا دوباره raise می‌کردیم، خودِ رکورد
    -- failed هم با rollback از بین می‌رفت و سقف تلاش هرگز فعال نمی‌شد.
    perform sys.job_finish(v_run, 'failed', sqlerrm);
    return query select 'failed'::text, 0, v_run;
  end;
end $$;

comment on function sys.run_session_cleanup(timestamptz, integer) is
  'outcome: ran | already_ran | failed؛ شکست در job_runs ثبت می‌شود و slot تا سقف تلاش باز می‌ماند';

-- -----------------------------------------------------------------------------
-- health_report: stuck / stuck_runs / exhausted_24h
-- -----------------------------------------------------------------------------
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
