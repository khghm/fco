-- =============================================================================
-- 0007_outbox_queue.sql — BR-1 گام ۸: Outbox، Queue Port، Worker و DLQ
-- مالک طرح: docs/Architecture-02/ADR-008-queue.md
--           docs/Architecture-02/SYSTEM_ARCHITECTURE.md §5
--           docs/Engineering-04/TEST_STRATEGY.md §4 (T-PLT-01/02)
--
-- مدل:
--   * تولید: `sys.outbox_emit` در همان تراکنش کسب‌وکار؛ بدنه رویداد
--     تغییرناپذیر است (تریگر 0001) و اپ INSERT مستقیم ندارد.
--   * مصرف: `sys.outbox_claim` با `FOR UPDATE SKIP LOCKED` و **lease**؛
--     رویداد در حال پردازش تا پایان lease دوباره تحویل نمی‌شود، پس دو Worker
--     هم‌زمان یک رویداد را نمی‌گیرند. attempts همان‌جا +۱ می‌شود.
--   * تکمیل: `sys.outbox_complete` یا `sys.outbox_fail`؛ پس از سقف تلاش
--     `dead_lettered_at` پر می‌شود و رویداد دیگر claim نمی‌شود.
--   * مصرف ایدم‌پوتنت: `sys.inbox_consume` با کلید (event_id, consumer)؛
--     تحویل دوباره `false` می‌دهد و اثر کسب‌وکار تکرار نمی‌شود.
--   * DLQ: `sys.dlq_list` با مجوز `platform.dlq.inspect`.
--   * lease و سقف تلاش از `sys.setting_versions` (هیچ عددی در کد نیست).
--
-- خارج از این Migration: Worker اجرایی (Node/Bun) و پایش عمق صف در گام ۹؛
-- اینجا قرارداد DB و ایدم‌پوتنسی آزمون‌پذیر بسته می‌شود.
-- =============================================================================

insert into sys.settings (key, value, description) values
  ('outbox.lease_seconds', '60'::jsonb,  'مدت قفل تحویل رویداد به یک Worker'),
  ('outbox.max_attempts',  '5'::jsonb,   'سقف تلاش پیش از انتقال به DLQ')
on conflict (key) do nothing;

-- تاریخچه تنظیم حذف‌شدنی نیست (تریگر 0005)؛ پس بذر فقط وقتی ساخته می‌شود
-- که برای آن کلید هیچ نسخه‌ای نباشد، تا بازگشت/اجرای دوباره نشکند.
insert into sys.setting_versions (key, value, effective_from, reason)
select v.key, v.value, v.effective_from, v.reason
from (values
  ('outbox.lease_seconds', '60'::jsonb, '2026-01-01 00:00:00+00'::timestamptz, 'مقدار اولیه BR-1'),
  ('outbox.max_attempts',  '5'::jsonb,  '2026-01-01 00:00:00+00'::timestamptz, 'مقدار اولیه BR-1')
) as v(key, value, effective_from, reason)
where not exists (select 1 from sys.setting_versions s where s.key = v.key);

-- -----------------------------------------------------------------------------
-- تولید رویداد (هم‌تراکنش با تغییر کسب‌وکار)
-- -----------------------------------------------------------------------------
create function sys.outbox_emit(
  p_aggregate_type text,
  p_aggregate_id uuid,
  p_event_name text,
  p_payload jsonb,
  p_headers jsonb default null
) returns bigint
language plpgsql security definer set search_path = sys, pg_catalog as $$
declare v_id bigint;
begin
  if p_aggregate_type is null or btrim(p_aggregate_type) = '' then
    raise exception 'FCO-1030: aggregate_type الزامی است' using errcode = '22023';
  end if;
  if p_aggregate_id is null then
    raise exception 'FCO-1030: aggregate_id الزامی است' using errcode = '22023';
  end if;
  if p_event_name is null
     or p_event_name !~ '^[a-z][a-z0-9]*(\.[a-z][a-z0-9_]*)+$' then
    raise exception 'FCO-1030: نام رویداد باید <domain>.<verb> با حروف کوچک باشد (%)',
      coalesce(p_event_name, 'null') using errcode = '22023';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'FCO-1030: payload باید شیء JSON باشد' using errcode = '22023';
  end if;

  insert into sys.outbox (aggregate_type, aggregate_id, event_name, payload, headers)
  values (p_aggregate_type, p_aggregate_id, p_event_name, p_payload, p_headers)
  returning id into v_id;

  return v_id;
end $$;

comment on function sys.outbox_emit(text, uuid, text, jsonb, jsonb) is
  'ثبت رویداد در تراکنش کسب‌وکار؛ بدنه پس از درج تغییرناپذیر است';

-- -----------------------------------------------------------------------------
-- تحویل با lease (ضد تحویل هم‌زمان به دو Worker)
-- -----------------------------------------------------------------------------
create function sys.outbox_claim(p_worker text, p_limit integer default 10)
returns table (
  id bigint,
  aggregate_type text,
  aggregate_id uuid,
  event_name text,
  payload jsonb,
  headers jsonb,
  attempts integer
)
language plpgsql security definer set search_path = sys, pg_catalog as $$
#variable_conflict use_column
declare
  v_lease integer := sys.setting_int('outbox.lease_seconds');
  v_limit integer := least(greatest(coalesce(p_limit, 10), 1), 100);
