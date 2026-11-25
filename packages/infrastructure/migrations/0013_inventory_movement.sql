-- =============================================================================
-- 0013_inventory_movement — BR-2 گام ۳: گردش اتمیک، رزرو و آزادسازی
-- مالک طرح: docs/Architecture-02/DATABASE_DESIGN.md §3.4 (قواعد سخت ۱–۵)
--           docs/Business-01/BUSINESS_REQUIREMENTS.md (BRQ-13، BRQ-14، BRQ-15)
--           docs/Business-01/USER_ROLES_AND_PERMISSIONS.md §3.4، §4
--           docs/Engineering-04/TEST_STRATEGY.md §4.1 (T-INV-01/03/04)
--
-- مدل:
--   * `inv.apply_movement` تنها مسیر تغییر `on_hand` است: ردیف تجمیع را
--     `FOR UPDATE` قفل می‌کند، `balance_after` را همان‌جا می‌سازد و دفتر را
--     در همان تراکنش درج می‌کند. مجوز از روی `reason_code` انتخاب می‌شود.
--   * `inv.reserve` موجودی قابل‌فروش را زیر قفل ردیف بررسی می‌کند و رزرو فعال
--     یکتا می‌سازد (oversell صفر، BRQ-14).
--   * `inv.release` آزادسازی یکتا و ایدمپوتنت است؛ آزادسازی دوباره `false`.
--   * `inv.expire_reservations` با `sys.job_begin`/`job_finish` اجرا می‌شود؛
--     اجرای دوباره همان slot بی‌اثر است (BRQ-15، T-INV-04).
--
-- خارج از این Migration: مصرف رزرو هنگام ارسال (کاهش هم‌زمان `on_hand` و
-- `reserved`) در BR-4؛ مجوز ایجاد رزرو از use-case سفارش در BR-3 می‌آید و
-- `inv.reserve` فقط برای کد سرور (fco_app) قابل اجراست.
-- =============================================================================

insert into sys.settings (key, value, description) values
  ('job.reservation_expiry.batch', '500'::jsonb, 'اندازه دسته آزادسازی رزروهای منقضی')
on conflict (key) do nothing;

insert into sys.setting_versions (key, value, effective_from, reason)
select v.key, v.value, v.effective_from, v.reason
from (values
  ('job.reservation_expiry.batch', '500'::jsonb,
   '2026-01-01 00:00:00+00'::timestamptz, 'مقدار اولیه BR-2')
) as v(key, value, effective_from, reason)
where not exists (select 1 from sys.setting_versions s where s.key = v.key);

-- -----------------------------------------------------------------------------
-- مجوزهای موجودی (USER_ROLES §3.4) — فقط نقش‌های ✔ ماتریس
-- -----------------------------------------------------------------------------
insert into iam.permissions (key, domain, description) values
  ('inventory.read',              'inventory', 'مشاهده موجودی و گردش'),
  ('inventory.adjust',            'inventory', 'تعدیل موجودی با دلیل'),
  ('warehouse.grn.create',        'warehouse', 'ثبت رسید انبار'),
  ('warehouse.pick.execute',      'warehouse', 'اجرای برداشت'),
  ('returns.inspection.record',   'returns',   'ثبت بازرسی مرجوعی')
on conflict (key) do nothing;

insert into iam.role_permissions (role_id, permission_id)
select r.id, p.id
from (values
  ('R-CEO',   'inventory.read'), ('R-SALES', 'inventory.read'),
  ('R-FIN',   'inventory.read'), ('R-ACC',   'inventory.read'),
  ('R-BUY',   'inventory.read'), ('R-WH',    'inventory.read'),
  ('R-OP',    'inventory.read'), ('R-MKT',   'inventory.read'),
  ('R-SUP',   'inventory.read'), ('R-SYS',   'inventory.read'),
  ('R-WH',    'inventory.adjust'),
  ('R-WH',    'warehouse.grn.create'),
  ('R-WH',    'warehouse.pick.execute'), ('R-OP', 'warehouse.pick.execute'),
  ('R-WH',    'returns.inspection.record')
) as m(role_key, permission_key)
join iam.roles r on r.key = m.role_key
join iam.permissions p on p.key = m.permission_key
on conflict do nothing;

