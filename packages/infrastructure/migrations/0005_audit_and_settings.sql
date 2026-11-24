-- =============================================================================
-- 0005_audit_and_settings — BR-1 گام ۷: Audit قابل‌جست‌وجو + تنظیم نسخه‌دار
-- مالک طرح: docs/Architecture-02/DATABASE_DESIGN.md §3.11
--           docs/Architecture-02/API_SPECIFICATION.md (T-PLT-05، request_id)
--           docs/Business-01/USER_ROLES_AND_PERMISSIONS.md §3.1/§3.10
--
-- تغییرهای این Migration:
--   ۱) تنها مسیر نوشتن Audit تابع `sys.audit_write` است: actor معتبر، action و
--      entity_type غیرخالی، حداقل یکی از before/after، و request_id الزامی.
--      INSERT مستقیم اپ روی `sys.audit_log` گرفته می‌شود.
--   ۲) `sys.audit_search` جست‌وجوی فیلترشده و صفحه‌بندی‌شده با مجوز
--      `iam.audit.read`؛ سقف سخت ۱۰۰ ردیف (اصل «هیچ لیست بدون LIMIT»).
--   ۳) `sys.setting_set` تنها مسیر تغییر تنظیم: مجوز `platform.setting.write`،
--      دلیل اجباری، تاریخ اعتبار غیرگذشته، و Audit در همان تراکنش.
--   ۴) تاریخچه تنظیم تغییرناپذیر و ترتیبی است: نسخه جدید بازه قبلی را می‌بندد،
--      تغییر مقدار نسخه قدیمی و حذف رد می‌شود (FCO-1020/1025).
--   ۵) `iam.grant_role` و `iam.set_password_hash` خودشان Audit می‌نویسند تا
--      عملیات حساس حتی با فراموشی لایه اپ هم ردپا داشته باشد.
--
-- خارج از این Migration: صفحه Audit در پنل و سند Export (BR-2/BR-3)؛
-- ثبت «تلاش ردشده» ممکن نیست چون Exception همان تراکنش را بازمی‌گرداند
-- (شکاف اعلام‌شده؛ راه‌حل: Outbox/Logger بیرونی در گام ۸).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- ۱) مسیر واحد نوشتن Audit
-- -----------------------------------------------------------------------------
revoke insert on sys.audit_log from fco_app;

create function sys.audit_write(
  p_actor uuid,
  p_action text,
  p_entity_type text,
  p_entity_id uuid default null,
  p_before jsonb default null,
  p_after jsonb default null,
  p_reason text default null,
  p_permission text default null,
  p_request_id text default null
) returns bigint
language plpgsql security definer set search_path = sys, iam, pg_catalog as $$
declare v_id bigint;
begin
  if p_actor is null or not exists (
    select 1 from iam.users u where u.id = p_actor and u.archived_at is null
  ) then
    raise exception 'FCO-1005: actor برای ثبت Audit نامعتبر است' using errcode = '28000';
  end if;

  if p_action is null or btrim(p_action) = ''
     or p_entity_type is null or btrim(p_entity_type) = '' then
    raise exception 'FCO-1018: action و entity_type الزامی و غیرخالی‌اند'
      using errcode = '22023';
  end if;

  if p_before is null and p_after is null then
    raise exception 'FCO-1018: حداقل یکی از before/after لازم است' using errcode = '22023';
  end if;

  if p_request_id is null or btrim(p_request_id) = '' then
    raise exception 'FCO-1018: request_id برای ردیابی الزامی است (T-PLT-05)'
      using errcode = '22023';
  end if;

  insert into sys.audit_log
    (actor_id, action, entity_type, entity_id, "before", "after", reason, permission, request_id)
  values
    (p_actor, p_action, p_entity_type, p_entity_id, p_before, p_after,
     p_reason, p_permission, p_request_id)
  returning id into v_id;

  return v_id;
end $$;

comment on function sys.audit_write(uuid, text, text, uuid, jsonb, jsonb, text, text, text) is
  'تنها مسیر مجاز نوشتن Audit؛ request_id اجباری و actor باید کاربر موجود باشد';

