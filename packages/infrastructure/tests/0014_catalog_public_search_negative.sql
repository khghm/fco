-- =============================================================================
-- 0014_catalog_public_search_negative — BR-2 گام ۴
-- مالک انتظارها: docs/Engineering-04/TEST_STRATEGY.md §4.1 (T-CAT-01..03)
--
-- اجرا:
--   docker exec -i fco-postgres psql -U fco -d fco -v ON_ERROR_STOP=1 -f - \
--     < packages/infrastructure/tests/0014_catalog_public_search_negative.sql
--
-- پوشش: پنهان‌بودن پیش‌نویس/آرشیو/آینده، یکسان‌سازی فارسی (ك عربی، ارقام)،
--       دسته شامل زیرشاخه، دسته/برند ناموجود، قیمت مؤثر کانال و بازه (نه آینده،
--       نه کانال دیگر)، موجودی قابل‌فروش، صفحه‌بندی بدون تکرار و total_count،
--       سقف‌های ورودی، مسیر دسته، و همان گاردها از نقش اپ.
-- همه‌چیز در یک تراکنش است و با rollback پاک می‌شود.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

-- --- داده آزمون -------------------------------------------------------------
insert into cat.brands (id, slug, title) values
  ('b4000000-0000-0000-0000-000000000001', 'nike', 'نایک'),
  ('b4000000-0000-0000-0000-000000000002', 'adidas', 'آدیداس');

insert into cat.categories (id, slug, title, parent_id) values
  ('c4000000-0000-0000-0000-000000000001', 'fashion', 'مد و پوشاک', null),
  ('c4000000-0000-0000-0000-000000000002', 'books', 'کتاب', 'c4000000-0000-0000-0000-000000000001'),
  ('c4000000-0000-0000-0000-000000000003', 'shoes', 'کفش', 'c4000000-0000-0000-0000-000000000001');

insert into cat.products (id, slug, title, description, brand_id, category_id, status, published_at) values
  ('a4000000-0000-0000-0000-000000000001', 'p1-book', 'کتاب فارسی', 'راهنمای خرید کتاب',
   'b4000000-0000-0000-0000-000000000001', 'c4000000-0000-0000-0000-000000000002',
   'published', now() - interval '1 hour'),
  ('a4000000-0000-0000-0000-000000000002', 'p2-draft', 'کتاب پیش‌نویس', null,
   'b4000000-0000-0000-0000-000000000001', 'c4000000-0000-0000-0000-000000000002',
   'draft', null),
  ('a4000000-0000-0000-0000-000000000003', 'p3-archived', 'کتاب آرشیو', null,
   'b4000000-0000-0000-0000-000000000001', 'c4000000-0000-0000-0000-000000000002',
   'archived', now() - interval '2 days'),
  ('a4000000-0000-0000-0000-000000000004', 'p4-future', 'کتاب آینده', null,
   'b4000000-0000-0000-0000-000000000001', 'c4000000-0000-0000-0000-000000000002',
   'published', now() + interval '1 day'),
  ('a4000000-0000-0000-0000-000000000005', 'p5-shoes', 'کفش ورزشی', null,
   'b4000000-0000-0000-0000-000000000002', 'c4000000-0000-0000-0000-000000000003',
   'published', now() - interval '2 hours'),
  ('a4000000-0000-0000-0000-000000000006', 'p6-arabic-kaf', 'كتاب با كاف عربی', null,
   'b4000000-0000-0000-0000-000000000001', 'c4000000-0000-0000-0000-000000000002',
   'published', now() - interval '3 hours'),
  ('a4000000-0000-0000-0000-000000000007', 'p7-digits', 'کتاب ۱۲۳ جلد دوم', null,
   'b4000000-0000-0000-0000-000000000002', 'c4000000-0000-0000-0000-000000000002',
   'published', now() - interval '30 minutes');

