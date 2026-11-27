-- =============================================================================
-- 0020_versioned_price_usecase — BR-2: price history use-case
-- =============================================================================

insert into iam.permissions (key, domain, description) values
  ('pricing.price.update', 'pricing', 'ثبت نسخهٔ تازهٔ قیمت با تاریخ اعتبار')
on conflict (key) do nothing;

insert into iam.role_permissions (role_id, permission_id)
select r.id, p.id
from (values
  ('R-SALES', 'pricing.price.update'),
  ('R-FIN', 'pricing.price.update')
) as m(role_key, permission_key)
join iam.roles r on r.key = m.role_key
join iam.permissions p on p.key = m.permission_key
on conflict do nothing;

create function pricing.price_set(
  p_actor uuid,
  p_variant_id uuid,
  p_amount_rial bigint,
  p_compare_at_rial bigint,
  p_effective_from timestamptz,
  p_channel text,
  p_request_id text,
  p_reason text default null
) returns uuid
language plpgsql security definer
set search_path = pricing, cat, sys, iam, pg_catalog as $$
declare
  v_current_id uuid;
  v_current_from timestamptz;
  v_latest_from timestamptz;
  v_price_id uuid;
begin
  perform iam.authorize(p_actor, 'pricing.price.update');

  if p_amount_rial is null or p_amount_rial < 0
     or (p_compare_at_rial is not null and p_compare_at_rial < 0)
     or p_effective_from is null
     or p_channel is null or btrim(p_channel) = ''
     or p_request_id is null or btrim(p_request_id) = '' then
    raise exception 'FCO-1080: مبلغ، تاریخ اعتبار، کانال و request_id معتبر الزامی‌اند'
      using errcode = '22023';
  end if;

  perform 1
    from cat.variants v
    join cat.products p on p.id = v.product_id
   where v.id = p_variant_id
     and v.archived_at is null
     and p.status <> 'archived'
   for update of v;

  if not found then
    raise exception 'FCO-1081: تنوع قابل قیمت‌گذاری یافت نشد (%)', p_variant_id
      using errcode = '22023';
  end if;

  select id, effective_from
    into v_current_id, v_current_from
    from pricing.prices
   where variant_id = p_variant_id
     and channel = btrim(p_channel)
     and effective_to is null
   order by effective_from desc
   limit 1
   for update;

  if v_current_id is not null then
    if p_effective_from <= v_current_from then
      raise exception 'FCO-1082: تاریخ نسخهٔ تازه باید پس از آخرین قیمت باشد'
        using errcode = '22023';
    end if;

    update pricing.prices
       set effective_to = p_effective_from
     where id = v_current_id;
  else
    select max(effective_from)
      into v_latest_from
      from pricing.prices
     where variant_id = p_variant_id
       and channel = btrim(p_channel);

    if v_latest_from is not null and p_effective_from <= v_latest_from then
      raise exception 'FCO-1082: تاریخ نسخهٔ تازه باید پس از آخرین قیمت باشد'
        using errcode = '22023';
    end if;
  end if;

  insert into pricing.prices
    (variant_id, channel, amount_rial, compare_at_rial, effective_from, created_by)
  values
    (p_variant_id, btrim(p_channel), p_amount_rial, p_compare_at_rial,
     p_effective_from, p_actor)
  returning id into v_price_id;

  if v_current_id is not null then
    update pricing.prices
       set superseded_by = v_price_id
     where id = v_current_id;
  end if;

  perform sys.audit_write(
    p_actor       => p_actor,
    p_action      => 'price.set',
    p_entity_type => 'prices',
    p_entity_id   => v_price_id,
    p_before      => case when v_current_id is null then null else
      jsonb_build_object(
        'price_id', v_current_id,
        'effective_from', v_current_from,
        'effective_to', p_effective_from)
    end,
    p_after       => jsonb_build_object(
      'variant_id', p_variant_id,
      'channel', btrim(p_channel),
      'amount_rial', p_amount_rial,
      'compare_at_rial', p_compare_at_rial,
      'effective_from', p_effective_from,
      'supersedes_price_id', v_current_id),
    p_reason      => p_reason,
    p_permission  => 'pricing.price.update',
    p_request_id  => p_request_id);

  return v_price_id;
end $$;

comment on function pricing.price_set(uuid, uuid, bigint, bigint, timestamptz, text, text, text) is
  'ثبت قیمت به‌صورت نسخهٔ جدید؛ نسخه قبلی حفظ و در همان تراکنش بسته، supersede و Audit می‌شود';

revoke all on function
  pricing.price_set(uuid, uuid, bigint, bigint, timestamptz, text, text, text)
from public;
grant execute on function
  pricing.price_set(uuid, uuid, bigint, bigint, timestamptz, text, text, text)
to fco_app;
