-- Doanh số thống nhất theo COD ở mọi màn (giống KPI tính lương):
--   doanh số = COD (đơn không có COD thì lấy giá trị đơn) + phí sàn (đơn Shopee / TikTok).
--   Áp cho Tổng quan, Team, Nhân sự, Sản phẩm (dash_orders, dash_products) và bảng Theo dõi theo ngày (team_daily, staff_daily).
--   kpi_report: người xem toàn công ty tính mọi đơn, kể cả đơn của nhân sự đã bị xoá khỏi danh mục.
-- Chạy sau 20261111000000_kqkd_filters.sql. Chạy lại nhiều lần không lỗi.

create or replace function public.dash_orders(p_from timestamptz, p_to timestamptz, p_project text default null, p_market text default null, p_channel text default null)
returns table (day date, project_id text, team_id text, staff_id text, marketer text, channel_id text, market_id text, shop_id text,
               st_group text, orders bigint, revenue_vnd numeric, cod_vnd numeric, cogs_vnd numeric, cogs_missing bigint)
language sql stable security invoker set search_path = public as $$
  select o.local_day,
         o.project_id, o.team_id, o.staff_id, coalesce(o.marketer_name, o.seller_name), o.channel_id, o.market_id, o.shop_id,
         case when o.status in (3,16) then 'ok' when o.status in (4,5,15) then 'ret' when o.status = 2 then 'ship'
              when o.status = 6 then 'cancel' else 'new' end,
         count(*), sum((coalesce(o.cod, o.total_price, 0) + coalesce(o.platform_fee, 0)) * coalesce(m.rate_vnd,1)), sum(coalesce(o.cod,0) * coalesce(m.rate_vnd,1)),
         case when (select public.sees_cost()) then sum(coalesce(o.cogs_vnd,0)) end,
         case when (select public.sees_cost()) then count(*) filter (where coalesce(o.cogs_missing,1) > 0) end
  from public.orders o left join public.markets m on m.id = o.market_id
  where o.local_day >= (p_from at time zone 'Asia/Ho_Chi_Minh')::date and o.local_day < (p_to at time zone 'Asia/Ho_Chi_Minh')::date
    and coalesce(o.status, 0) <> 7  -- đơn đã xoá trên POS: không tính
    and (p_project is null or o.project_id = p_project)
    and (p_market is null or o.market_id = any(string_to_array(p_market, ',')))
    and (p_channel is null or o.channel_id = any(string_to_array(p_channel, ',')) or ('__none' = any(string_to_array(p_channel, ',')) and o.channel_id is null))
  group by 1,2,3,4,5,6,7,8,9
$$;

create or replace function public.dash_products(p_from timestamptz, p_to timestamptz, p_project text default null, p_market text default null, p_channel text default null)
returns table (code text, name text, team_id text, staff_id text, st_group text, orders bigint, qty numeric, revenue_vnd numeric, cogs_vnd numeric, unit_cost_vnd numeric)
language sql stable security invoker set search_path = public as $$
  with o as (
    select o.*, coalesce(m.rate_vnd, 1) as rate,
           (select sum(coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1)) from jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i) as gross
    from public.orders o left join public.markets m on m.id = o.market_id
    where o.local_day >= (p_from at time zone 'Asia/Ho_Chi_Minh')::date and o.local_day < (p_to at time zone 'Asia/Ho_Chi_Minh')::date
      and (p_project is null or o.project_id = p_project)
      and (p_market is null or o.market_id = any(string_to_array(p_market, ',')))
      and (p_channel is null or o.channel_id = any(string_to_array(p_channel, ',')) or ('__none' = any(string_to_array(p_channel, ',')) and o.channel_id is null))
      and coalesce(o.status, 0) <> 7
  ), l as (
    select coalesce(nullif(i->>'code', ''), i->>'name', '?') as code, i->>'name' as name, o.team_id, o.staff_id,
           case when o.status in (3,16) then 'ok' when o.status in (4,5,15) then 'ret' when o.status = 2 then 'ship'
                when o.status = 6 then 'cancel' else 'new' end as st_group,
           o.pos_order_id, coalesce((i->>'quantity')::numeric, 1) as qty,
           case when coalesce(o.gross, 0) > 0 then coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1) / o.gross * (coalesce(o.cod, o.total_price, o.gross, 0) + coalesce(o.platform_fee, 0)) else 0 end * o.rate as rev,
           -- Đơn giá vốn đã ghi sẵn trong dòng hàng (ucost); đơn chưa tính lại thì tra như cũ.
           case when i ? 'ucost' then (i->>'ucost')::numeric
                else public.cost_at(coalesce(nullif(i->>'code', ''), i->>'name', '?'), i->>'name', (o.inserted_at at time zone 'Asia/Ho_Chi_Minh')::date) end as cost
    from o cross join lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i
  )
  select l.code, max(l.name), l.team_id, l.staff_id, l.st_group, count(distinct l.pos_order_id), sum(l.qty), sum(l.rev),
         case when (select public.sees_cost()) then sum(l.qty * coalesce(l.cost, 0)) end,
         case when (select public.sees_cost()) then max(l.cost) end
  from l
  group by l.code, l.team_id, l.staff_id, l.st_group