insert into cat.variants (id, product_id, sku) values
  ('e4000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000001', 'T-1A'),
  ('e4000000-0000-0000-0000-000000000002', 'a4000000-0000-0000-0000-000000000001', 'T-1B'),
  ('e4000000-0000-0000-0000-000000000003', 'a4000000-0000-0000-0000-000000000002', 'T-2'),
  ('e4000000-0000-0000-0000-000000000004', 'a4000000-0000-0000-0000-000000000003', 'T-3'),
  ('e4000000-0000-0000-0000-000000000005', 'a4000000-0000-0000-0000-000000000004', 'T-4'),
  ('e4000000-0000-0000-0000-000000000006', 'a4000000-0000-0000-0000-000000000005', 'T-5'),
  ('e4000000-0000-0000-0000-000000000007', 'a4000000-0000-0000-0000-000000000006', 'T-6'),
  ('e4000000-0000-0000-0000-000000000008', 'a4000000-0000-0000-0000-000000000007', 'T-7');

-- قیمت: بازه مؤثر web + بازه آینده (باید نادیده گرفته شود) + کانال b2b
insert into pricing.prices (variant_id, channel, amount_rial, effective_from, effective_to) values
  ('e4000000-0000-0000-0000-000000000001', 'web', 500000, now() - interval '2 days', now() + interval '2 days'),
  ('e4000000-0000-0000-0000-000000000001', 'web', 400000, now() + interval '2 days', null),
  ('e4000000-0000-0000-0000-000000000001', 'b2b', 300000, now() - interval '2 days', null),
  ('e4000000-0000-0000-0000-000000000002', 'web', 700000, now() - interval '2 days', null),
  ('e4000000-0000-0000-0000-000000000006', 'web', 900000, now() - interval '2 days', null),
  ('e4000000-0000-0000-0000-000000000007', 'web', 100000, now() - interval '2 days', null),
  ('e4000000-0000-0000-0000-000000000008', 'web', 120000, now() - interval '2 days', null);

insert into inv.warehouses (id, code, title) values
  ('94000000-0000-0000-0000-000000000001', 'PUB-WH', 'انبار عمومی');
insert into inv.stock_balance (warehouse_id, variant_id, on_hand, reserved) values
  ('94000000-0000-0000-0000-000000000001', 'e4000000-0000-0000-0000-000000000001', 3, 3),
  ('94000000-0000-0000-0000-000000000001', 'e4000000-0000-0000-0000-000000000002', 4, 2),
  ('94000000-0000-0000-0000-000000000001', 'e4000000-0000-0000-0000-000000000007', 5, 0),
  ('94000000-0000-0000-0000-000000000001', 'e4000000-0000-0000-0000-000000000008', 1, 0);

-- --- T-CAT-01: پنهان‌بودن غیرمنتشرشده‌ها -----------------------------------
do $$
declare v_count integer; v_draft jsonb; v_future jsonb; v_archived jsonb;
begin
  select count(*) into v_count from cat.public_product_ids(null, null, null);
  if v_count <> 4 then
    raise exception 'FAIL VISIBILITY: % محصول عمومی برگشت، انتظار ۴', v_count;
  end if;

  if exists (select 1 from cat.public_product_ids(null, null, null)
              where product_id in ('a4000000-0000-0000-0000-000000000002',
                                   'a4000000-0000-0000-0000-000000000003',
                                   'a4000000-0000-0000-0000-000000000004')) then
    raise exception 'FAIL VISIBILITY: پیش‌نویس/آرشیو/آینده در فیلتر عمومی آمد';
  end if;

  v_draft := cat.public_product('p2-draft');
  v_archived := cat.public_product('p3-archived');
  v_future := cat.public_product('p4-future');
  if v_draft is not null or v_archived is not null or v_future is not null then
    raise exception 'FAIL VISIBILITY: صفحه محصول غیرمنتشرشده NULL نبود';
  end if;
  if cat.public_product('does-not-exist') is not null then
    raise exception 'FAIL VISIBILITY: slug ناموجود صفحه داد';
  end if;
  raise notice 'PASS VISIBILITY | ۴ محصول منتشرشده دیده شد؛ پیش‌نویس/آرشیو/آینده/ناموجود پنهان ماندند';