-- -----------------------------------------------------------------------------
-- گردش اتمیک موجودی
-- -----------------------------------------------------------------------------
create function inv.apply_movement(
  p_actor uuid,
  p_warehouse_id uuid,
  p_variant_id uuid,
  p_delta integer,
  p_reason_code text,
  p_document_type text,
  p_document_id uuid,
  p_note text default null,
  p_request_id text default null
) returns uuid
language plpgsql security definer set search_path = inv, cat, sys, iam, pg_catalog as $$
declare
  v_permission text;
  v_on_hand    integer;
  v_reserved   integer;
  v_quarantined integer;
  v_available  integer;
  v_balance    integer;
  v_ledger     uuid;
begin
  v_permission := case p_reason_code
                    when 'grn'           then 'warehouse.grn.create'
                    when 'sale_ship'     then 'warehouse.pick.execute'
                    when 'return_restock' then 'returns.inspection.record'
                    when 'adjust'        then 'inventory.adjust'
                  end;

  if v_permission is null then
    raise exception 'FCO-1070: reason_code % برای گردش موجودی مجاز نیست', coalesce(p_reason_code, 'null')
      using errcode = '22023';
  end if;
  perform iam.authorize(p_actor, v_permission);

  if p_delta is null or p_delta = 0 then
    raise exception 'FCO-1070: مقدار گردش باید غیرصفر باشد' using errcode = '22023';
  end if;
  if p_document_id is null or p_document_type is null or btrim(p_document_type) = '' then
    raise exception 'FCO-1070: سند مرجع گردش الزامی است' using errcode = '22023';
  end if;
  if not exists (select 1 from inv.warehouses w where w.id = p_warehouse_id) then
    raise exception 'FCO-1072: انبار % وجود ندارد', p_warehouse_id using errcode = '22023';
  end if;
  if not exists (select 1 from cat.variants v where v.id = p_variant_id) then
    raise exception 'FCO-1072: تنوع % وجود ندارد', p_variant_id using errcode = '22023';
  end if;

  insert into inv.stock_balance (warehouse_id, variant_id)
  values (p_warehouse_id, p_variant_id)
  on conflict do nothing;

  select on_hand, reserved, quarantined
    into v_on_hand, v_reserved, v_quarantined
    from inv.stock_balance
   where warehouse_id = p_warehouse_id and variant_id = p_variant_id
   for update;

  v_available := v_on_hand - v_reserved - v_quarantined;
  v_balance := v_on_hand + p_delta;

  if v_balance < 0 then
    raise exception 'FCO-1075: گردش % موجودی را منفی می‌کند (on_hand=%)', p_delta, v_on_hand
      using errcode = '22023';
  end if;
  if v_available + p_delta < 0 then
    raise exception 'FCO-1076: موجودی قابل‌فروش کافی نیست (available=%، delta=%)',
      v_available, p_delta using errcode = '22023';
  end if;

  update inv.stock_balance
     set on_hand = v_balance
   where warehouse_id = p_warehouse_id and variant_id = p_variant_id;

  insert into inv.stock_ledger
    (warehouse_id, variant_id, quantity_delta, balance_after, reason_code,
     document_type, document_id, actor_id, note)
  values
    (p_warehouse_id, p_variant_id, p_delta, v_balance, p_reason_code,
     p_document_type, p_document_id, p_actor, p_note)
  returning id into v_ledger;

  perform sys.audit_write(
    p_actor       => p_actor,
    p_action      => 'stock.movement',
    p_entity_type => 'stock_ledger',
    p_entity_id   => v_ledger,
    p_after       => jsonb_build_object(
                       'warehouse_id', p_warehouse_id, 'variant_id', p_variant_id,
                       'delta', p_delta, 'balance_after', v_balance,
                       'reason', p_reason_code, 'document_type', p_document_type,
                       'document_id', p_document_id),
    p_permission  => v_permission,
    p_request_id  => coalesce(p_request_id, 'fn:apply_movement'));

  return v_ledger;
