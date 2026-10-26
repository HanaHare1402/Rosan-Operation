-- KPI lợi nhuận gộp (tính lương) cho nhân viên ADS và R&D, theo bảng "KPI Nhân Viên" / "KPI R&D" trong file Google Sheet.
--   Doanh số gửi đi = COD các đơn tạo trong kỳ (bỏ đơn huỷ / đã xoá), quy ra VNĐ theo tỷ giá thị trường.
--   Doanh số thành công = COD đơn đã giao. LNG = thành công − giá vốn − cước − phí DVVC − phí GIP − fulfill − ads − test − bao bì.
--   Mỗi đơn tính cho sản phẩm chính (dòng hàng giá trị lớn nhất, không tính hàng tặng), giống file tính theo cột "Sản Phẩm".
-- Chạy sau 20261025060000_cost_match.sql. Chạy lại nhiều lần không lỗi.

-- ---------- thông số từng tháng (kế toán / admin sửa) ----------
create table if not exists public.kpi_settings (
  month date primary key,                       -- ngày 1 của tháng
  ship_local numeric not null default 60,       -- cước / đơn, theo tiền thị trường (peso)
  dvvc_pct numeric not null default 1.12,       -- phí dịch vụ đơn vị vận chuyển, % doanh số thành công
  gip_pct numeric not null default 1.25,        -- phí dịch vụ GIP, % doanh số thành công
  ffm_pct numeric not null default 2.55,        -- phí fulfill, % doanh số gửi đi
  test_pct numeric not null default 0.70,       -- chi phí test, % doanh số gửi đi
  pack_pct numeric not null default 0,          -- chi phí bao bì, % doanh số gửi đi
  usd_vnd numeric not null default 27000,       -- tỷ giá USD cho chi phí quảng cáo
  updated_at timestamptz not null default now()
);
alter table public.kpi_settings enable row level security;
grant select, insert, update, delete on public.kpi_settings to authenticated;
drop policy if exists kpi_settings_read on public.kpi_settings;
create policy kpi_settings_read on public.kpi_settings for select to authenticated using ((select public.my_role()) is not null);
drop policy if exists kpi_settings_write on public.kpi_settings;
create policy kpi_settings_write on public.kpi_settings for all to authenticated
  using ((select public.has_role('admin','ke_toan'))) with check ((select public.has_role('admin','ke_toan')));

-- ---------- nhóm sản phẩm (1 dễ đẩy … 3 khó đẩy) và người R&D, cập nhật theo tháng ----------
-- Tháng chưa khai báo thì dùng giá trị của tháng gần nhất trước đó.
create table if not exists public.product_groups (
  month date not null,
  product_key text not null,                    -- lower(tên sản phẩm trên POS)
  name text not null,
  grp smallint check (grp between 1 and 3),
  rd_staff_id text references public.staff(id) on delete set null,
  updated_at timestamptz not null default now(),
  primary key (month, product_key)
);
alter table public.product_groups enable row level security;
grant select, insert, update, delete on public.product_groups to authenticated;
drop policy if exists product_groups_read on public.product_groups;
create policy product_groups_read on public.product_groups for select to authenticated using ((select public.my_role()) is not null);
drop policy if exists product_groups_write on public.product_groups;
create policy product_groups_write on public.product_groups for all to authenticated
  using ((select public.has_role('admin','quan_ly','ke_toan'))) with check ((select public.has_role('admin','quan_ly','ke_toan')));

-- ---------- chi phí quảng cáo (USD) theo ngày × nhân sự × sản phẩm ----------
create table if not exists public.ad_spend (
  day date not null,
  staff_id text not null references public.staff(id) on delete cascade,
  product_key text not null,
  product_name text not null,
  usd numeric not null check (usd >= 0),
  updated_by uuid default auth.uid(),
  updated_at timestamptz not null default now(),
  primary key (day, staff_id, product_key)
);
create index if not exists ad_spend_product on public.ad_spend (product_key, day);

-- Người xem có được thấy / nhập số của nhân sự này không (theo phạm vi tài khoản).
create or replace function public.can_see_staff(p_staff text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select public.can_see(coalesce(t.project_id, s.project_id), s.team_id, s.id)
    from public.staff s left join public.teams t on t.id = s.team_id where s.id = p_staff), false)
$$;
revoke all on function public.can_see_staff(text) from public, anon;
grant execute on function public.can_see_staff(text) to authenticated;

alter table public.ad_spend enable row level security;
grant select, insert, update, delete on public.ad_spend to authenticated;
drop policy if exists ad_spend_read on public.ad_spend;
create policy ad_spend_read on public.ad_spend for select to authenticated
  using ((select public.has_role('admin','ke_toan')) or public.can_see_staff(staff_id));
drop policy if exists ad_spend_write on public.ad_spend;
create policy ad_spend_write on public.ad_spend for all to authenticated
  using ((select public.has_role('admin','ke_toan'))
         or ((select public.has_role('quan_ly','truong_team','marketing')) and public.can_see_staff(staff_id)))
  with check ((select public.has_role('admin','ke_toan'))
         or ((select public.has_role('quan_ly','truong_team','marketing')) and public.can_see_staff(staff_id)));

-- ---------- danh sách sản phẩm (gợi ý khi nhập chi phí, gán nhóm) ----------
create or replace function public.kpi_products(p_days int default 60)
returns table (product_key text, name text, orders bigint)
language sql stable security definer set search_path = public as $$
  select lower(btrim(i->>'name')), max(btrim(i->>'name')), count(distinct o.pos_order_id)
  from public.orders o cross join lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i
  where o.inserted_at >= now() - make_interval(days => greatest(1, least(p_days, 400)))
    and coalesce(btrim(i->>'name'), '') <> '' and not coalesce((i->>'bonus')::boolean, false)
    and (select public.my_role()) is not null
  group by 1
$$;
revoke all on function public.kpi_products(int) from public, anon;
grant execute on function public.kpi_products(int) to authenticated;

-- ---------- báo cáo KPI ----------
-- p_mode 'ads': gộp theo marketer của đơn. 'rd': gộp theo người R&D phụ trách sản phẩm (đơn của mọi marketer).
-- Trả số gốc (VNĐ); các khoản phí theo % và cước tính ở trang theo thông số tháng.
-- who null: đơn chưa gán nhân sự / sản phẩm chưa gán R&D (chỉ người xem toàn công ty thấy).
drop function if exists public.kpi_report(timestamptz, timestamptz, text, text);
create or replace function public.kpi_report(p_from timestamptz, p_to timestamptz, p_mode text default 'ads', p_project text default null)
returns table (who text, product_key text, product text, grp smallint, orders bigint, sent numeric, ret numeric, ok numeric,
               cogs numeric, cogs_missing bigint, ship_rate numeric, ad_usd numeric)
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
           sum(o.rate) as ship_rate
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
           coalesce(a.usd, 0) as usd
    from ol full join a on a.who is not distinct from ol.who and a.pk = ol.pk
  )
  select j.who, j.pk, j.product, pg.grp, j.orders, j.sent, j.ret, j.ok, j.cogs, j.cogs_missing, j.ship_rate, j.usd
  from j left join pg on pg.product_key = j.pk, sc
  where (j.who is null and sc.scope = 'all') or j.who in (select id from vis)
$$;
revoke all on function public.kpi_report(timestamptz, timestamptz, text, text) from public, anon;
grant execute on function public.kpi_report(timestamptz, timestamptz, text, text) to authenticated;
