-- =============================================================================
-- 0004_otp_customer.down — بازگشت گام ۶
-- =============================================================================

drop function if exists iam.read_spool(uuid);
drop function if exists iam.spool_otp(uuid, text);
drop function if exists iam.verify_otp(text, text, bytea);
drop function if exists iam.request_otp(text, text, bytea, inet);

drop table if exists sys.otp_spool;
drop table if exists iam.otp_requests;

delete from sys.setting_versions where key like 'auth.otp.%';
delete from sys.settings where key like 'auth.otp.%';
