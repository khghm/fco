-- =============================================================================
-- 0004_otp_customer — BR-1 گام ۶: OTP مشتری (۶ رقم) + Spool توسعه
-- مالک طرح: docs/Architecture-02/SECURITY_ARCHITECTURE.md §2
--           docs/Business-01/USER_ROLES_AND_PERMISSIONS.md §7
--           docs/Engineering-04/TEST_STRATEGY.md §6 (T-SEC-12)
--
-- قاعده‌ها:
--   * پاسخ درخواست کد برای موبایل موجود/ناموجود یکسان است: تابع هیچ نگاهی
--     به `iam.users` ندارد، پس شمارش کاربران از این مسیر ممکن نیست (FR-1-08).
--   * کد فقط به‌صورت هش ذخیره می‌شود؛ کد خام هرگز در جدول اصلی نیست.
--   * TTL، سقف تلاش، فاصله ارسال مجدد و نرخ پنجره از `sys.setting_versions`
--     می‌آید؛ هیچ عددی در کد هارد‌کد نیست.
--   * Spool توسعه با تنظیم `auth.otp.spool_enabled` روشن می‌شود (پیش‌فرض خاموش)
--     و در Production باید خاموش بماند؛ در چک‌لیست استقرار گیت دارد (D-13).
--   * اپ به هیچ جدول OTP دسترسی مستقیم ندارد؛ فقط توابع.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- جدول درخواست‌های OTP
-- -----------------------------------------------------------------------------
create table iam.otp_requests (
  id              uuid primary key default gen_random_uuid(),
  mobile          varchar(11) not null,
  purpose         text not null check (purpose in ('login', 'password_reset')),
  code_hash       bytea not null,
  attempts        integer not null default 0 check (attempts >= 0),
  request_ip      inet,
  created_at      timestamptz not null default now(),
  expires_at      timestamptz not null,
  consumed_at     timestamptz,
  invalidated_at  timestamptz,
  constraint otp_requests_mobile_format check (mobile ~ '^09[0-9]{9}$'),
  constraint otp_requests_hash_present check (octet_length(code_hash) >= 16),
  constraint otp_requests_expiry_after_creation check (expires_at > created_at),
  constraint otp_requests_terminal_once
    check (consumed_at is null or invalidated_at is null)
);

-- هر موبایل+هدف در هر لحظه فقط یک کد فعال دارد (درخواست جدید قبلی را باطل می‌کند)
create unique index otp_requests_one_active
  on iam.otp_requests (mobile, purpose)
  where consumed_at is null and invalidated_at is null;

create index otp_requests_mobile_window_idx
  on iam.otp_requests (mobile, created_at desc);
create index otp_requests_ip_window_idx
  on iam.otp_requests (request_ip, created_at desc)
  where request_ip is not null;

comment on table iam.otp_requests is
  'OTP یک‌بارمصرف؛ کد خام ذخیره نمی‌شود و پاسخ درخواست برای کاربر موجود/ناموجود یکسان است';

-- -----------------------------------------------------------------------------
-- Spool توسعه (فقط توسعه؛ پیش‌فرض خاموش)
-- -----------------------------------------------------------------------------
create table sys.otp_spool (
  id              bigserial primary key,
  otp_request_id  uuid not null unique references iam.otp_requests (id) on delete cascade,
  mobile          varchar(11) not null,
  code            text not null,
  created_at      timestamptz not null default now(),
  expires_at      timestamptz not null,
  read_at         timestamptz
);

comment on table sys.otp_spool is
  'Spool جایگزین پیامک در توسعه (D-13)؛ در Production باید خاموش و خالی بماند';

-- -----------------------------------------------------------------------------
-- سیاست OTP (نسخه‌دار)
-- -----------------------------------------------------------------------------
insert into sys.settings (key, value, description) values
  ('auth.otp.ttl_seconds',      '120'::jsonb, 'عمر کد یک‌بارمصرف'),
  ('auth.otp.max_attempts',     '5'::jsonb,   'حداکثر تلاش برای هر کد'),
  ('auth.otp.resend_seconds',   '60'::jsonb,  'حداقل فاصله ارسال دوباره'),
  ('auth.otp.window_minutes',   '10'::jsonb,  'پنجره شمارش نرخ'),
  ('auth.otp.max_per_window',   '3'::jsonb,   'حداکثر کد در پنجره، هر موبایل'),
  ('auth.otp.max_per_ip_window','10'::jsonb,  'حداکثر کد در پنجره، هر IP'),
  ('auth.otp.spool_enabled',    'false'::jsonb, 'فعال‌سازی Spool توسعه (Production: false)')