begin
  if p_worker is null or btrim(p_worker) = '' then
    raise exception 'FCO-1031: شناسه Worker الزامی است' using errcode = '22023';
  end if;

  return query
  update sys.outbox o
     set attempts = o.attempts + 1,
         available_at = now() + make_interval(secs => v_lease),
         last_error = null
   where o.id in (
           select c.id
             from sys.outbox c
            where c.processed_at is null
              and c.dead_lettered_at is null
              and c.available_at <= now()
            order by c.id
            limit v_limit
            for update skip locked
         )
  returning o.id, o.aggregate_type, o.aggregate_id, o.event_name,
            o.payload, o.headers, o.attempts;
end $$;

comment on function sys.outbox_claim(text, integer) is
  'تحویل دسته‌ای با SKIP LOCKED و lease؛ attempts در همین گام +۱ می‌شود';

-- -----------------------------------------------------------------------------
-- پایان پردازش: موفق یا ناموفق
-- -----------------------------------------------------------------------------
create function sys.outbox_complete(p_id bigint)
returns boolean
language plpgsql security definer set search_path = sys, pg_catalog as $$
declare v_ok boolean;
begin
  update sys.outbox
     set processed_at = now(), last_error = null
   where id = p_id and processed_at is null and dead_lettered_at is null
   returning true into v_ok;

  return coalesce(v_ok, false);
end $$;

create function sys.outbox_fail(p_id bigint, p_error text)
returns text
language plpgsql security definer set search_path = sys, sys, pg_catalog as $$
declare
  v_max     integer := sys.setting_int('outbox.max_attempts');
  v_outcome text;
begin
  if p_error is null or btrim(p_error) = '' then
    raise exception 'FCO-1031: متن خطا برای DLQ الزامی است' using errcode = '22023';
  end if;

  update sys.outbox o
     set last_error = p_error,
         dead_lettered_at = case when o.attempts >= v_max then now() else null end,
         available_at = case when o.attempts >= v_max then o.available_at else now() end
   where o.id = p_id
     and o.processed_at is null
     and o.dead_lettered_at is null
   returning case when o.dead_lettered_at is not null then 'dead_letter' else 'retry' end
   into v_outcome;

  if v_outcome is null then
    raise exception 'FCO-1032: رویداد % در وضعیت قابل‌شکست نیست', p_id using errcode = '22023';
  end if;

  return v_outcome;
end $$;

comment on function sys.outbox_fail(bigint, text) is
  'retry تا سقف تنظیم‌شده، سپس dead_letter؛ رویداد DLQ دیگر claim نمی‌شود';

-- -----------------------------------------------------------------------------
-- مصرف ایدم‌پوتنت
-- -----------------------------------------------------------------------------
create function sys.inbox_consume(p_event_id text, p_consumer text)
returns boolean
language plpgsql security definer set search_path = sys, pg_catalog as $$
declare v_rows integer;
begin
  if p_event_id is null or btrim(p_event_id) = '' or p_consumer is null or btrim(p_consumer) = '' then
    raise exception 'FCO-1031: event_id و consumer الزامی‌اند' using errcode = '22023';
  end if;

  -- کلید ایدم‌پوتنسی خود رویداد است (event_id PK در 0001)؛
  -- یک رویداد فقط یک‌بار در دفتر مصرف ثبت می‌شود.
  insert into sys.inbox_events (event_id, consumer)
  values (p_event_id, p_consumer)
  on conflict (event_id) do nothing;

  get diagnostics v_rows = row_count;
  return v_rows > 0;
end $$;

comment on function sys.inbox_consume(text, text) is
  'true = نخستین مصرف؛ false = تحویل تکراری (اثر کسب‌وکار نباید تکرار شود)';

-- -----------------------------------------------------------------------------
-- DLQ با مجوز
-- -----------------------------------------------------------------------------
create function sys.dlq_list(p_caller uuid, p_limit integer default 50)
returns table (
  id bigint,
  aggregate_type text,
  aggregate_id uuid,
  event_name text,
  attempts integer,
  last_error text,
  dead_lettered_at timestamptz
)
language plpgsql stable security definer set search_path = sys, iam, pg_catalog as $$
#variable_conflict use_column
declare v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  perform iam.authorize(p_caller, 'platform.dlq.inspect');

  return query
    select o.id, o.aggregate_type, o.aggregate_id, o.event_name,
           o.attempts, o.last_error, o.dead_lettered_at
      from sys.outbox o
     where o.dead_lettered_at is not null
     order by o.dead_lettered_at desc, o.id desc
     limit v_limit;
end $$;

comment on function sys.dlq_list(uuid, integer) is
  'فهرست DLQ با مجوز platform.dlq.inspect و سقف ۱۰۰ ردیف';

-- -----------------------------------------------------------------------------
-- دسترسی
-- -----------------------------------------------------------------------------
grant execute on function
  sys.outbox_emit(text, uuid, text, jsonb, jsonb),
  sys.outbox_claim(text, integer),
  sys.outbox_complete(bigint),
  sys.outbox_fail(bigint, text),
  sys.inbox_consume(text, text),
  sys.dlq_list(uuid, integer)
to fco_app;

revoke all on sys.outbox from public;
