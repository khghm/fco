-- =============================================================================
-- 0020_reservation_expiry_failure_single_row.down — بازگشت به تعریف 0019
-- تعریف تابع 0019 (با هرس و سقف `failure_keep`) عیناً بازگردانده می‌شود،
-- ایندکس یکتا جای خود را به ایندکس 0017 می‌دهد و ستون‌های `failures` و
-- `first_failed_at` می‌روند (تاریخچه per-slot در این مسیر بازسازی نمی‌شود).
-- تاریخچه تنظیم `job.reservation_expiry.failure_keep` حذف نمی‌شود (0005/D-12).
-- =============================================================================

drop index if exists inv.reservation_expiry_failures_reservation_uidx;

create index reservation_expiry_failures_reservation_idx
  on inv.reservation_expiry_failures (reservation_id, occurred_at desc);

comment on index inv.reservation_expiry_failures_reservation_idx is
  'ستون پیشرو reservation_id: کلید exists اولویت صف (0018) و هرس نگهداشت (0019)؛ occurred_at desc برای انتخاب جدیدترین ردیف‌ها';

update sys.settings
   set description = 'سقف نگهداشت ردیف خطای هر رزرو در inv.reservation_expiry_failures (جدیدترین‌ها می‌مانند)'
 where key = 'job.reservation_expiry.failure_keep';

create or replace function inv.expire_reservations(
  p_actor uuid,
  p_scheduled_for timestamptz default date_trunc('hour', now()),
  p_limit integer default null
) returns table (outcome text, expired integer, run_id bigint, failed integer)
language plpgsql security definer set search_path = inv, sys, iam, pg_catalog as $$
declare
  v_batch  integer := coalesce(p_limit, sys.setting_int('job.reservation_expiry.batch'));
  v_keep   integer := sys.setting_int('job.reservation_expiry.failure_keep');
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

  if v_keep is null or v_keep < 1 or v_keep > 1000 then
    raise exception 'FCO-1079: سقف نگهداشت خطای رزرو باید بین ۱ و ۱۰۰۰ باشد (%)', coalesce(v_keep, -1)
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
        -- و بقیه دسته ادامه یابد.
        v_failed := v_failed + 1;
        insert into inv.reservation_expiry_failures
          (run_id, reservation_id, error_sqlstate, message)
        values (v_run, r.id, sqlstate, sqlerrm);

        -- نگهداشت: فقط جدیدترین ردیف‌های همین رزرو می‌مانند. ردیف‌های رزرو
        -- دیگر دست نمی‌خورند و حداقل یک ردیف می‌ماند، پس «سابقه‌دار بودن»
        -- (کلید اولویت 0018) حفظ می‌شود.
        delete from inv.reservation_expiry_failures f
         where f.reservation_id = r.id
           and f.id not in (
             select k.id from inv.reservation_expiry_failures k
              where k.reservation_id = r.id
              order by k.occurred_at desc, k.id desc
              limit v_keep
           );
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
  'outcome: ran | already_ran | failed؛ شکست هر رزرو جدا ثبت می‌شود، رزروهای سابقه‌دار آخر صف‌اند و ردیف‌های خطای هر رزرو تا job.reservation_expiry.failure_keep هرس می‌شوند';

revoke all on function inv.expire_reservations(uuid, timestamptz, integer) from public;
grant execute on function inv.expire_reservations(uuid, timestamptz, integer) to fco_app;

alter table inv.reservation_expiry_failures
  drop column if exists failures,
  drop column if exists first_failed_at;

comment on table inv.reservation_expiry_failures is
  'رزروهایی که Job انقضا نتوانست آزاد کند؛ هر ردیف یک شکست با run_id و sqlstate (T-INV-07)';
