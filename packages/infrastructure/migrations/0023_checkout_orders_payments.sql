-- =============================================================================
-- 0023_checkout_orders_payments — BR-3: checkout, order snapshots and mock pay
-- =============================================================================

create schema if not exists oms;
create schema if not exists pay;

insert into sys.settings (key, value, description) values
  ('shipping.flat_rate_rial', '500000'::jsonb, 'هزینه ثابت ارسال به ریال'),
  ('checkout.reservation_ttl_minutes', '15'::jsonb, 'مهلت پرداخت سفارش پیش از آزادسازی رزرو')
on conflict (key) do nothing;

insert into sys.setting_versions (key, value, effective_from, reason)
select v.key, v.value, '2026-01-01 00:00:00+00'::timestamptz, 'مقدار اولیه BR-3'
  from (values
    ('shipping.flat_rate_rial', '500000'::jsonb),
    ('checkout.reservation_ttl_minutes', '15'::jsonb)
  ) as v(key, value)
 where not exists (
   select 1 from sys.setting_versions current_version where current_version.key = v.key
 );

insert into iam.users (
  id, email, status, mfa_required, must_change_password
) values (
  'f0000000-0000-4000-8000-000000000023',
  'guest-checkout-system@fco.invalid',
  'disabled',
  true,
  true
)
on conflict do nothing;

create sequence oms.order_number_seq;

create table oms.orders (
  id                       uuid primary key default gen_random_uuid(),
  order_number             text not null unique,
  customer_id              uuid references iam.users (id) on delete restrict,
  guest_cart_id            uuid,
  guest_email              citext,
  guest_mobile             varchar(11),
  source_cart_id           uuid references shop.carts (id) on delete restrict,
  status                   text not null
                             check (status in ('awaiting_payment', 'paid', 'cancelled', 'expired')),
  payment_status           text not null default 'pending'
                             check (payment_status in ('pending', 'succeeded', 'failed', 'expired')),
  warehouse_id             uuid not null references inv.warehouses (id) on delete restrict,
  currency                 char(3) not null default 'IRR' check (currency = 'IRR'),
  subtotal_rial            bigint not null check (subtotal_rial >= 0),
  discount_rial            bigint not null default 0 check (discount_rial >= 0),
  shipping_rial            bigint not null check (shipping_rial >= 0),
  tax_amount_rial          bigint not null default 0 check (tax_amount_rial >= 0),
  total_rial               bigint not null check (total_rial >= 0),
  shipping_address_snapshot jsonb not null
                             check (jsonb_typeof(shipping_address_snapshot) = 'object'),
  correlation_id           uuid not null,
  payment_deadline         timestamptz not null,
  placed_at                timestamptz not null default now(),
  paid_at                  timestamptz,
  cancelled_at             timestamptz,
  cancel_reason            text,
  version                  integer not null default 1 check (version >= 1),
  created_at               timestamptz not null default now(),
  constraint orders_total_matches_components
    check (total_rial = subtotal_rial - discount_rial + shipping_rial + tax_amount_rial),
  constraint orders_customer_or_guest
    check (
      (customer_id is not null and guest_cart_id is null)
      or (customer_id is null and guest_cart_id is not null and guest_email is not null)
    ),
  constraint orders_guest_mobile_format
    check (guest_mobile is null or guest_mobile ~ '^09[0-9]{9}$')
);

create index orders_status_placed_idx on oms.orders (status, placed_at desc);
create index orders_customer_placed_idx on oms.orders (customer_id, placed_at desc);

create table oms.order_lines (
  id                 uuid primary key default gen_random_uuid(),
  order_id           uuid not null references oms.orders (id) on delete restrict,
  variant_id         uuid not null references cat.variants (id) on delete restrict,
  sku_snapshot       text not null,
  title_snapshot     text not null,
  quantity           integer not null check (quantity between 1 and 9999),
  unit_price_rial    bigint not null check (unit_price_rial >= 0),
  discount_rial      bigint not null default 0 check (discount_rial >= 0),
  tax_amount_rial    bigint not null default 0 check (tax_amount_rial >= 0),
  price_version_id   uuid not null references pricing.prices (id) on delete restrict,
  created_at         timestamptz not null default now(),
  unique (order_id, variant_id)
);

create index order_lines_order_idx on oms.order_lines (order_id);
create index order_lines_variant_idx on oms.order_lines (variant_id);

create table oms.order_events (
  id          bigserial primary key,
  order_id    uuid not null references oms.orders (id) on delete restrict,
  from_status text,
  to_status   text not null,
  actor_id    uuid references iam.users (id),
  reason      text not null,
  metadata    jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);

