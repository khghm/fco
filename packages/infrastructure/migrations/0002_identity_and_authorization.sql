-- =============================================================================
-- 0002_identity_and_authorization — BR-1 گام ۵: هویت، نشست و مجوز
-- مالک طرح: docs/Architecture-02/ADR/ADR-007-auth-session-strategy.md
--           docs/Architecture-02/SECURITY_ARCHITECTURE.md §2، §3، §5
--           docs/Business-01/USER_ROLES_AND_PERMISSIONS.md §2، §4، §5، §۷
-- محدوده:
--   * `iam.mfa_factors` (TOTP + کد بازیابی) و پرچم `requires_mfa` روی نقش
--   * بذر نقش‌های ۱۱گانه + گروه مجوز `iam.*`/`platform.*`/`export.*`
--   * قید DB برای SoD (ترکیب نقش ممنوع + Maker≠Checker)
--   * سیاست رمز/نشست/قفل به‌صورت تنظیم نسخه‌دار (هیچ عددی هارد‌کد نیست)
--   * توابع امنیتی `security definer` برای authorize/نشست/سیاست رمز
--   * نقش دیتابیس `fco_app` با حداقل دسترسی (بدون DDL، بدون تغییر دفترها)
--
-- خارج از این Migration (عمداً):
--   * `iam.otp_requests`             → BR-1 گام ۶
--   * کد هش رمز (Argon2id)          → لایه اپ؛ اینجا فقط سیاست و ذخیره هش
--   * جدول تأییدهای Maker/Checker  → دامنه (BR-2)؛ اینجا فقط تابع `sys.assert_separation`
--   * کاتالوگ کامل مجوز دامنه‌ها     → همراه دامنه خودش (BR-2+)
--
-- قاعده: هر تغییر schema فقط از طریق Migration نسخه‌دار؛ اجرا: scripts/db-migrate.sh
-- =============================================================================

-- -----------------------------------------------------------------------------
-- ستون‌های تکمیلی هویت
-- -----------------------------------------------------------------------------
alter table iam.roles
  add column requires_mfa boolean not null default false;

comment on column iam.roles.requires_mfa is
  'نقش حساس: ورود بدون MFA تأییدشده مسدود است (ADR-007، T-SEC-06)';

alter table iam.users
  add column password_changed_at timestamptz;

comment on column iam.users.password_changed_at is
  'زمان آخرین تغییر رمز؛ مبنای سیاست بازبینی، نه انقضای اجباری دوره‌ای (NIST)';

-- -----------------------------------------------------------------------------
-- iam.mfa_factors — عامل دوم
-- -----------------------------------------------------------------------------
create table iam.mfa_factors (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references iam.users (id) on delete cascade,
  kind              text not null check (kind in ('totp', 'recovery_code')),
  secret_ciphertext bytea not null,        -- TOTP: رمزنگاری‌شده با کلید اپ؛ بازیابی: هش
  label             text,
  confirmed_at      timestamptz,           -- تا تأیید نشود، ورود را باز نمی‌کند
  last_used_at      timestamptz,
  created_at        timestamptz not null default now(),
  disabled_at       timestamptz,
  constraint mfa_factors_secret_present check (octet_length(secret_ciphertext) >= 16)
);

create unique index mfa_factors_one_totp_per_user
  on iam.mfa_factors (user_id)
  where kind = 'totp' and disabled_at is null;

create index mfa_factors_confirmed_idx
  on iam.mfa_factors (user_id)
  where confirmed_at is not null and disabled_at is null;

comment on table iam.mfa_factors is
  'عامل دوم کاربر؛ راز TOTP هرگز خام ذخیره نمی‌شود (SECURITY_ARCHITECTURE §6)';

