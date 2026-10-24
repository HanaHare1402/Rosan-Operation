-- Giá vốn theo phương pháp NHẬP GẦN NHẤT.
-- Bảng purchases = dữ liệu nhập hàng (tải file Excel lên ở Quản trị → Giá vốn).
-- Giá vốn một sản phẩm trong đơn = đơn giá (VNĐ) của lần nhập gần nhất có ngày nhập ≤ ngày tạo đơn;
-- chưa có lần nhập nào trước ngày đó thì lấy lần nhập sớm nhất.
-- Chạy sau 20261025040000_recompute_batches.sql.

create table if not exists public.purchases (
  id bigint generated always as identity primary key,
  code text not null,
  name text,
  purchase_date date not null,
  qty numeric,
  unit_cost numeric not null,
  currency text not null default 'VND',
  unit_cost_vnd numeric not null,
  supplier text,
  note text,
  row_hash text not null unique,      -- chống trùng khi tải lại cùng một file
  imported_by uuid default auth.uid(),
  imported_at timestamptz not null default now()
);
create index if not exists purchases_code_date on public.purchases (lower(code), purchase_date desc, id desc);

alter table public.purchases enable row level security;
grant select, insert, delete on public.purchases to authenticated;
drop policy if exists purchases_read on public.purchases;
create policy purchases_read on public.purchases for select to authenticated using (public.has_role('admin','quan_ly','ke_toan'));
drop policy if exists purchases_insert on public.purchases;
create policy purchases_insert on public.purchases for insert to authenticated with check (public.has_role('admin','ke_toan'));
drop policy if exists purchases_delete on public.purchases;
create policy purchases_delete on public.purchases for delete to authenticated using (public.has_role('admin','ke_toan'));

create or replace function public.cost_at(p_code text, p_day date) returns numeric
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select unit_cost_vnd from public.purchases where lower(code) = lower(p_code) and purchase_date <= p_day
      order by purchase_date desc, id desc limit 1),
    (select unit_cost_vnd from public.purchases where lower(code) = lower(p_code)
      order by purchase_date asc, id asc limit 1))
$$;
revoke all on function public.cost_at(text, date) from public, anon;
grant execute on function public.cost_at(text, date) to authenticated, service_role;

alter table public.orders
  add column if not exists cogs_vnd numeric,
  add column if not exists cogs_missing int;

-- Giữ lại dấu hiệu "đơn đã xoá" của POS khi cắt gọn dữ liệu thô.
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
      'returned_reason','returned_reason_name','is_abandoned_order','is_exchange_order','prepaid','transfer_money',
      'is_removed','is_deleted','removed','removed_at','deleted_at'])
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
  -- Chỉ đánh dấu "cần tính lại" (derived_at → null): bỏ qua, đợt tính lại sẽ xử lý.
  if tg_op = 'UPDATE' and new.derived_at is null and old.derived_at is not null and new.raw is not distinct from old.raw then
    return new;
  end if;
  -- Đường nhanh: raw không đổi (chỉ tính lại gán nhân sự / kênh) thì bỏ qua phần dựng cột từ raw.
  -- Dựng lại khi: đơn mới, raw đổi (kéo lại từ POS), hoặc raw cũ chưa được cắt gọn / chưa có cột sản phẩm.
  if tg_op = 'INSERT' or new.raw is distinct from old.raw or old.items is null
     or old.raw ? 'customer' or old.raw ? 'status_history' or old.raw ? 'histories' then
  r := public.pos_slim(new.raw);
  new.raw := r;

  -- Cột số liệu, lấy lại từ raw để đơn cũ cũng đúng khi tính lại.
  new.status := coalesce((r->>'status')::int, new.status);
  new.status_name := coalesce(r->>'status_name', new.status_name);
  -- Đơn đã xoá trên POS (lấy về nhờ include_removed=1): coi như huỷ, mã 7 "Đã xoá", không tính doanh số.
  if coalesce(r->>'is_removed', r->>'is_deleted', r->>'removed', 'false') in ('true', '1')
     or nullif(coalesce(r->>'removed_at', r->>'deleted_at', ''), '') is not null then
    new.status := 7; new.status_name := 'removed';
  end if;
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

  end if;

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
  -- Giá vốn: mỗi dòng sản phẩm × đơn giá lần nhập gần nhất tính đến ngày tạo đơn (giờ VN).
  select sum(coalesce((i->>'quantity')::numeric, 1) * x.c), count(*) filter (where x.c is null)
    into new.cogs_vnd, new.cogs_missing
  from jsonb_array_elements(coalesce(new.items, '[]'::jsonb)) i
  cross join lateral (select public.cost_at(i->>'code', (coalesce(new.inserted_at, now()) at time zone 'Asia/Ho_Chi_Minh')::date) as c) x;
  new.derived_at := clock_timestamp();
  return new;
