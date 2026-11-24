-- =============================================================================
-- 0009_job_retry.sql — بازبینی گام ۹: تلاش دوباره همان slot پس از شکست
--
-- مشکل: `sys.job_begin` هر slot را «همیشه یک‌بار» می‌گرفت؛ اگر اجرا با
-- وضعیت failed تمام می‌شد، همان slot تا ابد مسدود می‌ماند و پاک‌سازی نشست
-- تا slot بعدی عقب می‌افتاد.
--
-- قاعده جدید:
--   * slot جدید → رکورد running ساخته می‌شود (attempt=1)
--   * slot موفق → NULL (کاری برای انجام نیست)
--   * slot در حال اجرا → NULL (ضد اجرای هم‌زمان)
--   * slot شکست‌خورده → همان رکورد با attempt+1 دوباره running می‌شود
-- اجرای هم‌زمان با INSERT ... ON CONFLICT و SELECT ... FOR UPDATE کنترل می‌شود.
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
    return v_id;   -- slot تازه
  end if;

  select id, status into v_id, v_status
    from sys.job_runs
   where job_name = btrim(p_job_name)
     and scheduled_for = p_scheduled_for
   for update;

  if v_status = 'succeeded' or v_status = 'running' then
    return null;
  end if;

  -- failed: همان slot مجاز به تلاش دوباره است
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
  'slot تازه یا شکست‌خورده شناسه می‌گیرد؛ slot موفق/درحال‌اجرا NULL؛ هر تلاش attempt را +۱ می‌کند';
