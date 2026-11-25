-- =============================================================================
-- 0011_catalog_inventory.down — بازگشت BR-2 گام ۱ (D-12)
--
-- schemaها و اشیای همین Migration را برمی‌دارد. تاریخچه `inv.reservation_ttl_minutes`
-- در `sys.setting_versions` حذف نمی‌شود: تاریخچه تنظیمات فقط‌افزودنی است و
-- تریگر 0005 حذف را رد می‌کند. با اجرای دوباره `up`، بذر به‌خاطر وجود نسخه
-- دوباره ساخته نمی‌شود و مقدار قبلی معتبر می‌ماند.
-- =============================================================================

drop schema if exists inv cascade;
drop schema if exists pricing cascade;
drop schema if exists cat cascade;

-- تنها این Migration آن را ساخته است؛ برای جلوگیری از باقی‌ماندن وابستگی
drop extension if exists btree_gist;
