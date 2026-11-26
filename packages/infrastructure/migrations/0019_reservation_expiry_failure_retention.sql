-- =============================================================================
-- 0019_reservation_expiry_failure_retention — BR-2: نگهداشت جدول خطای انقضا
-- مالک طرح: docs/Architecture-02/DATABASE_DESIGN.md §3.5
--           docs/Engineering-04/TEST_STRATEGY.md §4.1 (T-INV-08)
--           docs/Architecture-02/ADR/ADR-010-data-retention.md
--
-- پرسش بازبینی سوم دو بخش داشت:
--   ۱) `exists` اولویت صف در 0018 روی `reservation_id` است؛ ایندکس مناسب دارد؟
--      بله: `0017` ایندکس `reservation_expiry_failures_reservation_idx`
--      `(reservation_id, occurred_at desc)` را می‌سازد و ستون پیشرو همان کلید
--      `exists` است. این Migration چیزی برای ساختن ندارد، فقط ایندکس را
--      مستند می‌کند تا کسی آن را «ایندکس بی‌مصرف» نبیند و حذفش نکند.
--   ۲) نگهداشت جدول روشن نبود. در 0018 نوشته شده بود «نگهداشت با پاک‌سازی
--      sys.job_runs است، چون run_id آبشاری است» — این در عمل هیچ‌وقت اجرا
--      نمی‌شود: هیچ Job یا Migration‌ای `sys.job_runs` را پاک نمی‌کند. پس
--      رزروی که ساعت‌ها خراب می‌ماند، در هر slot یک ردیف اضافه می‌کرد و جدول
--      بی‌مرز رشد می‌کرد (۲۴ ردیف در روز برای هر رزرو خراب).
--
-- تصمیم: نگهداشت نسخه‌دار، نه عدد هارد‌کد و نه امید به cascade.
--   * `job.reservation_expiry.failure_keep` (پیش‌فرض ۲۴ = یک روز در آهنگ
--     ساعتی) سقف ردیف هر رزرو است.
--   * هرس در همان slotی انجام می‌شود که ردیف جدید درج می‌شود و فقط برای همان
--     رزرو: جدیدترین `failure_keep` ردیف می‌ماند. هزینه‌اش به تعداد شکست‌های
--     همان دور محدود است و روی ایندکس `reservation_id` انجام می‌شود، نه اسکن
--     کل جدول.
--   * تنها جدیدترین ردیف‌ها می‌مانند تا «سابقه‌دار بودن» رزرو (کلید اولویت
--     0018) هرگز پاک نشود؛ اگر همه ردیف‌های یک رزرو هرس می‌شد، رزرو خراب
--     دوباره سر صف برمی‌گشت و همان گرسنگی 0018 برمی‌گشت.
--   * ردیف‌ها با حذف خود رزرو هم می‌روند (`on delete cascade`).
-- باقی‌مانده: رزروِ رفع‌شده سابقه‌اش را نگه می‌دارد (≤ سقف) و جاروی سنی
-- عمومی به Job نگهداشت `sys.job_runs` گره خورده که ADR-010 اعدادش را به
-- پیکربندی سپرده است.
-- =============================================================================

insert into sys.settings (key, value, description) values
  ('job.reservation_expiry.failure_keep', '24'::jsonb,
   'سقف نگهداشت ردیف خطای هر رزرو در inv.reservation_expiry_failures (جدیدترین‌ها می‌مانند)')
on conflict (key) do nothing;

insert into sys.setting_versions (key, value, effective_from, reason)
select v.key, v.value, v.effective_from, v.reason
from (values
  ('job.reservation_expiry.failure_keep', '24'::jsonb,
   '2026-01-01 00:00:00+00'::timestamptz, 'مقدار اولیه BR-2 (بازبینی سوم)')
) as v(key, value, effective_from, reason)
where not exists (select 1 from sys.setting_versions s where s.key = v.key);

-- ایندکس از 0017 هست؛ فقط نقشش را برای بازبین بعدی روشن می‌کند.
comment on index inv.reservation_expiry_failures_reservation_idx is
  'ستون پیشرو reservation_id: کلید exists اولویت صف (0018) و هرس نگهداشت (0019)؛ occurred_at desc برای انتخاب جدیدترین ردیف‌ها';

-- بدنه مثل 0018 است؛ فقط سقف نگهداشت و هرس همان رزرو اضافه شده.
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