-- -----------------------------------------------------------------------------
-- بذر نقش‌ها (USER_ROLES_AND_PERMISSIONS §2)
-- -----------------------------------------------------------------------------
insert into iam.roles (key, title, description, is_system, requires_mfa) values
  ('R-CEO',   'مدیرعامل',              'همه (خواندن) + تأیید سطح بالا',      true, true),
  ('R-SALES', 'مدیر فروش',             'سفارش، قیمت، کاتالوگ',               true, true),
  ('R-FIN',   'مدیر مالی',             'مالی + تأیید پرداخت',                true, true),
  ('R-ACC',   'حسابدار',               'اسناد، فاکتور، تطبیق',               true, true),
  ('R-BUY',   'مسئول تأمین',           'خرید و تأمین‌کننده (فاز ۲)',          true, true),
  ('R-WH',    'سرپرست انبار',          'موجودی، رسید، شمارش',                true, true),
  ('R-OP',    'اپراتور انبار',         'برداشت/بسته‌بندی',                   true, false),
  ('R-MKT',   'بازاریابی',             'کمپین، تخفیف، محتوا',                true, true),
  ('R-SUP',   'پشتیبانی',              'تیکت و RMA (درخواست)',               true, true),
  ('R-SYS',   'مدیر سیستم',            'پیکربندی، نقش، پایش',                true, true),
  ('R-CUST',  'مشتری',                 'فقط منابع خودش؛ ورود با OTP',        true, false)
-- روی نسخه قبل (T-MIG-02) نقش ممکن است از پیش وجود داشته باشد؛ پرچم MFA باید به‌روز شود
on conflict (key) do update set requires_mfa = excluded.requires_mfa;

-- -----------------------------------------------------------------------------
-- بذر مجوزها — فقط گروه‌های لازم برای BR-1
-- -----------------------------------------------------------------------------
insert into iam.permissions (key, domain, description) values
  ('iam.user.read',        'iam',      'مشاهده کاربران'),
  ('iam.user.create',      'iam',      'ایجاد کاربر کارمند'),
  ('iam.user.disable',     'iam',      'غیرفعال‌سازی کاربر'),
  ('iam.role.assign',      'iam',      'تخصیص/سلب نقش'),
  ('iam.permission.read',  'iam',      'مشاهده ماتریس مجوز'),
  ('iam.session.revoke',   'iam',      'ابطال نشست/دستگاه'),
  ('iam.audit.read',       'iam',      'مشاهده Audit'),
  ('platform.setting.read','platform', 'خواندن تنظیمات'),
  ('platform.setting.write','platform','نوشتن تنظیم نسخه‌دار'),
  ('platform.flag.toggle', 'platform', 'تغییر Feature Flag'),
  ('platform.job.run',     'platform', 'اجرای Job'),
  ('platform.job.retry',   'platform', 'تلاش دوباره Job'),
  ('platform.dlq.inspect', 'platform', 'بازرسی DLQ'),
  ('platform.health.read', 'platform', 'خواندن سلامت سامانه'),
  ('export.data',          'export',   'Export داده مجاز'),
  ('export.pii',           'export',   'Export PII (فقط R-SYS)'),
  ('report.build',         'report',   'ساخت گزارش تحلیلی')
on conflict (key) do nothing;

-- نگاشت نقش×مجوز، مطابق ماتریس خلاصه §4 (زیرمجموعه BR-1)
insert into iam.role_permissions (role_id, permission_id)
select r.id, p.id
from (values
  ('R-CEO',  'iam.user.read'), ('R-CEO',  'iam.audit.read'),
  ('R-CEO',  'platform.setting.read'), ('R-CEO', 'platform.health.read'),
  ('R-CEO',  'export.data'), ('R-CEO',  'report.build'),

  ('R-FIN',  'iam.user.read'), ('R-FIN',  'iam.audit.read'),
  ('R-FIN',  'platform.setting.read'), ('R-FIN', 'platform.setting.write'),
  ('R-FIN',  'export.data'), ('R-FIN',  'report.build'),

  ('R-WH',   'iam.user.read'), ('R-WH',   'platform.setting.read'),

  ('R-SALES','platform.setting.read'),

  ('R-SYS',  'iam.user.read'), ('R-SYS',  'iam.user.create'),
  ('R-SYS',  'iam.user.disable'), ('R-SYS', 'iam.role.assign'),
  ('R-SYS',  'iam.permission.read'), ('R-SYS', 'iam.session.revoke'),
  ('R-SYS',  'iam.audit.read'), ('R-SYS',  'platform.setting.read'),
  ('R-SYS',  'platform.setting.write'), ('R-SYS', 'platform.flag.toggle'),
  ('R-SYS',  'platform.job.run'), ('R-SYS', 'platform.job.retry'),
  ('R-SYS',  'platform.dlq.inspect'), ('R-SYS', 'platform.health.read'),
  ('R-SYS',  'export.data'), ('R-SYS',  'export.pii'),
  ('R-SYS',  'report.build')
) as m(role_key, permission_key)
join iam.roles r on r.key = m.role_key
join iam.permissions p on p.key = m.permission_key
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- تفکیک وظایف در DB (USER_ROLES §5) — حتی با دور زدن UI هم نقض ممکن نیست
-- -----------------------------------------------------------------------------
create table iam.sod_role_conflicts (
  rule_code  text not null,                         -- SoD-7
  role_a     text not null references iam.roles (key) on update cascade,
  role_b     text not null references iam.roles (key) on update cascade,
  note       text,
  primary key (rule_code, role_a, role_b),
  constraint sod_role_conflicts_ordered check (role_a < role_b)
);

