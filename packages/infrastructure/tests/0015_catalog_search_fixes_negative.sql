-- =============================================================================
-- 0015_catalog_search_fixes_negative — بازبینی گام ۴
-- مالک انتظارها: docs/Engineering-04/TEST_STRATEGY.md §4.1.1 (T-CAT-04)
--
-- پوشش: قیمت/موجودی فقط از تنوع فعال، compare از همان قیمت کمینه، حذف پیکربندی
--       تغییرپذیر `cat.fa` با سالم‌ماندن جست‌وجو و ایندکس، سقف طول عبارت در
--       `search_query`، و دسترسی واقعی (PUBLIC برداشته شده، فقط نقش اپ مجاز،
--       کمک‌تابع بدون LIMIT غیرقابل‌فراخوانی از اپ).
-- همه‌چیز در یک تراکنش است و با rollback پاک می‌شود.
-- =============================================================================
\set ON_ERROR_STOP on
\pset pager off

begin;

insert into cat.brands (id, slug, title) values
  ('b5000000-0000-0000-0000-000000000001', 'rev-brand', 'برند بازبینی');
insert into cat.categories (id, slug, title) values
  ('c5000000-0000-0000-0000-000000000001', 'rev-cat', 'دسته بازبینی');
insert into cat.products (id, slug, title, brand_id, category_id, status, published_at) values
  ('a5000000-0000-0000-0000-000000000001', 'p-15', 'کتاب بازبینی', 
   'b5000000-0000-0000-0000-000000000001', 'c5000000-0000-0000-0000-000000000001',
   'published', now() - interval '1 hour');

insert into cat.variants (id, product_id, sku, archived_at) values
  ('e5000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000001', 'R-A', null),
  ('e5000000-0000-0000-0000-000000000002', 'a5000000-0000-0000-0000-000000000001', 'R-B', now()),
  ('e5000000-0000-0000-0000-000000000003', 'a5000000-0000-0000-0000-000000000001', 'R-C', null);

-- R-B آرشیوشده و ارزان‌ترین است؛ نباید قیمت کارت را تعیین کند.
-- R-A گران‌تر ولی با compare؛ R-C ارزان‌ترین فعال و بدون compare.
insert into pricing.prices (variant_id, channel, amount_rial, compare_at_rial, effective_from) values
  ('e5000000-0000-0000-0000-000000000001', 'web', 500000, 600000, now() - interval '1 day'),
  ('e5000000-0000-0000-0000-000000000002', 'web', 100000, 900000, now() - interval '1 day'),
  ('e5000000-0000-0000-0000-000000000003', 'web', 400000, null,   now() - interval '1 day');

insert into inv.warehouses (id, code, title) values
  ('95000000-0000-0000-0000-000000000001', 'REV-WH', 'انبار بازبینی');
insert into inv.stock_balance (warehouse_id, variant_id, on_hand, reserved) values
  ('95000000-0000-0000-0000-000000000001', 'e5000000-0000-0000-0000-000000000001', 5, 0),
  ('95000000-0000-0000-0000-000000000001', 'e5000000-0000-0000-0000-000000000002', 9, 0),
  ('95000000-0000-0000-0000-000000000001', 'e5000000-0000-0000-0000-000000000003', 1, 0);

-- --- T-CAT-04: تنوع آرشیوشده نه قیمت می‌دهد نه موجودی -----------------------
do $$
declare v_price bigint; v_compare bigint; v_qty integer; v jsonb;
begin
  select price_rial, compare_at_rial, available_qty
    into v_price, v_compare, v_qty
    from cat.search_products(null, null, null, 'web', 10, 0)
   where slug = 'p-15';

  if v_price <> 400000 then
    raise exception 'FAIL ARCHIVED: قیمت فهرست=% (انتظار ۴۰۰۰۰۰؛ ۱۰۰۰۰۰ تنوع آرشیوشده ممنوع)', v_price;
  end if;
  if v_compare is not null then
    raise exception 'FAIL COMPARE: compare_at=% (انتظار NULL از همان قیمت کمینه)', v_compare;
  end if;
  if v_qty <> 6 then
    raise exception 'FAIL ARCHIVED: موجودی=% (انتظار ۶؛ ۹ واحد تنوع آرشیوشده نباید بیاید)', v_qty;
  end if;

  v := cat.public_product('p-15');
  if jsonb_array_length(v -> 'variants') <> 2 then
    raise exception 'FAIL ARCHIVED: صفحه % تنوع نشان داد، انتظار ۲', jsonb_array_length(v -> 'variants');
  end if;
  if exists (select 1 from jsonb_array_elements(v -> 'variants') t where t ->> 'sku' = 'R-B') then
    raise exception 'FAIL ARCHIVED: تنوع آرشیوشده در صفحه محصول آمد';
  end if;
  raise notice 'PASS ARCHIVED | قیمت ۴۰۰۰۰۰، compare=NULL، موجودی ۶ و صفحه بدون تنوع آرشیوشده';
