-- Bảng tổng hợp sẵn theo ngày (order_daily) cho Tổng quan / Team / Nhân sự (dash_orders),
-- bảng Theo dõi theo ngày (team_daily, staff_daily) và KPI / Kết quả kinh doanh (kpi_report).
--
-- Cách làm:
--   * order_daily: mỗi dòng = tổng các đơn cùng ngày × cửa hàng × dự án × team × nhân sự × marketer × kênh ×
--     thị trường × trạng thái × sản phẩm chính. Tiền lưu theo tiền gốc của đơn, nhân tỷ giá lúc xem (đổi tỷ giá
--     không cần tổng hợp lại). Báo cáo cộng vài nghìn dòng thay vì cả trăm nghìn / cả triệu đơn.
--   * order_daily_dirty: (ngày, cửa hàng) có đơn vừa thêm / sửa / xoá. Báo cáo đọc bảng tổng cho phần đã tổng hợp
--     và tính thẳng từ đơn cho phần vừa đổi, nên số luôn đúng ngay, kể cả khi chưa kịp tổng hợp lại.
--   * order_daily_refresh(): tổng hợp lại các (ngày, cửa hàng) đã đổi, chạy dần sau mỗi lần đồng bộ POS.
--
-- File này nhẹ: chỉ đánh dấu mọi ngày là "cần tổng hợp" rồi tổng hợp 3 ngày gần nhất để tự kiểm tra.
-- Phần còn lại được tổng hợp dần sau mỗi lần đồng bộ (vài phút / lần), không làm nghẽn máy chủ.
-- Tự kiểm tra: so 4 báo cáo mới với cách tính cũ trên 3 ngày gần nhất; lệch thì huỷ cả file.
-- Chạy sau 20261112020000_order_lines.sql. Chạy lại nhiều lần không lỗi.

begin;
set local statement_timeout = '5min';

create table if not exists public.order_daily (
  day date not null,
  shop_id text not null,
  project_id text,
  team_id text,
  staff_id text,
  marketer text,
  channel_id text,
  market_id text,
  status int,
  pk_team text,     -- khoá sản phẩm chính (chữ thường) dùng cho bảng theo ngày
  pname text,       -- tên sản phẩm chính dùng cho KPI / KQKD
  n bigint not null,
  rev numeric not null,   -- COD (không có thì giá trị đơn) + phí sàn, tiền gốc
  cod numeric not null,
  fee numeric not null,   -- phí sàn, tiền gốc
  cogs numeric not null,  -- giá vốn (VNĐ)
  miss1 bigint not null,  -- số đơn thiếu giá vốn (chưa tính coi như thiếu)
  miss0 bigint not null   -- số đơn thiếu giá vốn (chưa tính coi như đủ)
);
create index if not exists order_daily_day on public.order_daily (day);
create index if not exists order_daily_shop_day on public.order_daily (shop_id, day);
alter table public.order_daily enable row level security;
revoke all on public.order_daily from public, anon, authenticated;

create sequence if not exists public.order_daily_seq;
create table if not exists public.order_daily_dirty (
  day date not null,
  shop_id text not null,
  seq bigint not null default nextval('public.order_daily_seq'),
  primary key (day, shop_id)
);
alter table public.order_daily_dirty enable row level security;
revoke all on public.order_daily_dirty from public, anon, authenticated;
revoke all on sequence public.order_daily_seq from public, anon, authenticated;

-- Tổng hợp các đơn theo khoá của order_daily (đơn đã xoá trên POS - trạng thái 7 - không tính, như mọi báo cáo).
-- Một cửa hàng, khoảng ngày [p_d1, p_d2).
drop function if exists public.order_daily_agg(date, date, text, boolean);
create or replace function public.order_daily_agg(p_d1 date, p_d2 date, p_shop text)
returns setof public.order_daily
language sql stable as $$  -- không đặt search_path để Postgres gộp được vào câu hỏi của báo cáo (tên bảng đã ghi đủ public.)
  select o.local_day, o.shop_id, o.project_id, o.team_id, o.staff_id, coalesce(o.marketer_name, o.seller_name),
         o.channel_id, o.market_id, o.status,
         coalesce(o.main_pk, (select lower(btrim(i->>'name')) from jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i where not coalesce((i->>'bonus')::boolean, false) and coalesce(btrim(i->>'name'), '') <> '' order by coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1) desc limit 1)),
         coalesce(o.main_name, (select btrim(i->>'name') from jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i where not coalesce((i->>'bonus')::boolean, false) and coalesce(btrim(i->>'name'), '') <> '' order by coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1) desc limit 1)),
         count(*), sum(coalesce(o.cod, o.total_price, 0) + coalesce(o.platform_fee, 0)), sum(coalesce(o.cod, 0)),
         sum(coalesce(o.platform_fee, 0)), sum(coalesce(o.cogs_vnd, 0)),
         count(*) filter (where coalesce(o.cogs_missing, 1) > 0), count(*) filter (where coalesce(o.cogs_missing, 0) > 0)
  from public.orders o
  where o.local_day >= p_d1 and o.local_day < p_d2
    and coalesce(o.status, 0) <> 7
    and o.shop_id = p_shop
  group by 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11
