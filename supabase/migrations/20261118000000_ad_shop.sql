-- Chi phí ads kênh sàn (Shopee, TikTok, Lazada) nhập theo SHOP (gian hàng) thay vì theo sản phẩm.
--   * ad_spend: dòng theo shop có product_key = 'shop:' + tên shop (chữ thường), product_name = tên shop.
--   * ad_spend_alloc(): báo cáo đọc chi phí qua hàm này. Dòng theo shop được chia cho các sản phẩm bán qua shop đó
--     trong cùng ngày, theo tỷ lệ doanh số (COD + phí sàn, không tính đơn huỷ / đã xoá), sản phẩm = sản phẩm chính
--     của đơn (giống KPI). Ngày shop không có đơn: giữ nguyên một dòng mang tên shop. Tổng chi phí không đổi.
--   * Dòng nhập theo sản phẩm (Facebook…, kể cả dòng Shopee / TikTok nhập theo sản phẩm trước đây) giữ nguyên.
--   * ad_shops(): danh sách shop (gian hàng từ POS) của các kênh sàn để gợi ý khi nhập.
--   * team_daily, staff_daily, kpi_report: đọc ad_spend_alloc thay cho ad_spend (phần đơn hàng không đổi).
--   * Tự kiểm tra: tổng chi phí theo nhân sự × ngày × kênh qua ad_spend_alloc = ad_spend (90 ngày gần nhất).
-- Chạy sau 20261116000000_product_revenue_fallback.sql. Chạy lại nhiều lần không lỗi.

begin;
set local statement_timeout = '5min';

-- Kênh sàn: tên / mã / từ khoá có shopee, tiktok hoặc lazada.
create or replace function public.is_mkt_channel(p_channel text) returns boolean
language sql stable as $$
  select exists (select 1 from public.channels c where c.id = p_channel
                 and (c.name ~* '(shopee|tiktok|lazada)' or c.id ~* '(shopee|tiktok|lazada)'
                      or array_to_string(c.keywords, ',') ~* '(shopee|tiktok|lazada)'))
$$;
grant execute on function public.is_mkt_channel(text) to authenticated, service_role;

-- Danh sách shop của các kênh sàn trong p_days ngày qua (gợi ý khi nhập chi phí).
create or replace function public.ad_shops(p_days int default 60)
returns table (shop text, channel_id text, orders bigint)
language sql stable security definer set search_path = public as $$
  select max(btrim(o.page_name)), o.channel_id, count(*)
  from public.orders o
  where o.local_day >= current_date - greatest(least(coalesce(p_days, 60), 400), 1)
    and coalesce(btrim(o.page_name), '') <> '' and o.channel_id is not null
    and public.is_mkt_channel(o.channel_id)
    and (select public.my_role()) is not null
  group by lower(btrim(o.page_name)), o.channel_id
$$;
revoke all on function public.ad_shops(int) from public, anon;
grant execute on function public.ad_shops(int) to authenticated;

-- Chi phí ads đã chia: dòng theo shop → các sản phẩm bán qua shop trong ngày, theo tỷ lệ doanh số.
create or replace function public.ad_spend_alloc(p_d1 date, p_d2 date)
returns table (day date, staff_id text, product_key text, product_name text, channel_id text, usd numeric)
language sql stable as $$  -- không đặt search_path để Postgres gộp được vào câu hỏi của báo cáo (tên bảng đã ghi đủ public.)
  with a as (
    select x.day, x.staff_id, x.product_key, x.product_name, x.channel_id, x.usd
    from public.ad_spend x where x.day >= p_d1 and x.day < p_d2
  ),
  sh as (select a.*, substr(a.product_key, 6) as shop from a where a.product_key like 'shop:%'),
  o as (
    select o.local_day as d, lower(btrim(o.page_name)) as shop,
           lower(coalesce(o.main_name, '(không rõ sản phẩm)')) as pk, max(coalesce(o.main_name, '(không rõ sản phẩm)')) as pname,
           sum(coalesce(o.cod, o.total_price, 0) + coalesce(o.platform_fee, 0)) as rev
    from public.orders o
    where o.local_day >= p_d1 and o.local_day < p_d2 and coalesce(o.status, 0) not in (6, 7)
      and lower(btrim(o.page_name)) in (select distinct sh.shop from sh)
    group by 1, 2, 3
  ),
  ot as (select o.d, o.shop, sum(o.rev) as t from o group by 1, 2 having sum(o.rev) > 0)
  select a.day, a.staff_id, a.product_key, a.product_name, a.channel_id, a.usd from a where a.product_key not like 'shop:%'
  union all
  select sh.day, sh.staff_id, o.pk, o.pname, sh.channel_id, sh.usd * o.rev / ot.t
  from sh join ot on ot.d = sh.day and ot.shop = sh.shop
  join o on o.d = ot.d and o.shop = ot.shop and o.rev <> 0
  union all
  select sh.day, sh.staff_id, sh.product_key, sh.product_name, sh.channel_id, sh.usd
  from sh where not exists (select 1 from ot where ot.d = sh.day and ot.shop = sh.shop)
