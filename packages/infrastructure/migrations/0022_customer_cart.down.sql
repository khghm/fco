drop function if exists shop.pending_guest_cart_merges(uuid);
drop function if exists shop.complete_guest_cart_merge(uuid, uuid);
drop function if exists shop.merge_guest_cart(uuid, uuid, jsonb);
drop function if exists iam.invalidate_otp(uuid);
drop schema if exists shop cascade;