end $$;

-- Tải / xoá dữ liệu nhập hàng → tính lại giá vốn các đơn theo đợt.
create or replace function public.recompute_orders_purchases() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.request_recompute();
  return null;
end $$;
drop trigger if exists purchases_recompute on public.purchases;
create trigger purchases_recompute after insert or delete on public.purchases
  for each statement execute function public.recompute_orders_purchases();

-- Số liệu bảng điều hành, thêm giá vốn (chỉ admin, quản lý, kế toán thấy).
drop function if exists public.dash_orders(timestamptz, timestamptz, text, text, text);
create or replace function public.dash_orders(p_from timestamptz, p_to timestamptz, p_project text default null, p_market text default null, p_channel text default null)
returns table (day date, project_id text, team_id text, staff_id text, marketer text, channel_id text, market_id text, shop_id text,
               st_group text, orders bigint, revenue_vnd numeric, cod_vnd numeric, cogs_vnd numeric, cogs_missing bigint)
language sql stable security invoker set search_path = public as $$
  select (o.inserted_at at time zone coalesce(m.timezone, 'Asia/Ho_Chi_Minh'))::date,
         o.project_id, o.team_id, o.staff_id, coalesce(o.marketer_name, o.seller_name), o.channel_id, o.market_id, o.shop_id,
         case when o.status in (3,16) then 'ok' when o.status in (4,5,15) then 'ret' when o.status = 2 then 'ship'
              when o.status in (6,7) then 'cancel' else 'new' end,
         count(*), sum(coalesce(o.total_price,0) * coalesce(m.rate_vnd,1)), sum(coalesce(o.cod,0) * coalesce(m.rate_vnd,1)),
         case when (select public.has_role('admin','quan_ly','ke_toan')) then sum(coalesce(o.cogs_vnd,0)) end,
         case when (select public.has_role('admin','quan_ly','ke_toan')) then count(*) filter (where coalesce(o.cogs_missing,1) > 0) end
  from public.orders o left join public.markets m on m.id = o.market_id
  where o.inserted_at >= p_from and o.inserted_at < p_to
    and (p_project is null or o.project_id = p_project)
    and (p_market is null or o.market_id = p_market)
    and (p_channel is null or o.channel_id = p_channel)
  group by 1,2,3,4,5,6,7,8,9
$$;

drop function if exists public.dash_products(timestamptz, timestamptz, text, text, text);
create or replace function public.dash_products(p_from timestamptz, p_to timestamptz, p_project text default null, p_market text default null, p_channel text default null)
returns table (code text, name text, team_id text, staff_id text, st_group text, orders bigint, qty numeric, revenue_vnd numeric, cogs_vnd numeric, unit_cost_vnd numeric)
language sql stable security invoker set search_path = public as $$
  with o as (
    select o.*, coalesce(m.rate_vnd, 1) as rate,
           (select sum(coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1)) from jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i) as gross
    from public.orders o left join public.markets m on m.id = o.market_id
    where o.inserted_at >= p_from and o.inserted_at < p_to
      and (p_project is null or o.project_id = p_project)
      and (p_market is null or o.market_id = p_market)
      and (p_channel is null or o.channel_id = p_channel)
  ), l as (
    select coalesce(nullif(i->>'code', ''), i->>'name', '?') as code, i->>'name' as name, o.team_id, o.staff_id,
           case when o.status in (3,16) then 'ok' when o.status in (4,5,15) then 'ret' when o.status = 2 then 'ship'
                when o.status in (6,7) then 'cancel' else 'new' end as st_group,
           o.pos_order_id, coalesce((i->>'quantity')::numeric, 1) as qty,
           case when coalesce(o.gross, 0) > 0 then coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1) / o.gross * coalesce(o.total_price, o.gross) else 0 end * o.rate as rev,
           (o.inserted_at at time zone 'Asia/Ho_Chi_Minh')::date as day
    from o cross join lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i
  ),
  -- Tra giá vốn theo từng cặp (sản phẩm, ngày) thay vì từng dòng hàng.
  c as (select k.code, k.day, public.cost_at(k.code, k.day) as cost from (select distinct code, day from l) k)
  select l.code, max(l.name), l.team_id, l.staff_id, l.st_group, count(distinct l.pos_order_id), sum(l.qty), sum(l.rev),
         case when (select public.has_role('admin','quan_ly','ke_toan')) then sum(l.qty * coalesce(c.cost, 0)) end,
         case when (select public.has_role('admin','quan_ly','ke_toan')) then max(c.cost) end
  from l left join c on c.code = l.code and c.day = l.day
  group by l.code, l.team_id, l.staff_id, l.st_group
