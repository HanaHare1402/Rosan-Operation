-- Vai trò "Ban lãnh đạo": xem mọi màn báo cáo và mọi số (cả giá vốn, % Net) trong phạm vi được gán, KHÔNG sửa được gì.
--   Chỉ đọc là nhờ các policy ghi hiện có chỉ cho admin / quản lý / kế toán / trưởng team / marketing; vai trò mới không nằm trong đó.
--   Ở đây chỉ mở thêm quyền ĐỌC số chi phí (giá vốn, chi phí ngoài đơn hàng) cho vai trò mới.
-- Chạy lại nhiều lần không lỗi. So sánh vai trò bằng chữ để dùng được ngay trong cùng lần chạy với lệnh thêm giá trị enum.

alter type public.app_role add value if not exists 'lanh_dao';

-- Ai được xem giá vốn / chi phí: admin, quản lý, kế toán, ban lãnh đạo.
create or replace function public.sees_cost() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role::text from public.profiles where id = auth.uid()) in ('admin','quan_ly','ke_toan','lanh_dao'), false)
$$;
revoke all on function public.sees_cost() from public, anon;
grant execute on function public.sees_cost() to authenticated;

-- Số liệu bảng điều hành: giá vốn trả về cho người xem được chi phí (thêm ban lãnh đạo).
create or replace function public.dash_orders(p_from timestamptz, p_to timestamptz, p_project text default null, p_market text default null, p_channel text default null)
returns table (day date, project_id text, team_id text, staff_id text, marketer text, channel_id text, market_id text, shop_id text,
               st_group text, orders bigint, revenue_vnd numeric, cod_vnd numeric, cogs_vnd numeric, cogs_missing bigint)
language sql stable security invoker set search_path = public as $$
  select (o.inserted_at at time zone coalesce(m.timezone, 'Asia/Ho_Chi_Minh'))::date,
         o.project_id, o.team_id, o.staff_id, coalesce(o.marketer_name, o.seller_name), o.channel_id, o.market_id, o.shop_id,
         case when o.status in (3,16) then 'ok' when o.status in (4,5,15) then 'ret' when o.status = 2 then 'ship'
              when o.status in (6,7) then 'cancel' else 'new' end,
         count(*), sum(coalesce(o.total_price,0) * coalesce(m.rate_vnd,1)), sum(coalesce(o.cod,0) * coalesce(m.rate_vnd,1)),
         case when (select public.sees_cost()) then sum(coalesce(o.cogs_vnd,0)) end,
         case when (select public.sees_cost()) then count(*) filter (where coalesce(o.cogs_missing,1) > 0) end
  from public.orders o left join public.markets m on m.id = o.market_id
  where o.inserted_at >= p_from and o.inserted_at < p_to
    and (p_project is null or o.project_id = p_project)
    and (p_market is null or o.market_id = p_market)
    and (p_channel is null or o.channel_id = p_channel)
  group by 1,2,3,4,5,6,7,8,9
$$;

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
         case when (select public.sees_cost()) then sum(l.qty * coalesce(c.cost, 0)) end,
         case when (select public.sees_cost()) then max(c.cost) end
  from l left join c on c.code = l.code and c.name is not distinct from l.name and c.day = l.day
  group by l.code, l.team_id, l.staff_id, l.st_group
$$;

-- Chi phí ngoài đơn hàng (báo cáo kết quả kinh doanh): ban lãnh đạo được đọc, không được sửa.
drop policy if exists pl_other_read on public.pl_other;
create policy pl_other_read on public.pl_other for select to authenticated using ((select public.sees_cost()));
