do $$
declare
  v_count integer;
  v_failures integer;
  v_error text;
  v_message text;
  v_run bigint;
  v_first timestamptz;
  v_latest timestamptz;
  v_columns integer;
  v_defaults integer;
begin
  select count(*), max(failures), max(error_sqlstate), max(message), max(run_id),
         min(first_failed_at), max(occurred_at)
    into v_count, v_failures, v_error, v_message, v_run, v_first, v_latest
    from inv.reservation_expiry_failures
   where reservation_id = 'ba190000-0000-0000-0000-000000000005';

  if v_count <> 1 or v_failures <> 3
     or v_error <> 'XX000' or v_message <> 'latest failure'
     or v_run <> (select id from sys.job_runs
                   where job_name = 'reservation_expiry_migration_test'
                     and scheduled_for = '2000-01-01 03:00:00+00')
     or v_first <> '2000-01-01 01:00:00+00'
     or v_latest <> '2000-01-01 03:00:00+00' then
    raise exception 'FAIL BACKFILL: count=% failures=% sqlstate=% message=% run=% first=% latest=%',
      v_count, v_failures, v_error, v_message, v_run, v_first, v_latest;
  end if;

  select count(*), count(*) filter (where column_default is not null)
    into v_columns, v_defaults
    from information_schema.columns
   where table_schema = 'inv' and table_name = 'reservation_expiry_failures'
     and column_name in ('failures', 'first_failed_at');
  if v_columns <> 2 or v_defaults <> 0 then
    raise exception 'FAIL DEFAULT: found % columns and % defaults (expected 2 and 0)',
      v_columns, v_defaults;
  end if;

  begin
    insert into inv.reservation_expiry_failures
      (run_id, reservation_id, error_sqlstate, message)
    values (v_run, 'ba190000-0000-0000-0000-000000000007',
            'XX000', 'missing migration defaults');
    raise exception 'FAIL DEFAULT: insert without failures/first_failed_at succeeded';
  exception when not_null_violation then
    null;
  end;
end $$;

delete from inv.reservation_expiry_failures
 where reservation_id in ('ba190000-0000-0000-0000-000000000005',
                          'ba190000-0000-0000-0000-000000000007');
delete from inv.reservations
 where id in ('ba190000-0000-0000-0000-000000000005',
              'ba190000-0000-0000-0000-000000000007');
delete from inv.stock_balance
 where warehouse_id = 'ba190000-0000-0000-0000-000000000004';
delete from inv.warehouses where id = 'ba190000-0000-0000-0000-000000000004';
delete from cat.variants where id = 'ba190000-0000-0000-0000-000000000003';
delete from cat.products where id = 'ba190000-0000-0000-0000-000000000002';
delete from cat.brands where id = 'ba190000-0000-0000-0000-000000000001';
delete from sys.job_runs where job_name = 'reservation_expiry_migration_test';

select 'PASS BACKFILL | legacy rows collapsed by migration 0019';
select 'PASS DEFAULT | no defaults; incomplete insert rejected';