comment on table iam.sod_role_conflicts is
  'ترکیب نقش‌های ممنوع؛ هر ردیف یک قاعده SoD قابل‌آزمون است';

-- SoD-7: R-SYS سند مالی ثبت/تأیید نمی‌کند ⇒ نمی‌تواند نقش مالی هم داشته باشد
insert into iam.sod_role_conflicts (rule_code, role_a, role_b, note) values
  ('SoD-7', 'R-ACC', 'R-SYS', 'مدیر سیستم نباید حسابدار باشد'),
  ('SoD-7', 'R-FIN', 'R-SYS', 'مدیر سیستم نباید تأییدکننده مالی باشد');

create function iam.enforce_sod_role_conflicts() returns trigger
language plpgsql as $$
declare
  v_role   text;
  v_other  text;
  v_rule   text;
begin
  select key into v_role from iam.roles where id = new.role_id;

  select c.rule_code, r.key
    into v_rule, v_other
    from iam.user_roles ur
    join iam.roles r on r.id = ur.role_id
    join iam.sod_role_conflicts c
      on (c.role_a = least(v_role, r.key) and c.role_b = greatest(v_role, r.key))
   where ur.user_id = new.user_id
     and ur.role_id <> new.role_id
   limit 1;

  if v_other is not null then
    raise exception 'FCO-1004: % — ترکیب نقش‌های % و % برای کاربر % مجاز نیست',
      v_rule, v_role, v_other, new.user_id
      using errcode = 'insufficient_privilege';
  end if;
  return new;
end $$;

create trigger user_roles_sod_conflict
  before insert or update on iam.user_roles
  for each row execute function iam.enforce_sod_role_conflicts();

-- Maker≠Checker برای تأییدهای دامنه (SoD-1/2/3/5/6)؛ جدول تأیید در BR-2 می‌آید
create function sys.assert_separation(p_maker uuid, p_checker uuid, p_context text)
returns void
language plpgsql immutable as $$
begin
  if p_maker is null or p_checker is null then
    raise exception 'FCO-1004: SoD — ایجادکننده و تأییدکننده هر دو لازم‌اند (%)', p_context
      using errcode = 'insufficient_privilege';
  end if;
  if p_maker = p_checker then
    raise exception 'FCO-1004: SoD — % نمی‌تواند توسط ایجادکننده خود تأیید شود', p_context
      using errcode = 'insufficient_privilege';
  end if;
end $$;

comment on function sys.assert_separation(uuid, uuid, text) is
  'قید مشترک Maker≠Checker؛ هر use-case تأیید باید این را هم صدا بزند';

-- -----------------------------------------------------------------------------
-- سیاست‌های هویت: تنظیم نسخه‌دار، نه عدد هارد‌کد (FR-15-04)
-- -----------------------------------------------------------------------------
insert into sys.settings (key, value, description) values
  ('auth.password.min_length',      '12'::jsonb, 'حداقل طول رمز کارکنان'),
  ('auth.password.max_length',      '128'::jsonb, 'حداکثر طول پذیرفته‌شده'),
  ('auth.password.min_classes',     '3'::jsonb,  'تعداد دسته‌های کاراکتری لازم'),
  ('auth.password.reject_common',   'true'::jsonb, 'رد رمزهای فهرست رایج'),
  ('auth.session.idle_minutes',     '30'::jsonb, 'انقضای بی‌فعالیتی نشست'),
  ('auth.session.absolute_hours',   '12'::jsonb, 'عمر مطلق نشست'),
  ('auth.session.max_active',       '5'::jsonb,  'حداکثر نشست فعال هر کاربر'),
  ('auth.login.max_failed_attempts','5'::jsonb,  'آستانه قفل پس از تلاش ناموفق'),
  ('auth.login.lock_minutes',       '15'::jsonb, 'مدت قفل ورود')
