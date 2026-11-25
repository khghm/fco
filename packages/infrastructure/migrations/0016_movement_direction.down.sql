-- بازگشت 0016_movement_direction
drop trigger if exists stock_ledger_direction_guard on inv.stock_ledger;
drop function if exists inv.stock_ledger_direction_guard();
