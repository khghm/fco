-- =============================================================================
-- 0006_password_change_actor — بازبینی گام ۷: عامل واقعی تغییر رمز
--
-- مشکل: `iam.set_password_hash` رکورد Audit را با actor = کاربر هدف می‌نوشت.
-- اگر مدیر سیستم رمز کارمند دیگری را بازنشانی می‌کرد، Audit می‌گفت خود کارمند
-- رمزش را عوض کرده است؛ یعنی اتریبیوشن عملیات حساس نادرست بود.
--
-- اصلاح: عامل عملیات پارامتر جداست (`p_actor`) و Audit آن را ثبت می‌کند؛
-- کاربر هدف در `entity_id` و در `after.target_user_id` می‌ماند.
-- برای عملیات self-service، فراخواننده همان `p_actor = p_user_id` را می‌دهد.
-- مجوز بازنشانی رمز دیگران همچنان در use-case اپ بررسی می‌شود؛ این Migration
-- فقط درستی ردپا را تضمین می‌کند.
-- =============================================================================

drop function iam.set_password_hash(uuid, text, text);

create function iam.set_password_hash(
  p_user_id uuid,
  p_password_hash text,
  p_actor uuid,
  p_request_id text default null
) returns void
language plpgsql security definer set search_path = iam, sys, pg_catalog as $$
begin
  if p_actor is null or not exists (
    select 1 from iam.users u where u.id = p_actor and u.archived_at is null
  ) then
    raise exception 'FCO-1005: عامل تغییر رمز نامعتبر است' using errcode = '28000';
  end if;

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
    p_actor      => p_actor,
    p_action     => 'password.change',
    p_entity_type => 'users',
    p_entity_id  => p_user_id,
    p_after      => jsonb_build_object(
                      'password_changed_at', now(),
                      'sessions_revoked', true,
                      'target_user_id', p_user_id,
                      'self_service', p_actor = p_user_id),
    p_permission => null,
    p_request_id => coalesce(p_request_id, 'fn:set_password_hash')
  );
end $$;

comment on function iam.set_password_hash(uuid, text, uuid, text) is
  'تغییر رمز با ثبت عامل واقعی در Audit؛ actor و کاربر هدف جدا نگه داشته می‌شوند';

grant execute on function iam.set_password_hash(uuid, text, uuid, text) to fco_app;