on conflict (key) do nothing;

insert into sys.setting_versions (key, value, effective_from, reason) values
  ('auth.otp.ttl_seconds',      '120'::jsonb,   '2026-01-01 00:00:00+00', 'مقدار اولیه BR-1'),
  ('auth.otp.max_attempts',     '5'::jsonb,     '2026-01-01 00:00:00+00', 'مقدار اولیه BR-1'),
  ('auth.otp.resend_seconds',   '60'::jsonb,    '2026-01-01 00:00:00+00', 'مقدار اولیه BR-1'),
  ('auth.otp.window_minutes',   '10'::jsonb,    '2026-01-01 00:00:00+00', 'مقدار اولیه BR-1'),
  ('auth.otp.max_per_window',   '3'::jsonb,     '2026-01-01 00:00:00+00', 'مقدار اولیه BR-1'),
  ('auth.otp.max_per_ip_window','10'::jsonb,    '2026-01-01 00:00:00+00', 'مقدار اولیه BR-1'),
  ('auth.otp.spool_enabled',    'false'::jsonb, '2026-01-01 00:00:00+00', 'خاموش تا محیط توسعه آن را روشن کند')
on conflict (key, effective_from) do nothing;

-- -----------------------------------------------------------------------------
-- توابع OTP
-- -----------------------------------------------------------------------------
create function iam.request_otp(
  p_mobile text,
  p_purpose text,
  p_code_hash bytea,
  p_ip inet default null
) returns uuid
language plpgsql security definer set search_path = iam, sys, pg_catalog as $$
declare
  v_mobile        varchar(11) := btrim(p_mobile);
  v_window        interval := make_interval(mins => sys.setting_int('auth.otp.window_minutes'));
  v_max_window    integer := sys.setting_int('auth.otp.max_per_window');
  v_max_ip        integer := sys.setting_int('auth.otp.max_per_ip_window');
  v_resend        integer := sys.setting_int('auth.otp.resend_seconds');
  v_ttl           integer := sys.setting_int('auth.otp.ttl_seconds');
  v_mobile_count  integer;
  v_ip_count      integer;
  v_last          timestamptz;
  v_id            uuid;
begin
  if v_mobile is null or v_mobile !~ '^09[0-9]{9}$' then
    raise exception 'FCO-1016: شماره موبایل نامعتبر است' using errcode = '22023';
  end if;
  if p_purpose is null or p_purpose not in ('login', 'password_reset') then
    raise exception 'FCO-1016: هدف درخواست کد نامعتبر است' using errcode = '22023';
  end if;
  if p_code_hash is null or octet_length(p_code_hash) < 16 then
    raise exception 'FCO-1016: هش کد الزامی است' using errcode = '22023';
  end if;

  select count(*), max(created_at)
    into v_mobile_count, v_last
    from iam.otp_requests
   where mobile = v_mobile
     and created_at > now() - v_window;

  if v_last is not null and v_last > now() - make_interval(secs => v_resend) then
    raise exception 'FCO-1013: فاصله ارسال دوباره کد رعایت نشده است' using errcode = '53300';
  end if;

  if v_mobile_count >= v_max_window then
    raise exception 'FCO-1012: سقف درخواست کد در این بازه پر شده است' using errcode = '53300';
  end if;

  if p_ip is not null then
    select count(*) into v_ip_count
      from iam.otp_requests
     where request_ip = p_ip
       and created_at > now() - v_window;
    if v_ip_count >= v_max_ip then
      raise exception 'FCO-1012: سقف درخواست کد از این نشانی پر شده است' using errcode = '53300';
    end if;
  end if;

  -- کد فعال قبلی باطل می‌شود تا هم‌زمان دو کد معتبر نباشد
  update iam.otp_requests
     set invalidated_at = now()
   where mobile = v_mobile
     and purpose = p_purpose
     and consumed_at is null
     and invalidated_at is null;

  insert into iam.otp_requests (mobile, purpose, code_hash, request_ip, expires_at)
  values (v_mobile, p_purpose, p_code_hash, p_ip,
          now() + make_interval(secs => v_ttl))
  returning id into v_id;

  return v_id;
end $$;

comment on function iam.request_otp(text, text, bytea, inet) is
  'درخواست کد؛ پاسخ برای موبایل موجود و ناموجود یکسان است (ضد شمارش کاربر)';