$$;

-- Quản trị → Giá vốn: giá vốn hiện tại từng sản phẩm, kèm sản phẩm đang bán mà chưa có giá vốn.
create or replace function public.admin_cost_overview() returns table (
  code text, name text, unit_cost_vnd numeric, last_date date, last_qty numeric, purchases bigint, sold_30d numeric)
language sql stable security definer set search_path = public as $$
  with latest as (
    select distinct on (lower(code)) lower(code) as k, code, name, unit_cost_vnd, purchase_date, qty
    from public.purchases order by lower(code), purchase_date desc, id desc
  ), cnt as (select lower(code) k, count(*) n from public.purchases group by 1),
  sold as (
    select lower(i->>'code') k, max(i->>'code') code, max(i->>'name') name, sum(coalesce((i->>'quantity')::numeric, 1)) q
    from public.orders o cross join lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i
    where o.inserted_at >= now() - interval '30 days' and coalesce(i->>'code', '') <> ''
    group by 1
  )
  select coalesce(l.code, s.code), coalesce(s.name, l.name), l.unit_cost_vnd, l.purchase_date, l.qty, coalesce(c.n, 0), coalesce(s.q, 0)
  from latest l full join sold s on s.k = l.k left join cnt c on c.k = coalesce(l.k, s.k)
  where public.has_role('admin','quan_ly','ke_toan')
  order by (l.k is null) desc, coalesce(s.q, 0) desc
$$;
revoke all on function public.admin_cost_overview() from public, anon;
grant execute on function public.admin_cost_overview() to authenticated;

-- Kế toán được chạy đợt tính lại (sau khi tải file giá vốn).
create or replace function public.recompute_batch(p_limit int default 2000) returns table (done bigint, remaining bigint)
language plpgsql security definer set search_path = public as $$
declare since timestamptz; n bigint;
begin
  if auth.uid() is not null and not public.has_role('admin','quan_ly','ke_toan') then raise exception 'Không có quyền' using errcode = '42501'; end if;
  since := coalesce((select (value->>'at')::timestamptz from public.app_settings where key = 'recompute_after'), '-infinity');
  with c as (
    select shop_id, pos_order_id from public.orders
    where derived_at is null or derived_at < since
    limit greatest(1, least(p_limit, 20000))
    for update skip locked
  )
  update public.orders o set synced_at = o.synced_at from c
  where o.shop_id = c.shop_id and o.pos_order_id = c.pos_order_id;
  get diagnostics n = row_count;
  return query select n, (select count(*) from public.orders where derived_at is null or derived_at < since);
end $$;

-- Quyền đọc / ghi các bảng danh mục: bọc lời gọi hàm trong (select ...) để Postgres tính MỘT lần mỗi lệnh.
-- Trước đây khi báo cáo nối đơn với bảng thị trường, hàm quyền bị gọi lại cho từng đơn (50.000 đơn ≈ 2 giây).
do $$
declare t text;
begin
  foreach t in array array['projects','markets','channels'] loop
    execute format('drop policy if exists %1$s_read on public.%1$s', t);
    execute format('create policy %1$s_read on public.%1$s for select to authenticated using ((select public.my_role()) is not null)', t);
    execute format('drop policy if exists %1$s_write on public.%1$s', t);
    execute format('create policy %1$s_write on public.%1$s for all to authenticated using ((select public.is_admin())) with check ((select public.is_admin()))', t);
  end loop;
end $$;

drop policy if exists teams_read on public.teams;
create policy teams_read on public.teams for select to authenticated using ((select public.my_role()) is not null);
drop policy if exists staff_read on public.staff;
create policy staff_read on public.staff for select to authenticated using ((select public.my_role()) is not null);
drop policy if exists ffm_select on public.ffm_units;
create policy ffm_select on public.ffm_units for select to authenticated using ((select public.my_role()) is not null);
drop policy if exists ffm_write on public.ffm_units;
create policy ffm_write on public.ffm_units for all to authenticated
  using ((select public.has_role('admin','quan_ly','ke_toan'))) with check ((select public.has_role('admin','quan_ly','ke_toan')));
drop policy if exists pos_shops_select on public.pos_shops;
create policy pos_shops_select on public.pos_shops for select to authenticated using ((select public.my_role()) is not null);
drop policy if exists pos_shops_write on public.pos_shops;
create policy pos_shops_write on public.pos_shops for all to authenticated
  using ((select public.has_role('admin','quan_ly'))) with check ((select public.has_role('admin','quan_ly')));
drop policy if exists purchases_read on public.purchases;
create policy purchases_read on public.purchases for select to authenticated using ((select public.has_role('admin','quan_ly','ke_toan')));
