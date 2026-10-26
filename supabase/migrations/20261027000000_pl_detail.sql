-- Báo cáo kết quả kinh doanh chi tiết:
--   1) kpi_report trả thêm số đơn đã giao / hoàn để tách cước vận chuyển theo trạng thái đơn.
--   2) pl_other: các khoản ngoài đơn hàng nhập tay theo tháng (chi phí Việt Nam, kho Phil, thu nhập / chi phí khác).
-- Chạy sau 20261026020000_staff_daily.sql. Chạy lại nhiều lần không lỗi.

create table if not exists public.pl_other (
  month date not null,                 -- ngày 1 của tháng
  item text not null,                  -- qldn_vn | nguyen_lieu | luong_vn | kho_phil | thu_nhap_khac | chi_phi_khac
  amount_vnd numeric not null default 0,
  note text,
  updated_at timestamptz not null default now(),
  primary key (month, item)
);
alter table public.pl_other enable row level security;
grant select, insert, update, delete on public.pl_other to authenticated;
drop policy if exists pl_other_read on public.pl_other;
create policy pl_other_read on public.pl_other for select to authenticated using ((select public.has_role('admin','quan_ly','ke_toan')));
drop policy if exists pl_other_write on public.pl_other;
create policy pl_other_write on public.pl_other for all to authenticated
  using ((select public.has_role('admin','ke_toan'))) with check ((select public.has_role('admin','ke_toan')));

drop function if exists public.kpi_report(timestamptz, timestamptz, text, text);
create or replace function public.kpi_report(p_from timestamptz, p_to timestamptz, p_mode text default 'ads', p_project text default null)
returns table (who text, product_key text, product text, grp smallint, orders bigint, sent numeric, ret numeric, ok numeric,
               cogs numeric, cogs_missing bigint, ship_rate numeric, ad_usd numeric, ok_n bigint, ret_n bigint)
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
           coalesce(o.cod, o.total_price, 0) * coalesce(m.rate_vnd, 1) as cod_vnd,
           coalesce(o.cogs_vnd, 0) as cogs, coalesce(o.cogs_missing, 0) as miss,
           coalesce(mp.name, '(không rõ sản phẩm)') as name
    from public.orders o
    left join public.markets m on m.id = o.market_id
    left join lateral (
      select btrim(i->>'name') as name from jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i
      where not coalesce((i->>'bonus')::boolean, false) and coalesce(btrim(i->>'name'), '') <> ''
      order by coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1) desc limit 1
    ) mp on true, sc
    where o.inserted_at >= p_from and o.inserted_at < p_to
      and coalesce(o.status, 0) not in (6, 7)
      and (p_mode = 'rd' or p_project is null or o.project_id = p_project)
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
           count(*) filter (where o.status in (4, 5, 15)) as ret_n
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
    group by 1, 2
  ),
  j as (
    select coalesce(ol.who, a.who) as who, coalesce(ol.pk, a.pk) as pk, coalesce(ol.product, a.product) as product,
           coalesce(ol.orders, 0) as orders, coalesce(ol.sent, 0) as sent, coalesce(ol.ret, 0) as ret, coalesce(ol.ok, 0) as ok,
           coalesce(ol.cogs, 0) as cogs, coalesce(ol.cogs_missing, 0) as cogs_missing, coalesce(ol.ship_rate, 0) as ship_rate,
           coalesce(a.usd, 0) as usd, coalesce(ol.ok_n, 0) as ok_n, coalesce(ol.ret_n, 0) as ret_n
    from ol full join a on a.who is not distinct from ol.who and a.pk = ol.pk
  )
  select j.who, j.pk, j.product, pg.grp, j.orders, j.sent, j.ret, j.ok, j.cogs, j.cogs_missing, j.ship_rate, j.usd, j.ok_n, j.ret_n
  from j left join pg on pg.product_key = j.pk, sc
  where (j.who is null and sc.scope = 'all') or j.who in (select id from vis)
$$;
revoke all on function public.kpi_report(timestamptz, timestamptz, text, text) from public, anon;
grant execute on function public.kpi_report(timestamptz, timestamptz, text, text) to authenticated;
