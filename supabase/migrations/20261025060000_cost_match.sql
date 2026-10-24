-- Khớp giá vốn khi mã trong file nhập hàng (MC60, VP3805...) khác mã POS (G042-...):
--   1) bảng product_alias: mã POS → mã trong file (admin / kế toán gán tay ở Quản trị → Giá vốn)
--   2) không có thì khớp theo mã trùng, hoặc tên tiếng Anh trong file = tên sản phẩm trên POS.
-- Chạy sau 20261025050000_cost.sql.

alter table public.purchases add column if not exists name_en text;
create index if not exists purchases_name_en on public.purchases (lower(name_en), purchase_date desc, id desc);

create table if not exists public.product_alias (
  pos_key text primary key,          -- lower(mã POS)
  pos_code text not null,
  cost_code text not null,           -- mã trong file nhập hàng
  updated_at timestamptz not null default now()
);
alter table public.product_alias enable row level security;
grant select, insert, update, delete on public.product_alias to authenticated;
drop policy if exists product_alias_read on public.product_alias;
create policy product_alias_read on public.product_alias for select to authenticated using ((select public.has_role('admin','quan_ly','ke_toan')));
drop policy if exists product_alias_write on public.product_alias;
create policy product_alias_write on public.product_alias for all to authenticated
  using ((select public.has_role('admin','ke_toan'))) with check ((select public.has_role('admin','ke_toan')));

create or replace function public.cost_at(p_code text, p_name text, p_day date) returns numeric
language sql stable security definer set search_path = public as $$
  with k as (select coalesce((select cost_code from public.product_alias where pos_key = lower(p_code)), p_code) as code),
  m as (
    select p.unit_cost_vnd, p.purchase_date, p.id from public.purchases p, k
    where lower(p.code) = lower(k.code) or (p_name is not null and p_name <> '' and lower(p.name_en) = lower(p_name))
  )
  select coalesce(
    (select unit_cost_vnd from m where purchase_date <= p_day order by purchase_date desc, id desc limit 1),
    (select unit_cost_vnd from m order by purchase_date asc, id asc limit 1))
$$;
revoke all on function public.cost_at(text, text, date) from public, anon;
grant execute on function public.cost_at(text, text, date) to authenticated, service_role;

create or replace function public.cost_at(p_code text, p_day date) returns numeric
language sql stable security definer set search_path = public as $$ select public.cost_at(p_code, null, p_day) $$;

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
  cross join lateral (select public.cost_at(i->>'code', i->>'name', (coalesce(new.inserted_at, now()) at time zone 'Asia/Ho_Chi_Minh')::date) as c) x;
  new.derived_at := clock_timestamp();
  return new;
end $$;

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
  c as (select k.code, k.name, k.day, public.cost_at(k.code, k.name, k.day) as cost from (select distinct code, name, day from l) k)
  select l.code, max(l.name), l.team_id, l.staff_id, l.st_group, count(distinct l.pos_order_id), sum(l.qty), sum(l.rev),
         case when (select public.has_role('admin','quan_ly','ke_toan')) then sum(l.qty * coalesce(c.cost, 0)) end,
         case when (select public.has_role('admin','quan_ly','ke_toan')) then max(c.cost) end
  from l left join c on c.code = l.code and c.name is not distinct from l.name and c.day = l.day
  group by l.code, l.team_id, l.staff_id, l.st_group
$$;

drop trigger if exists product_alias_recompute on public.product_alias;
create trigger product_alias_recompute after insert or update or delete on public.product_alias
  for each statement execute function public.recompute_orders_purchases();
drop trigger if exists purchases_recompute on public.purchases;
create trigger purchases_recompute after insert or update or delete on public.purchases
  for each statement execute function public.recompute_orders_purchases();
grant update on public.purchases to authenticated;
drop policy if exists purchases_update on public.purchases;
create policy purchases_update on public.purchases for update to authenticated
  using ((select public.has_role('admin','ke_toan'))) with check ((select public.has_role('admin','ke_toan')));

-- Quản trị → Giá vốn: từng sản phẩm bán trong 30 ngày, lần nhập khớp gần nhất (theo mã gán / mã / tên tiếng Anh).
drop function if exists public.admin_cost_overview();
create or replace function public.admin_cost_overview() returns table (
  code text, name text, alias text, cost_code text, unit_cost_vnd numeric, last_date date, last_qty numeric, purchases bigint, sold_30d numeric)
language sql stable security definer set search_path = public as $$
  with sold as (
    select lower(i->>'code') k, max(i->>'code') code, max(i->>'name') name, sum(coalesce((i->>'quantity')::numeric, 1)) q
    from public.orders o cross join lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i
    where o.inserted_at >= now() - interval '30 days' and coalesce(i->>'code', '') <> ''
    group by 1
  )
  select s.code, s.name, a.cost_code, lp.code, lp.unit_cost_vnd, lp.purchase_date, lp.qty,
         (select count(*) from public.purchases p2 where lower(p2.code) = lower(lp.code)), s.q
  from sold s
  left join public.product_alias a on a.pos_key = s.k
  left join lateral (
    select p.code, p.unit_cost_vnd, p.purchase_date, p.qty from public.purchases p
    where lower(p.code) = lower(coalesce(a.cost_code, s.code)) or (s.name is not null and lower(p.name_en) = lower(s.name))
    order by p.purchase_date desc, p.id desc limit 1
  ) lp on true
  where (select public.has_role('admin','quan_ly','ke_toan'))
  order by (lp.code is null) desc, s.q desc
$$;
revoke all on function public.admin_cost_overview() from public, anon;
grant execute on function public.admin_cost_overview() to authenticated;
