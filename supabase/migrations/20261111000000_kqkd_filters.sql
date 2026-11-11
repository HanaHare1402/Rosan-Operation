-- Kết quả kinh doanh lọc được theo thị trường và kênh (VD chỉ xem Shopee).
--   kpi_report thêm p_market, p_channel (danh sách cách nhau dấu phẩy, '__none' = chưa xác định kênh), mặc định null = mọi nơi.
--   Màn KPI tính lương vẫn gọi không kèm hai tham số này nên số không đổi.
--   Chi phí quảng cáo lọc theo kênh marketer chọn khi nhập; chi phí quảng cáo không có thị trường nên không lọc theo thị trường.
-- Chạy sau 20261110000000_marketplace_revenue.sql. Chạy lại nhiều lần không lỗi.

drop function if exists public.kpi_report(timestamptz, timestamptz, text, text);
drop function if exists public.kpi_report(timestamptz, timestamptz, text, text, text, text);
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
  where (j.who is null and sc.scope = 'all') or j.who in (select id from vis)
$$;
revoke all on function public.kpi_report(timestamptz, timestamptz, text, text, text, text) from public, anon;
grant execute on function public.kpi_report(timestamptz, timestamptz, text, text, text, text) to authenticated;