$$;
revoke all on function public.ad_spend_alloc(date, date) from public, anon, authenticated;

create or replace function public.team_daily(p_from timestamptz, p_to timestamptz, p_project text default null, p_team text default null,
  p_market text default null, p_channel text default null)
returns table (day date, team_id text, grp smallint, orders bigint, revenue numeric, ad_usd numeric)
language plpgsql stable security definer set search_path = public set plan_cache_mode = force_custom_plan as $$
#variable_conflict use_column
begin
  return query
  with sc as (select * from public.my_scope() limit 1),
  mon as (select date_trunc('month', p_from at time zone 'Asia/Ho_Chi_Minh')::date as m),
  pg as (
    select distinct on (g.product_key) g.product_key, g.grp
    from public.product_groups g, mon where g.month <= mon.m
    order by g.product_key, g.month desc
  ),
  o as (
    select f.day as d, f.team_id, pg.grp, f.n, f.rev * coalesce(m.rate_vnd, 1) as rev
    from public.order_facts((p_from at time zone 'Asia/Ho_Chi_Minh')::date, (p_to at time zone 'Asia/Ho_Chi_Minh')::date) f
    left join public.markets m on m.id = f.market_id
    left join pg on pg.product_key = f.pk_team, sc
    where coalesce(f.status, 0) not in (6, 7)
      and (p_project is null or f.project_id = p_project)
      and (p_team is null or f.team_id = p_team)
      and (p_market is null or f.market_id = any(string_to_array(p_market, ',')))
      and (p_channel is null or f.channel_id = any(string_to_array(p_channel, ',')) or ('__none' = any(string_to_array(p_channel, ',')) and f.channel_id is null))
      and (sc.scope = 'all'
           or (sc.scope = 'project' and f.project_id = any(sc.project_ids))
           or (sc.scope = 'team' and f.team_id = sc.team_id)
           or (sc.scope = 'self' and f.staff_id = sc.staff_id))
  ),
  oa as (select d, team_id, grp, sum(n)::bigint as n, sum(rev) as rev from o group by 1, 2, 3),
  a as (
    select x.day as d, s.team_id, pg.grp, sum(x.usd) as usd
    from public.ad_spend_alloc((p_from at time zone 'Asia/Ho_Chi_Minh')::date, (p_to at time zone 'Asia/Ho_Chi_Minh')::date) x
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
  from oa full join a on a.d = oa.d and a.team_id is not distinct from oa.team_id and a.grp is not distinct from oa.grp;
end $$;

create or replace function public.staff_daily(p_from timestamptz, p_to timestamptz, p_staff text,
  p_market text default null, p_channel text default null)
returns table (day date, grp smallint, orders bigint, revenue numeric, ad_usd numeric)
language plpgsql stable security definer set search_path = public set plan_cache_mode = force_custom_plan as $$
#variable_conflict use_column
begin
  return query
  with mon as (select date_trunc('month', p_from at time zone 'Asia/Ho_Chi_Minh')::date as m),
  pg as (
    select distinct on (g.product_key) g.product_key, g.grp
    from public.product_groups g, mon where g.month <= mon.m
    order by g.product_key, g.month desc
  ),
  o as (
    select f.day as d, pg.grp, f.n, f.rev * coalesce(m.rate_vnd, 1) as rev
    from public.order_facts((p_from at time zone 'Asia/Ho_Chi_Minh')::date, (p_to at time zone 'Asia/Ho_Chi_Minh')::date) f
    left join public.markets m on m.id = f.market_id
    left join pg on pg.product_key = f.pk_team
    where f.staff_id = p_staff
      and coalesce(f.status, 0) not in (6, 7)
      and (p_market is null or f.market_id = any(string_to_array(p_market, ',')))
      and (p_channel is null or f.channel_id = any(string_to_array(p_channel, ',')) or ('__none' = any(string_to_array(p_channel, ',')) and f.channel_id is null))
  ),
  oa as (select d, grp, sum(n)::bigint as n, sum(rev) as rev from o group by 1, 2),
  a as (
    select x.day as d, pg.grp, sum(x.usd) as usd
    from public.ad_spend_alloc((p_from at time zone 'Asia/Ho_Chi_Minh')::date, (p_to at time zone 'Asia/Ho_Chi_Minh')::date) x left join pg on pg.product_key = x.product_key
    where x.staff_id = p_staff
      and (p_channel is null or x.channel_id = any(string_to_array(p_channel, ',')) or ('__none' = any(string_to_array(p_channel, ',')) and coalesce(x.channel_id, '') = ''))
      and x.day >= (p_from at time zone 'Asia/Ho_Chi_Minh')::date and x.day < (p_to at time zone 'Asia/Ho_Chi_Minh')::date
    group by 1, 2
  )
  select coalesce(oa.d, a.d), coalesce(oa.grp, a.grp), coalesce(oa.n, 0), coalesce(oa.rev, 0), coalesce(a.usd, 0)
  from oa full join a on a.d = oa.d and a.grp is not distinct from oa.grp
  where public.can_see_staff(p_staff);
end $$;

create or replace function public.kpi_report(p_from timestamptz, p_to timestamptz, p_mode text default 'ads', p_project text default null,
  p_market text default null, p_channel text default null)
returns table (who text, product_key text, product text, grp smallint, orders bigint, sent numeric, ret numeric, ok numeric,
               cogs numeric, cogs_missing bigint, ship_rate numeric, ad_usd numeric, ok_n bigint, ret_n bigint, platform_fee numeric)
language plpgsql stable security definer set search_path = public set plan_cache_mode = force_custom_plan as $$
#variable_conflict use_column
begin
  return query
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
    select f.staff_id, f.project_id, f.status, f.n, coalesce(m.rate_vnd, 1) as rate,
           f.rev * coalesce(m.rate_vnd, 1) as cod_vnd,
           f.fee * coalesce(m.rate_vnd, 1) as fee_vnd,
           f.cogs, f.miss0,
           coalesce(f.pname, '(không rõ sản phẩm)') as name
    from public.order_facts((p_from at time zone 'Asia/Ho_Chi_Minh')::date, (p_to at time zone 'Asia/Ho_Chi_Minh')::date) f
    left join public.markets m on m.id = f.market_id
    , sc
    where coalesce(f.status, 0) not in (6, 7)
      and (p_mode = 'rd' or p_project is null or f.project_id = p_project)
      and (p_market is null or f.market_id = any(string_to_array(p_market, ',')))
      and (p_channel is null or f.channel_id = any(string_to_array(p_channel, ',')) or ('__none' = any(string_to_array(p_channel, ',')) and f.channel_id is null))
      and (p_mode = 'rd'
           or sc.scope = 'all'
           or (sc.scope = 'project' and f.project_id = any(sc.project_ids))
           or (sc.scope = 'team' and f.team_id = sc.team_id)
           or (sc.scope = 'self' and f.staff_id = sc.staff_id))
  ),
  ol as (
    select case when p_mode = 'rd' then pg.rd_staff_id else o.staff_id end as who, lower(o.name) as pk, max(o.name) as product,
           sum(o.n)::bigint as orders, sum(o.cod_vnd) as sent,
           sum(o.cod_vnd) filter (where o.status in (4, 5, 15)) as ret,
           sum(o.cod_vnd) filter (where o.status in (3, 16)) as ok,
           sum(o.cogs) filter (where o.status in (3, 16)) as cogs,
           (sum(o.miss0) filter (where o.status in (3, 16)))::bigint as cogs_missing,
           sum(o.n * o.rate) as ship_rate,
           (sum(o.n) filter (where o.status in (3, 16)))::bigint as ok_n,
           (sum(o.n) filter (where o.status in (4, 5, 15)))::bigint as ret_n,
           sum(o.fee_vnd) filter (where o.status in (3, 16)) as fee
    from o left join pg on pg.product_key = lower(o.name)
    group by 1, 2
  ),
  a as (
    select case when p_mode = 'rd' then pg.rd_staff_id else x.staff_id end as who, x.product_key as pk,
           max(x.product_name) as product, sum(x.usd) as usd
    from public.ad_spend_alloc((p_from at time zone 'Asia/Ho_Chi_Minh')::date, (p_to at time zone 'Asia/Ho_Chi_Minh')::date) x
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
  where sc.scope = 'all' or j.who in (select id from vis);
end $$;

-- Tự kiểm tra: chia xong tổng chi phí không đổi (theo nhân sự × ngày × kênh, 90 ngày gần nhất).
do $$
declare bad bigint; d0 date := current_date - 90; d1 date := current_date + 1;
begin
  select count(*) into bad from (
    select coalesce(a.staff_id, b.staff_id), coalesce(a.day, b.day), coalesce(a.channel_id, b.channel_id)
    from (select staff_id, day, channel_id, sum(usd) as usd from public.ad_spend where day >= d0 and day < d1 group by 1, 2, 3) a
    full join (select staff_id, day, channel_id, sum(usd) as usd from public.ad_spend_alloc(d0, d1) group by 1, 2, 3) b
      on a.staff_id = b.staff_id and a.day = b.day and a.channel_id is not distinct from b.channel_id
    where a.usd is null or b.usd is null or abs(a.usd - b.usd) > 0.000001
  ) x;
  if bad > 0 then
    raise exception 'Kiểm tra không khớp (% nhóm nhân sự × ngày lệch tổng chi phí), đã huỷ toàn bộ thay đổi. Gửi dòng này cho người phát triển.', bad;
  end if;
end $$;

commit;
