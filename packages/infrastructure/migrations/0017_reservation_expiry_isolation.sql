-- =============================================================================
-- 0017_reservation_expiry_isolation — BR-2: خطای یک رزرو، بقیه دسته را متوقف نکند
-- مالک طرح: docs/Architecture-02/DATABASE_DESIGN.md §3.4
--           docs/Engineering-04/TEST_STRATEGY.md §4.1 (T-INV-04، T-INV-07)
--           docs/Business-01/BUSINESS_REQUIREMENTS.md (BRQ-15)
--
-- مشکل (0013): حلقه انقضا یک `begin … exception when others` دور کل دسته داشت.
-- در PL/pgSQL هر بلوک exception یک زیرتراکنش است؛ پس خطای یک رزرو همه
-- آزادسازی‌های همان دسته را هم برمی‌گرداند و Job با outcome='failed' تمام
-- می‌شد. نتیجه: یک ردیف خراب (مثلاً reserved ناهم‌خوان با رزروها) کل پاک‌سازی
-- رزروهای منقضی را تا رفع دستی داده متوقف می‌کرد.
--
-- اصلاح:
--   * زیرتراکنش به‌ازای هر رزرو (نه هر دسته): خطا فقط همان رزرو را برمی‌گرداند
--     و حلقه ادامه می‌یابد.
--   * خطاها در `inv.reservation_expiry_failures` با `run_id`، شناسه رزرو،
--     `sqlstate` و پیام ثبت می‌شوند؛ ثبت بیرون زیرتراکنش رزرو است تا با
--     rollback خودِ رزرو از بین نرود.
--   * انتخاب دسته با `FOR UPDATE SKIP LOCKED` انجام می‌شود تا رزرو قفل‌شده
--     دسته را معطل نکند؛ رزرو خراب `active` می‌ماند و در slot بعدی دوباره
--     تلاش می‌شود (تا رفع داده)، پس شکست پایدار دیده می‌شود نه پنهان.
--   * Job با شکست جزئی هم 'succeeded' است (کار انجام شد) ولی `error` شمار
--     شکست‌ها و نام جدول خطا را می‌برد تا در `sys.job_runs` دیده شود؛ دسته
--     'failed' نمی‌شود چون آن تلاش دوباره/سقف `job.max_attempts` را بی‌دلیل
--     می‌سوزاند و بقیه رزروها را هم عقب می‌انداخت.
--   * `failed` به خروجی اضافه شد: caller باید بتواند بدون کوئری جدی خطا هم
--     تفکیک «هیچ کاری نبود» از «کار انجام شد ولی رزرو خرابی داشت» را ببیند.
-- =============================================================================

create table inv.reservation_expiry_failures (
  id             bigint generated always as identity primary key,
  run_id         bigint not null references sys.job_runs (id) on delete cascade,
  reservation_id uuid not null references inv.reservations (id) on delete cascade,
  error_sqlstate text not null check (error_sqlstate ~ '^[0-9A-Z]{5}$'),
  message        text not null check (btrim(message) <> ''),
  occurred_at    timestamptz not null default now()
);
create index reservation_expiry_failures_reservation_idx
  on inv.reservation_expiry_failures (reservation_id, occurred_at desc);

comment on table inv.reservation_expiry_failures is
  'رزروهایی که Job انقضا نتوانست آزاد کند؛ هر ردیف یک شکست با run_id و sqlstate (T-INV-07)';

-- امضای خروجی تغییر می‌کند (افزودن failed)، پس تابع بازساخته می‌شود.
drop function if exists inv.expire_reservations(uuid, timestamptz, integer);

create function inv.expire_reservations(
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
      select id from inv.reservations
       where status = 'active' and expires_at <= now()
       order by expires_at
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
  'outcome: ran | already_ran | failed؛ هر رزرو زیرتراکنش مستقل دارد، شکست‌ها در inv.reservation_expiry_failures ثبت و بقیه دسته آزاد می‌شوند';

-- EXECUTE به‌طور پیش‌فرض به PUBLIC داده می‌شود؛ مجوز فقط برای اپ (D-19).
revoke all on function inv.expire_reservations(uuid, timestamptz, integer) from public;
grant execute on function inv.expire_reservations(uuid, timestamptz, integer) to fco_app;