create trigger order_events_immutable
  before update or delete on oms.order_events
  for each row execute function sys.reject_mutation();

create function oms.find_checkout_by_idempotency(
  p_customer_id uuid,
  p_guest_cart_id uuid,
  p_idempotency_key text,
  p_request_hash text
) returns table (
  order_id uuid,
  order_number text,
  payment_id uuid,
  subtotal_rial bigint,
  shipping_rial bigint,
  tax_amount_rial bigint,
  total_rial bigint,
  payment_deadline timestamptz,
  status text,
  payment_status text,
  already_placed boolean
)
language plpgsql security definer set search_path = oms, pay, pg_catalog as $$
#variable_conflict use_column
declare
  v_scope text;
  v_existing record;
begin
  if (p_customer_id is null) = (p_guest_cart_id is null)
     or p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9._:-]{8,128}$'
     or p_request_hash is null
     or p_request_hash !~ '^[a-f0-9]{64}$' then
    raise exception 'FCO-1001: کلید تکرار یا هویت سبد معتبر نیست'
      using errcode = '22023';
  end if;

  v_scope := case
    when p_customer_id is not null then 'customer:' || p_customer_id::text
    else 'guest:' || p_guest_cart_id::text
  end;
  select request.request_hash, request.order_id, request.payment_id
    into v_existing
    from oms.checkout_idempotency request
   where request.scope = v_scope
     and request.idempotency_key = p_idempotency_key;

  if not found then
    return;
  end if;
  if v_existing.request_hash <> p_request_hash then
    raise exception 'FCO-1090: کلید Idempotency با درخواست دیگری استفاده شده است'
      using errcode = '23505';
  end if;

  return query
    select order_row.id, order_row.order_number, payment_row.id,
           order_row.subtotal_rial, order_row.shipping_rial,
           order_row.tax_amount_rial, order_row.total_rial,
           order_row.payment_deadline, order_row.status, order_row.payment_status, true
      from oms.orders order_row
      join pay.transactions payment_row on payment_row.id = v_existing.payment_id
     where order_row.id = v_existing.order_id;
end $$;

create table oms.checkout_idempotency (
  scope           text not null,
  idempotency_key text not null,
  request_hash    text not null,
  order_id        uuid not null references oms.orders (id) on delete restrict,
  payment_id      uuid not null,
  created_at      timestamptz not null default now(),
  primary key (scope, idempotency_key),
  check (idempotency_key ~ '^[A-Za-z0-9._:-]{8,128}$'),
  check (request_hash ~ '^[a-f0-9]{64}$')
);

create table oms.checkout_guest_carts (
  guest_cart_id       uuid primary key,
  order_id            uuid not null unique references oms.orders (id) on delete restrict,
  redis_deleted_at    timestamptz,
  restore_cart_id     uuid unique,
  restore_requested_at timestamptz,
  redis_restored_at   timestamptz,
  constraint checkout_guest_restore_state
    check (
      (restore_cart_id is null and restore_requested_at is null and redis_restored_at is null)
      or (restore_cart_id is not null and restore_requested_at is not null)
    )
);

create table pay.transactions (
  id                uuid primary key,
  order_id          uuid not null references oms.orders (id) on delete restrict,
  provider          text not null check (provider = 'mock'),
  provider_ref      text unique,
  amount_rial       bigint not null check (amount_rial >= 0),
  status            text not null default 'initiated'
                      check (status in ('initiated', 'succeeded', 'failed', 'unknown', 'reconciled', 'expired')),
  idempotency_key   text not null,
  mock_token_hash   bytea not null check (octet_length(mock_token_hash) = 32),
  verified_at       timestamptz,
  raw_request       jsonb,
  raw_response      jsonb,
  created_at        timestamptz not null default now(),
  unique (order_id, id)
);

create index payment_transactions_order_idx on pay.transactions (order_id, created_at desc);

alter table inv.reservations
  add constraint reservations_order_line_fk
  foreign key (order_line_id) references oms.order_lines (id) on delete restrict
  not valid;

create function oms.tax_amount_rial(p_subtotal_rial bigint, p_shipping_rial bigint)
returns bigint
language sql immutable set search_path = pg_catalog as $$
  select 0::bigint
$$;

comment on function oms.tax_amount_rial(bigint, bigint) is
  'محاسبه مالیات در MVP عمداً صفر است؛ ورودی‌ها و ستون tax_amount_rial برای سیاست آتی حفظ شده‌اند';