$$;
revoke all on function public.order_daily_agg(date, date, text) from public, anon, authenticated;

-- Số liệu đơn cho báo cáo: phần đã tổng hợp đọc từ order_daily, phần vừa đổi tính thẳng từ đơn (cùng một lần đọc).
create or replace function public.order_facts(p_d1 date, p_d2 date)
returns setof public.order_daily
language sql stable as $$  -- không đặt search_path để Postgres gộp được vào câu hỏi của báo cáo (tên bảng đã ghi đủ public.)
  select r.* from public.order_daily r
  where r.day >= p_d1 and r.day < p_d2
    and not exists (select 1 from public.order_daily_dirty d where d.day = r.day and d.shop_id = r.shop_id)
  union all
  select a.* from public.order_daily_dirty d
  cross join lateral public.order_daily_agg(d.day, d.day + 1, d.shop_id) a
  where d.day >= p_d1 and d.day < p_d2
$$;
revoke all on function public.order_facts(date, date) from public, anon, authenticated;

-- Đánh dấu (ngày, cửa hàng) cần tổng hợp lại khi đơn thêm / sửa / xoá.
create or replace function public.order_daily_mark() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into public.order_daily_dirty (day, shop_id)
    select distinct n.local_day, n.shop_id from new_rows n where n.local_day is not null
    order by 1, 2   -- luôn khoá theo cùng một thứ tự: hai lần ghi song song không chặn chéo nhau
    on conflict (day, shop_id) do update set seq = nextval('public.order_daily_seq');
  elsif tg_op = 'DELETE' then
    insert into public.order_daily_dirty (day, shop_id)
    select distinct o.local_day, o.shop_id from old_rows o where o.local_day is not null
    order by 1, 2
    on conflict (day, shop_id) do update set seq = nextval('public.order_daily_seq');
  else
    insert into public.order_daily_dirty (day, shop_id)
    select distinct x.day, x.shop_id from (
      select n.local_day as day, n.shop_id, o.local_day as oday, o.shop_id as oshop
      from new_rows n join old_rows o on o.shop_id = n.shop_id and o.pos_order_id = n.pos_order_id
      where (n.local_day, n.shop_id, n.project_id, n.team_id, n.staff_id, n.marketer_name, n.seller_name, n.channel_id,
             n.market_id, n.status, n.main_pk, n.main_name, n.cod, n.total_price, n.platform_fee, n.cogs_vnd, n.cogs_missing)
            is distinct from
            (o.local_day, o.shop_id, o.project_id, o.team_id, o.staff_id, o.marketer_name, o.seller_name, o.channel_id,
             o.market_id, o.status, o.main_pk, o.main_name, o.cod, o.total_price, o.platform_fee, o.cogs_vnd, o.cogs_missing)
         or ((n.main_pk is null or n.main_name is null) and n.items is distinct from o.items)
    ) c cross join lateral (values (c.day, c.shop_id), (c.oday, c.oshop)) x(day, shop_id)
    where x.day is not null
    order by 1, 2
    on conflict (day, shop_id) do update set seq = nextval('public.order_daily_seq');
  end if;
  return null;
end $$;
revoke all on function public.order_daily_mark() from public, anon, authenticated;

drop trigger if exists orders_daily_ins on public.orders;
drop trigger if exists orders_daily_upd on public.orders;
drop trigger if exists orders_daily_del on public.orders;
create trigger orders_daily_ins after insert on public.orders referencing new table as new_rows
  for each statement execute function public.order_daily_mark();
create trigger orders_daily_upd after update on public.orders referencing old table as old_rows new table as new_rows
  for each statement execute function public.order_daily_mark();
create trigger orders_daily_del after delete on public.orders referencing old table as old_rows
  for each statement execute function public.order_daily_mark();

-- Tổng hợp lại các (ngày, cửa hàng) đã đổi, mới nhất trước, trong tối đa p_ms mili giây.
-- Khoá dòng đánh dấu khi đang làm: đơn đổi trong lúc đó sẽ đánh dấu lại sau, không bị sót.
create or replace function public.order_daily_refresh(p_ms int default 3000, p_since date default null)
returns table (done int, remaining bigint)
language plpgsql security definer set search_path = public as $$
declare r record; k int := 0; t0 timestamptz := clock_timestamp();
begin
  if auth.uid() is not null and not public.has_role('admin', 'quan_ly', 'ke_toan') then
    raise exception 'Không có quyền' using errcode = '42501';
  end if;
  for r in
    select d.day, d.shop_id, d.seq from public.order_daily_dirty d
    where p_since is null or d.day >= p_since
    order by d.day desc
    for update skip locked
  loop
    delete from public.order_daily where day = r.day and shop_id = r.shop_id;
    insert into public.order_daily select * from public.order_daily_agg(r.day, r.day + 1, r.shop_id);
    delete from public.order_daily_dirty where day = r.day and shop_id = r.shop_id and seq = r.seq;
    k := k + 1;
    exit when clock_timestamp() - t0 > make_interval(secs => greatest(p_ms, 200) / 1000.0);
  end loop;
  return query select k, (select count(*) from public.order_daily_dirty);
