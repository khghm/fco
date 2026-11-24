-- =============================================================================
-- 0010_job_limits.down — بازگشت به رفتار 0009/0008
-- =============================================================================

create or replace function sys.job_begin(
  p_job_name text,
  p_scheduled_for timestamptz default now()
) returns bigint
language plpgsql security definer set search_path = sys, pg_catalog as $$
declare
  v_id     bigint;
  v_status text;
begin
  if p_job_name is null or btrim(p_job_name) = '' then
    raise exception 'FCO-1041: نام Job الزامی است' using errcode = '22023';
  end if;

  insert into sys.job_runs (job_name, scheduled_for, started_at)
  values (btrim(p_job_name), p_scheduled_for, now())
  on conflict (job_name, scheduled_for) do nothing
  returning id into v_id;

  if v_id is not null then
    return v_id;
  end if;

  select id, status into v_id, v_status
    from sys.job_runs
   where job_name = btrim(p_job_name)
     and scheduled_for = p_scheduled_for
   for update;

  if v_status = 'succeeded' or v_status = 'running' then
    return null;
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
    perform sys.job_finish(v_run, 'failed', sqlerrm);
    raise;
  end;
end $$;

create or replace function sys.health_report(p_caller uuid)
returns jsonb
language plpgsql stable security definer set search_path = sys, iam, pg_catalog as $$
declare v_report jsonb;
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
      'running', (select count(*) from sys.job_runs j where j.finished_at is null)
    ),
    'schema_migrations', (select count(*) from sys.schema_migrations)
  ) into v_report;

  return v_report;
end $$;

-- تنظیم‌ها عمداً می‌مانند: تاریخچه `setting_versions` قابل حذف نیست و
-- Migrationهای بعدی نباید کلیدهای نسخه‌دار قبلی را پاک کنند.
