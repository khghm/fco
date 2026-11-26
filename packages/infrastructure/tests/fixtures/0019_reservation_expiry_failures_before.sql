insert into cat.brands (id, slug, title)
values ('ba190000-0000-0000-0000-000000000001', 'migration-0019-fixture', 'Migration 0019 fixture');

insert into cat.products (id, slug, title, brand_id)
values ('ba190000-0000-0000-0000-000000000002', 'migration-0019-fixture',
        'Migration 0019 fixture', 'ba190000-0000-0000-0000-000000000001');

insert into cat.variants (id, product_id, sku)
values ('ba190000-0000-0000-0000-000000000003', 'ba190000-0000-0000-0000-000000000002',
        'MIG-0019');

insert into inv.warehouses (id, code, title)
values ('ba190000-0000-0000-0000-000000000004', 'MIG-0019', 'Migration 0019 fixture');

insert into inv.stock_balance (warehouse_id, variant_id, on_hand)
values ('ba190000-0000-0000-0000-000000000004',
        'ba190000-0000-0000-0000-000000000003', 2);

insert into inv.reservations
  (id, warehouse_id, variant_id, order_line_id, quantity, expires_at)
values ('ba190000-0000-0000-0000-000000000005',
        'ba190000-0000-0000-0000-000000000004',
        'ba190000-0000-0000-0000-000000000003',
        'ba190000-0000-0000-0000-000000000006', 1, now() + interval '1 day'),
       ('ba190000-0000-0000-0000-000000000007',
        'ba190000-0000-0000-0000-000000000004',
        'ba190000-0000-0000-0000-000000000003',
        'ba190000-0000-0000-0000-000000000008', 1, now() + interval '1 day');

do $$
declare
  v_old_run bigint;
  v_middle_run bigint;
  v_latest_run bigint;
begin
  insert into sys.job_runs (job_name, scheduled_for)
  values ('reservation_expiry_migration_test', '2000-01-01 01:00:00+00')
  returning id into v_old_run;
  insert into sys.job_runs (job_name, scheduled_for)
  values ('reservation_expiry_migration_test', '2000-01-01 02:00:00+00')
  returning id into v_middle_run;
  insert into sys.job_runs (job_name, scheduled_for)
  values ('reservation_expiry_migration_test', '2000-01-01 03:00:00+00')
  returning id into v_latest_run;

  insert into inv.reservation_expiry_failures
    (run_id, reservation_id, error_sqlstate, message, occurred_at)
  values
    (v_old_run, 'ba190000-0000-0000-0000-000000000005',
     '23514', 'oldest failure', '2000-01-01 01:00:00+00'),
    (v_middle_run, 'ba190000-0000-0000-0000-000000000005',
     '23505', 'middle failure', '2000-01-01 02:00:00+00'),
    (v_latest_run, 'ba190000-0000-0000-0000-000000000005',
     'XX000', 'latest failure', '2000-01-01 03:00:00+00');
end $$;
