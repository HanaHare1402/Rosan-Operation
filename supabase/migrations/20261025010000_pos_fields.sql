-- Khớp đúng các trường của đơn Pancake POS (theo đơn mẫu thật):
--   marketer {id, name, fb_id}  · pke_mkter = mã marketer
--   p_utm_medium "LONGLT - BÚT ĐÁNH DẤU - V1 - 14/10 - ..." → mã nhân sự ở đầu tên camp
--   ads_source "Facebook" (order_sources_name thường trống)
--   items[].variation_info {name, product_display_id (mã SP), retail_price, last_imported_price}
--   total_price_after_sub_discount = tiền sau giảm giá; warehouse_info.name = kho
-- Đồng thời cắt bớt dữ liệu thô (bỏ thông tin khách, lịch sử, ảnh...) để database không phình.
-- Chạy sau 20261025000000_org_structure.sql. Chạy xong: select public.admin_recompute_orders();

alter table public.orders
  add column if not exists marketer_id text,
  add column if not exists utm_code text,
  add column if not exists utm_campaign text,
  add column if not exists ad_id text,
  add column if not exists discount numeric;
create index if not exists orders_marketer_id on public.orders (marketer_id);

-- Chỉ giữ các trường cần cho báo cáo. Tên/SĐT khách nằm ở cột riêng, không giữ trong raw.
create or replace function public.pos_slim(r jsonb) returns jsonb
language sql immutable as $$
  select (
    select coalesce(jsonb_object_agg(k, v), '{}'::jsonb) from jsonb_each(r) e(k, v)
    where k = any (array['id','system_id','shop_id','status','status_name','sub_status','inserted_at','updated_at',
      'order_sources','order_sources_name','ads_source','account','account_name','page_id','post_id','ad_id',
      'p_utm_source','p_utm_medium','p_utm_campaign','p_utm_content','p_utm_term','p_utm_id','pke_mkter',
      'assigning_seller_id','assigning_care_id','warehouse_id','cod','money_to_collect','total_price',
      'total_price_after_sub_discount','shipping_fee','total_discount','partner_fee','return_fee','surcharge',
      'order_currency','total_quantity','items_length','tags','marketplace_id','fee_marketplace',
      'returned_reason','returned_reason_name','is_abandoned_order','is_exchange_order','prepaid','transfer_money'])
  )
  || jsonb_strip_nulls(jsonb_build_object(
    'marketer', case when jsonb_typeof(r->'marketer') = 'object' then jsonb_build_object('id', r->'marketer'->'id', 'name', r->'marketer'->'name', 'fb_id', r->'marketer'->'fb_id') end,
    'assigning_seller', case when jsonb_typeof(r->'assigning_seller') = 'object' then jsonb_build_object('id', r->'assigning_seller'->'id', 'name', r->'assigning_seller'->'name') end,
    'assigning_care', case when jsonb_typeof(r->'assigning_care') = 'object' then jsonb_build_object('id', r->'assigning_care'->'id', 'name', r->'assigning_care'->'name') end,
    'warehouse_info', case when jsonb_typeof(r->'warehouse_info') = 'object' then jsonb_build_object('name', r->'warehouse_info'->'name') end,
    'partner', case when jsonb_typeof(r->'partner') = 'object' then jsonb_build_object(
        'partner_id', r->'partner'->'partner_id', 'partner_name', r->'partner'->'partner_name',
        'extend_code', r->'partner'->'extend_code', 'total_fee', r->'partner'->'total_fee') end,
    'shipping_address', case when jsonb_typeof(r->'shipping_address') = 'object' then jsonb_build_object(
        'province_name', r->'shipping_address'->'province_name', 'province_id', r->'shipping_address'->'province_id',
        'district_name', r->'shipping_address'->'district_name') end,
    'items', case when jsonb_typeof(r->'items') = 'array' then (
        select coalesce(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
          'product_id', i->'product_id', 'variation_id', i->'variation_id', 'quantity', i->'quantity',
          'return_quantity', i->'return_quantity', 'is_bonus_product', i->'is_bonus_product',
          'discount_each_product', i->'discount_each_product', 'total_discount', i->'total_discount',
          'product_name', i->'product_name', 'retail_price', i->'retail_price',
          'variation_info', case when jsonb_typeof(i->'variation_info') = 'object' then jsonb_build_object(
            'name', i->'variation_info'->'name', 'display_id', i->'variation_info'->'display_id',
            'product_display_id', i->'variation_info'->'product_display_id',
            'retail_price', i->'variation_info'->'retail_price', 'last_imported_price', i->'variation_info'->'last_imported_price') end
        ))), '[]'::jsonb) from jsonb_array_elements(r->'items') i) end
  ))
