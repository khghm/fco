-- =============================================================================
-- 0016_movement_direction — جهت گردش به reason_code گره می‌خورد
-- مالک طرح: docs/Architecture-02/DATABASE_DESIGN.md §3.4 (قواعد سخت ۱–۵)
--           docs/Business-01/USER_ROLES_AND_PERMISSIONS.md §3.4
--           docs/Engineering-04/TEST_STRATEGY.md §4.1 (T-INV-06)
--
-- شکاف واقعی (بازبینی گام ۳): `inv.apply_movement` مجوز را از `reason_code`
-- نگاشت می‌کرد ولی علامت `delta` را بررسی نمی‌کرد. نتیجه: کارمندی که فقط
-- مجوز `warehouse.grn.create` داشت می‌توانست `grn` با مقدار منفی ثبت کند و
-- موجودی را بدون `inventory.adjust` کاهش دهد — دور زدن ماتریس مجوز.
--
-- راه‌حل: گارد روی `inv.stock_ledger` (تنها جدول دفتر گردش) به‌جای تکرار در
-- `apply_movement`. هر نویسنده آینده هم ناچار به همین قاعده است و رفتار
-- فعلی تابع تغییر نمی‌کند:
--   grn، return_restock → فقط مثبت (ورود به انبار)
--   sale_ship          → فقط منفی (خروج از انبار)
--   adjust             → هر دو (تعدیل با دلیل)
--   reserve/release    → در دفتر گردش مجاز نیستند (گردش نیستند)
-- خطا: FCO-1078. برگشت خروج کالا/ابطال رسید مسیر خودش (`adjust` یا RMA) را دارد.
-- =============================================================================

create function inv.stock_ledger_direction_guard() returns trigger
language plpgsql as $$
begin
  case new.reason_code
    when 'grn' then
      if new.quantity_delta < 0 then
        raise exception 'FCO-1078: رسید انبار (grn) فقط افزایشی است (%)', new.quantity_delta
          using errcode = '22023';
      end if;
    when 'return_restock' then
      if new.quantity_delta < 0 then
        raise exception 'FCO-1078: بازگشت به انبار فقط افزایشی است (%)', new.quantity_delta
          using errcode = '22023';
      end if;
    when 'sale_ship' then
      if new.quantity_delta > 0 then
        raise exception 'FCO-1078: خروج فروش (sale_ship) فقط کاهشی است (%)', new.quantity_delta
          using errcode = '22023';
      end if;
    when 'adjust' then
      null;   -- تعدیل دوطرفه است؛ مجوزش جدا بررسی می‌شود
    else
      raise exception 'FCO-1078: reason_code % برای دفتر گردش مجاز نیست', new.reason_code
        using errcode = '22023';
  end case;

  return new;
end $$;

create trigger stock_ledger_direction_guard
  before insert on inv.stock_ledger
  for each row execute function inv.stock_ledger_direction_guard();

comment on function inv.stock_ledger_direction_guard() is
  'جهت delta را با reason_code تطبیق می‌دهد؛ grn/return مثبت، sale_ship منفی، reserve/release ممنوع (FCO-1078)';
