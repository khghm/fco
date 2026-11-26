-- =============================================================================
-- 0018_reservation_expiry_fairness — BR-2: رزروِ پیوسته‌خراب، صف انقضا را گرسنه نکند
-- مالک طرح: docs/Architecture-02/DATABASE_DESIGN.md §3.5
--           docs/Engineering-04/TEST_STRATEGY.md §4.1 (T-INV-07)
--           docs/Business-01/BUSINESS_REQUIREMENTS.md (BRQ-15)
--
-- مشکل (0017): رزروی که آزادشدنش خطا می‌دهد عمداً `active` می‌ماند تا در slot بعدی
-- دوباره تلاش شود، و دسته با `order by expires_at` انتخاب می‌شد. نتیجه: هر رزرو
-- خراب قدیمی‌ترین `expires_at` را نگه می‌دارد و همیشه سر صف است؛ وقتی شمار
-- رزروهای خراب به اندازه `job.reservation_expiry.batch` برسد، هیچ رزرو سالمی
-- دیگر در دسته جا نمی‌شود و موجودی رزروشده تا رفع دستی داده قفل می‌ماند — آن هم
-- در حالی که Job هر ساعت `succeeded` گزارش می‌کند. (این همان «شکست پنهان»ی است
-- که 0017 می‌خواست از آن دوری کند، فقط یک لایه عقب‌تر.)
--
-- اصلاح: ترتیب دسته دو کلید می‌گیرد:
--   ۱) رزروهایی که تا امروز شکست ثبت‌شده دارند، بعد از بقیه می‌آیند
--      (`exists` روی `inv.reservation_expiry_failures`)؛
--   ۲) درون هر گروه، قدیمی‌ترین `expires_at` اول.
-- پس صف سالم همیشه پیش از صف خراب مصرف می‌شود و تا وقتی رزرو سالم منقضی
-- باقی است، رزرو خراب فقط در ظرفیت خالی دوباره تلاش می‌شود؛ داده که رفع شد،
-- رزرو خراب هم آزاد و ردیف خطایش تاریخ‌دار باقی می‌ماند. هیچ رزروی حذف یا
-- نادیده گرفته نمی‌شود؛ فقط اولویت دارد.
--
-- همچنین `run_id` جدول خطا ایندکس می‌شود: FK آن `on delete cascade` است و
-- پاک‌سازی `sys.job_runs` بدون این ایندکس هر بار کل جدول خطا را اسکن می‌کرد.
-- =============================================================================

create index reservation_expiry_failures_run_idx
  on inv.reservation_expiry_failures (run_id);

comment on index inv.reservation_expiry_failures_run_idx is
  'حذف آبشاری sys.job_runs بدون اسکن کامل جدول خطا (0018)';

-- امضای خروجی نسبت به 0017 تغییری نکرده؛ فقط بدنه و ترتیب انتخاب دسته.
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
  'outcome: ran | already_ran | failed؛ هر رزرو زیرتراکنش مستقل دارد، شکست‌ها در inv.reservation_expiry_failures ثبت می‌شوند، رزروهای سابقه‌دار آخر صف دسته‌اند و بقیه دسته آزاد می‌شوند';

revoke all on function inv.expire_reservations(uuid, timestamptz, integer) from public;
grant execute on function inv.expire_reservations(uuid, timestamptz, integer) to fco_app;
