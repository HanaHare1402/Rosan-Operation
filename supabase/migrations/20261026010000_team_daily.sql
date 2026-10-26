-- Bảng theo dõi theo ngày của team / toàn bộ (giống sheet "Team Mừng"): chi phí ads, doanh số, số đơn theo nhóm sản phẩm.
-- Thêm target cho team: trần % chi phí ads, target doanh số nhóm 2.
-- Chạy sau 20261026000000_kpi.sql. Chạy lại nhiều lần không lỗi.

alter table public.teams add column if not exists ads_pct_max numeric;      -- VD 27 (%): chi phí ads / doanh số không quá mức này
alter table public.teams add column if not exists target_g2_vnd numeric;    -- target doanh số sản phẩm nhóm 2 / tháng

-- Mỗi dòng: ngày × team × nhóm sản phẩm. Đơn tính cho sản phẩm chính (như KPI), doanh số = tiền đơn (trừ huỷ) quy VNĐ;
-- chi phí ads (USD) theo team của nhân sự nhập. Nhóm sản phẩm theo tháng của ngày bắt đầu kỳ.
drop function if exists public.team_daily(timestamptz, timestamptz, text, text);
create or replace function public.team_daily(p_from timestamptz, p_to timestamptz, p_project text default null, p_team text default null)
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
    select (o.inserted_at at time zone coalesce(m.timezone, 'Asia/Ho_Chi_Minh'))::date as d, o.team_id, pg.grp,
           coalesce(o.total_price, 0) * coalesce(m.rate_vnd, 1) as rev
    from public.orders o
    left join public.markets m on m.id = o.market_id
    left join lateral (
      select lower(btrim(i->>'name')) as pk from jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i
      where not coalesce((i->>'bonus')::boolean, false) and coalesce(btrim(i->>'name'), '') <> ''
      order by coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1) desc limit 1
    ) mp on true
    left join pg on pg.product_key = mp.pk, sc
    where o.inserted_at >= p_from and o.inserted_at < p_to
      and coalesce(o.status, 0) not in (6, 7)
      and (p_project is null or o.project_id = p_project)
      and (p_team is null or o.team_id = p_team)
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
revoke all on function public.team_daily(timestamptz, timestamptz, text, text) from public, anon;
grant execute on function public.team_daily(timestamptz, timestamptz, text, text) to authenticated;
