-- بازگشت 0017: تعریف 0013 برمی‌گردد (بدون `failed` و بدون جدول خطا)
drop function if exists inv.expire_reservations(uuid, timestamptz, integer);

create function inv.expire_reservations(
  p_actor uuid,
  p_scheduled_for timestamptz default date_trunc('hour', now()),
  p_limit integer default null
) returns table (outcome text, expired integer, run_id bigint)
language plpgsql security definer set search_path = inv, sys, iam, pg_catalog as $$
declare
  v_batch integer := coalesce(p_limit, sys.setting_int('job.reservation_expiry.batch'));
  v_run   bigint;
  v_count integer := 0;
  r       record;
begin
  perform iam.authorize(p_actor, 'platform.job.run');

  if v_batch is null or v_batch < 1 or v_batch > 1000 then
    raise exception 'FCO-1077: اندازه دسته باید بین ۱ و ۱۰۰۰ باشد (%)', coalesce(v_batch, -1)
      using errcode = '22023';
  end if;

  v_run := sys.job_begin('reservation_expiry', p_scheduled_for);
  if v_run is null then
    return query select 'already_ran'::text, 0, null::bigint;
    return;
  end if;

  begin
    for r in
      select id from inv.reservations
       where status = 'active' and expires_at <= now()
       order by expires_at
       limit v_batch
    loop
      if inv.release(p_actor, r.id, 'expired') then
        v_count := v_count + 1;
      end if;
    end loop;

    perform sys.job_finish(v_run, 'succeeded');
    return query select 'ran'::text, v_count, v_run;
  exception when others then
    perform sys.job_finish(v_run, 'failed', sqlerrm);
    return query select 'failed'::text, 0, v_run;
  end;
end $$;

comment on function inv.expire_reservations(uuid, timestamptz, integer) is
  'outcome: ran | already_ran | failed؛ هر slot حداکثر یک‌بار آزادسازی می‌کند';

grant execute on function inv.expire_reservations(uuid, timestamptz, integer) to fco_app;

drop table if exists inv.reservation_expiry_failures;