on conflict (key) do nothing;

insert into sys.setting_versions (key, value, effective_from, reason) values
  ('auth.password.min_length',      '12'::jsonb,    '2026-01-01 00:00:00+00', 'مقدار اولیه BR-1'),
  ('auth.password.max_length',      '128'::jsonb,   '2026-01-01 00:00:00+00', 'مقدار اولیه BR-1'),
  ('auth.password.min_classes',     '3'::jsonb,     '2026-01-01 00:00:00+00', 'مقدار اولیه BR-1'),
  ('auth.password.reject_common',   'true'::jsonb,  '2026-01-01 00:00:00+00', 'مقدار اولیه BR-1'),
  ('auth.session.idle_minutes',     '30'::jsonb,    '2026-01-01 00:00:00+00', 'مقدار اولیه BR-1'),
  ('auth.session.absolute_hours',   '12'::jsonb,    '2026-01-01 00:00:00+00', 'مقدار اولیه BR-1'),
  ('auth.session.max_active',       '5'::jsonb,     '2026-01-01 00:00:00+00', 'مقدار اولیه BR-1'),
  ('auth.login.max_failed_attempts','5'::jsonb,     '2026-01-01 00:00:00+00', 'مقدار اولیه BR-1'),
  ('auth.login.lock_minutes',       '15'::jsonb,    '2026-01-01 00:00:00+00', 'مقدار اولیه BR-1')
on conflict (key, effective_from) do nothing;

create function sys.setting_value(p_key text) returns jsonb
language sql stable security definer set search_path = sys, pg_catalog as $$
  select coalesce(
    (select v.value
       from sys.setting_versions v
      where v.key = p_key
        and v.effective_from <= now()
        and (v.effective_to is null or v.effective_to > now())
      order by v.effective_from desc
      limit 1),
    (select s.value from sys.settings s where s.key = p_key)
  );
$$;