-- -----------------------------------------------------------------------------
-- ۲) جست‌وجوی Audit با مجوز و سقف
-- -----------------------------------------------------------------------------
create function sys.audit_search(
  p_caller uuid,
  p_entity_type text default null,
  p_entity_id uuid default null,
  p_actor uuid default null,
  p_action text default null,
  p_from timestamptz default null,
  p_to timestamptz default null,
  p_limit integer default 50,
  p_offset integer default 0
) returns table (
  id bigint,
  created_at timestamptz,
  actor_id uuid,
  action text,
  entity_type text,
  entity_id uuid,
  before jsonb,
  after jsonb,
  reason text,
  request_id text,
  permission text
)
language plpgsql stable security definer set search_path = sys, iam, pg_catalog as $$
declare v_limit integer := least(greatest(coalesce(p_limit, 50), 1), 100);
begin
  perform iam.authorize(p_caller, 'iam.audit.read');

  return query
    select a.id, a.created_at, a.actor_id, a.action, a.entity_type, a.entity_id,
           a."before", a."after", a.reason, a.request_id, a.permission
      from sys.audit_log a
     where (p_entity_type is null or a.entity_type = p_entity_type)
       and (p_entity_id is null or a.entity_id = p_entity_id)
       and (p_actor is null or a.actor_id = p_actor)
       and (p_action is null or a.action = p_action)
       and (p_from is null or a.created_at >= p_from)
       and (p_to is null or a.created_at < p_to)
     order by a.created_at desc, a.id desc
     limit v_limit offset greatest(coalesce(p_offset, 0), 0);
end $$;

comment on function sys.audit_search(uuid, text, uuid, uuid, text, timestamptz, timestamptz, integer, integer) is
  'جست‌وجوی Audit؛ مجوز iam.audit.read و حداکثر ۱۰۰ ردیف در هر صفحه';

-- -----------------------------------------------------------------------------
-- ۳) تاریخچه تنظیمات: ترتیبی، فقط‌افزودنی، با بستن بازه قبلی
-- -----------------------------------------------------------------------------
create function sys.setting_versions_guard() returns trigger
language plpgsql as $$
begin
  if tg_op = 'INSERT' then
    if exists (
      select 1 from sys.setting_versions v
       where v.key = new.key and v.effective_from >= new.effective_from
    ) then
      raise exception 'FCO-1020: نسخه تنظیم % باید بعد از آخرین نسخه ثبت شود', new.key
        using errcode = '22023';
    end if;

    -- بازه نسخه قبلی با شروع نسخه جدید بسته می‌شود؛ دو نسخه هم‌پوشان نمی‌مانند
    update sys.setting_versions
       set effective_to = new.effective_from
     where key = new.key
       and effective_to is null
       and effective_from < new.effective_from;

    return new;
  end if;

  if tg_op = 'DELETE' then
    raise exception 'FCO-1025: تاریخچه تنظیمات حذف نمی‌شود'
      using errcode = 'insufficient_privilege';
  end if;

  -- تنها تغییر مجاز: بستن بازه باز (NULL → مقدار)؛ هر تغییر دیگر = تاریخ‌سازی
  if new.key is distinct from old.key
     or new.value is distinct from old.value
     or new.effective_from is distinct from old.effective_from
     or new.changed_by is distinct from old.changed_by
     or new.reason is distinct from old.reason
     or old.effective_to is not null
     or new.effective_to is null then
    raise exception 'FCO-1025: نسخه تنظیم تغییرناپذیر است؛ فقط بستن بازه مجاز است'
      using errcode = 'insufficient_privilege';
  end if;

  return new;
end $$;

create trigger setting_versions_guard
  before insert or update or delete on sys.setting_versions
  for each row execute function sys.setting_versions_guard();

comment on table sys.setting_versions is
  'تاریخچه فقط‌افزودنی؛ نسخه جدید بازه قبلی را می‌بندد و تغییر/حذف نسخه رد می‌شود';

-- -----------------------------------------------------------------------------
-- ۴) تغییر تنظیم با مجوز، دلیل، تاریخ اعتبار و Audit
-- -----------------------------------------------------------------------------
create function sys.setting_set(
  p_actor uuid,
  p_key text,
  p_value jsonb,
  p_effective_from timestamptz default null,
  p_reason text default null,
  p_request_id text default null
) returns bigint
language plpgsql security definer set search_path = sys, iam, pg_catalog as $$
declare
  v_effective timestamptz := coalesce(p_effective_from, now());
  v_before    jsonb;
  v_id        bigint;
