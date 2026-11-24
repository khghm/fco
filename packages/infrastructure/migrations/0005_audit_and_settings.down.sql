-- =============================================================================
-- 0005_audit_and_settings.down — بازگشت گام ۷
-- =============================================================================

drop function if exists iam.set_password_hash(uuid, text, text);
drop function if exists iam.grant_role(uuid, uuid, text, text);

-- بازگرداندن امضاهای پیش از گام ۷
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

  if p_actor = p_user_id and p_role_key = 'R-SYS' then
    raise exception 'FCO-1004: SoD-4 — تخصیص نقش R-SYS به خود مجاز نیست'
      using errcode = 'insufficient_privilege';
  end if;

  insert into iam.user_roles (user_id, role_id, granted_by)
  values (p_user_id, v_role_id, p_actor)
  on conflict (user_id, role_id) do nothing;
end $$;

create function iam.set_password_hash(p_user_id uuid, p_password_hash text)
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

  perform iam.revoke_all_sessions(p_user_id, 'password_changed');
end $$;

drop function if exists sys.setting_set(uuid, text, jsonb, timestamptz, text, text);
drop trigger if exists setting_versions_guard on sys.setting_versions;
drop function if exists sys.setting_versions_guard();
drop function if exists sys.audit_search(uuid, text, uuid, uuid, text, timestamptz, timestamptz, integer, integer);
drop function if exists sys.audit_write(uuid, text, text, uuid, jsonb, jsonb, text, text, text);

grant insert on sys.audit_log to fco_app;

grant execute on function
  iam.grant_role(uuid, uuid, text),
  iam.set_password_hash(uuid, text)
to fco_app;