create function sys.setting_int(p_key text) returns integer
language plpgsql stable security definer set search_path = sys, pg_catalog as $$
declare v_value jsonb := sys.setting_value(p_key);
begin
  if v_value is null then
    raise exception 'FCO-1010: تنظیم % تعریف نشده است', p_key using errcode = '22023';
  end if;
  return (v_value #>> '{}')::integer;
end $$;

-- رمزهای رایج؛ لیست کوتاه و قابل‌گسترش، نه داور کامل (NIST: بررسی لیست رایج)
create table iam.common_passwords (
  password text primary key,
  note     text
);

insert into iam.common_passwords (password, note) values
  ('password',        'کلاسیک'),
  ('password1',       'کلاسیک'),
  ('Password123!',    'الگوی آموزش‌دیده'),
  ('Qwerty123456',    'الگوی صفحه‌کلید'),
  ('123456789012',    'فقط عدد'),
  ('admin1234567',    'نام محصول'),
  ('welcome12345',    'خوش‌آمد'),
  ('iloveyou123',     'عبارت رایج'),
  ('fco123456789',    'نام پروژه'),
  ('letmein12345',    'عبارت رایج')
on conflict (password) do nothing;

-- -----------------------------------------------------------------------------
-- توابع احراز هویت/مجوز (security definer: اپ به جدول‌ها دست نمی‌زند)
-- -----------------------------------------------------------------------------
create function iam.has_permission(p_user_id uuid, p_permission text)
returns boolean
language sql stable security definer set search_path = iam, pg_catalog as $$
  select exists (
    select 1
      from iam.users u
      join iam.user_roles ur on ur.user_id = u.id
      join iam.roles r on r.id = ur.role_id
      join iam.role_permissions rp on rp.role_id = r.id
      join iam.permissions p on p.id = rp.permission_id
     where u.id = p_user_id
       and u.status = 'active'
       and u.archived_at is null
       and p.key = p_permission
  );
$$;

create function iam.authorize(p_user_id uuid, p_permission text)
returns void
language plpgsql stable security definer set search_path = iam, pg_catalog as $$
declare v_status text;
begin
  select status into v_status
    from iam.users
   where id = p_user_id and archived_at is null;

  if v_status is null then
    raise exception 'FCO-1005: کاربر نامعتبر است (%)', p_user_id using errcode = '28000';
  end if;
  if v_status <> 'active' then
    raise exception 'FCO-1005: حساب کاربر % است', v_status using errcode = '28000';
  end if;
  if not iam.has_permission(p_user_id, p_permission) then
    raise exception 'FCO-1003: مجوز % برای این کاربر وجود ندارد', p_permission
      using errcode = 'insufficient_privilege';
  end if;
end $$;

comment on function iam.authorize(uuid, text) is
  'بررسی مجوز در use-case؛ اپ باید 42501 را به 403 FCO-1003 و 28000 را به 401 نگاشت کند';

create function iam.assert_password_policy(p_password text)
returns void
language plpgsql security definer set search_path = iam, sys, pg_catalog as $$
declare
  v_min_len     integer := sys.setting_int('auth.password.min_length');
  v_max_len     integer := sys.setting_int('auth.password.max_length');
  v_min_classes integer := sys.setting_int('auth.password.min_classes');
  v_classes     integer := 0;
begin
  if p_password is null or p_password = '' then
    raise exception 'FCO-1007: رمز خالی مجاز نیست' using errcode = '22023';
  end if;
  if length(p_password) < v_min_len then
    raise exception 'FCO-1007: رمز باید حداقل % کاراکتر باشد', v_min_len using errcode = '22023';
  end if;
  if length(p_password) > v_max_len then
    raise exception 'FCO-1007: رمز نباید بیش از % کاراکتر باشد', v_max_len using errcode = '22023';
  end if;

  if p_password ~ '[0-9]'               then v_classes := v_classes + 1; end if;
  if p_password ~ '[a-z]'               then v_classes := v_classes + 1; end if;
  if p_password ~ '[A-Z]'               then v_classes := v_classes + 1; end if;
  if p_password ~ '[^0-9a-zA-Z[:space:]]' then v_classes := v_classes + 1; end if;

  if v_classes < v_min_classes then
    raise exception 'FCO-1007: رمز باید از % دسته کاراکتری متفاوت باشد (فعلی: %)',
      v_min_classes, v_classes using errcode = '22023';
  end if;

  if sys.setting_value('auth.password.reject_common') = 'true'::jsonb
     and exists (select 1 from iam.common_passwords c
                  where lower(c.password) = lower(p_password)) then
    raise exception 'FCO-1007: رمز در فهرست رمزهای رایج است' using errcode = '22023';
  end if;
end $$;

create function iam.start_session(
  p_user_id uuid,
  p_token_hash bytea,
  p_ip inet default null,
  p_user_agent text default null
) returns uuid
language plpgsql security definer set search_path = iam, sys, pg_catalog as $$
declare
  v_status       text;
  v_mfa_required boolean;
  v_max_active   integer := sys.setting_int('auth.session.max_active');
  v_hours        integer := sys.setting_int('auth.session.absolute_hours');
  v_session_id   uuid;
begin
  select u.status,
         u.mfa_required or exists (
           select 1
             from iam.user_roles ur
             join iam.roles r on r.id = ur.role_id
            where ur.user_id = u.id and r.requires_mfa
         )
    into v_status, v_mfa_required
    from iam.users u
   where u.id = p_user_id and u.archived_at is null;

  if v_status is null then
    raise exception 'FCO-1005: کاربر نامعتبر است (%)', p_user_id using errcode = '28000';
  end if;
  if v_status <> 'active' then
    raise exception 'FCO-1005: ورود برای حساب % مجاز نیست', v_status using errcode = '28000';
  end if;

  if v_mfa_required and not exists (
    select 1 from iam.mfa_factors f
     where f.user_id = p_user_id
       and f.kind = 'totp'
       and f.confirmed_at is not null
       and f.disabled_at is null
  ) then
    raise exception 'FCO-1006: ورود نقش حساس بدون MFA تأییدشده مسدود است'
      using errcode = 'insufficient_privilege';
  end if;

  if (select count(*) from iam.sessions s
       where s.user_id = p_user_id and s.revoked_at is null and s.expires_at > now()) >= v_max_active then
    update iam.sessions
       set revoked_at = now(), revoke_reason = 'session_limit'
     where id = (select s.id from iam.sessions s
                  where s.user_id = p_user_id and s.revoked_at is null and s.expires_at > now()
                  order by s.created_at asc
                  limit 1);
  end if;

  insert into iam.sessions (user_id, token_hash, ip, user_agent, expires_at)
  values (p_user_id, p_token_hash, p_ip, p_user_agent,
          now() + make_interval(hours => v_hours))
  returning id into v_session_id;

  return v_session_id;
end $$;

create function iam.authenticate(p_token_hash bytea, p_touch boolean default true)
returns table (sid uuid, uid uuid)
language plpgsql security definer set search_path = iam, sys, pg_catalog as $$
declare
  v_session record;
  v_idle    interval := make_interval(mins => sys.setting_int('auth.session.idle_minutes'));
begin
  select s.id, s.user_id, s.expires_at, s.revoked_at, s.created_at, s.last_seen_at, u.status
    into v_session
    from iam.sessions s
    join iam.users u on u.id = s.user_id
   where s.token_hash = p_token_hash;

  if not found then
    raise exception 'FCO-1001: نشست معتبر نیست' using errcode = '28000';
  end if;
  if v_session.revoked_at is not null then
    raise exception 'FCO-1001: نشست ابطال شده است' using errcode = '28000';
  end if;
  if v_session.expires_at <= now() then
    raise exception 'FCO-1001: نشست منقضی شده است' using errcode = '28000';
  end if;
  if coalesce(v_session.last_seen_at, v_session.created_at) + v_idle <= now() then
    raise exception 'FCO-1001: نشست به‌دلیل بی‌فعالیتی منقضی شده است' using errcode = '28000';
  end if;
  if v_session.status <> 'active' then
    raise exception 'FCO-1001: حساب کاربر فعال نیست' using errcode = '28000';
  end if;

  if p_touch then
    update iam.sessions set last_seen_at = now() where id = v_session.id;
  end if;

  return query select v_session.id, v_session.user_id;
end $$;

create function iam.revoke_session(p_session_id uuid, p_reason text default 'logout')
returns boolean
language plpgsql security definer set search_path = iam, pg_catalog as $$
begin
  update iam.sessions
     set revoked_at = now(), revoke_reason = p_reason
   where id = p_session_id and revoked_at is null;
  return found;
end $$;

create function iam.revoke_all_sessions(p_user_id uuid, p_reason text default 'revoke_all')
returns integer
language plpgsql security definer set search_path = iam, pg_catalog as $$
declare v_count integer;
begin
  update iam.sessions
     set revoked_at = now(), revoke_reason = p_reason
   where user_id = p_user_id and revoked_at is null;
  get diagnostics v_count = row_count;
  return v_count;
end $$;

create function iam.set_password_hash(p_user_id uuid, p_password_hash text)
returns void
language plpgsql security definer set search_path = iam, pg_catalog as $$
begin
  if p_password_hash is null or length(p_password_hash) < 20 then
    raise exception 'FCO-1008: هش رمز نامعتبر است (Argon2id در لایه اپ ساخته می‌شود)'
      using errcode = '22023';
  end if;

  update iam.users
     set password_hash = p_password_hash,
         password_changed_at = now(),
         must_change_password = false,
         failed_attempts = 0,
         locked_until = null,
         status = case when status = 'locked' then 'active' else status end
   where id = p_user_id and archived_at is null;

  if not found then
    raise exception 'FCO-1005: کاربر نامعتبر است (%)', p_user_id using errcode = '28000';
  end if;

  -- چرخش اجباری: تغییر رمز همه نشست‌های قبلی را باطل می‌کند (ADR-007)
  perform iam.revoke_all_sessions(p_user_id, 'password_changed');
end $$;

comment on function iam.set_password_hash(uuid, text) is
  'ذخیره هش Argon2id؛ سیاست رمز باید پیش‌تر با iam.assert_password_policy بررسی شود';

create function iam.register_login_failure(p_user_id uuid)
returns timestamptz
language plpgsql security definer set search_path = iam, sys, pg_catalog as $$
declare
  v_max    integer := sys.setting_int('auth.login.max_failed_attempts');
  v_lock   integer := sys.setting_int('auth.login.lock_minutes');
  v_locked timestamptz;
begin
  update iam.users
     set failed_attempts = failed_attempts + 1,
         locked_until = case
                          when failed_attempts + 1 >= v_max
                            then now() + make_interval(mins => v_lock)
                          else locked_until
                        end,
         status = case when failed_attempts + 1 >= v_max then 'locked' else status end
   where id = p_user_id and archived_at is null
  returning locked_until into v_locked;

  if not found then
    raise exception 'FCO-1005: کاربر نامعتبر است (%)', p_user_id using errcode = '28000';
  end if;
  return v_locked;
end $$;

create function iam.register_login_success(p_user_id uuid)
returns void
language plpgsql security definer set search_path = iam, pg_catalog as $$
begin
  update iam.users
     set failed_attempts = 0,
         locked_until = null,
         last_login_at = now(),
         status = case when status = 'locked' then 'active' else status end
   where id = p_user_id and archived_at is null;

  if not found then
    raise exception 'FCO-1005: کاربر نامعتبر است (%)', p_user_id using errcode = '28000';
  end if;
end $$;

create function iam.grant_role(p_actor uuid, p_user_id uuid, p_role_key text)
returns void
language plpgsql security definer set search_path = iam, pg_catalog as $$
declare v_role_id uuid;
begin
  perform iam.authorize(p_actor, 'iam.role.assign');

  select id into v_role_id from iam.roles where key = p_role_key;
  if v_role_id is null then
    raise exception 'FCO-1011: نقش % وجود ندارد', p_role_key using errcode = '22023';
  end if;

  -- SoD-4: تخصیص نقش سیستم به خود
  if p_actor = p_user_id and p_role_key = 'R-SYS' then
    raise exception 'FCO-1004: SoD-4 — تخصیص نقش R-SYS به خود مجاز نیست'
      using errcode = 'insufficient_privilege';
  end if;

  insert into iam.user_roles (user_id, role_id, granted_by)
  values (p_user_id, v_role_id, p_actor)
  on conflict (user_id, role_id) do nothing;
end $$;

-- -----------------------------------------------------------------------------
-- نقش دیتابیس اپ: تفکیک کاربر Migration از کاربر اپ (D-12)
-- -----------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'fco_app') then
    execute 'create role fco_app nologin';
  end if;
