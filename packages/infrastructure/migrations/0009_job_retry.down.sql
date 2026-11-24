-- =============================================================================
-- 0009_job_retry.down — بازگشت به «یک‌بار برای همیشه»
-- =============================================================================

create or replace function sys.job_begin(
  p_job_name text,
  p_scheduled_for timestamptz default now()
) returns bigint
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

  return v_id;
end $$;
