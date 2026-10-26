-- Bảng theo dõi theo ngày cho một nhân sự (màn Nhân sự): chi phí ads, doanh số, số đơn theo nhóm sản phẩm.
-- Cùng cách tính với team_daily. Chạy sau 20261026010000_team_daily.sql. Chạy lại nhiều lần không lỗi.
drop function if exists public.staff_daily(timestamptz, timestamptz, text);
create or replace function public.staff_daily(p_from timestamptz, p_to timestamptz, p_staff text)
returns table (day date, grp smallint, orders bigint, revenue numeric, ad_usd numeric)
language sql stable security definer set search_path = public as $$
  with mon as (select date_trunc('month', p_from at time zone 'Asia/Ho_Chi_Minh')::date as m),
  pg as (
    select distinct on (g.product_key) g.product_key, g.grp
    from public.product_groups g, mon where g.month <= mon.m
    order by g.product_key, g.month desc
  ),
  o as (
    select (o.inserted_at at time zone coalesce(m.timezone, 'Asia/Ho_Chi_Minh'))::date as d, pg.grp,
           coalesce(o.total_price, 0) * coalesce(m.rate_vnd, 1) as rev
    from public.orders o
    left join public.markets m on m.id = o.market_id
    left join lateral (
      select lower(btrim(i->>'name')) as pk from jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i
      where not coalesce((i->>'bonus')::boolean, false) and coalesce(btrim(i->>'name'), '') <> ''
      order by coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1) desc limit 1
    ) mp on true
    left join pg on pg.product_key = mp.pk
    where o.staff_id = p_staff and o.inserted_at >= p_from and o.inserted_at < p_to
      and coalesce(o.status, 0) not in (6, 7)
  ),
  oa as (select d, grp, count(*) as n, sum(rev) as rev from o group by 1, 2),
  a as (
    select x.day as d, pg.grp, sum(x.usd) as usd
    from public.ad_spend x left join pg on pg.product_key = x.product_key
    where x.staff_id = p_staff
      and x.day >= (p_from at time zone 'Asia/Ho_Chi_Minh')::date and x.day < (p_to at time zone 'Asia/Ho_Chi_Minh')::date
    group by 1, 2
  )
  select coalesce(oa.d, a.d), coalesce(oa.grp, a.grp), coalesce(oa.n, 0), coalesce(oa.rev, 0), coalesce(a.usd, 0)
  from oa full join a on a.d = oa.d and a.grp is not distinct from oa.grp
  where public.can_see_staff(p_staff)
$$;
revoke all on function public.staff_daily(timestamptz, timestamptz, text) from public, anon;
grant execute on function public.staff_daily(timestamptz, timestamptz, text) to authenticated;