end $$;

-- --- پیکربندی حذف شد ولی جست‌وجو و ایندکس سالم است -------------------------
do $$
declare v_hits integer; v_def text;
begin
  if exists (select 1 from pg_ts_config c join pg_namespace n on n.oid = c.cfgnamespace
              where n.nspname = 'cat' and c.cfgname = 'fa') then
    raise exception 'FAIL CONFIG: پیکربندی تغییرپذیر cat.fa هنوز وجود دارد';
  end if;

  select count(*) into v_hits from cat.search_products('كتاب');
  if v_hits <> 1 then
    raise exception 'FAIL SEARCH: پس از حذف cat.fa جست‌وجو % نتیجه داد', v_hits;
  end if;

  if to_regclass('cat.products_search_gin') is null then
    raise exception 'FAIL INDEX: ایندکس GIN پس از بازسازی وجود ندارد';
  end if;
  v_def := pg_get_indexdef('cat.products_search_gin'::regclass);
  if v_def not like '%search_vector%' or v_def not like '%gin%' then
    raise exception 'FAIL INDEX: تعریف ایندکس نامنتظر: %', v_def;
  end if;
  raise notice 'PASS CONFIG/INDEX | بدون cat.fa جست‌وجو کار می‌کند و GIN روی search_vector است';
end $$;

-- --- سقف طول در search_query (همه مسیرها) ----------------------------------
do $$
declare v_ok integer := 0;
begin
  begin
    perform cat.search_query(repeat('a', 101));
  exception when sqlstate '22023' then
    if sqlerrm like 'FCO-1081%' then v_ok := v_ok + 1; else raise; end if;
  end;
  begin
    perform 1 from cat.search_products(repeat('a', 101), null, null, 'web', 10, 0);
  exception when sqlstate '22023' then
    if sqlerrm like 'FCO-1081%' then v_ok := v_ok + 1; else raise; end if;
  end;
  if v_ok <> 2 then
    raise exception 'FAIL GUARD: سقف طول در % مسیر از ۲ مسیر اعمال شد', v_ok;
  end if;
  raise notice 'PASS GUARD | عبارت ۱۰۱ کاراکتری در search_query و search_products → FCO-1081';
end $$;

-- --- دسترسی واقعی: PUBLIC ندارد، اپ فقط مسیرهای مجاز ----------------------
do $$
declare v_public integer; v_allowed boolean; v_blocked boolean;
begin
  select count(*) into v_public
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a
   where n.nspname = 'cat'
     and p.proname in ('normalize_text', 'search_vector', 'search_query',
                       'public_product_ids', 'search_products', 'public_product',
                       'category_path')
     and a.grantee = 0 and a.privilege_type = 'EXECUTE';
  if v_public <> 0 then
    raise exception 'FAIL ACL: % تابع همچنان برای PUBLIC قابل اجراست', v_public;
  end if;

  v_allowed := has_function_privilege('fco_app',
    'cat.search_products(text,text,text,text,integer,integer)', 'execute');
  v_blocked := has_function_privilege('fco_app',
    'cat.public_product_ids(text,text,text)', 'execute');
  if v_allowed is not true or v_blocked is not false then
    raise exception 'FAIL ACL: search_products=% و public_product_ids=% برای اپ',
      v_allowed, v_blocked;
  end if;
  raise notice 'PASS ACL | PUBLIC صفر مجوز؛ اپ search_products دارد و کمک‌تابع بدون LIMIT ندارد';
end $$;

set local role fco_app;

do $$
declare v_count integer; v_blocked integer := 0;
begin
  select count(*) into v_count from cat.search_products('كتاب');
  if v_count <> 1 then
    raise exception 'FAIL APP-ROLE: جست‌وجو از نقش اپ % ردیف داد', v_count;
  end if;

  begin
    perform 1 from cat.public_product_ids(null, null, null);
  exception when insufficient_privilege then
    v_blocked := 1;
  end;
  if v_blocked <> 1 then
    raise exception 'FAIL APP-ROLE: نقش اپ کمک‌تابع بدون LIMIT را اجرا کرد';
  end if;
  raise notice 'PASS APP-ROLE | جست‌وجو مجاز است، کمک‌تابع داخلی ممنوع';
end $$;

reset role;

select 'ALL STEP-BR2-4B NEGATIVE CASES PASSED' as result;
rollback;
