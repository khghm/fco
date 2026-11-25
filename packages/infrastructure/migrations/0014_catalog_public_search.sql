-- =============================================================================
-- 0014_catalog_public_search — BR-2 گام ۴: لایه خواندن عمومی محصول/دسته/جست‌وجو
-- مالک طرح: docs/Architecture-02/DATABASE_DESIGN.md §3.2 (جست‌وجوی فارسی GIN)
--           docs/product/CAPABILITY_MAP.md FR-6-01
--           docs/Engineering-04/TEST_STRATEGY.md §4.1 (T-CAT-01..03)
--
-- چرا لایه خواندن پیش از صفحه: صفحه عمومی بدون قاعده آزمون‌شده دقیقاً دو جا
-- می‌شکند که در ظاهر دیده نمی‌شود — نمایش محصول منتشرنشده/آینده، و انتخاب
-- قیمت غیرمؤثر (کانال یا بازه اشتباه). این Migration همان دو قاعده را در
-- دیتابیس می‌بندد تا Route فقط مصرف‌کننده باشد.
--
-- مدل:
--   * `cat.normalize_text` — ی/ي، ک/ك، همزه‌ها، ة/ۀ، ZWNJ و ارقام فارسی/عربی
--     را یکسان می‌کند. IMMUTABLE است تا در ایندکس بیانتی استفاده شود.
--   * `cat.fa` — پیکربندی جست‌وجوی فارسی با دیکشنری `simple` (PostgreSQL 16
--     دیکشنری ریشه‌یاب فارسی ندارد؛ یکسان‌سازی بالا کار آن را انجام می‌دهد).
--   * GIN روی `cat.search_vector(title, description)` — دقیقاً همان چیزی که
--     `0011` تا گام ۴ به تعویق انداخته بود.
--   * `cat.public_product_ids` — تنها منبع فیلتر عمومی (منتشرشده و گذشته)؛
--     جست‌وجو، دسته (با زیرشاخه‌ها) و برند در همین یک جا اعمال می‌شوند.
--   * `cat.search_products` — صفحه‌بندی سرور، قیمت مؤثر کانال، موجودی قابل‌فروش.
--   * `cat.public_product` — جزئیات محصول به‌صورت JSON برای صفحه محصول.
--   * `cat.category_path` — مسیر ریشه→برگ برای صفحه دسته.
--
-- خارج از این Migration: رندر صفحه/Route (اسکلت اپ) و انتشار محصول
-- (BRQ-02/BRQ-04). هیچ محدودیت دسترسی جدیدی ساخته نمی‌شود؛ این توابع فقط
-- می‌خوانند و فقط داده عمومی برمی‌گردانند.
-- =============================================================================

insert into sys.settings (key, value, description) values
  ('cat.search.page_size', '24'::jsonb, 'اندازه صفحه پیش‌فرض فهرست/جست‌وجوی عمومی'),
  ('cat.search.page_size_max', '60'::jsonb, 'سقف اندازه صفحه عمومی'),
  ('cat.search.query_max_length', '100'::jsonb, 'سقف طول عبارت جست‌وجو'),
  ('cat.search.max_offset', '5000'::jsonb, 'سقف offset برای صفحه‌بندی عمومی')
on conflict (key) do nothing;

insert into sys.setting_versions (key, value, effective_from, reason)
select v.key, v.value, v.effective_from, v.reason
from (values
  ('cat.search.page_size', '24'::jsonb,
   '2026-01-01 00:00:00+00'::timestamptz, 'مقدار اولیه BR-2 گام ۴'),
  ('cat.search.page_size_max', '60'::jsonb,
   '2026-01-01 00:00:00+00'::timestamptz, 'مقدار اولیه BR-2 گام ۴'),
  ('cat.search.query_max_length', '100'::jsonb,
   '2026-01-01 00:00:00+00'::timestamptz, 'مقدار اولیه BR-2 گام ۴'),
  ('cat.search.max_offset', '5000'::jsonb,
   '2026-01-01 00:00:00+00'::timestamptz, 'مقدار اولیه BR-2 گام ۴')
) as v(key, value, effective_from, reason)
where not exists (select 1 from sys.setting_versions s where s.key = v.key);

-- -----------------------------------------------------------------------------
-- یکسان‌سازی متن فارسی
-- -----------------------------------------------------------------------------
create function cat.normalize_text(p_text text) returns text
language sql immutable strict parallel safe as $$
  select btrim(regexp_replace(
           translate(
             translate(lower(p_text), u&'\200C', ' '),
             'يىكأإآةۀؤ۰۱۲۳۴۵۶۷۸۹٠١٢٣٤٥٦٧٨٩',
             'ییکاااههو01234567890123456789'),
           '[[:space:]]+', ' ', 'g'))
