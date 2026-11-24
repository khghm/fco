-- =============================================================================
-- 0008_ops_monitoring.sql — BR-1 گام ۹: رصد و نگهداشت عملیاتی
-- مالک طرح: docs/Engineering-04/OBSERVABILITY_PLAN.md (برنامه‌ریزی‌شده)
--           docs/Engineering-04/BACKUP_AND_RECOVERY.md
--           docs/Architecture-02/ADR-008-queue.md (پایش صف)
--
-- محتوا:
--   * `sys.job_begin` / `sys.job_finish` — اجرای یک‌بارِ هر slot (کلید
--     `job_runs (job_name, scheduled_for)`) و ثبت پایان موفق/ناموفق.
--   * `sys.purge_expired_sessions` — حذف نشست‌های منقضی/باطل پس از grace
--     (تنظیم نسخه‌دار؛ عملیاتی، نه نگهداشت PII که منتظر LEG-EXT است).
--   * `sys.run_session_cleanup` — Job پاک‌سازی با ثبت در job_runs؛ اجرای دوباره
--     همان slot بی‌اثر است.
--   * `sys.health_report` — گزارش JSON برای رصد: عمق و سن صف، DLQ، نشست‌ها،
--     کاربران قفل‌شده، Jobهای ناموفق ۲۴ ساعت، تعداد Migration.
--
-- خارج از این Migration: Endpoint پایش و اتصال به متریک (گام ۱۰/BR-3)؛
-- اینجا قرارداد داده و دسترسی بسته می‌شود.
-- =============================================================================

insert into sys.settings (key, value, description) values
  ('session.purge_grace_hours', '24'::jsonb,  'مهلت نگهداشت نشست منقضی پیش از حذف'),
  ('job.session_cleanup.batch', '500'::jsonb, 'اندازه دسته پاک‌سازی نشست')
on conflict (key) do nothing;

insert into sys.setting_versions (key, value, effective_from, reason)
select v.key, v.value, v.effective_from, v.reason
from (values
  ('session.purge_grace_hours', '24'::jsonb,  '2026-01-01 00:00:00+00'::timestamptz, 'مقدار اولیه BR-1'),
  ('job.session_cleanup.batch', '500'::jsonb, '2026-01-01 00:00:00+00'::timestamptz, 'مقدار اولیه BR-1')
) as v(key, value, effective_from, reason)
where not exists (select 1 from sys.setting_versions s where s.key = v.key);

-- -----------------------------------------------------------------------------
-- Job runs: یک اجرا برای هر slot
-- -----------------------------------------------------------------------------
create function sys.job_begin(p_job_name text, p_scheduled_for timestamptz default now())
returns bigint
language plpgsql security definer set search_path = sys, pg_catalog as $$
declare v_id bigint;
begin
  if p_job_name is null or btrim(p_job_name) = '' then
    raise exception 'FCO-1041: نام Job الزامی است' using errcode = '22023';
  end if;

  insert into sys.job_runs (job_name, scheduled_for, started_at)
  values (btrim(p_job_name), p_scheduled_for, now())
  on conflict (job_name, scheduled_for) do nothing
  returning id into v_id;

  return v_id;   -- NULL یعنی این slot قبلاً شروع شده است
end $$;

comment on function sys.job_begin(text, timestamptz) is
  'NULL = slot قبلاً گرفته شده؛ هر Job در هر slot حداکثر یک‌بار شروع می‌شود';

create function sys.job_finish(p_run_id bigint, p_status text, p_error text default null)
returns void
language plpgsql security definer set search_path = sys, pg_catalog as $$
begin
  if p_status is null or p_status not in ('succeeded', 'failed') then
    raise exception 'FCO-1041: وضعیت پایان Job باید succeeded یا failed باشد'
      using errcode = '22023';
  end if;

  update sys.job_runs
     set finished_at = now(),
         status = p_status,
         error = p_error
   where id = p_run_id and finished_at is null;

  if not found then
    raise exception 'FCO-1040: اجرای Job % باز یا موجود نیست', p_run_id
      using errcode = '22023';
  end if;
end $$;

-- -----------------------------------------------------------------------------
-- پاک‌سازی نشست‌ها
-- -----------------------------------------------------------------------------
create function sys.purge_expired_sessions(p_limit integer default null)
returns integer
language plpgsql security definer set search_path = sys, iam, pg_catalog as $$
declare
  v_batch integer := coalesce(p_limit, sys.setting_int('job.session_cleanup.batch'));
  v_grace integer := sys.setting_int('session.purge_grace_hours');
  v_count integer;
begin
  if v_batch < 1 or v_batch > 1000 then
    raise exception 'FCO-1041: اندازه دسته باید بین ۱ و ۱۰۰۰ باشد (%)', v_batch
      using errcode = '22023';
  end if;

  delete from iam.sessions s
   where s.id in (
           select c.id
             from iam.sessions c
            where c.expires_at < now() - make_interval(hours => v_grace)
               or (c.revoked_at is not null
                   and c.revoked_at < now() - make_interval(hours => v_grace))
            order by c.expires_at
            limit v_batch
         );

  get diagnostics v_count = row_count;
  return v_count;
end $$;

comment on function sys.purge_expired_sessions(integer) is
  'فقط نشست‌های منقضی/باطل قدیمی‌تر از grace را حذف می‌کند؛ نشست فعال دست‌نخورده است';

create function sys.run_session_cleanup(
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

comment on function sys.run_session_cleanup(timestamptz, integer) is
  'Job پاک‌سازی با ثبت job_runs؛ اجرای دوباره همان slot نتیجه already_ran می‌دهد';

-- -----------------------------------------------------------------------------
-- گزارش سلامت (رصد)
-- -----------------------------------------------------------------------------
create function sys.health_report(p_caller uuid)
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

comment on function sys.health_report(uuid) is
  'گزارش JSON رصد با مجوز platform.health.read؛ عمق/سن صف و DLQ را شامل می‌شود';

grant execute on function
  sys.job_begin(text, timestamptz),
  sys.job_finish(bigint, text, text),
  sys.purge_expired_sessions(integer),
  sys.run_session_cleanup(timestamptz, integer),
  sys.health_report(uuid)
to fco_app;
