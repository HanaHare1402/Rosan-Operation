-- KIỂM TRA (không thay đổi dữ liệu): so 4 báo cáo đang dùng (đọc bảng tổng hợp order_daily) với cách tính cũ
-- (cộng thẳng từ từng đơn) trên TOÀN BỘ tháng trước và tháng này: Tổng quan, Theo dõi theo ngày (team + nhân sự nhiều đơn nhất),
-- KPI / KQKD (theo người chạy ads và theo R&D).
-- Kết quả: một dòng "Khớp hoàn toàn", hoặc báo lỗi "KHÔNG KHỚP" kèm báo cáo lệch.
-- Nên chạy lúc ít người dùng (đọc toàn bộ đơn 2 tháng, có thể mất 10–60 giây). Chạy bao nhiêu lần cũng được.

begin;
set local statement_timeout = '5min';

create or replace function pg_temp.dash_orders_v1(p_from timestamptz, p_to timestamptz, p_project text default null, p_market text default null, p_channel text default null)
returns table (day date, project_id text, team_id text, staff_id text, marketer text, channel_id text, market_id text, shop_id text,
               st_group text, orders bigint, revenue_vnd numeric, cod_vnd numeric, cogs_vnd numeric, cogs_missing bigint)
language sql stable as $$
  select o.local_day,
         o.project_id, o.team_id, o.staff_id, coalesce(o.marketer_name, o.seller_name), o.channel_id, o.market_id, o.shop_id,
         case when o.status in (3,16) then 'ok' when o.status in (4,5,15) then 'ret' when o.status = 2 then 'ship'
              when o.status = 6 then 'cancel' else 'new' end,
         count(*), sum((coalesce(o.cod, o.total_price, 0) + coalesce(o.platform_fee, 0)) * coalesce(m.rate_vnd,1)), sum(coalesce(o.cod,0) * coalesce(m.rate_vnd,1)),
         case when (select public.sees_cost()) then sum(coalesce(o.cogs_vnd,0)) end,
         case when (select public.sees_cost()) then count(*) filter (where coalesce(o.cogs_missing,1) > 0) end
  from public.orders o left join public.markets m on m.id = o.market_id
  where o.local_day >= (p_from at time zone 'Asia/Ho_Chi_Minh')::date and o.local_day < (p_to at time zone 'Asia/Ho_Chi_Minh')::date
    and coalesce(o.status, 0) <> 7
    and (p_project is null or o.project_id = p_project)
    and (p_market is null or o.market_id = any(string_to_array(p_market, ',')))
    and (p_channel is null or o.channel_id = any(string_to_array(p_channel, ',')) or ('__none' = any(string_to_array(p_channel, ',')) and o.channel_id is null))
  group by 1,2,3,4,5,6,7,8,9
$$;

create or replace function pg_temp.team_daily_v1(p_from timestamptz, p_to timestamptz, p_project text default null, p_team text default null,
  p_market text default null, p_channel text default null)
returns table (day date, team_id text, grp smallint, orders bigint, revenue numeric, ad_usd numeric)
language sql stable as $$
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

create or replace function pg_temp.staff_daily_v1(p_from timestamptz, p_to timestamptz, p_staff text,
  p_market text default null, p_channel text default null)
returns table (day date, grp smallint, orders bigint, revenue numeric, ad_usd numeric)
language sql stable as $$
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

create or replace function pg_temp.kpi_report_v1(p_from timestamptz, p_to timestamptz, p_mode text default 'ads', p_project text default null,
  p_market text default null, p_channel text default null)
returns table (who text, product_key text, product text, grp smallint, orders bigint, sent numeric, ret numeric, ok numeric,
               cogs numeric, cogs_missing bigint, ship_rate numeric, ad_usd numeric, ok_n bigint, ret_n bigint, platform_fee numeric)
language sql stable as $$
  with sc as (select * from public.my_scope() limit 1),
  mon as (select date_trunc('month', p_from at time zone 'Asia/Ho_Chi_Minh')::date as m),
  pg as (
    select distinct on (g.product_key) g.product_key, g.grp, g.rd_staff_id
    from public.product_groups g, mon where g.month <= mon.m
    order by g.product_key, g.month desc
  ),
  vis as (
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
  where sc.scope = 'all' or j.who in (select id from vis)
$$;

do $$
declare
  uid uuid; d0 date := (date_trunc('month', now() at time zone 'Asia/Ho_Chi_Minh') - interval '1 month')::date;
  d1 date := (now() at time zone 'Asia/Ho_Chi_Minh')::date + 1;
  f timestamptz; t timestamptz; st text; bad bigint; what text := '';
begin
  select p.id into uid from public.profiles p where p.role = 'admin' and p.scope = 'all' limit 1;
  if uid is null then raise exception 'Không tìm thấy tài khoản admin xem toàn công ty để kiểm tra.'; end if;
  perform set_config('request.jwt.claim.sub', uid::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  f := (d0::timestamp) at time zone 'Asia/Ho_Chi_Minh'; t := (d1::timestamp) at time zone 'Asia/Ho_Chi_Minh';
  select o.staff_id into st from public.orders o where o.local_day >= d0 and o.staff_id is not null group by 1 order by count(*) desc limit 1;

  select count(*) into bad from ((select * from public.dash_orders(f, t) except all select * from pg_temp.dash_orders_v1(f, t))
                                 union all (select * from pg_temp.dash_orders_v1(f, t) except all select * from public.dash_orders(f, t))) x;
  if bad > 0 then what := what || ' Tổng quan: ' || bad || ' dòng;'; end if;
  select count(*) into bad from ((select * from public.team_daily(f, t) except all select * from pg_temp.team_daily_v1(f, t))
                                 union all (select * from pg_temp.team_daily_v1(f, t) except all select * from public.team_daily(f, t))) x;
  if bad > 0 then what := what || ' Theo dõi ngày (team): ' || bad || ' dòng;'; end if;
  if st is not null then
    select count(*) into bad from ((select * from public.staff_daily(f, t, st) except all select * from pg_temp.staff_daily_v1(f, t, st))
                                   union all (select * from pg_temp.staff_daily_v1(f, t, st) except all select * from public.staff_daily(f, t, st))) x;
    if bad > 0 then what := what || ' Theo dõi ngày (nhân sự): ' || bad || ' dòng;'; end if;
  end if;
  select count(*) into bad from ((select * from public.kpi_report(f, t) except all select * from pg_temp.kpi_report_v1(f, t))
                                 union all (select * from pg_temp.kpi_report_v1(f, t) except all select * from public.kpi_report(f, t))) x;
  if bad > 0 then what := what || ' KPI: ' || bad || ' dòng;'; end if;
  select count(*) into bad from ((select * from public.kpi_report(f, t, 'rd') except all select * from pg_temp.kpi_report_v1(f, t, 'rd'))
                                 union all (select * from pg_temp.kpi_report_v1(f, t, 'rd') except all select * from public.kpi_report(f, t, 'rd'))) x;
  if bad > 0 then what := what || ' KPI R&D: ' || bad || ' dòng;'; end if;

  if what <> '' then
    raise exception 'KHÔNG KHỚP. Gửi dòng này cho người phát triển:%', what;
  end if;
end $$;


commit;
select 'Khớp hoàn toàn' as ket_qua, (select count(*) from public.order_daily_dirty) as ngay_chua_tong_hop;
