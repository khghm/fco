-- =============================================================================
-- 0013_inventory_movement.down — بازگشت BR-2 گام ۳
-- تاریخچه تنظیم `job.reservation_expiry.batch` حذف نمی‌شود (قاعده 0005/D-12).
-- =============================================================================

drop function if exists inv.expire_reservations(uuid, timestamptz, integer);
drop function if exists inv.release(uuid, uuid, text);
drop function if exists inv.reserve(uuid, uuid, uuid, uuid, integer, integer);
drop function if exists inv.apply_movement(uuid, uuid, uuid, integer, text, text, uuid, text, text);

delete from iam.role_permissions
 where permission_id in (
   select id from iam.permissions
    where key in ('inventory.read', 'inventory.adjust', 'warehouse.grn.create',
                  'warehouse.pick.execute', 'returns.inspection.record'));

delete from iam.permissions
 where key in ('inventory.read', 'inventory.adjust', 'warehouse.grn.create',
               'warehouse.pick.execute', 'returns.inspection.record');