$$;

create or replace function public.team_daily(p_from timestamptz, p_to timestamptz, p_project text default null, p_team text default null,
  p_market text default null, p_channel text default null)
returns table (day date, team_id text, grp smallint, orders bigint, revenue numeric, ad_usd numeric)
language sql stable security definer set search_path = public as $$
  with sc as (select * from public.my_scope() limit 1),
  mon as (select date_trunc('month', p_from at time zone 'Asia/Ho_Chi_Minh')::date as m),
  pg as (
    select distinct on (g.product_key) g.product_key, g.grp
    from public.product_groups g, mon where g.month <= mon.m
    order by g.product_key, g.month desc
  ),
  o as (
    select o.local_day as d, o.team_id, pg.grp,
           (coalesce(o.cod, o.total_price, 0) + coalesce(o.platform_fee, 0)) * coalesce(m.rate_vnd, 1) as rev
    from public.orders o
    left join public.markets m on m.id = o.market_id
    left join pg on pg.product_key = coalesce(o.main_pk, (select lower(btrim(i->>'name')) from jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i where not coalesce((i->>'bonus')::boolean, false) and coalesce(btrim(i->>'name'), '') <> '' order by coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1) desc limit 1)), sc
    where o.local_day >= (p_from at time zone 'Asia/Ho_Chi_Minh')::date and o.local_day < (p_to at time zone 'Asia/Ho_Chi_Minh')::date
      and coalesce(o.status, 0) not in (6, 7)
      and (p_project is null or o.project_id = p_project)
      and (p_team is null or o.team_id = p_team)
      and (p_market is null or o.market_id = any(string_to_array(p_market, ',')))
      and (p_channel is null or o.channel_id = any(string_to_array(p_channel, ',')) or ('__none' = any(string_to_array(p_channel, ',')) and o.channel_id is null))
      and (sc.scope = 'all'
           or (sc.scope = 'project' and o.project_id = any(sc.project_ids))
           or (sc.scope = 'team' and o.team_id = sc.team_id)
           or (sc.scope = 'self' and o.staff_id = sc.staff_id))
  ),
  oa as (select d, team_id, grp, count(*) as n, sum(rev) as rev from o group by 1, 2, 3),
  a as (
    select x.day as d, s.team_id, pg.grp, sum(x.usd) as usd
    from public.ad_spend x
    join public.staff s on s.id = x.staff_id
    left join public.teams t on t.id = s.team_id
    left join pg on pg.product_key = x.product_key, sc
    where x.day >= (p_from at time zone 'Asia/Ho_Chi_Minh')::date and x.day < (p_to at time zone 'Asia/Ho_Chi_Minh')::date
      and (p_project is null or coalesce(t.project_id, s.project_id) = p_project)
      and (p_team is null or s.team_id = p_team)
      and (p_channel is null or x.channel_id = any(string_to_array(p_channel, ',')) or ('__none' = any(string_to_array(p_channel, ',')) and coalesce(x.channel_id, '') = ''))
      and (sc.scope = 'all'
           or (sc.scope = 'project' and coalesce(t.project_id, s.project_id) = any(sc.project_ids))
           or (sc.scope = 'team' and s.team_id = sc.team_id)
           or (sc.scope = 'self' and s.id = sc.staff_id))
    group by 1, 2, 3
  )
  select coalesce(oa.d, a.d), coalesce(oa.team_id, a.team_id), coalesce(oa.grp, a.grp),
         coalesce(oa.n, 0), coalesce(oa.rev, 0), coalesce(a.usd, 0)
  from oa full join a on a.d = oa.d and a.team_id is not distinct from oa.team_id and a.grp is not distinct from oa.grp
