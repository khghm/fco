-- =============================================================================
-- 0008_ops_monitoring.down — بازگشت گام ۹
-- =============================================================================

drop function if exists sys.health_report(uuid);
drop function if exists sys.run_session_cleanup(timestamptz, integer);
drop function if exists sys.purge_expired_sessions(integer);
drop function if exists sys.job_finish(bigint, text, text);
drop function if exists sys.job_begin(text, timestamptz);

-- تاریخچه تنظیم پاک نمی‌شود (ممنوعیت حذف نسخه در 0005)؛ بذر 0008 فقط در
-- نبود نسخه اجرا می‌شود، پس اجرای دوباره آن را تکرار نمی‌کند.
