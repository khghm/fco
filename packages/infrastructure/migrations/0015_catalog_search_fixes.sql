-- =============================================================================
-- 0015_catalog_search_fixes — بازبینی گام ۴ (0014 ویرایش نمی‌شود)
-- مالک طرح: docs/Architecture-02/DATABASE_DESIGN.md §3.2/§4
--           docs/Engineering-04/TEST_STRATEGY.md §4.1.1 (T-CAT-04)
--
-- شکاف‌های واقعی که این Migration می‌بندد:
--   ۱) قیمت/موجودی تنوع آرشیوشده: فهرست، قیمت را از همه تنوع‌ها می‌گرفت؛
--      یک تنوع آرشیوشده با قیمت پایین می‌توانست قیمت کارت محصول را تعیین کند.
--      (موجودی از قبل فیلتر می‌شد، قیمت نه.)
--   ۲) `compare_at_rial` با `min()` مستقل از تنوع دیگر انتخاب می‌شد و می‌توانست
--      «قیمت قبل» تنوعی دیگر باشد. حالا از همان قیمتِ کمینه می‌آید.
--   ۳) پیکربندی `cat.fa` حذف می‌شود: نسخه‌ای از `simple` بود که هیچ رفتاری
--      اضافه نمی‌کرد، ولی تغییرپذیر است؛ `ALTER` آن ایندکس GIN را بی‌سروصدا
--      کهنه می‌کرد. جست‌وجو با `simple` + `cat.normalize_text` انجام می‌شود.
--   ۴) سقف طول عبارت به `cat.search_query` منتقل شد تا هر مسیر (نه فقط
--      `search_products`) محافظت شود؛ `public_product_ids` هیچ grant‌ای ندارد
--      چون بدون LIMIT بود و فقط کمک‌تابع داخلی است.
--   ۵) `grant ... to fco_app` در 0014 محدودیتی نمی‌ساخت: PostgreSQL به‌طور
--      پیش‌فرض EXECUTE را به PUBLIC می‌دهد. این Migration PUBLIC را برمی‌دارد
--      و فقط نقش اپ را مجاز می‌کند.
--
-- ایندکس GIN پس از تغییر بدنه `cat.search_vector` بازسازی می‌شود؛ ایندکس بیانتی
-- با تغییر تابع، خودکار کهنه می‌شود (REINDEX صریح).
-- =============================================================================

-- -----------------------------------------------------------------------------
-- گام ۱: بردار جست‌وجو با simple (بدون پیکربندی تغییرپذیر)
-- -----------------------------------------------------------------------------
drop index if exists cat.products_search_gin;

create or replace function cat.search_vector(p_title text, p_description text) returns tsvector
language sql immutable parallel safe as $$
  select to_tsvector('simple',
    cat.normalize_text(coalesce(p_title, '') || ' ' || coalesce(p_description, '')))
$$;

comment on function cat.search_vector(text, text) is
  'بردار جست‌وجوی محصول با دیکشنری simple + cat.normalize_text؛ پیکربندی قابل‌تغییر ندارد';

create index products_search_gin
  on cat.products using gin (cat.search_vector(title, description));

drop text search configuration if exists cat.fa;

-- -----------------------------------------------------------------------------
-- گام ۲: عبارت → tsquery با سقف طول در همین‌جا
-- -----------------------------------------------------------------------------
create or replace function cat.search_query(p_text text) returns tsquery
language plpgsql stable parallel safe
set search_path = cat, sys, pg_catalog as $$
declare
  v_max integer := coalesce(sys.setting_int('cat.search.query_max_length'), 100);
  v_q   text;
begin
  if p_text is null then
    return null;
  end if;
  if length(p_text) > v_max then
    raise exception 'FCO-1081: طول عبارت جست‌وجو حداکثر % است', v_max
      using errcode = '22023';
  end if;

  v_q := btrim(regexp_replace(
           regexp_replace(cat.normalize_text(p_text),
             '[.,،؛:;!?؟()\[\]{}«»"''/\\+*&|<>%=~^#@$`_-]+', ' ', 'g'),
           '[[:space:]]+', ' ', 'g'));

  return to_tsquery('simple',
    (select string_agg(term || ':*', ' & ')
       from unnest(string_to_array(v_q, ' ')) as term
      where term <> ''));
end $$;

comment on function cat.search_query(text) is
  'عبارت کاربر با سقف طول به tsquery امن تبدیل می‌شود؛ عبارت خالی/نشانه‌ای → NULL';

-- -----------------------------------------------------------------------------
-- گام ۳: قیمت فقط از تنوع فعال، compare از همان قیمت کمینه
-- -----------------------------------------------------------------------------
create or replace function cat.search_products(
  p_query text default null,
  p_category_slug text default null,
  p_brand_slug text default null,
  p_channel text default 'web',
  p_limit integer default null,
  p_offset integer default 0
) returns table (
  product_id     uuid,
  slug           text,
  title          text,
  brand_slug     text,
  brand_title    text,
  category_slug  text,
  category_title text,
  price_rial     bigint,
  compare_at_rial bigint,
  available_qty  integer,
  in_stock       boolean,
  media_key      text,
  media_alt      text,
  published_at   timestamptz,
  total_count    bigint
)
language plpgsql stable security definer
set search_path = cat, pricing, inv, sys, public, pg_catalog as $$
declare
  v_limit  integer := coalesce(p_limit, sys.setting_int('cat.search.page_size'));
  v_max    integer := coalesce(sys.setting_int('cat.search.page_size_max'), 60);
  v_offset integer := coalesce(p_offset, 0);
  v_omax   integer := coalesce(sys.setting_int('cat.search.max_offset'), 5000);
