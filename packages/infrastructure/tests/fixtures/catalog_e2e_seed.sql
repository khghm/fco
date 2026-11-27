-- Seed only the fresh isolated database created by scripts/catalog-e2e.sh.
begin;

insert into cat.brands (id, slug, title) values
  ('b4000000-0000-0000-0000-000000000001', 'fco-e2e', 'FCO E2E');

insert into cat.categories (id, slug, title) values
  ('c4000000-0000-0000-0000-000000000001', 'e2e', 'آزمون فروشگاه');

insert into cat.products
  (id, slug, title, description, brand_id, category_id, status, published_at)
values
  ('a4000000-0000-0000-0000-000000000001', 'e2e-shirt',
   'پیراهن آزمایشی FCO', 'محصول نمونه برای آزمون endpoint',
   'b4000000-0000-0000-0000-000000000001',
   'c4000000-0000-0000-0000-000000000001',
   'published', now() - interval '1 minute'),
  ('a4000000-0000-0000-0000-000000000002', 'cart-e2e-scarf',
   'شال آزمایشی', 'محصول دوم برای آزمون ادغام سبد',
   null,
   'c4000000-0000-0000-0000-000000000001',
   'published', now() - interval '1 minute');

insert into cat.variants (id, product_id, sku) values
  ('e4000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000001', 'E2E-SHIRT-001'),
  ('e4000000-0000-0000-0000-000000000002',
   'a4000000-0000-0000-0000-000000000002', 'CART-E2E-SCARF-001');

insert into cat.product_media
  (id, product_id, storage_key, alt_text, sort_order)
values
  ('f4000000-0000-0000-0000-000000000001',
   'a4000000-0000-0000-0000-000000000001',
   'catalog/e2e-shirt/front.png', 'نمای جلو', 1);

insert into pricing.prices
  (variant_id, channel, amount_rial, compare_at_rial, effective_from)
values
  ('e4000000-0000-0000-0000-000000000001', 'web', 650000, 800000,
   now() - interval '1 day'),
  ('e4000000-0000-0000-0000-000000000002', 'web', 450000, null,
   now() - interval '1 day');

insert into inv.warehouses (id, code, title) values
  ('94000000-0000-0000-0000-000000000001', 'E2E-WH', 'انبار آزمون');

insert into inv.stock_balance (warehouse_id, variant_id, on_hand, reserved) values
  ('94000000-0000-0000-0000-000000000001',
   'e4000000-0000-0000-0000-000000000001', 5, 1),
  ('94000000-0000-0000-0000-000000000001',
   'e4000000-0000-0000-0000-000000000002', 8, 0);

insert into iam.users (id, mobile, full_name, status, mfa_required)
values (
  'd4000000-0000-0000-0000-000000000001',
  '09120000000',
  'E2E Customer',
  'active',
  false
);

insert into sys.setting_versions (key, value, effective_from, reason)
values (
  'auth.otp.spool_enabled',
  'true'::jsonb,
  now(),
  'فعال‌سازی Mock SMS فقط برای دیتابیس E2E موقت'
);

commit;
