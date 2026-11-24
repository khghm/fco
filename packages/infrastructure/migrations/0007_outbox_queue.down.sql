-- =============================================================================
-- 0007_outbox_queue.down — بازگشت گام ۸
-- =============================================================================

drop function if exists sys.dlq_list(uuid, integer);
drop function if exists sys.inbox_consume(text, text);
drop function if exists sys.outbox_fail(bigint, text);
drop function if exists sys.outbox_complete(bigint);
drop function if exists sys.outbox_claim(text, integer);
drop function if exists sys.outbox_emit(text, uuid, text, jsonb, jsonb);

-- تاریخچه تنظیم عمداً پاک نمی‌شود: تریگر 0005 حذف نسخه را رد می‌کند
-- (تاریخچه تنظیم فقط‌افزودنی است). مقادیر outbox.* بی‌ضرر می‌مانند و
-- اجرای دوباره `up` با on conflict دوباره آن‌ها را نمی‌سازد.