begin
  perform iam.authorize(p_actor, 'platform.setting.write');

  if p_key is null or not exists (select 1 from sys.settings s where s.key = p_key) then
    raise exception 'FCO-1021: تنظیم % تعریف نشده است', p_key using errcode = '22023';
  end if;
  if p_value is null then
    raise exception 'FCO-1021: مقدار تنظیم % خالی است', p_key using errcode = '22023';
  end if;
  if p_reason is null or btrim(p_reason) = '' then
    raise exception 'FCO-1022: دلیل تغییر تنظیم الزامی است' using errcode = '22023';
  end if;
  if v_effective < now() then
    raise exception 'FCO-1023: تاریخ اعتبار تنظیم نمی‌تواند در گذشته باشد'
      using errcode = '22023';
  end if;

  select value into v_before from sys.settings where key = p_key;

  insert into sys.setting_versions (key, value, effective_from, changed_by, reason)
  values (p_key, p_value, v_effective, p_actor, p_reason)
  returning id into v_id;

  if v_effective <= now() then
    update sys.settings set value = p_value where key = p_key;
  end if;

  perform sys.audit_write(
    p_actor      => p_actor,
    p_action     => 'setting.update',
    p_entity_type => 'settings',
    p_before     => jsonb_build_object('key', p_key, 'value', v_before,
                                       'effective_from', v_effective),
    p_after      => jsonb_build_object('key', p_key, 'value', p_value,
                                       'effective_from', v_effective),
    p_reason     => p_reason,
    p_permission => 'platform.setting.write',
    p_request_id => coalesce(p_request_id, 'fn:setting_set')
  );

  return v_id;
end $$;

comment on function sys.setting_set(uuid, text, jsonb, timestamptz, text, text) is
  'تنها مسیر تغییر تنظیم؛ مجوز platform.setting.write + دلیل + تاریخ اعتبار غیرگذشته';

-- -----------------------------------------------------------------------------
-- ۵) Audit خودکار عملیات حساس هویت
-- -----------------------------------------------------------------------------
drop function iam.grant_role(uuid, uuid, text);

create function iam.grant_role(
  p_actor uuid,
  p_user_id uuid,
  p_role_key text,
  p_request_id text default null
) returns void
language plpgsql security definer set search_path = iam, sys, pg_catalog as $$
declare
  v_role_id uuid;
  v_rows    integer;
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

  get diagnostics v_rows = row_count;
  if v_rows > 0 then
    perform sys.audit_write(
      p_actor      => p_actor,
      p_action     => 'role.assign',
      p_entity_type => 'users',
      p_entity_id  => p_user_id,
      p_after      => jsonb_build_object('role', p_role_key),
      p_permission => 'iam.role.assign',
      p_request_id => coalesce(p_request_id, 'fn:grant_role')
    );
  end if;
end $$;

drop function iam.set_password_hash(uuid, text);

create function iam.set_password_hash(
  p_user_id uuid,
  p_password_hash text,
  p_request_id text default null
) returns void
language plpgsql security definer set search_path = iam, sys, pg_catalog as $$
begin
  if p_password_hash is null
     or (p_password_hash !~ '^\$argon2id\$v=19\$'
         and p_password_hash !~ '^\$2[aby]\$1[2-9]\$') then
    raise exception 'FCO-1008: هش رمز باید Argon2id یا bcrypt با cost ≥ 12 باشد'
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

  perform sys.audit_write(
    p_actor      => p_user_id,
    p_action     => 'password.change',
    p_entity_type => 'users',
    p_entity_id  => p_user_id,
    p_after      => jsonb_build_object('password_changed_at', now(), 'sessions_revoked', true),
    p_permission => null,
    p_request_id => coalesce(p_request_id, 'fn:set_password_hash')
  );
end $$;

-- -----------------------------------------------------------------------------
-- دسترسی‌ها
-- -----------------------------------------------------------------------------
grant execute on function
  sys.audit_write(uuid, text, text, uuid, jsonb, jsonb, text, text, text),
  sys.audit_search(uuid, text, uuid, uuid, text, timestamptz, timestamptz, integer, integer),
  sys.setting_set(uuid, text, jsonb, timestamptz, text, text),
  iam.grant_role(uuid, uuid, text, text),
  iam.set_password_hash(uuid, text, text)
to fco_app;

revoke all on sys.audit_log from public;
