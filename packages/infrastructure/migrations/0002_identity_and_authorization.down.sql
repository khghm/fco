-- =============================================================================
-- 0002_identity_and_authorization.down — بازگشت گام ۵
-- توجه: بذر نقش/مجوز/تنظیماتِ همین Migration پاک می‌شود؛ در محیط توسعه است.
-- =============================================================================

drop trigger if exists user_roles_sod_conflict on iam.user_roles;
drop function if exists iam.enforce_sod_role_conflicts();
drop table if exists iam.sod_role_conflicts;

drop function if exists iam.grant_role(uuid, uuid, text);
drop function if exists iam.register_login_success(uuid);
drop function if exists iam.register_login_failure(uuid);
drop function if exists iam.set_password_hash(uuid, text);
drop function if exists iam.revoke_all_sessions(uuid, text);
drop function if exists iam.revoke_session(uuid, text);
drop function if exists iam.authenticate(bytea, boolean);
drop function if exists iam.start_session(uuid, bytea, inet, text);
drop function if exists iam.assert_password_policy(text);
drop function if exists iam.authorize(uuid, text);
drop function if exists iam.has_permission(uuid, text);
drop function if exists sys.assert_separation(uuid, uuid, text);
drop function if exists sys.setting_int(text);
drop function if exists sys.setting_value(text);

delete from sys.setting_versions where key like 'auth.%';
delete from sys.settings where key like 'auth.%';

delete from iam.role_permissions;
delete from iam.user_roles;
delete from iam.permissions;
delete from iam.roles;

drop table if exists iam.common_passwords;
drop table if exists iam.mfa_factors;

alter table iam.users drop column if exists password_changed_at;
alter table iam.roles drop column if exists requires_mfa;

-- پیش از حذف نقش، همه GRANTهای روی اشیای باقی‌مانده باید برداشته شود
revoke all on iam.users, iam.roles, iam.permissions, iam.role_permissions,
               iam.user_roles, iam.sessions from fco_app;
revoke all on sys.audit_log, sys.settings, sys.setting_versions from fco_app;
revoke all on sequence sys.audit_log_id_seq from fco_app;
revoke all on schema iam, sys from fco_app;
drop role if exists fco_app;

comment on schema iam is 'هویت، نقش و نشست (DATABASE_DESIGN §3.1)';