end $$;

comment on function inv.apply_movement(uuid, uuid, uuid, integer, text, text, uuid, text, text) is
  'تنها مسیر تغییر on_hand؛ قفل ردیف تجمیع + دفتر + Audit در یک تراکنش';

-- -----------------------------------------------------------------------------
-- رزرو (بدون مجوز کارمند؛ از use-case سفارش در BR-3 صدا زده می‌شود)
-- -----------------------------------------------------------------------------
create function inv.reserve(
  p_actor uuid,
  p_order_line_id uuid,
  p_warehouse_id uuid,
  p_variant_id uuid,
  p_quantity integer,
  p_ttl_minutes integer default null
) returns uuid
language plpgsql security definer set search_path = inv, sys, iam, pg_catalog as $$
declare
  v_ttl       integer := coalesce(p_ttl_minutes, sys.setting_int('inv.reservation_ttl_minutes'));
  v_on_hand   integer;
  v_reserved  integer;
  v_quarantined integer;
  v_available integer;
  v_id        uuid;
begin
  if p_actor is null or not exists (select 1 from iam.users u where u.id = p_actor) then
    raise exception 'FCO-1005: actor رزرو نامعتبر است' using errcode = '28000';
  end if;
  if p_quantity is null or p_quantity <= 0 then
    raise exception 'FCO-1071: مقدار رزرو باید مثبت باشد' using errcode = '22023';
  end if;
  if v_ttl is null or v_ttl < 1 or v_ttl > 1440 then
    raise exception 'FCO-1071: TTL رزرو باید بین ۱ و ۱۴۴۰ دقیقه باشد (%)', coalesce(v_ttl, -1)
      using errcode = '22023';
  end if;

  select on_hand, reserved, quarantined
    into v_on_hand, v_reserved, v_quarantined
    from inv.stock_balance
   where warehouse_id = p_warehouse_id and variant_id = p_variant_id
   for update;

  if not found then
    raise exception 'FCO-1072: ردیف موجودی برای تنوع % در انبار % وجود ندارد',
      p_variant_id, p_warehouse_id using errcode = '22023';
  end if;

  v_available := v_on_hand - v_reserved - v_quarantined;
  if v_available < p_quantity then
    raise exception 'FCO-1071: موجودی کافی نیست (available=%، درخواست=%)',
      v_available, p_quantity using errcode = '22023';
  end if;

  begin
    insert into inv.reservations
      (warehouse_id, variant_id, order_line_id, quantity, expires_at)
    values
      (p_warehouse_id, p_variant_id, p_order_line_id, p_quantity,
       now() + make_interval(mins => v_ttl))
    returning id into v_id;
  exception when unique_violation then
    raise exception 'FCO-1073: برای این قلم سفارش، رزرو فعال وجود دارد'
      using errcode = '23505';
  end;

  update inv.stock_balance
     set reserved = reserved + p_quantity
   where warehouse_id = p_warehouse_id and variant_id = p_variant_id;

  perform sys.audit_write(
    p_actor       => p_actor,
    p_action      => 'stock.reserve',
    p_entity_type => 'reservations',
    p_entity_id   => v_id,
    p_after       => jsonb_build_object(
                       'warehouse_id', p_warehouse_id, 'variant_id', p_variant_id,
                       'order_line_id', p_order_line_id, 'quantity', p_quantity,
                       'expires_in_minutes', v_ttl),
    p_request_id  => 'fn:reserve');

  return v_id;
end $$;

comment on function inv.reserve(uuid, uuid, uuid, uuid, integer, integer) is
  'رزرو اتمیک زیر قفل ردیف تجمیع؛ oversell صفر (BRQ-14)';