end $$;

-- --- T-CAT-02: یکسان‌سازی فارسی و جست‌وجو -----------------------------------
do $$
declare v_kaf integer; v_digits integer; v_desc integer; v_total bigint; v_noise integer;
begin
  -- «كتاب» با کاف عربی باید «کتاب» را پیدا کند
  select count(*) into v_kaf from cat.search_products('كتاب');
  if v_kaf <> 3 then
    raise exception 'FAIL SEARCH: جست‌وجوی كاف عربی % نتیجه داد، انتظار ۳', v_kaf;
  end if;

  select count(*) into v_digits from cat.search_products('123');
  if v_digits <> 1 then
    raise exception 'FAIL SEARCH: ارقام لاتین % نتیجه داد، انتظار ۱', v_digits;
  end if;

  select count(*) into v_desc from cat.search_products('راهنمای');
  if v_desc <> 1 then
    raise exception 'FAIL SEARCH: جست‌وجو در description % نتیجه داد، انتظار ۱', v_desc;
  end if;

  select total_count into v_total from cat.search_products('کتاب', null, null, 'web', 1, 0);
  if v_total <> 3 then
    raise exception 'FAIL SEARCH: total_count=% ، انتظار ۳', v_total;
  end if;

  -- عبارت بی‌معنا نباید خطا بدهد و نباید همه‌چیز برگرداند
  select count(*) into v_noise from cat.search_products('!!! ???');
  if v_noise <> 0 then
    raise exception 'FAIL SEARCH: عبارت نشانه‌ای % ردیف برگرداند', v_noise;
  end if;
  raise notice 'PASS SEARCH | ك→ک، ۱۲۳→123، جست‌وجو در description، عبارت نشانه‌ای بی‌نتیجه';
end $$;

-- --- T-CAT-02: دسته (شامل زیرشاخه) و برند -----------------------------------
do $$
declare v_books integer; v_fashion integer; v_unknown integer; v_brand integer;
begin
  select count(*) into v_books from cat.search_products(null, 'books');
  if v_books <> 3 then
    raise exception 'FAIL CATEGORY: دسته books % ردیف داد، انتظار ۳', v_books;
  end if;

  select count(*) into v_fashion from cat.search_products(null, 'fashion');
  if v_fashion <> 4 then
    raise exception 'FAIL CATEGORY: دسته مادر % ردیف داد، انتظار ۴ (کتاب ۳ + کفش ۱)', v_fashion;
  end if;

  select count(*) into v_unknown from cat.search_products(null, 'no-such-category');
  if v_unknown <> 0 then
    raise exception 'FAIL CATEGORY: دسته ناموجود % ردیف داد (نباید بی‌فیلتر شود)', v_unknown;
  end if;

  select count(*) into v_brand from cat.search_products(null, null, 'adidas');
  if v_brand <> 2 then
    raise exception 'FAIL BRAND: برند adidas % ردیف داد، انتظار ۲', v_brand;
  end if;
  raise notice 'PASS CATEGORY | books=3، fashion=4، دسته ناموجود=0، adidas=2';
end $$;

-- --- T-CAT-03: قیمت مؤثر کانال/بازه و موجودی قابل‌فروش ---------------------
do $$
declare v_web bigint; v_future_is_used boolean; v_b2b bigint;
        v_qty integer; v_in_stock boolean; v_shoes_qty integer; v_shoes_in_stock boolean;