create function oms.place_order(
  p_customer_id uuid,
  p_guest_cart_id uuid,
  p_guest_email citext,
  p_guest_mobile varchar,
  p_shipping_address jsonb,
  p_idempotency_key text,
  p_request_hash text,
  p_guest_items jsonb,
  p_payment_id uuid,
  p_mock_token_hash bytea,
  p_order_year integer,
  p_request_id text
) returns table (
  order_id uuid,
  order_number text,
  payment_id uuid,
  subtotal_rial bigint,
  shipping_rial bigint,
  tax_amount_rial bigint,
  total_rial bigint,
  payment_deadline timestamptz,
  status text,
  payment_status text,
  already_placed boolean
)
language plpgsql security definer set search_path = oms, pay, shop, inv, pricing, cat, sys, iam, pg_catalog as $$
#variable_conflict use_variable
declare
  v_scope text;
  v_existing record;
  v_cart_id uuid;
  v_items jsonb;
  v_item_count integer;
  v_distinct_count integer;
  v_subtotal numeric;
  v_shipping bigint;
  v_tax bigint;
  v_total numeric;
  v_ttl integer;
  v_warehouse_id uuid;
  v_actor_id uuid;
  v_order_id uuid := gen_random_uuid();
  v_order_number text;
  v_order_sequence bigint;
  v_deadline timestamptz;
  v_line_id uuid;
  v_item record;
