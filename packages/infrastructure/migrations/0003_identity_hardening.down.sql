-- =============================================================================
-- 0003_identity_hardening.down — بازگشت اصلاحات بازبینی گام ۵
-- =============================================================================

drop function if exists iam.unlock_if_expired(uuid);

create or replace function iam.set_password_hash(p_user_id uuid, p_password_hash text)
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

  perform iam.revoke_all_sessions(p_user_id, 'password_changed');
end $$;

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

grant insert, update on iam.sessions to fco_app;
grant insert, update on iam.users to fco_app;
grant select on iam.common_passwords to fco_app;
revoke insert (mobile, email, full_name, status, mfa_required, must_change_password, created_by)
  on iam.users from fco_app;
revoke update (mobile, email, full_name, status, mfa_required, must_change_password)
  on iam.users from fco_app;

comment on table iam.sessions is 'نشست‌ها؛ توکن فقط به‌صورت هش (DATABASE_DESIGN §3.1)';
