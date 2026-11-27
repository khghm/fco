alter table inv.reservations
  drop constraint if exists reservations_order_line_fk;

drop function if exists pay.complete_mock_payment(uuid, bytea, text, uuid, text);
drop function if exists pay.mock_payment_details(uuid);
drop function if exists inv.confirm_order_reservations(uuid);
drop function if exists oms.complete_guest_cart_restore(uuid);
drop function if exists oms.guest_cart_checkout_state(uuid);
drop function if exists oms.guest_cart_restore_target(uuid);
drop function if exists oms.pending_guest_cart_restore(uuid);
drop function if exists oms.complete_guest_cart_checkout(uuid);
drop function if exists oms.pending_guest_cart_checkout(uuid);
drop function if exists oms.find_checkout_by_idempotency(uuid, uuid, text, text);
drop function if exists oms.place_order(uuid, uuid, citext, varchar, jsonb, text, text, jsonb, uuid, bytea, integer, text);
drop function if exists oms.tax_amount_rial(bigint, bigint);
drop schema if exists pay cascade;
drop schema if exists oms cascade;

-- sys.settings/sys.setting_versions تاریخچهٔ فقط‌افزودنی دارند و عمداً حذف نمی‌شوند.
-- هویت غیرفعال سامانه نیز به‌دلیل ردپای رزروهای احتمالی حذف نمی‌شود.