begin
  select price_rial, available_qty, in_stock into v_web, v_qty, v_in_stock
    from cat.search_products('کتاب فارسی') where slug = 'p1-book';
  if v_web <> 500000 then
    raise exception 'FAIL PRICE: قیمت web=% (انتظار ۵۰۰۰۰۰؛ نه ۴۰۰۰۰۰ آینده، نه ۳۰۰۰۰۰ b2b)', v_web;
  end if;
  if v_qty <> 2 or v_in_stock is not true then
    raise exception 'FAIL STOCK: p1 qty=% in_stock=% (انتظار ۲/true)', v_qty, v_in_stock;
  end if;

  select (price_rial = 400000) into v_future_is_used
    from cat.search_products('کتاب فارسی') where slug = 'p1-book';
  if v_future_is_used then
    raise exception 'FAIL PRICE: قیمت بازه آینده اعمال شد';
  end if;

  select price_rial into v_b2b
    from cat.search_products('کتاب فارسی', null, null, 'b2b') where slug = 'p1-book';
  if v_b2b <> 300000 then
    raise exception 'FAIL PRICE: قیمت کانال b2b=% (انتظار ۳۰۰۰۰۰)', v_b2b;
  end if;

  select available_qty, in_stock into v_shoes_qty, v_shoes_in_stock
    from cat.search_products(null, 'shoes') where slug = 'p5-shoes';
  if v_shoes_qty <> 0 or v_shoes_in_stock is not false then
    raise exception 'FAIL STOCK: کالای بدون موجودی qty=% in_stock=%', v_shoes_qty, v_shoes_in_stock;
  end if;
  raise notice 'PASS PRICE/STOCK | web=500000 (نه آینده/نه b2b)، b2b=300000، p1 qty=2، بدون موجودی=false';
end $$;

-- --- صفحه‌بندی و سقف‌های ورودی ----------------------------------------------
do $$
declare v_page1 uuid; v_page2 uuid; v_total bigint; v_ok integer := 0;
begin
  select product_id, total_count into v_page1, v_total
    from cat.search_products('کتاب', null, null, 'web', 1, 0);
  select product_id into v_page2
    from cat.search_products('کتاب', null, null, 'web', 1, 1);
  if v_page1 = v_page2 then
    raise exception 'FAIL PAGING: دو صفحه یک محصول دادند (%)', v_page1;
  end if;
  if v_total <> 3 then
    raise exception 'FAIL PAGING: total_count=% انتظار ۳', v_total;
  end if;

  begin
    perform 1 from cat.search_products(null, null, null, 'web', 0, 0);
  exception when sqlstate '22023' then
    if sqlerrm like 'FCO-1081%' then v_ok := v_ok + 1; else raise; end if;
  end;
  begin
    perform 1 from cat.search_products(null, null, null, 'web', 61, 0);
  exception when sqlstate '22023' then
    if sqlerrm like 'FCO-1081%' then v_ok := v_ok + 1; else raise; end if;
  end;
  begin
    perform 1 from cat.search_products(null, null, null, 'web', 10, -1);
  exception when sqlstate '22023' then
    if sqlerrm like 'FCO-1081%' then v_ok := v_ok + 1; else raise; end if;
  end;
  begin
    perform 1 from cat.search_products(repeat('a', 101), null, null, 'web', 10, 0);
  exception when sqlstate '22023' then
    if sqlerrm like 'FCO-1081%' then v_ok := v_ok + 1; else raise; end if;
  end;
  begin
    perform 1 from cat.search_products(null, null, null, '', 10, 0);
  exception when sqlstate '22023' then
    if sqlerrm like 'FCO-1081%' then v_ok := v_ok + 1; else raise; end if;
  end;
  if v_ok <> 5 then
    raise exception 'FAIL GUARDS: % سقف از ۵ سقف رد شد', v_ok;
  end if;
  raise notice 'PASS PAGING/GUARDS | صفحه‌های متمایز، total_count=3، ۵ ورودی نامجاز → FCO-1081';
end $$;