$$;

create or replace function public.staff_daily(p_from timestamptz, p_to timestamptz, p_staff text,
  p_market text default null, p_channel text default null)
returns table (day date, grp smallint, orders bigint, revenue numeric, ad_usd numeric)
language sql stable security definer set search_path = public as $$
  with mon as (select date_trunc('month', p_from at time zone 'Asia/Ho_Chi_Minh')::date as m),
  pg as (
    select distinct on (g.product_key) g.product_key, g.grp
    from public.product_groups g, mon where g.month <= mon.m
    order by g.product_key, g.month desc
  ),
  o as (
    select o.local_day as d, pg.grp,
           (coalesce(o.cod, o.total_price, 0) + coalesce(o.platform_fee, 0)) * coalesce(m.rate_vnd, 1) as rev
    from public.orders o
    left join public.markets m on m.id = o.market_id
    left join pg on pg.product_key = coalesce(o.main_pk, (select lower(btrim(i->>'name')) from jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i where not coalesce((i->>'bonus')::boolean, false) and coalesce(btrim(i->>'name'), '') <> '' order by coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1) desc limit 1))
    where o.staff_id = p_staff and o.local_day >= (p_from at time zone 'Asia/Ho_Chi_Minh')::date and o.local_day < (p_to at time zone 'Asia/Ho_Chi_Minh')::date
      and coalesce(o.status, 0) not in (6, 7)
      and (p_market is null or o.market_id = any(string_to_array(p_market, ',')))
      and (p_channel is null or o.channel_id = any(string_to_array(p_channel, ',')) or ('__none' = any(string_to_array(p_channel, ',')) and o.channel_id is null))
  ),
  oa as (select d, grp, count(*) as n, sum(rev) as rev from o group by 1, 2),
  a as (
    select x.day as d, pg.grp, sum(x.usd) as usd
    from public.ad_spend x left join pg on pg.product_key = x.product_key
    where x.staff_id = p_staff
      and (p_channel is null or x.channel_id = any(string_to_array(p_channel, ',')) or ('__none' = any(string_to_array(p_channel, ',')) and coalesce(x.channel_id, '') = ''))
      and x.day >= (p_from at time zone 'Asia/Ho_Chi_Minh')::date and x.day < (p_to at time zone 'Asia/Ho_Chi_Minh')::date
    group by 1, 2
  )
  select coalesce(oa.d, a.d), coalesce(oa.grp, a.grp), coalesce(oa.n, 0), coalesce(oa.rev, 0), coalesce(a.usd, 0)
  from oa full join a on a.d = oa.d and a.grp is not distinct from oa.grp
  where public.can_see_staff(p_staff)
$$;

create or replace function public.kpi_report(p_from timestamptz, p_to timestamptz, p_mode text default 'ads', p_project text default null,
  p_market text default null, p_channel text default null)
returns table (who text, product_key text, product text, grp smallint, orders bigint, sent numeric, ret numeric, ok numeric,
               cogs numeric, cogs_missing bigint, ship_rate numeric, ad_usd numeric, ok_n bigint, ret_n bigint, platform_fee numeric)