end $$;

comment on role fco_app is
  'نقش اپ: بدون DDL، بدون تغییر دفترها؛ رمز ورود از محیط تزریق می‌شود، نه مخزن';

grant usage on schema iam, sys to fco_app;

grant select, insert, update on iam.users to fco_app;
grant select on iam.roles, iam.permissions, iam.role_permissions,
                iam.user_roles, iam.sod_role_conflicts, iam.common_passwords to fco_app;
grant select, insert, update on iam.sessions to fco_app;
grant select, insert, update on iam.mfa_factors to fco_app;

grant select, insert on sys.audit_log to fco_app;
grant usage, select on sequence sys.audit_log_id_seq to fco_app;
grant select on sys.settings, sys.setting_versions to fco_app;

grant execute on function
  iam.has_permission(uuid, text),
  iam.authorize(uuid, text),
  iam.assert_password_policy(text),
  iam.start_session(uuid, bytea, inet, text),
  iam.authenticate(bytea, boolean),
  iam.revoke_session(uuid, text),
  iam.revoke_all_sessions(uuid, text),
  iam.set_password_hash(uuid, text),
  iam.register_login_failure(uuid),
  iam.register_login_success(uuid),
  iam.grant_role(uuid, uuid, text),
  sys.setting_value(text),
  sys.setting_int(text),
  sys.assert_separation(uuid, uuid, text)
to fco_app;

-- کمترین دسترسی: هیچ شیئی برای PUBLIC و هیچ DDL برای اپ
revoke all on iam.users, iam.sessions, iam.mfa_factors from public;
revoke all on sys.audit_log from public;
revoke create on schema iam, sys from fco_app;

comment on schema iam is
  'هویت، نقش و نشست (DATABASE_DESIGN §3.1) — دسترسی اپ فقط از توابع و GRANT محدود';
