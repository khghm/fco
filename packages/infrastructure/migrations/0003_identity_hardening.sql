-- =============================================================================
-- 0003_identity_hardening — بازبینی گام ۵: بستن سه شکاف واقعی
--
-- ۱) MFA/چرخش دور زدنی بود: `fco_app` اجازه INSERT روی `iam.sessions` داشت،
--    پس با یک مسیر کد نادرست می‌شد بدون `start_session` (و بدون MFA) نشست ساخت.
--    اکنون نوشتن نشست فقط از تابع است.
-- ۲) `fco_app` اجازه UPDATE کامل `iam.users` داشت و می‌توانست `password_hash`
--    را دور از `set_password_hash` (و بدون ابطال نشست‌ها) عوض کند. اکنون GRANT
--    ستونی است و `password_hash` فقط از تابع تغییر می‌کند.
-- ۳) قفل ورود پس از انقضای `locked_until` هرگز باز نمی‌شد: `start_session`
--    وضعیت `locked` را رد می‌کرد و مسیر موفق وجود نداشت. اکنون قفل منقضی
--    به‌صورت خودکار در شروع ورود آزاد می‌شود.
-- به‌علاوه: قالب هش در `set_password_hash` اعتبارسنجی می‌شود (Argon2id/bcrypt≥12)،
-- و SELECT فهرست رمزهای رایج از اپ گرفته می‌شود (فقط تابع امنیتی آن را می‌خواند).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- ۱ و ۲: حداقل دسترسی نوشتن
-- -----------------------------------------------------------------------------
revoke insert, update on iam.sessions from fco_app;
-- هر دو سطح لازم است: GRANT ستونی، GRANT سطح‌جدول را حذف نمی‌کند
revoke insert, update on iam.users from fco_app;
revoke select on iam.common_passwords from fco_app;

grant insert (mobile, email, full_name, status, mfa_required, must_change_password, created_by)
  on iam.users to fco_app;
grant update (mobile, email, full_name, status, mfa_required, must_change_password)
  on iam.users to fco_app;

comment on table iam.sessions is
  'نشست‌ها فقط با iam.start_session ساخته می‌شوند؛ اپ اجازه INSERT/UPDATE مستقیم ندارد';

-- -----------------------------------------------------------------------------
-- ۳: آزادسازی خودکار قفل منقضی
-- -----------------------------------------------------------------------------
create function iam.unlock_if_expired(p_user_id uuid)
returns void
language plpgsql security definer set search_path = iam, pg_catalog as $$
begin
  update iam.users
     set status = 'active',
         failed_attempts = 0,
         locked_until = null
   where id = p_user_id
     and status = 'locked'
     and locked_until is not null
     and locked_until <= now();
end $$;

comment on function iam.unlock_if_expired(uuid) is
  'قفل تدریجی موقت است؛ پس از پایان locked_until ورود دوباره ممکن می‌شود';

create or replace function iam.start_session(
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
  perform iam.unlock_if_expired(p_user_id);

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

-- -----------------------------------------------------------------------------
-- قالب هش در تنها مسیر مجاز تغییر رمز
-- -----------------------------------------------------------------------------
create or replace function iam.set_password_hash(p_user_id uuid, p_password_hash text)
returns void
language plpgsql security definer set search_path = iam, pg_catalog as $$
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
end $$;