$$;

create or replace function public.order_derive() returns trigger
language plpgsql security definer set search_path = public as $$
declare r jsonb; st record; keys text[];
begin
  r := public.pos_slim(new.raw);
  new.raw := r;

  -- Cột số liệu, lấy lại từ raw để đơn cũ cũng đúng khi tính lại.
  new.status := coalesce((r->>'status')::int, new.status);
  new.status_name := coalesce(r->>'status_name', new.status_name);
  new.total_price := coalesce((r->>'total_price_after_sub_discount')::numeric, (r->>'total_price')::numeric, new.total_price);
  new.discount := (r->>'total_discount')::numeric;
  new.cod := coalesce((r->>'cod')::numeric, (r->>'money_to_collect')::numeric, new.cod);
  new.shipping_fee := coalesce((r->>'shipping_fee')::numeric, new.shipping_fee);
  new.warehouse := coalesce(r->'warehouse_info'->>'name', r->>'warehouse_id', new.warehouse);
  new.province := coalesce(r->'shipping_address'->>'province_name', new.province);
  new.tracking := coalesce(nullif(r->'partner'->>'extend_code', ''), new.tracking);
  if jsonb_typeof(r->'items') = 'array' then
    new.items := (select coalesce(jsonb_agg(jsonb_build_object(
        'code', coalesce(nullif(i->'variation_info'->>'product_display_id', ''), nullif(i->'variation_info'->>'display_id', ''), i->>'product_id'),
        'name', coalesce(i->'variation_info'->>'name', i->>'product_name'),
        'quantity', coalesce((i->>'quantity')::numeric, 1),
        'price', coalesce((i->'variation_info'->>'retail_price')::numeric, (i->>'retail_price')::numeric, 0),
        'cost', (i->'variation_info'->>'last_imported_price')::numeric,
        'bonus', coalesce((i->>'is_bonus_product')::boolean, false))), '[]'::jsonb)
      from jsonb_array_elements(r->'items') i);
  end if;

  -- Ai, kênh nào.
  new.marketer_id := nullif(coalesce(r->'marketer'->>'id', r->>'pke_mkter', ''), '');
  new.marketer_name := nullif(btrim(coalesce(r->'marketer'->>'name', '')), '');
  new.seller_name := nullif(btrim(coalesce(r->'assigning_seller'->>'name', r->'assigning_care'->>'name', '')), '');
  new.utm_code := case when position(' - ' in coalesce(r->>'p_utm_medium', '')) > 0
                       then nullif(btrim(split_part(r->>'p_utm_medium', ' - ', 1)), '') end;
  new.utm_campaign := nullif(r->>'p_utm_campaign', '');
  new.ad_id := nullif(coalesce(r->>'ad_id', r->>'p_utm_content', ''), '');
  new.page_id := nullif(coalesce(r->>'page_id', ''), '');
  new.page_name := nullif(coalesce(r->>'account_name', ''), '');
  new.source_name := coalesce(nullif(btrim(r->>'order_sources_name'), ''), nullif(btrim(r->>'ads_source'), ''),
                              nullif(btrim(r->>'p_utm_source'), ''));

  -- Nhân sự: mã marketer / tên marketer → mã trong tên camp → người được gán → page.
  select s.id, s.team_id, coalesce(t.project_id, s.project_id) as project_id,
         case when lower(new.marketer_id) = any(k.keys) or lower(new.marketer_name) = any(k.keys) then 1
              when lower(new.utm_code) = any(k.keys) then 2
              when lower(new.seller_name) = any(k.keys) then 3 else 4 end as pri
    into st
  from public.staff s
  left join public.teams t on t.id = s.team_id
  cross join lateral (select array(select lower(btrim(x)) from unnest(s.pos_names || s.name) x where btrim(x) <> '') as keys) k
  where s.active and (
       lower(new.marketer_id) = any(k.keys) or lower(new.marketer_name) = any(k.keys)
    or lower(new.utm_code) = any(k.keys)
    or lower(new.seller_name) = any(k.keys)
    or new.page_id = any(s.pages) or new.page_name = any(s.pages))
  order by pri
  limit 1;
  new.staff_id := st.id; new.team_id := st.team_id; new.project_id := st.project_id;

  select c.id into new.channel_id from public.channels c
  where new.source_name is not null and exists (select 1 from unnest(c.keywords) kw where kw <> '' and lower(new.source_name) like '%' || lower(kw) || '%')
  order by c.sort, c.name limit 1;

  select s.market_id into new.market_id from public.pos_shops s where s.id = new.shop_id;
  return new;