begin
  if (p_customer_id is null) = (p_guest_cart_id is null) then
    raise exception 'FCO-1001: دقیقاً یکی از نشست مشتری یا سبد مهمان لازم است'
      using errcode = '22023';
  end if;
  if p_shipping_address is null or jsonb_typeof(p_shipping_address) <> 'object' then
    raise exception 'FCO-1001: نشانی ارسال معتبر نیست' using errcode = '22023';
  end if;
  if p_idempotency_key is null
     or p_idempotency_key !~ '^[A-Za-z0-9._:-]{8,128}$'
     or p_request_hash is null
     or p_request_hash !~ '^[a-f0-9]{64}$'
     or p_payment_id is null
     or p_mock_token_hash is null
     or octet_length(p_mock_token_hash) <> 32
     or p_order_year is null or p_order_year < 1900 or p_order_year > 2100 then
    raise exception 'FCO-1001: کلید تکرار یا دادهٔ پرداخت معتبر نیست'
      using errcode = '22023';
  end if;
  if p_customer_id is null and
     (p_guest_email is null or p_guest_mobile is null or p_guest_mobile !~ '^09[0-9]{9}$') then
    raise exception 'FCO-1001: ایمیل و موبایل معتبر مهمان الزامی است'
      using errcode = '22023';
  end if;
  if p_customer_id is not null and not exists (
    select 1 from iam.users u
     where u.id = p_customer_id and u.status = 'active' and u.archived_at is null
  ) then
    raise exception 'FCO-1005: نشست مشتری معتبر نیست' using errcode = '28000';
  end if;

  v_scope := case
    when p_customer_id is not null then 'customer:' || p_customer_id::text
    else 'guest:' || p_guest_cart_id::text
  end;
  perform pg_advisory_xact_lock(hashtextextended(v_scope || ':' || p_idempotency_key, 0));

  select request.request_hash, request.order_id, request.payment_id
    into v_existing
    from oms.checkout_idempotency request
   where request.scope = v_scope
     and request.idempotency_key = p_idempotency_key
   for update;

  if found then
    if v_existing.request_hash <> p_request_hash then
      raise exception 'FCO-1090: کلید Idempotency با درخواست دیگری استفاده شده است'
        using errcode = '23505';
    end if;
    return query
      select order_row.id, order_row.order_number, payment_row.id,
             order_row.subtotal_rial, order_row.shipping_rial,
             order_row.tax_amount_rial, order_row.total_rial,
             order_row.payment_deadline, order_row.status, order_row.payment_status, true
        from oms.orders order_row
        join pay.transactions payment_row on payment_row.id = v_existing.payment_id
       where order_row.id = v_existing.order_id;
    return;
  end if;

  if p_customer_id is not null then
    select cart.id into v_cart_id
      from shop.carts cart
     where cart.user_id = p_customer_id and cart.status = 'active'
     for update;
    if v_cart_id is null then
      raise exception 'FCO-1001: سبد خرید خالی است' using errcode = '22023';
    end if;
    select coalesce(
             jsonb_agg(
               jsonb_build_object('variant_id', item.variant_id, 'quantity', item.quantity)
               order by item.variant_id
             ),
             '[]'::jsonb
           )
      into v_items
      from shop.cart_items item
     where item.cart_id = v_cart_id;
  else
    if p_guest_items is null or jsonb_typeof(p_guest_items) <> 'array' then
      raise exception 'FCO-1001: اقلام سبد مهمان معتبر نیستند' using errcode = '22023';
    end if;
    v_items := p_guest_items;
  end if;

  select count(*), count(distinct requested.variant_id)
    into v_item_count, v_distinct_count
    from jsonb_to_recordset(v_items) as requested(variant_id uuid, quantity integer);
  if v_item_count < 1 or v_item_count > 50 or v_item_count <> v_distinct_count
     or exists (
       select 1
         from jsonb_to_recordset(v_items) as requested(variant_id uuid, quantity integer)
        where requested.quantity is null or requested.quantity < 1 or requested.quantity > 9999
     ) then
    raise exception 'FCO-1001: تعداد یا اقلام سبد معتبر نیستند' using errcode = '22023';
  end if;

  if exists (
    select 1
      from jsonb_to_recordset(v_items) as requested(variant_id uuid, quantity integer)
      left join cat.variants variant on variant.id = requested.variant_id
      left join cat.products product on product.id = variant.product_id
      left join lateral (
        select price.id, price.amount_rial
          from pricing.prices price
         where price.variant_id = variant.id
           and price.channel = 'web'
           and price.effective_from <= now()
           and (price.effective_to is null or price.effective_to > now())
         order by price.effective_from desc
         limit 1
      ) current_price on true
     where variant.id is null
        or variant.archived_at is not null
        or not variant.is_active
        or product.status <> 'published'
        or product.published_at is null
        or product.published_at > now()
        or current_price.id is null
  ) then
    raise exception 'FCO-2002: یکی از اقلام دیگر برای فروش در دسترس نیست'
      using errcode = '22023';
  end if;

  select coalesce(sum(requested.quantity::numeric * current_price.amount_rial), 0)
    into v_subtotal
    from jsonb_to_recordset(v_items) as requested(variant_id uuid, quantity integer)
    join cat.variants variant on variant.id = requested.variant_id
    join cat.products product on product.id = variant.product_id
    join lateral (
      select price.amount_rial
        from pricing.prices price
       where price.variant_id = variant.id
         and price.channel = 'web'
         and price.effective_from <= now()
         and (price.effective_to is null or price.effective_to > now())
       order by price.effective_from desc
       limit 1
    ) current_price on true
   where product.status = 'published'
     and variant.is_active
     and variant.archived_at is null;

  if v_subtotal > 9000000000000000 then
    raise exception 'FCO-1001: مبلغ سبد بیش از حد مجاز است' using errcode = '22023';
  end if;

  v_shipping := sys.setting_int('shipping.flat_rate_rial');
  v_ttl := sys.setting_int('checkout.reservation_ttl_minutes');
  if v_shipping is null or v_shipping < 0 or v_ttl is null or v_ttl < 1 or v_ttl > 1440 then
    raise exception 'FCO-1018: تنظیم هزینه ارسال یا مهلت رزرو معتبر نیست'
      using errcode = '22023';
  end if;
  v_tax := oms.tax_amount_rial(v_subtotal::bigint, v_shipping);
  v_total := v_subtotal + v_shipping + v_tax;
  if v_total > 9000000000000000 then
    raise exception 'FCO-1001: مبلغ سفارش بیش از حد مجاز است' using errcode = '22023';
  end if;

  select warehouse.id
    into v_warehouse_id
    from inv.warehouses warehouse
   where warehouse.is_active
     and not exists (
       select 1
         from jsonb_to_recordset(v_items) as requested(variant_id uuid, quantity integer)
         left join inv.stock_balance balance
           on balance.warehouse_id = warehouse.id
          and balance.variant_id = requested.variant_id
        where balance.variant_id is null
           or balance.on_hand - balance.reserved - balance.quarantined < requested.quantity
     )
   order by warehouse.code
   limit 1;
  if v_warehouse_id is null then
    raise exception 'FCO-2001: موجودی کافی برای سبد در یک انبار وجود ندارد'
      using errcode = '22023';
  end if;

  v_deadline := clock_timestamp() + make_interval(mins => v_ttl);
  v_order_sequence := nextval('oms.order_number_seq');
  v_order_number := 'FCO-' || p_order_year::text || '-' ||
                    lpad(v_order_sequence::text, greatest(6, length(v_order_sequence::text)), '0');
  v_actor_id := p_customer_id;
  if v_actor_id is null then
    select u.id into v_actor_id
      from iam.users u
     where u.email = 'guest-checkout-system@fco.invalid'
       and u.status = 'disabled'
       and u.archived_at is null;
    if v_actor_id is null then
      raise exception 'FCO-1018: هویت سیستمی ثبت Audit موجود نیست'
        using errcode = '22023';
    end if;
  end if;

  insert into oms.orders (
    id, order_number, customer_id, guest_cart_id, guest_email, guest_mobile,
    source_cart_id, status, payment_status, warehouse_id, subtotal_rial,
    discount_rial, shipping_rial, tax_amount_rial, total_rial,
    shipping_address_snapshot, correlation_id, payment_deadline
  ) values (
    v_order_id, v_order_number, p_customer_id, p_guest_cart_id, p_guest_email,
    p_guest_mobile, v_cart_id, 'awaiting_payment', 'pending', v_warehouse_id,
    v_subtotal::bigint, 0, v_shipping, v_tax, v_total::bigint,
    p_shipping_address, gen_random_uuid(), v_deadline
  );

  for v_item in
    select requested.variant_id, requested.quantity, variant.sku, product.title,
           current_price.amount_rial, current_price.id as price_version_id
      from jsonb_to_recordset(v_items) as requested(variant_id uuid, quantity integer)
      join cat.variants variant on variant.id = requested.variant_id
      join cat.products product on product.id = variant.product_id
      join lateral (
        select price.id, price.amount_rial
          from pricing.prices price
         where price.variant_id = variant.id
           and price.channel = 'web'
           and price.effective_from <= now()
           and (price.effective_to is null or price.effective_to > now())
         order by price.effective_from desc
         limit 1
      ) current_price on true
     order by requested.variant_id
  loop
    v_line_id := gen_random_uuid();
    insert into oms.order_lines (
      id, order_id, variant_id, sku_snapshot, title_snapshot,
      quantity, unit_price_rial, discount_rial, tax_amount_rial, price_version_id
    ) values (
      v_line_id, v_order_id, v_item.variant_id, v_item.sku, v_item.title,
      v_item.quantity, v_item.amount_rial, 0, 0, v_item.price_version_id
    );

    perform inv.reserve(
      v_actor_id, v_line_id, v_warehouse_id, v_item.variant_id, v_item.quantity, v_ttl
    );
  end loop;

  insert into pay.transactions (
    id, order_id, provider, amount_rial, status, idempotency_key, mock_token_hash
  ) values (
    p_payment_id, v_order_id, 'mock', v_total::bigint, 'initiated',
    v_scope || ':' || p_idempotency_key, p_mock_token_hash
  );

  if p_customer_id is not null then
    update shop.carts
       set status = 'checked_out', updated_at = now()
     where id = v_cart_id;
  else
    insert into oms.checkout_guest_carts (guest_cart_id, order_id)
    values (p_guest_cart_id, v_order_id);
  end if;

  insert into oms.order_events
    (order_id, from_status, to_status, actor_id, reason, metadata)
  values
    (v_order_id, null, 'awaiting_payment', p_customer_id, 'checkout.placed',
     jsonb_build_object('request_id', p_request_id));

  insert into oms.checkout_idempotency
    (scope, idempotency_key, request_hash, order_id, payment_id)
  values
    (v_scope, p_idempotency_key, p_request_hash, v_order_id, p_payment_id);

  perform sys.outbox_emit(
    'order', v_order_id, 'order.placed.v1',
    jsonb_build_object(
      'order_id', v_order_id,
      'order_number', v_order_number,
      'customer_id', p_customer_id,
      'status', 'awaiting_payment'
    ),
    jsonb_build_object('request_id', p_request_id)
  );

  return query select
    v_order_id, v_order_number, p_payment_id,
    v_subtotal::bigint, v_shipping, v_tax, v_total::bigint, v_deadline,
    'awaiting_payment', 'pending', false;