$$;

comment on function cat.normalize_text(text) is
  'یکسان‌سازی ی/ي، ک/ك، همزه، ة/ۀ، ZWNJ و ارقام برای جست‌وجوی فارسی (IMMUTABLE)';

-- -----------------------------------------------------------------------------
-- پیکربندی و بردار جست‌وجو
-- -----------------------------------------------------------------------------
create text search configuration cat.fa (copy = pg_catalog.simple);

comment on text search configuration cat.fa is
  'جست‌وجوی فارسی روی دیکشنری simple؛ ریشه‌یابی در PostgreSQL 16 وجود ندارد '
  'و cat.normalize_text نقش نرمال‌سازی را دارد';

create function cat.search_vector(p_title text, p_description text) returns tsvector
language sql immutable parallel safe as $$
  select to_tsvector('cat.fa',
    cat.normalize_text(coalesce(p_title, '') || ' ' || coalesce(p_description, '')))
$$;

comment on function cat.search_vector(text, text) is
  'بردار جست‌وجوی محصول؛ همان عبارتی که GIN روی آن ساخته می‌شود';

create index products_search_gin
  on cat.products using gin (cat.search_vector(title, description));
create index products_brand_idx on cat.products (brand_id);

-- -----------------------------------------------------------------------------
-- عبارت کاربر → tsquery (امن: هیچ ورودی‌ای خطای نحو تولید نمی‌کند)
-- -----------------------------------------------------------------------------
create function cat.search_query(p_text text) returns tsquery
language sql immutable parallel safe as $$
  with cleaned as (
    select btrim(regexp_replace(
             regexp_replace(
               cat.normalize_text(p_text),
               '[.,،؛:;!?؟()\[\]{}«»"''/\\+*&|<>%=~^#@$`_-]+', ' ', 'g'),
             '[[:space:]]+', ' ', 'g')) as q
  )
  select to_tsquery('cat.fa',
    (select string_agg(term || ':*', ' & ')
       from unnest(string_to_array(q, ' ')) as term
      where term <> ''))
  from cleaned
$$;

comment on function cat.search_query(text) is
  'عبارت کاربر رشته‌ای امن می‌شود؛ عبارت خالی یا فقط نشانه → NULL (بدون خطا)';

-- -----------------------------------------------------------------------------
-- فیلتر عمومی: تنها جایی که «منتشرشده و گذشته» اعمال می‌شود
-- -----------------------------------------------------------------------------
create function cat.public_product_ids(
  p_query text,
  p_category_slug text,
  p_brand_slug text
) returns table (product_id uuid, rank real, published_at timestamptz)
language sql stable security definer
set search_path = cat, public, pg_catalog as $$
  with recursive q as (
    select nullif(btrim(coalesce(p_query, '')), '') as raw,
           cat.search_query(p_query) as ts
  ), tree as (
    select c.id from cat.categories c
     where p_category_slug is not null and c.slug = p_category_slug
    union all
    select ch.id from cat.categories ch join tree t on ch.parent_id = t.id
  )
  select p.id,
         case when q.ts is null then 0::real
              else ts_rank(cat.search_vector(p.title, p.description), q.ts) end,
         p.published_at
    from cat.products p
    left join cat.brands b on b.id = p.brand_id
    left join cat.categories c on c.id = p.category_id
    cross join q
   where p.status = 'published'
     and p.published_at is not null
     and p.published_at <= now()
     and (p_brand_slug is null or b.slug = p_brand_slug)
     and (p_category_slug is null or p.category_id in (select id from tree))
     and (q.raw is null
          or (q.ts is not null
              and cat.search_vector(p.title, p.description) @@ q.ts))
$$;

comment on function cat.public_product_ids(text, text, text) is
  'فیلتر عمومی محصول: فقط published و published_at ≤ now؛ دسته شامل زیرشاخه‌ها';