end $$;

-- Sửa nhân sự: tính lại đơn khớp bất kỳ khoá nào của bản cũ hoặc mới.
create or replace function public.recompute_orders_staff() returns trigger
language plpgsql security definer set search_path = public as $$
declare names text[]; pg text[];
begin
  names := array(select lower(btrim(x)) from unnest(
    coalesce((case when tg_op <> 'INSERT' then old.pos_names || old.name end), '{}') ||
    coalesce((case when tg_op <> 'DELETE' then new.pos_names || new.name end), '{}')) x);
  pg := coalesce((case when tg_op <> 'INSERT' then old.pages end), '{}') || coalesce((case when tg_op <> 'DELETE' then new.pages end), '{}');
  update public.orders o set synced_at = o.synced_at
  where lower(o.marketer_id) = any(names) or lower(o.marketer_name) = any(names) or lower(o.utm_code) = any(names)
     or lower(o.seller_name) = any(names) or o.page_id = any(pg) or o.page_name = any(pg)
     or o.staff_id = (case when tg_op <> 'INSERT' then old.id end);
  return null;
end $$;

-- Danh sách chưa khai báo: marketer theo mã (kèm tên), mã trong tên camp, nguồn đơn.
drop function if exists public.admin_unmapped();
create or replace function public.admin_unmapped() returns table (kind text, key text, value text, orders bigint, last_at timestamptz)
language sql stable security definer set search_path = public as $$
  select * from (
    select 'marketer'::text, marketer_id, max(marketer_name), count(*), max(inserted_at) from public.orders
     where staff_id is null and marketer_id is not null group by marketer_id
    union all
    select 'utm', utm_code, utm_code, count(*), max(inserted_at) from public.orders
     where staff_id is null and marketer_id is null and utm_code is not null group by utm_code
    union all
    select 'no_name', coalesce(page_name, page_id, '(trống)'), coalesce(page_name, page_id, '(trống)'), count(*), max(inserted_at) from public.orders
     where staff_id is null and marketer_id is null and utm_code is null and seller_name is null group by 2
    union all
    select 'source', source_name, source_name, count(*), max(inserted_at) from public.orders
     where channel_id is null and source_name is not null group by source_name
    union all
    select 'no_source', '', '(không có nguồn)', count(*), max(inserted_at) from public.orders
     where source_name is null having count(*) > 0
  ) u
  where public.has_role('admin','quan_ly')
  order by 1, 4 desc
$$;
revoke all on function public.admin_unmapped() from public, anon;
grant execute on function public.admin_unmapped() to authenticated;

-- Doanh số sản phẩm: chia tiền sau giảm giá của đơn theo giá trị từng dòng sản phẩm.
create or replace function public.dash_products(p_from timestamptz, p_to timestamptz, p_project text default null, p_market text default null, p_channel text default null)
returns table (code text, name text, team_id text, staff_id text, st_group text, orders bigint, qty numeric, revenue_vnd numeric)
language sql stable security invoker set search_path = public as $$
  with o as (
    select o.*, coalesce(m.rate_vnd, 1) as rate,
           (select sum(coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1)) from jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i) as gross
    from public.orders o left join public.markets m on m.id = o.market_id
    where o.inserted_at >= p_from and o.inserted_at < p_to
      and (p_project is null or o.project_id = p_project)
      and (p_market is null or o.market_id = p_market)
      and (p_channel is null or o.channel_id = p_channel)
  )
  select coalesce(nullif(i->>'code', ''), i->>'name', '?'), max(i->>'name'), o.team_id, o.staff_id,
         case when o.status in (3,16) then 'ok' when o.status in (4,5,15) then 'ret' when o.status = 2 then 'ship'
              when o.status in (6,7) then 'cancel' else 'new' end,
         count(distinct o.pos_order_id), sum(coalesce((i->>'quantity')::numeric, 1)),
         sum(case when coalesce(o.gross, 0) > 0
                  then coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1) / o.gross * coalesce(o.total_price, o.gross)
                  else 0 end * o.rate)
  from o cross join lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i
  group by 1, 3, 4, 5
$$;