language sql stable security definer set search_path = public as $$
  with sc as (select * from public.my_scope() limit 1),
  mon as (select date_trunc('month', p_from at time zone 'Asia/Ho_Chi_Minh')::date as m),
  pg as (
    select distinct on (g.product_key) g.product_key, g.grp, g.rd_staff_id
    from public.product_groups g, mon where g.month <= mon.m
    order by g.product_key, g.month desc
  ),
  vis as (  -- nhân sự người xem được thấy
    select s.id, coalesce(t.project_id, s.project_id) as project_id
    from public.staff s left join public.teams t on t.id = s.team_id, sc
    where sc.scope = 'all'
       or (sc.scope = 'project' and coalesce(t.project_id, s.project_id) = any(sc.project_ids))
       or (sc.scope = 'team' and s.team_id = sc.team_id)
       or (sc.scope = 'self' and s.id = sc.staff_id)
  ),
  o as (
    select o.staff_id, o.project_id, o.status, coalesce(m.rate_vnd, 1) as rate,
           (coalesce(o.cod, o.total_price, 0) + coalesce(o.platform_fee, 0)) * coalesce(m.rate_vnd, 1) as cod_vnd,
           coalesce(o.platform_fee, 0) * coalesce(m.rate_vnd, 1) as fee_vnd,
           coalesce(o.cogs_vnd, 0) as cogs, coalesce(o.cogs_missing, 0) as miss,
           coalesce(o.main_name, (select btrim(i->>'name') from jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i where not coalesce((i->>'bonus')::boolean, false) and coalesce(btrim(i->>'name'), '') <> '' order by coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1) desc limit 1), '(không rõ sản phẩm)') as name
    from public.orders o
    left join public.markets m on m.id = o.market_id
    , sc
    where o.local_day >= (p_from at time zone 'Asia/Ho_Chi_Minh')::date and o.local_day < (p_to at time zone 'Asia/Ho_Chi_Minh')::date
      and coalesce(o.status, 0) not in (6, 7)
      and (p_mode = 'rd' or p_project is null or o.project_id = p_project)
      and (p_market is null or o.market_id = any(string_to_array(p_market, ',')))
      and (p_channel is null or o.channel_id = any(string_to_array(p_channel, ',')) or ('__none' = any(string_to_array(p_channel, ',')) and o.channel_id is null))
      and (p_mode = 'rd'
           or sc.scope = 'all'
           or (sc.scope = 'project' and o.project_id = any(sc.project_ids))
           or (sc.scope = 'team' and o.team_id = sc.team_id)
           or (sc.scope = 'self' and o.staff_id = sc.staff_id))
  ),
  ol as (
    select case when p_mode = 'rd' then pg.rd_staff_id else o.staff_id end as who, lower(o.name) as pk, max(o.name) as product,
           count(*) as orders, sum(o.cod_vnd) as sent,
           sum(o.cod_vnd) filter (where o.status in (4, 5, 15)) as ret,
           sum(o.cod_vnd) filter (where o.status in (3, 16)) as ok,
           sum(o.cogs) filter (where o.status in (3, 16)) as cogs,
           count(*) filter (where o.status in (3, 16) and o.miss > 0) as cogs_missing,
           sum(o.rate) as ship_rate,
           count(*) filter (where o.status in (3, 16)) as ok_n,
           count(*) filter (where o.status in (4, 5, 15)) as ret_n,
           sum(o.fee_vnd) filter (where o.status in (3, 16)) as fee
    from o left join pg on pg.product_key = lower(o.name)
    group by 1, 2
  ),
  a as (
    select case when p_mode = 'rd' then pg.rd_staff_id else x.staff_id end as who, x.product_key as pk,
           max(x.product_name) as product, sum(x.usd) as usd
    from public.ad_spend x
    left join pg on pg.product_key = x.product_key
    left join public.staff s on s.id = x.staff_id left join public.teams t on t.id = s.team_id
    where x.day >= (p_from at time zone 'Asia/Ho_Chi_Minh')::date and x.day < (p_to at time zone 'Asia/Ho_Chi_Minh')::date
      and (p_mode = 'rd' or p_project is null or coalesce(t.project_id, s.project_id) = p_project)
      and (p_channel is null or x.channel_id = any(string_to_array(p_channel, ',')) or ('__none' = any(string_to_array(p_channel, ',')) and coalesce(x.channel_id, '') = ''))
    group by 1, 2
  ),
  j as (
    select coalesce(ol.who, a.who) as who, coalesce(ol.pk, a.pk) as pk, coalesce(ol.product, a.product) as product,
           coalesce(ol.orders, 0) as orders, coalesce(ol.sent, 0) as sent, coalesce(ol.ret, 0) as ret, coalesce(ol.ok, 0) as ok,
           coalesce(ol.cogs, 0) as cogs, coalesce(ol.cogs_missing, 0) as cogs_missing, coalesce(ol.ship_rate, 0) as ship_rate,
           coalesce(a.usd, 0) as usd, coalesce(ol.ok_n, 0) as ok_n, coalesce(ol.ret_n, 0) as ret_n, coalesce(ol.fee, 0) as fee
    from ol full join a on a.who is not distinct from ol.who and a.pk = ol.pk
  )
  select j.who, j.pk, j.product, pg.grp, j.orders, j.sent, j.ret, j.ok, j.cogs, j.cogs_missing, j.ship_rate, j.usd, j.ok_n, j.ret_n, j.fee
  from j left join pg on pg.product_key = j.pk, sc
  -- Xem toàn công ty: tính mọi đơn, kể cả đơn của nhân sự đã xoá khỏi danh mục (để khớp số đơn với Tổng quan).
  where sc.scope = 'all' or j.who in (select id from vis)
$$;