end $$;

create function oms.pending_guest_cart_checkout(p_guest_cart_id uuid)
returns boolean
language sql security definer set search_path = oms, pg_catalog as $$
  select exists (
    select 1 from oms.checkout_guest_carts source
     where source.guest_cart_id = p_guest_cart_id
       and source.redis_deleted_at is null
  )
$$;

create function oms.complete_guest_cart_checkout(p_guest_cart_id uuid)
returns boolean
language plpgsql security definer set search_path = oms, pg_catalog as $$
begin
  update oms.checkout_guest_carts
     set redis_deleted_at = coalesce(redis_deleted_at, now())
   where guest_cart_id = p_guest_cart_id;
  return found;
end $$;

create function oms.pending_guest_cart_restore(p_guest_cart_id uuid)
returns table (restore_cart_id uuid, items jsonb)
language sql security definer set search_path = oms, pg_catalog as $$
  select source.restore_cart_id,
         coalesce(
           jsonb_agg(
             jsonb_build_object('variant_id', line.variant_id, 'quantity', line.quantity)
             order by line.variant_id
           ),
           '[]'::jsonb
         ) as items
    from oms.checkout_guest_carts source
    join oms.orders order_row on order_row.id = source.order_id
    join oms.order_lines line on line.order_id = order_row.id
   where source.guest_cart_id = p_guest_cart_id
     and source.restore_requested_at is not null
     and source.redis_restored_at is null
     and order_row.payment_status in ('failed', 'expired')
   group by source.restore_cart_id