-- --- صفحه محصول: تنوع‌ها، قیمت و موجودی هر تنوع ----------------------------
do $$
declare v jsonb; v_p1 jsonb; v_t1a jsonb; v_t1b jsonb;
begin
  v_p1 := cat.public_product('p1-book');
  if v_p1 is null then
    raise exception 'FAIL DETAIL: محصول منتشرشده NULL داد';
  end if;
  if jsonb_array_length(v_p1 -> 'variants') <> 2 then
    raise exception 'FAIL DETAIL: تعداد تنوع‌ها % است، انتظار ۲',
      jsonb_array_length(v_p1 -> 'variants');
  end if;

  select t into v_t1a from jsonb_array_elements(v_p1 -> 'variants') t
   where t ->> 'sku' = 'T-1A';
  select t into v_t1b from jsonb_array_elements(v_p1 -> 'variants') t
   where t ->> 'sku' = 'T-1B';
  if (v_t1a ->> 'price_rial')::bigint <> 500000 then
    raise exception 'FAIL DETAIL: قیمت T-1A=%', v_t1a ->> 'price_rial';
  end if;
  if (v_t1a ->> 'available_qty')::integer <> 0 then
    raise exception 'FAIL DETAIL: موجودی T-1A=%', v_t1a ->> 'available_qty';
  end if;
  if (v_t1b ->> 'available_qty')::integer <> 2 then
    raise exception 'FAIL DETAIL: موجودی T-1B=%', v_t1b ->> 'available_qty';
  end if;

  v := cat.public_product('p1-book', 'b2b');
  select t into v_t1a from jsonb_array_elements(v -> 'variants') t where t ->> 'sku' = 'T-1A';
  if (v_t1a ->> 'price_rial')::bigint <> 300000 then
    raise exception 'FAIL DETAIL: قیمت b2b تنوع=%', v_t1a ->> 'price_rial';
  end if;
  raise notice 'PASS DETAIL | ۲ تنوع، قیمت مؤثر هر کانال و موجودی قابل‌فروش هر تنوع';
end $$;

-- --- مسیر دسته -------------------------------------------------------------
do $$
declare v_path text; v_n integer;
begin
  select string_agg(slug, '>' order by depth desc), count(*) into v_path, v_n
    from cat.category_path('books');
  if v_path <> 'fashion>books' or v_n <> 2 then
    raise exception 'FAIL PATH: مسیر=% (تعداد=%)', v_path, v_n;
  end if;

  select count(*) into v_n from cat.category_path('no-such-category');
  if v_n <> 0 then
    raise exception 'FAIL PATH: دسته ناموجود % ردیف داد', v_n;
  end if;

  select string_agg(slug, '>' order by depth desc) into v_path
    from cat.category_path('books', false);
  if v_path <> 'fashion' then
    raise exception 'FAIL PATH: مسیر بدون خود=%', v_path;
  end if;
  raise notice 'PASS PATH | fashion>books و دسته ناموجود بدون ردیف';
end $$;

-- --- همان گاردها از نقش اپ -------------------------------------------------
set local role fco_app;

do $$
declare v_count integer; v_draft jsonb;
begin
  select count(*) into v_count from cat.search_products('كتاب');
  if v_count <> 3 then
    raise exception 'FAIL APP-ROLE: جست‌وجو از نقش اپ % ردیف داد، انتظار ۳', v_count;
  end if;

  v_draft := cat.public_product('p2-draft');
  if v_draft is not null then
    raise exception 'FAIL APP-ROLE: پیش‌نویس از نقش اپ دیده شد';
  end if;
  raise notice 'PASS APP-ROLE | نقش اپ اجرا می‌کند و همچنان فقط داده منتشرشده می‌بیند';
end $$;

reset role;

-- --- شاهد زیرساخت: ایندکس GIN و پیکربندی ----------------------------------
do $$
begin
  if to_regclass('cat.products_search_gin') is null then
    raise exception 'FAIL INDEX: ایندکس GIN جست‌وجو ساخته نشده است';
  end if;
  if not exists (select 1 from pg_ts_config c join pg_namespace n on n.oid = c.cfgnamespace
                  where n.nspname = 'cat' and c.cfgname = 'fa') then
    raise exception 'FAIL INDEX: پیکربندی cat.fa وجود ندارد';
  end if;
  raise notice 'PASS INDEX | GIN روی cat.search_vector و پیکربندی cat.fa موجود است';
end $$;

select 'ALL STEP-BR2-4 NEGATIVE CASES PASSED' as result;
rollback;