create function iam.verify_otp(
  p_mobile text,
  p_purpose text,
  p_code_hash bytea
) returns table (outcome text, request_id uuid)
language plpgsql security definer set search_path = iam, sys, pg_catalog as $$
declare
  v_mobile       varchar(11) := btrim(p_mobile);
  v_max_attempts integer := sys.setting_int('auth.otp.max_attempts');
  v_request      record;
begin
  if p_purpose is null or p_purpose not in ('login', 'password_reset') then
    raise exception 'FCO-1016: هدف درخواست کد نامعتبر است' using errcode = '22023';
  end if;

  select r.id, r.code_hash, r.expires_at, r.attempts
    into v_request
    from iam.otp_requests r
   where r.mobile = v_mobile
     and r.purpose = p_purpose
     and r.consumed_at is null
     and r.invalidated_at is null
   order by r.created_at desc
   limit 1;

  -- نبود کد، انقضا و کد غلط یک پاسخ می‌گیرند (ضد افشا و ضد شمارش)
  -- خروجی وضعیت است، نه Exception: با RAISE، شمارنده تلاش هم بازمی‌گشت و
  -- محافظت Brute Force عملاً بی‌اثر می‌شد (شکاف پیدا‌شده در آزمون گام ۶).
  if not found then
    return query select 'invalid'::text, null::uuid;
    return;
  end if;
  if v_request.expires_at <= now() then
    return query select 'invalid'::text, v_request.id;
    return;
  end if;
  if v_request.attempts >= v_max_attempts then
    return query select 'locked'::text, v_request.id;
    return;
  end if;

  if v_request.code_hash <> p_code_hash then
    update iam.otp_requests
       set attempts = attempts + 1
     where id = v_request.id;
    return query select 'invalid'::text, v_request.id;
    return;
  end if;

  update iam.otp_requests
     set consumed_at = now(), attempts = attempts + 1
   where id = v_request.id;

  return query select 'ok'::text, v_request.id;
end $$;

comment on function iam.verify_otp(text, text, bytea) is
  'مصرف یک‌بارمصرف کد؛ outcome: ok|invalid|locked (اپ آن را به 200/400/429 نگاشت می‌کند)';

-- Spool: نوشتن کد خام فقط در توسعه و فقط با تنظیم روشن
create function iam.spool_otp(p_request_id uuid, p_code text)
returns void
language plpgsql security definer set search_path = iam, sys, pg_catalog as $$
declare
  v_enabled boolean := sys.setting_value('auth.otp.spool_enabled') = 'true'::jsonb;
  v_request record;
begin
  if not v_enabled then
    raise exception 'FCO-1017: Spool توسعه خاموش است' using errcode = '22023';
  end if;

  select r.mobile, r.expires_at, r.consumed_at, r.invalidated_at
    into v_request
    from iam.otp_requests r
   where r.id = p_request_id;

  if not found or v_request.consumed_at is not null or v_request.invalidated_at is not null then
    raise exception 'FCO-1014: درخواست کد معتبر نیست' using errcode = '22023';
  end if;

  insert into sys.otp_spool (otp_request_id, mobile, code, expires_at)
  values (p_request_id, v_request.mobile, p_code, v_request.expires_at)
  on conflict (otp_request_id) do update
    set code = excluded.code,
        expires_at = excluded.expires_at;
end $$;

create function iam.read_spool(p_request_id uuid)
returns text
language plpgsql security definer set search_path = iam, sys, pg_catalog as $$
declare
  v_enabled boolean := sys.setting_value('auth.otp.spool_enabled') = 'true'::jsonb;
  v_code    text;
begin
  if not v_enabled then
    raise exception 'FCO-1017: Spool توسعه خاموش است' using errcode = '22023';
  end if;

  select s.code into v_code
    from sys.otp_spool s
   where s.otp_request_id = p_request_id
     and s.expires_at > now();

  update sys.otp_spool set read_at = now()
   where otp_request_id = p_request_id and read_at is null;

  return v_code;
end $$;

comment on function iam.read_spool(uuid) is
  'خواندن کد در محیط توسعه؛ در Production تنظیم خاموش است و فراخوانی رد می‌شود';

-- -----------------------------------------------------------------------------
-- دسترسی: فقط توابع، هیچ جدول OTP برای اپ
-- -----------------------------------------------------------------------------
grant execute on function
  iam.request_otp(text, text, bytea, inet),
  iam.verify_otp(text, text, bytea),
  iam.spool_otp(uuid, text),
  iam.read_spool(uuid)
to fco_app;

revoke all on iam.otp_requests from public;
revoke all on sys.otp_spool from public;