$$;

create function oms.guest_cart_restore_target(p_guest_cart_id uuid)
returns table (restore_cart_id uuid, items jsonb, restore_pending boolean)
language sql security definer set search_path = oms, pg_catalog as $$
  select source.restore_cart_id,
         coalesce(
           jsonb_agg(
             jsonb_build_object('variant_id', line.variant_id, 'quantity', line.quantity)
             order by line.variant_id
           ),
           '[]'::jsonb
         ) as items,
         source.redis_restored_at is null as restore_pending
    from oms.checkout_guest_carts source
    join oms.orders order_row on order_row.id = source.order_id
    join oms.order_lines line on line.order_id = order_row.id
   where source.guest_cart_id = p_guest_cart_id
     and source.restore_requested_at is not null
     and order_row.payment_status in ('failed', 'expired')
   group by source.restore_cart_id, source.redis_restored_at
$$;

create function oms.guest_cart_checkout_state(p_guest_cart_id uuid)
returns text
language sql security definer set search_path = oms, pg_catalog as $$
  select order_row.payment_status
    from oms.checkout_guest_carts source
    join oms.orders order_row on order_row.id = source.order_id
   where source.guest_cart_id = p_guest_cart_id
$$;

create function oms.complete_guest_cart_restore(p_guest_cart_id uuid)
returns boolean
language plpgsql security definer set search_path = oms, pg_catalog as $$
begin
  update oms.checkout_guest_carts
     set redis_restored_at = coalesce(redis_restored_at, now())
   where guest_cart_id = p_guest_cart_id
     and restore_requested_at is not null;
  return found;
end $$;

create function inv.confirm_order_reservations(p_order_id uuid)
returns boolean
language plpgsql security definer set search_path = inv, oms, pg_catalog as $$
declare
  v_line_count integer;
  v_reservation_count integer;
  v_updated integer;
begin
  if not exists (
    select 1 from oms.orders order_row
     where order_row.id = p_order_id and order_row.status = 'paid'
  ) then
    raise exception 'FCO-2003: سفارش برای تثبیت رزرو پرداخت‌شده نیست'
      using errcode = '22023';
  end if;

  select count(*) into v_line_count
    from oms.order_lines line where line.order_id = p_order_id;
  perform reservation.id
    from inv.reservations reservation
    join oms.order_lines line on line.id = reservation.order_line_id
   where line.order_id = p_order_id and reservation.status = 'active'
   order by reservation.id
   for update of reservation;
  select count(*) into v_reservation_count
    from inv.reservations reservation
    join oms.order_lines line on line.id = reservation.order_line_id
   where line.order_id = p_order_id
     and reservation.status = 'active'
     and reservation.expires_at > clock_timestamp();

  if v_line_count = 0 or v_line_count <> v_reservation_count then
    raise exception 'FCO-2003: رزرو سفارش منقضی یا ناقص است'
      using errcode = '22023';
  end if;

  update inv.reservations reservation
     set status = 'committed'
    from oms.order_lines line
   where line.id = reservation.order_line_id
     and line.order_id = p_order_id
     and reservation.status = 'active'
     and reservation.expires_at > clock_timestamp();
  get diagnostics v_updated = row_count;
  if v_updated <> v_line_count then
    raise exception 'FCO-2003: تثبیت رزرو سفارش کامل نشد'
      using errcode = '40001';
  end if;
  return true;
end $$;

create function pay.mock_payment_details(p_payment_id uuid)
returns table (
  order_id uuid,
  order_number text,
  amount_rial bigint,
  status text,
  payment_deadline timestamptz,
  mock_token_hash bytea
)
language sql security definer set search_path = pay, oms, pg_catalog as $$
  select transaction.order_id, order_row.order_number, transaction.amount_rial,
         transaction.status, order_row.payment_deadline, transaction.mock_token_hash
    from pay.transactions transaction
    join oms.orders order_row on order_row.id = transaction.order_id
   where transaction.id = p_payment_id and transaction.provider = 'mock'
$$;

