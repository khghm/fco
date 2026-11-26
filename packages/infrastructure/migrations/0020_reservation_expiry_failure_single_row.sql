-- =============================================================================
-- 0020_reservation_expiry_failure_single_row — BR-2: یک ردیف برای هر رزرو
-- مالک طرح: docs/Architecture-02/DATABASE_DESIGN.md §3.5
--           docs/Engineering-04/TEST_STRATEGY.md §4.1 (T-INV-08)
--           docs/Architecture-02/ADR/ADR-010-data-retention.md
--
-- بازبینی چهارم روی 0019 سه ایراد واقعی نشان داد:
--   ۱) هرس داخل بلوک `exception` بود، یعنی نگهداشت (کار نظافتی) در همان
--      زیرتراکنشی اجرا می‌شد که خطای رزرو را مدیریت می‌کند؛ خطای همان DELETE
--      به بلوک بیرونی می‌رسید و کل دسته (آزادسازی‌های موفق + ردیف‌های خطا) را
--      برمی‌گرداند و Job را `failed` می‌کرد، یعنی `job.max_attempts` را
--      می‌سوزاند — همان چیزی که 0017 عمداً از آن پرهیز داشت.
--   ۲) دامنه هرس فقط رزروهایی بود که «در همان دور» شکست می‌خوردند: رزروی که
--      رفع می‌شد سابقه‌اش تا ابد می‌ماند و کم‌کردن سقف هم ردیف‌های موجود را
--      هرس نمی‌کرد (سقف فقط از لحظه شکست بعدی اعمال می‌شد). پس «سقف» نیمه‌کاره
--      بود و عدد ۲۴ هم فقط «یک روز در آهنگ ساعتی» را رمز می‌کرد، نه یک invariant.
--   ۳) ردیف‌های تکراری یک رزرو خراب تقریباً یکسان‌اند؛ تنها سیگنال مفیدشان
--      «چند بار شکست خورد» بود که برای شمردنش باید ردیف‌ها شمرده می‌شد — و
--      هرس همان سیگنال را از بین می‌برد.
--
-- اصلاح (ساده‌سازی): نگهداشت با ساختار داده، نه با حذف.
--   * یکتایی `(reservation_id)`: هر رزرو حداکثر یک ردیف دارد.
--   * درج با `on conflict (reservation_id) do update`: آخرین `run_id`/
--     `sqlstate`/`message`/`occurred_at` به‌روز می‌شود و `failures` یک واحد
--     بالا می‌رود؛ `first_failed_at` هم تاریخ نخستین شکست را نگه می‌دارد.
--   * پس هیچ `delete`ی در مسیر شکست نیست، دامنه هرس بی‌معنا می‌شود، سقف
--     پیکربندی حذف می‌شود و رشد جدول = تعداد رزروهایی که تا امروز شکست
--     خورده‌اند (نه تعداد slotها).
--   * «سابقه‌دار بودن» (کلید اولویت 0018) با همان یک ردیف حفظ می‌شود و ردیف
--     با حذف خود رزرو می‌رود (`on delete cascade`).
-- تنظیم `job.reservation_expiry.failure_keep` بازنشسته می‌شود. ردیفش حذف
-- نمی‌شود چون `sys.setting_versions.key` با `on delete restrict` به آن گره
-- خورده است و تاریخچه تنظیم‌ها پاک‌شدنی نیست (0005/D-12)؛ فقط توضیحش
-- بازنشستگی را اعلام می‌کند و هیچ کدی آن را نمی‌خواند.
-- =============================================================================

alter table inv.reservation_expiry_failures
  add column failures        integer not null default 1,
  add column first_failed_at timestamptz not null default now();

alter table inv.reservation_expiry_failures
  add constraint reservation_expiry_failures_failures_check check (failures >= 1);

-- ردیف‌های موجود (اگر از 0019 مانده باشند) به یک ردیف برای هر رزرو جمع می‌شوند:
-- شمار شکست‌ها = تعداد ردیف‌های قبلی، تاریخ نخستین = قدیمی‌ترین، و ردیف
-- جدیدترین (occurred_at/id) می‌ماند تا آخرین run_id و پیام حفظ شود.
with keep as (
  select reservation_id,
         count(*)::integer as total,
         min(occurred_at) as first_at,
         (array_agg(id order by occurred_at desc, id desc))[1] as keep_id
    from inv.reservation_expiry_failures
   group by reservation_id
)
update inv.reservation_expiry_failures f
   set failures = keep.total,
       first_failed_at = keep.first_at
  from keep
 where f.id = keep.keep_id;

delete from inv.reservation_expiry_failures f
 using (
   select reservation_id,
          (array_agg(id order by occurred_at desc, id desc))[1] as keep_id
     from inv.reservation_expiry_failures
    group by reservation_id
 ) d
 where f.reservation_id = d.reservation_id
   and f.id <> d.keep_id;

-- ایندکس 0017 (reservation_id, occurred_at desc) جایش را به یکتایی می‌دهد:
-- کلید `exists` اولویت صف همان ستون پیشرو است و `on conflict` هم به آن نیاز دارد.
drop index if exists inv.reservation_expiry_failures_reservation_idx;

create unique index reservation_expiry_failures_reservation_uidx
  on inv.reservation_expiry_failures (reservation_id);

comment on index inv.reservation_expiry_failures_reservation_uidx is
  'یک ردیف برای هر رزرو: کلید exists اولویت صف (0018) و هدف on conflict (0020)';

comment on table inv.reservation_expiry_failures is
  'هر رزروی که Job انقضا نتوانست آزاد کند: یک ردیف با آخرین run_id/sqlstate، شمار شکست‌ها و تاریخ نخستین شکست (T-INV-07/08)';
comment on column inv.reservation_expiry_failures.failures is
  'شمار تلاش‌های ناموفق آزادسازی این رزرو (نه تعداد ردیف)';
comment on column inv.reservation_expiry_failures.occurred_at is
  'زمان آخرین شکست';
comment on column inv.reservation_expiry_failures.first_failed_at is
  'زمان نخستین شکست همین رزرو';

update sys.settings
   set description = 'بازنشسته در 0020: نگهداشت با یکتایی reservation_id انجام می‌شود و هیچ کدی این تنظیم را نمی‌خواند'
 where key = 'job.reservation_expiry.failure_keep';

-- بدنه مثل 0018/0019 است؛ هرس و سقف نگهداشت حذف و ثبت شکست به upsert تبدیل شد.
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
        -- و بقیه دسته ادامه یابد. یک ردیف برای هر رزرو، شمار شکست بالا می‌رود.
        v_failed := v_failed + 1;
        insert into inv.reservation_expiry_failures
          (run_id, reservation_id, error_sqlstate, message, failures, first_failed_at, occurred_at)
        values (v_run, r.id, sqlstate, sqlerrm, 1, now(), now())
        on conflict (reservation_id) do update
           set run_id         = excluded.run_id,
               error_sqlstate = excluded.error_sqlstate,
               message        = excluded.message,
               occurred_at    = excluded.occurred_at,
               failures       = inv.reservation_expiry_failures.failures + 1;
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
  'outcome: ran | already_ran | failed؛ شکست هر رزرو جدا در یک ردیف upsert می‌شود (شمار شکست‌ها)، رزروهای سابقه‌دار آخر صف‌اند و بقیه دسته آزاد می‌شوند';

revoke all on function inv.expire_reservations(uuid, timestamptz, integer) from public;
grant execute on function inv.expire_reservations(uuid, timestamptz, integer) to fco_app;
