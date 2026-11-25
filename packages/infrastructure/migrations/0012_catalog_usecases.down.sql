-- =============================================================================
-- 0012_catalog_usecases.down — بازگشت BR-2 گام ۲
-- ترتیب: use-caseها، گاردهای جدید، مجوزها، سپس بازگرداندن شکل ۰۰۱۱.
-- =============================================================================

drop function if exists cat.variant_update(uuid, uuid, text, integer, boolean, integer, text);
drop function if exists cat.variant_create(uuid, uuid, text, text, integer, text);
drop function if exists cat.product_update(uuid, uuid, text, text, uuid, uuid, jsonb, integer, text);
drop function if exists cat.product_create(uuid, text, text, text, uuid, uuid, jsonb, text);

drop trigger if exists prices_supersede_guard on pricing.prices;
drop function if exists pricing.prices_supersede_guard();

drop trigger if exists stock_balance_bump_version on inv.stock_balance;
drop function if exists inv.stock_balance_bump_version();

delete from iam.role_permissions
 where role_id in (select id from iam.roles where key = 'R-SALES')
   and permission_id in (select id from iam.permissions
                          where key in ('catalog.product.write', 'catalog.variant.write'));

delete from iam.permissions
 where key in ('catalog.product.write', 'catalog.variant.write');

alter table cat.products drop constraint if exists products_attributes_object;

alter table cat.variants drop constraint if exists variants_sku_check;
alter table cat.variants
  add constraint variants_sku_check check (sku = upper(sku) and btrim(sku) <> '');

alter table cat.variants drop column if exists version;