create function pay.complete_mock_payment(
  p_payment_id uuid,
  p_token_hash bytea,
  p_outcome text,
  p_restore_cart_id uuid,
  p_request_id text
) returns table (
  result text,
  order_id uuid,
  order_number text,
  customer_id uuid,
  guest_cart_id uuid,
  restore_cart_id uuid,
  restore_items jsonb
)
language plpgsql security definer set search_path = pay, oms, inv, shop, sys, pg_catalog as $$
declare
  v_payment pay.transactions%rowtype;
  v_order oms.orders%rowtype;
  v_result text;
  v_restore_id uuid;
  v_restore_items jsonb;
  v_actor_id uuid;
  v_reservation record;
begin
  if p_outcome not in ('succeeded', 'failed') then
    raise exception 'FCO-1001: نتیجهٔ Mock Payment معتبر نیست' using errcode = '22023';
  end if;
  select transaction.* into v_payment
    from pay.transactions transaction
   where transaction.id = p_payment_id and transaction.provider = 'mock'
   for update;
  if not found or v_payment.mock_token_hash is distinct from p_token_hash then
    raise exception 'FCO-1005: لینک پرداخت معتبر نیست' using errcode = '28000';
  end if;
  select order_row.* into v_order
    from oms.orders order_row where order_row.id = v_payment.order_id for update;

  if v_payment.status <> 'initiated' then
    if (v_payment.status = 'succeeded' and p_outcome = 'succeeded')
       or (v_payment.status = 'failed' and p_outcome = 'failed')
       or (v_payment.status = 'expired' and p_outcome = 'failed') then
      select source.restore_cart_id into v_restore_id
        from oms.checkout_guest_carts source
       where source.guest_cart_id = v_order.guest_cart_id;
      select coalesce(
               jsonb_agg(jsonb_build_object('variant_id', line.variant_id, 'quantity', line.quantity)
                         order by line.variant_id),
               '[]'::jsonb
             )
        into v_restore_items
        from oms.order_lines line where line.order_id = v_order.id;
      return query select v_payment.status, v_order.id, v_order.order_number,
        v_order.customer_id, v_order.guest_cart_id, v_restore_id, v_restore_items;
      return;
    end if;
    raise exception 'FCO-1091: تراکنش پرداخت قبلاً با نتیجه دیگری نهایی شده است'
      using errcode = '23505';
  end if;

  if v_order.status <> 'awaiting_payment' then
    raise exception 'FCO-1091: سفارش در انتظار پرداخت نیست' using errcode = '23505';
  end if;

  if clock_timestamp() >= v_order.payment_deadline then
    v_result := 'expired';
  elsif p_outcome = 'succeeded' then
    v_result := 'succeeded';
  else
    v_result := 'failed';
  end if;

  if v_result = 'succeeded' then
    update pay.transactions
       set status = 'succeeded',
           provider_ref = 'mock:' || p_payment_id::text,
           verified_at = now(),
           raw_response = jsonb_build_object('outcome', 'succeeded')
     where id = p_payment_id;
    update oms.orders
       set status = 'paid', payment_status = 'succeeded', paid_at = now(),
           version = version + 1
     where id = v_order.id;
    perform inv.confirm_order_reservations(v_order.id);
    insert into oms.order_events
      (order_id, from_status, to_status, actor_id, reason, metadata)
    values
      (v_order.id, 'awaiting_payment', 'paid', v_order.customer_id, 'mock_payment.succeeded',
       jsonb_build_object('request_id', p_request_id, 'payment_id', p_payment_id));
    perform sys.outbox_emit(
      'order', v_order.id, 'order.paid.v1',
      jsonb_build_object('order_id', v_order.id, 'order_number', v_order.order_number),
      jsonb_build_object('request_id', p_request_id)
    );
    return query select 'succeeded', v_order.id, v_order.order_number,
      v_order.customer_id, v_order.guest_cart_id, null::uuid, null::jsonb;
    return;
  end if;

  update pay.transactions
     set status = v_result,
         provider_ref = 'mock:' || p_payment_id::text || ':' || v_result,
         verified_at = now(),
         raw_response = jsonb_build_object('outcome', v_result)
   where id = p_payment_id;
  update oms.orders
     set status = case when v_result = 'expired' then 'expired' else 'cancelled' end,
         payment_status = v_result,
         cancelled_at = case when v_result = 'expired' then null else now() end,
         cancel_reason = case when v_result = 'expired' then 'payment_expired' else 'payment_failed' end,
         version = version + 1
   where id = v_order.id;

  if v_result = 'expired' then
    v_actor_id := v_order.customer_id;
    if v_actor_id is null then
      select u.id into v_actor_id
        from iam.users u
       where u.email = 'guest-checkout-system@fco.invalid'
         and u.status = 'disabled'
         and u.archived_at is null;
      if v_actor_id is null then
        raise exception 'FCO-1018: هویت سیستمی ثبت Audit موجود نیست'
          using errcode = '22023';
      end if;
    end if;
    for v_reservation in
      select reservation.id
        from inv.reservations reservation
        join oms.order_lines line on line.id = reservation.order_line_id
       where line.order_id = v_order.id and reservation.status = 'active'
       order by reservation.id
       for update of reservation
    loop
      perform inv.release(v_actor_id, v_reservation.id, 'expired');
    end loop;
  end if;

  if v_order.customer_id is not null then
    insert into shop.carts (user_id)
    values (v_order.customer_id)
    on conflict (user_id) where status = 'active'
    do update set updated_at = now()
    returning id into v_restore_id;
    insert into shop.cart_items (cart_id, variant_id, quantity)
    select v_restore_id, line.variant_id, line.quantity
      from oms.order_lines line
     where line.order_id = v_order.id
    on conflict (cart_id, variant_id)
    do update set quantity = shop.cart_items.quantity + excluded.quantity,
                  updated_at = now();
  else
    if p_restore_cart_id is null then
      raise exception 'FCO-1018: شناسهٔ سبد جایگزین الزامی است'
        using errcode = '22023';
    end if;
    update oms.checkout_guest_carts source
       set restore_cart_id = coalesce(source.restore_cart_id, p_restore_cart_id),
           restore_requested_at = coalesce(source.restore_requested_at, now())
     where source.guest_cart_id = v_order.guest_cart_id
    returning source.restore_cart_id into v_restore_id;
    select coalesce(
             jsonb_agg(jsonb_build_object('variant_id', line.variant_id, 'quantity', line.quantity)
                       order by line.variant_id),
             '[]'::jsonb
           )
      into v_restore_items
      from oms.order_lines line where line.order_id = v_order.id;
  end if;

  insert into oms.order_events
    (order_id, from_status, to_status, actor_id, reason, metadata)
  values
    (v_order.id, 'awaiting_payment',
     case when v_result = 'expired' then 'expired' else 'cancelled' end,
     v_order.customer_id, 'mock_payment.' || v_result,
     jsonb_build_object('request_id', p_request_id, 'payment_id', p_payment_id));
  perform sys.outbox_emit(
    'order', v_order.id, 'order.payment_failed.v1',
    jsonb_build_object('order_id', v_order.id, 'order_number', v_order.order_number,
                       'result', v_result),
    jsonb_build_object('request_id', p_request_id)
  );

  return query select v_result, v_order.id, v_order.order_number,
    v_order.customer_id, v_order.guest_cart_id, v_restore_id, v_restore_items;