begin
  if v_limit is null or v_limit < 1 or v_limit > v_max then
    raise exception 'FCO-1081: اندازه صفحه باید بین ۱ و % باشد (%)', v_max, coalesce(v_limit, -1)
      using errcode = '22023';
  end if;
  if v_offset < 0 or v_offset > v_omax then
    raise exception 'FCO-1081: offset باید بین ۰ و % باشد (%)', v_omax, v_offset
      using errcode = '22023';
  end if;
  if p_channel is null or btrim(p_channel) = '' then
    raise exception 'FCO-1081: کانال الزامی است' using errcode = '22023';
  end if;

  return query
  with ids as (
    select * from cat.public_product_ids(p_query, p_category_slug, p_brand_slug)
  ), page as (
    select i.* from ids i
     order by i.rank desc, i.published_at desc, i.product_id
     limit v_limit offset v_offset
  ), total as (
    select count(*) as c from ids
  ), prices as (
    select distinct on (pr.variant_id) pr.variant_id,
           pr.amount_rial, pr.compare_at_rial
      from pricing.prices pr
      join cat.variants v on v.id = pr.variant_id
      join page pg on pg.product_id = v.product_id
     where pr.channel = p_channel
       and pr.effective_from <= now()
       and (pr.effective_to is null or pr.effective_to > now())
       and v.is_active
       and v.archived_at is null
     order by pr.variant_id, pr.effective_from desc
  ), cheapest as (
    select distinct on (v.product_id) v.product_id,
           pr.amount_rial, pr.compare_at_rial
      from prices pr
      join cat.variants v on v.id = pr.variant_id
     order by v.product_id, pr.amount_rial, v.sku
  ), stock as (
    select v.product_id,
           sum(b.on_hand - b.reserved - b.quarantined)::integer as qty
      from cat.variants v
      join inv.stock_balance b on b.variant_id = v.id
     where v.is_active and v.archived_at is null
     group by v.product_id
  ), media as (
    select distinct on (m.product_id) m.product_id, m.storage_key, m.alt_text
      from cat.product_media m
      join page pg on pg.product_id = m.product_id
     order by m.product_id, m.sort_order, m.created_at
  )
  select pg.product_id, p.slug, p.title,
         b.slug, b.title, c.slug, c.title,
         ch.amount_rial, ch.compare_at_rial,
         coalesce(st.qty, 0), coalesce(st.qty, 0) > 0,
         md.storage_key, md.alt_text,
         pg.published_at, tt.c
    from page pg
    join cat.products p on p.id = pg.product_id
    left join cat.brands b on b.id = p.brand_id
    left join cat.categories c on c.id = p.category_id
    left join cheapest ch on ch.product_id = pg.product_id
    left join stock st on st.product_id = pg.product_id
    left join media md on md.product_id = pg.product_id
    cross join total tt
   order by pg.rank desc, pg.published_at desc, pg.product_id;
end $$;

comment on function cat.search_products(text, text, text, text, integer, integer) is
  'صفحه عمومی: قیمت/موجودی فقط از تنوع فعال؛ compare از همان قیمت کمینه';

-- -----------------------------------------------------------------------------
-- گام ۴: دسترسی واقعی (PUBLIC به‌طور پیش‌فرض EXECUTE دارد)
-- -----------------------------------------------------------------------------
-- `grant ... to fco_app` در 0014 چیزی را محدود نمی‌کرد: PostgreSQL به‌طور پیش‌فرض
-- EXECUTE را به PUBLIC می‌دهد و نقش اپ هم از همان مسیر مجاز بود. ابتدا PUBLIC
-- برداشته می‌شود و سپس فقط نقش اپ اجازه می‌گیرد. `public_product_ids` که بدون
-- LIMIT است، هیچ grant‌ای نمی‌گیرد و فقط کمک‌تابع داخلی می‌ماند.
revoke all on function
  cat.normalize_text(text),
  cat.search_vector(text, text),
  cat.search_query(text),
  cat.public_product_ids(text, text, text),
  cat.search_products(text, text, text, text, integer, integer),
  cat.public_product(text, text),
  cat.category_path(text, boolean)
from public;

revoke execute on function cat.public_product_ids(text, text, text) from fco_app;

grant execute on function
  cat.normalize_text(text),
  cat.search_vector(text, text),
  cat.search_query(text),
  cat.search_products(text, text, text, text, integer, integer),
  cat.public_product(text, text),
  cat.category_path(text, boolean)
to fco_app;

comment on function cat.public_product_ids(text, text, text) is
  'کمک‌تابع داخلی فیلتر عمومی (بدون LIMIT)؛ فقط از search_products صدا زده می‌شود';
