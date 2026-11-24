-- =============================================================================
-- 0006_password_change_actor.down — بازگشت به امضای پیش از بازبینی
-- =============================================================================

drop function if exists iam.set_password_hash(uuid, text, uuid, text);

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

grant execute on function iam.set_password_hash(uuid, text, text) to fco_app;