-- -----------------------------------------------------------------------------
-- آزادسازی (ایدمپوتنت)
-- -----------------------------------------------------------------------------
create function inv.release(
  p_actor uuid,
  p_reservation_id uuid,
  p_reason text default 'release'
) returns boolean
language plpgsql security definer set search_path = inv, iam, sys, pg_catalog as $$
declare
  v_quantity integer;
  v_status   text;
  v_warehouse uuid;
  v_variant  uuid;
begin
  select quantity, status, warehouse_id, variant_id
    into v_quantity, v_status, v_warehouse, v_variant
    from inv.reservations
   where id = p_reservation_id
   for update;

  if not found then
    raise exception 'FCO-1074: رزرو % وجود ندارد', p_reservation_id using errcode = '22023';
  end if;
  if v_status <> 'active' then
    return false;   -- آزادسازی دوباره اثری ندارد
  end if;

  update inv.reservations
     set status = 'released', released_at = now()
   where id = p_reservation_id;

  update inv.stock_balance
     set reserved = reserved - v_quantity
   where warehouse_id = v_warehouse and variant_id = v_variant;

  perform sys.audit_write(
    p_actor       => p_actor,
    p_action      => 'stock.release',
    p_entity_type => 'reservations',
    p_entity_id   => p_reservation_id,
    p_before      => jsonb_build_object('status', 'active', 'quantity', v_quantity),
    p_after       => jsonb_build_object('status', 'released', 'reason', coalesce(p_reason, 'release')),
    p_request_id  => 'fn:release');

  return true;
end $$;

comment on function inv.release(uuid, uuid, text) is
  'آزادسازی یک‌بار؛ فراخوانی دوباره false می‌دهد و reserved را دوباره کم نمی‌کند';

-- -----------------------------------------------------------------------------
-- Job آزادسازی رزروهای منقضی (T-INV-04)
-- -----------------------------------------------------------------------------
create function inv.expire_reservations(
  p_actor uuid,
  p_scheduled_for timestamptz default date_trunc('hour', now()),
  p_limit integer default null
) returns table (outcome text, expired integer, run_id bigint)
language plpgsql security definer set search_path = inv, sys, iam, pg_catalog as $$
declare
  v_batch integer := coalesce(p_limit, sys.setting_int('job.reservation_expiry.batch'));
  v_run   bigint;
  v_count integer := 0;
  r       record;
begin
  perform iam.authorize(p_actor, 'platform.job.run');

  if v_batch is null or v_batch < 1 or v_batch > 1000 then
    raise exception 'FCO-1077: اندازه دسته باید بین ۱ و ۱۰۰۰ باشد (%)', coalesce(v_batch, -1)
      using errcode = '22023';
  end if;

  v_run := sys.job_begin('reservation_expiry', p_scheduled_for);
  if v_run is null then
    return query select 'already_ran'::text, 0, null::bigint;
    return;
  end if;

  begin
    for r in
      select id from inv.reservations
       where status = 'active' and expires_at <= now()
       order by expires_at
       limit v_batch
    loop
      if inv.release(p_actor, r.id, 'expired') then
        v_count := v_count + 1;
      end if;
    end loop;

    perform sys.job_finish(v_run, 'succeeded');
    return query select 'ran'::text, v_count, v_run;
  exception when others then
    perform sys.job_finish(v_run, 'failed', sqlerrm);
    return query select 'failed'::text, 0, v_run;
  end;
end $$;

comment on function inv.expire_reservations(uuid, timestamptz, integer) is
  'outcome: ran | already_ran | failed؛ هر slot حداکثر یک‌بار آزادسازی می‌کند';

-- -----------------------------------------------------------------------------
-- دسترسی
-- -----------------------------------------------------------------------------
grant execute on function
  inv.apply_movement(uuid, uuid, uuid, integer, text, text, uuid, text, text),
  inv.reserve(uuid, uuid, uuid, uuid, integer, integer),
  inv.release(uuid, uuid, text),
  inv.expire_reservations(uuid, timestamptz, integer)
to fco_app;