end $$;
revoke all on function public.order_daily_refresh(int, date) from public, anon;
grant execute on function public.order_daily_refresh(int, date) to authenticated, service_role;

-- Đơn đã có: đánh dấu mọi (ngày, cửa hàng) là cần tổng hợp (nhẹ: chỉ vài trăm dòng).
insert into public.order_daily_dirty (day, shop_id)
select distinct local_day, shop_id from public.orders where local_day is not null
on conflict (day, shop_id) do nothing;

-- ---------- giữ lại cách tính cũ (tạm, trong phiên này) để tự kiểm tra ----------
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

-- ---------- báo cáo mới: đọc order_facts ----------
-- Quyền xem: giống hệt quyền xem đơn (orders_select) / phạm vi cũ của từng hàm.
-- plpgsql + force_custom_plan: lập kế hoạch theo đúng khoảng ngày được hỏi (kế hoạch chung chung đoán sai số dòng, chậm gấp nhiều lần).

create or replace function public.dash_orders(p_from timestamptz, p_to timestamptz, p_project text default null, p_market text default null, p_channel text default null)
returns table (day date, project_id text, team_id text, staff_id text, marketer text, channel_id text, market_id text, shop_id text,
               st_group text, orders bigint, revenue_vnd numeric, cod_vnd numeric, cogs_vnd numeric, cogs_missing bigint)
language plpgsql stable security definer set search_path = public set plan_cache_mode = force_custom_plan as $$
#variable_conflict use_column
begin
  return query
  with sc as (select * from public.my_scope() limit 1)
  select f.day, f.project_id, f.team_id, f.staff_id, f.marketer, f.channel_id, f.market_id, f.shop_id,
         case when f.status in (3,16) then 'ok' when f.status in (4,5,15) then 'ret' when f.status = 2 then 'ship'
              when f.status = 6 then 'cancel' else 'new' end,
         sum(f.n)::bigint, sum(f.rev * coalesce(m.rate_vnd, 1)), sum(f.cod * coalesce(m.rate_vnd, 1)),
         case when (select public.sees_cost()) then sum(f.cogs) end,
         case when (select public.sees_cost()) then sum(f.miss1)::bigint end
  from public.order_facts((p_from at time zone 'Asia/Ho_Chi_Minh')::date, (p_to at time zone 'Asia/Ho_Chi_Minh')::date) f
  left join public.markets m on m.id = f.market_id
  cross join sc
  where (p_project is null or f.project_id = p_project)
    and (p_market is null or f.market_id = any(string_to_array(p_market, ',')))
    and (p_channel is null or f.channel_id = any(string_to_array(p_channel, ',')) or ('__none' = any(string_to_array(p_channel, ',')) and f.channel_id is null))
    and case sc.scope
          when 'all' then true
          when 'project' then array[f.project_id] <@ sc.project_ids
          when 'team' then f.team_id = sc.team_id
          when 'self' then f.staff_id = sc.staff_id
          else false
        end
  group by 1,2,3,4,5,6,7,8,9;
end $$;

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
    from public.ad_spend x left join pg on pg.product_key = x.product_key
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
  where sc.scope = 'all' or j.who in (select id from vis);
end $$;

-- ---------- tự kiểm tra: tổng hợp 3 ngày gần nhất rồi so báo cáo mới với cách cũ ----------
do $$
declare
  uid uuid; d0 date := (now() at time zone 'Asia/Ho_Chi_Minh')::date - 3;
  f timestamptz; t timestamptz; st text; bad bigint; what text := '';
begin
  perform public.order_daily_refresh(240000, d0);
  select p.id into uid from public.profiles p where p.role = 'admin' and p.scope = 'all' limit 1;
  if uid is null then raise notice 'Không có tài khoản admin để tự kiểm tra, bỏ qua.'; return; end if;
  perform set_config('request.jwt.claim.sub', uid::text, true);
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  f := (d0::timestamp) at time zone 'Asia/Ho_Chi_Minh'; t := ((d0 + 4)::timestamp) at time zone 'Asia/Ho_Chi_Minh';
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
    raise exception 'Kiểm tra không khớp, đã huỷ toàn bộ thay đổi. Gửi dòng này cho người phát triển:%', what;
  end if;
end $$;

commit;