end $$;

grant usage on schema oms, pay to fco_app;
grant select on oms.orders, oms.order_lines, oms.order_events, pay.transactions to fco_app;
grant execute on function oms.tax_amount_rial(bigint, bigint),
  oms.find_checkout_by_idempotency(uuid, uuid, text, text),
  oms.place_order(uuid, uuid, citext, varchar, jsonb, text, text, jsonb, uuid, bytea, integer, text),
  oms.pending_guest_cart_checkout(uuid),
  oms.complete_guest_cart_checkout(uuid),
  oms.pending_guest_cart_restore(uuid),
  oms.guest_cart_restore_target(uuid),
  oms.guest_cart_checkout_state(uuid),
  oms.complete_guest_cart_restore(uuid),
  inv.confirm_order_reservations(uuid),
  pay.mock_payment_details(uuid),
  pay.complete_mock_payment(uuid, bytea, text, uuid, text)
to fco_app;

revoke all on oms.orders, oms.order_lines, oms.order_events, oms.checkout_idempotency,
  oms.checkout_guest_carts, pay.transactions from public;
revoke all on function oms.tax_amount_rial(bigint, bigint),
  oms.find_checkout_by_idempotency(uuid, uuid, text, text),
  oms.place_order(uuid, uuid, citext, varchar, jsonb, text, text, jsonb, uuid, bytea, integer, text),
  oms.pending_guest_cart_checkout(uuid),
  oms.complete_guest_cart_checkout(uuid),
  oms.pending_guest_cart_restore(uuid),
  oms.guest_cart_restore_target(uuid),
  oms.guest_cart_checkout_state(uuid),
  oms.complete_guest_cart_restore(uuid),
  inv.confirm_order_reservations(uuid),
  pay.mock_payment_details(uuid),
  pay.complete_mock_payment(uuid, bytea, text, uuid, text) from public;
