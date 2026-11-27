-- =============================================================================
-- 0022_customer_cart — BR-3: customer OTP login and guest/account cart merge
-- =============================================================================

create schema if not exists shop;

create table shop.carts (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references iam.users (id) on delete restrict,
  status     text not null default 'active'
               check (status in ('active', 'checked_out', 'abandoned')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index carts_one_active_per_user
  on shop.carts (user_id)
  where status = 'active';

create table shop.cart_items (
  cart_id    uuid not null references shop.carts (id) on delete cascade,
  variant_id uuid not null references cat.variants (id) on delete restrict,
  quantity   integer not null check (quantity between 1 and 9999),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (cart_id, variant_id)
);

create table shop.cart_merge_sources (
  guest_cart_id      uuid primary key,
  cart_id            uuid not null references shop.carts (id) on delete restrict,
  user_id            uuid not null references iam.users (id) on delete restrict,
  merged_at          timestamptz not null default now(),
  redis_deleted_at   timestamptz
);

create index cart_merge_sources_pending_idx
  on shop.cart_merge_sources (user_id, merged_at)
  where redis_deleted_at is null;

create function iam.invalidate_otp(p_request_id uuid)
returns boolean
language plpgsql security definer set search_path = iam, pg_catalog as $$
begin
  update iam.otp_requests
     set invalidated_at = now()
   where id = p_request_id
     and consumed_at is null
     and invalidated_at is null;
  return found;
end $$;

create function shop.merge_guest_cart(
  p_guest_cart_id uuid,
  p_user_id uuid,
  p_items jsonb
) returns table (cart_id uuid, already_merged boolean)
language plpgsql security definer set search_path = shop, iam, pg_catalog as $$
declare
  v_cart_id uuid;
  v_existing_user uuid;
  v_item record;
begin
  if p_guest_cart_id is null or p_user_id is null
     or p_items is null or jsonb_typeof(p_items) <> 'array' then
    raise exception 'FCO-1090: دادهٔ ادغام سبد معتبر نیست' using errcode = '22023';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(p_guest_cart_id::text, 0));

  select s.cart_id, s.user_id
    into v_cart_id, v_existing_user
    from shop.cart_merge_sources s
   where s.guest_cart_id = p_guest_cart_id;

  if found then
    if v_existing_user <> p_user_id then
      raise exception 'FCO-1091: سبد مهمان قبلاً به حساب دیگری پیوند خورده است'
        using errcode = '28000';
    end if;
    return query select v_cart_id, true;
    return;
  end if;

  insert into shop.carts (user_id)
  values (p_user_id)
  on conflict (user_id) where status = 'active'
  do update set updated_at = now()
  returning id into v_cart_id;

  insert into shop.cart_merge_sources (guest_cart_id, cart_id, user_id)
  values (p_guest_cart_id, v_cart_id, p_user_id);

  for v_item in
    select item.variant_id, item.quantity
      from jsonb_to_recordset(p_items) as item(variant_id uuid, quantity integer)
  loop
    if v_item.quantity is null or v_item.quantity < 1 or v_item.quantity > 9999 then
      raise exception 'FCO-1090: تعداد کالای سبد معتبر نیست' using errcode = '22023';
    end if;

    insert into shop.cart_items (cart_id, variant_id, quantity)
    values (v_cart_id, v_item.variant_id, v_item.quantity)
    on conflict on constraint cart_items_pkey
    do update set quantity = shop.cart_items.quantity + excluded.quantity,
                  updated_at = now();
  end loop;

  return query select v_cart_id, false;
end $$;

create function shop.complete_guest_cart_merge(
  p_guest_cart_id uuid,
  p_user_id uuid
) returns boolean
language plpgsql security definer set search_path = shop, pg_catalog as $$
begin
  update shop.cart_merge_sources
     set redis_deleted_at = coalesce(redis_deleted_at, now())
   where guest_cart_id = p_guest_cart_id
     and user_id = p_user_id;
  return found;
end $$;

create function shop.pending_guest_cart_merges(p_user_id uuid)
returns table (guest_cart_id uuid)
language sql security definer set search_path = shop, pg_catalog as $$
  select source.guest_cart_id
    from shop.cart_merge_sources source
   where source.user_id = p_user_id
     and source.redis_deleted_at is null
   order by source.merged_at
$$;

grant usage on schema shop to fco_app;
grant select, insert, update on shop.carts to fco_app;
grant select, insert, update, delete on shop.cart_items to fco_app;
grant execute on function iam.invalidate_otp(uuid) to fco_app;
grant execute on function shop.merge_guest_cart(uuid, uuid, jsonb),
  shop.complete_guest_cart_merge(uuid, uuid),
  shop.pending_guest_cart_merges(uuid) to fco_app;

revoke all on shop.carts, shop.cart_items, shop.cart_merge_sources from public;
revoke all on function iam.invalidate_otp(uuid),
  shop.merge_guest_cart(uuid, uuid, jsonb),
  shop.complete_guest_cart_merge(uuid, uuid),
  shop.pending_guest_cart_merges(uuid) from public;
