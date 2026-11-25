-- بازگشت 0014_catalog_public_search
-- ترتیب: توابع وابسته → ایندکس → پیکربندی → تنظیم‌ها
drop function if exists cat.search_products(text, text, text, text, integer, integer);
drop function if exists cat.public_product(text, text);
drop function if exists cat.category_path(text, boolean);
drop function if exists cat.public_product_ids(text, text, text);
drop function if exists cat.search_query(text);
drop index if exists cat.products_search_gin;
drop index if exists cat.products_brand_idx;
drop function if exists cat.search_vector(text, text);
drop text search configuration if exists cat.fa;
drop function if exists cat.normalize_text(text);

-- `sys.settings`/`sys.setting_versions` حذف نمی‌شوند: تاریخچه تنظیمات
-- فقط‌افزودنی است (FCO-1025) و همان الگوی بازگشت 0011/0013 است.