-- -----------------------------------------------------------------------------
-- فهرست/جست‌وجوی صفحه‌بندی‌شده با قیمت مؤثر و موجودی قابل‌فروش
-- -----------------------------------------------------------------------------
create function cat.search_products(
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
  v_qmax   integer := coalesce(sys.setting_int('cat.search.query_max_length'), 100);
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
  if p_query is not null and length(p_query) > v_qmax then
    raise exception 'FCO-1081: طول عبارت جست‌وجو حداکثر % است', v_qmax
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
     order by pr.variant_id, pr.effective_from desc
  ), product_price as (
    select v.product_id,
           min(pe.amount_rial) as amount,
           min(pe.compare_at_rial) as compare
      from prices pe
      join cat.variants v on v.id = pe.variant_id
     group by v.product_id
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
         pp.amount, pp.compare,
         coalesce(st.qty, 0), coalesce(st.qty, 0) > 0,
         md.storage_key, md.alt_text,
         pg.published_at, tt.c
    from page pg
    join cat.products p on p.id = pg.product_id
    left join cat.brands b on b.id = p.brand_id
    left join cat.categories c on c.id = p.category_id
    left join product_price pp on pp.product_id = pg.product_id
    left join stock st on st.product_id = pg.product_id
    left join media md on md.product_id = pg.product_id
    cross join total tt
   order by pg.rank desc, pg.published_at desc, pg.product_id;
end $$;

comment on function cat.search_products(text, text, text, text, integer, integer) is
  'صفحه عمومی محصول/دسته/جست‌وجو: فقط منتشرشده، قیمت مؤثر کانال، موجودی قابل‌فروش';

-- -----------------------------------------------------------------------------
-- جزئیات محصول (JSON آماده صفحه)
-- -----------------------------------------------------------------------------
create function cat.public_product(
  p_slug text,
  p_channel text default 'web'
) returns jsonb
language sql stable security definer
set search_path = cat, pricing, inv, public, pg_catalog as $$
  select jsonb_build_object(
    'id', p.id,
    'slug', p.slug,
    'title', p.title,
    'description', p.description,
    'attributes', p.attributes,
    'published_at', p.published_at,
    'brand', case when b.id is null then null
                  else jsonb_build_object('slug', b.slug, 'title', b.title) end,
    'category', case when c.id is null then null
                     else jsonb_build_object('slug', c.slug, 'title', c.title) end,
    'media', coalesce((
      select jsonb_agg(jsonb_build_object('key', m.storage_key, 'alt', m.alt_text)
                       order by m.sort_order, m.created_at)
        from cat.product_media m where m.product_id = p.id), '[]'::jsonb),
    'variants', coalesce((
      select jsonb_agg(jsonb_build_object(
               'sku', v.sku,
               'barcode', v.barcode,
               'price_rial', ep.amount_rial,
               'compare_at_rial', ep.compare_at_rial,
               'available_qty', coalesce((
                 select sum(sb.on_hand - sb.reserved - sb.quarantined)
                   from inv.stock_balance sb where sb.variant_id = v.id), 0)
             ) order by v.sku)
        from cat.variants v
        left join lateral (
          select pr.amount_rial, pr.compare_at_rial
            from pricing.prices pr
           where pr.variant_id = v.id
             and pr.channel = p_channel
             and pr.effective_from <= now()
             and (pr.effective_to is null or pr.effective_to > now())
           order by pr.effective_from desc
           limit 1
        ) ep on true
       where v.product_id = p.id and v.is_active and v.archived_at is null), '[]'::jsonb)
  )
  from cat.products p
  left join cat.brands b on b.id = p.brand_id
  left join cat.categories c on c.id = p.category_id
  where p.slug = p_slug
    and p.status = 'published'
    and p.published_at is not null
    and p.published_at <= now()
$$;

comment on function cat.public_product(text, text) is
  'صفحه محصول؛ برای slug ناموجود/پیش‌نویس/آینده/آرشیو NULL برمی‌گرداند';

-- -----------------------------------------------------------------------------
-- مسیر دسته (ریشه → برگ)
-- -----------------------------------------------------------------------------
create function cat.category_path(
  p_slug text,
  p_with_self boolean default true
) returns table (slug text, title text, depth integer)
language sql stable security definer
set search_path = cat, public, pg_catalog as $$
  with recursive up as (
    select c.id, c.slug, c.title, c.parent_id, 0 as depth
      from cat.categories c
     where c.slug = p_slug
    union all
    select p.id, p.slug, p.title, p.parent_id, u.depth + 1
      from cat.categories p
      join up u on u.parent_id = p.id
  )
  select up.slug, up.title, up.depth
    from up
   where p_with_self or up.depth > 0
   order by up.depth desc
$$;

comment on function cat.category_path(text, boolean) is
  'مسیر دسته برای breadcrumb؛ دسته ناموجود → صفر ردیف';

-- -----------------------------------------------------------------------------
-- دسترسی: فقط خواندن عمومی، فقط از مسیر اپ
-- -----------------------------------------------------------------------------
grant execute on function
  cat.normalize_text(text),
  cat.search_vector(text, text),
  cat.search_query(text),
  cat.public_product_ids(text, text, text),
  cat.search_products(text, text, text, text, integer, integer),
  cat.public_product(text, text),
  cat.category_path(text, boolean)
to fco_app;
