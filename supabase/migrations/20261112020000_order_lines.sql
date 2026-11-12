-- Tăng tốc bảng sản phẩm (dash_products): tách sẵn từng dòng sản phẩm của đơn vào bảng order_lines.
--   * Trước: mỗi lần mở báo cáo, máy chủ mở JSON dòng hàng của toàn bộ đơn trong kỳ và chia doanh số lại từ đầu.
--   * Sau: dòng hàng được tách sẵn lúc đơn được ghi / sửa (trigger), báo cáo chỉ cộng số.
--   * Chỉ tách phần thuộc về chính dòng hàng (mã, tên, số lượng, phần doanh số theo tiền gốc, đơn giá vốn).
--     Team, nhân sự, trạng thái, ngày, thị trường, tỷ giá vẫn đọc trực tiếp từ đơn lúc xem, nên chuyển team,
--     đổi trạng thái, đổi tỷ giá... không cần cập nhật bảng này.
--   * Cuối file có bước tự kiểm tra: so cách tính mới với cách tính cũ trên TOÀN BỘ đơn; lệch dù 1 dòng thì
--     cả file bị huỷ (không thay đổi gì), web giữ nguyên cách tính cũ.
-- Chạy sau 20261112010000_security_hardening.sql. Chạy lại nhiều lần không lỗi. Có thể mất 1–3 phút.

begin;
set local statement_timeout = '15min';

create table if not exists public.order_lines (
  shop_id text not null,
  pos_order_id text not null,
  n int not null,                 -- thứ tự dòng trong đơn
  code text not null,             -- mã sản phẩm (không có mã thì lấy tên)
  name text,
  qty numeric not null,
  rev numeric not null,           -- phần doanh số của dòng, theo tiền của đơn (chưa nhân tỷ giá)
  ucost numeric,                  -- đơn giá vốn: lấy từ dòng hàng (ucost); đơn cũ chưa ghi thì tra bảng nhập hàng lúc tách
  has_ucost boolean not null,     -- dòng hàng đã có sẵn đơn giá vốn hay phải tra
  first_of_code boolean not null, -- dòng đầu tiên của mã này trong đơn: đếm số đơn theo mã mà không phải đếm trùng
  cost_day date,                  -- ngày tra giá vốn (ngày tạo đơn, giờ VN)
  primary key (shop_id, pos_order_id, n),
  foreign key (shop_id, pos_order_id) references public.orders (shop_id, pos_order_id) on delete cascade
);
-- Bảng nội bộ: không ai đọc trực tiếp, chỉ đọc qua hàm báo cáo (đã lọc theo quyền xem).
alter table public.order_lines enable row level security;
revoke all on public.order_lines from public, anon, authenticated;

-- Tách dòng hàng của một đơn. Công thức giống hệt dash_products cũ.
create or replace function public.order_lines_build(o public.orders)
returns table (n int, code text, name text, qty numeric, rev numeric, ucost numeric, has_ucost boolean, first_of_code boolean, cost_day date)
language sql stable set search_path = public as $$
  with it as (select case when jsonb_typeof(o.items) = 'array' then o.items else '[]'::jsonb end as items),
  g as (
    select (select sum(coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1))
            from it, jsonb_array_elements(it.items) i) as gross
  )
  select t.n::int,
         coalesce(nullif(t.i->>'code', ''), t.i->>'name', '?'),
         t.i->>'name',
         coalesce((t.i->>'quantity')::numeric, 1),
         case when coalesce(g.gross, 0) > 0
              then coalesce((t.i->>'price')::numeric, 0) * coalesce((t.i->>'quantity')::numeric, 1) / g.gross
                   * (coalesce(o.cod, o.total_price, g.gross, 0) + coalesce(o.platform_fee, 0))
              else 0 end,
         -- Khi giá nhập đổi, mọi đơn được tính lại (ghi ucost mới) nên dòng tách sẵn cũng được làm mới theo.
         case when t.i ? 'ucost' then (t.i->>'ucost')::numeric
              else public.cost_at(coalesce(nullif(t.i->>'code', ''), t.i->>'name', '?'), t.i->>'name', (o.inserted_at at time zone 'Asia/Ho_Chi_Minh')::date) end,
         t.i ? 'ucost',
         row_number() over (partition by coalesce(nullif(t.i->>'code', ''), t.i->>'name', '?') order by t.n) = 1,
         (o.inserted_at at time zone 'Asia/Ho_Chi_Minh')::date
  from it, g, jsonb_array_elements(it.items) with ordinality t(i, n)
$$;
revoke all on function public.order_lines_build(public.orders) from public, anon, authenticated;

-- Giữ order_lines khớp với đơn: đơn mới hoặc đổi dòng hàng / COD / giá trị / phí sàn / ngày tạo thì tách lại.
create or replace function public.order_lines_sync() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'UPDATE' then
    delete from public.order_lines where shop_id = new.shop_id and pos_order_id = new.pos_order_id;
  end if;
  insert into public.order_lines (shop_id, pos_order_id, n, code, name, qty, rev, ucost, has_ucost, first_of_code, cost_day)
  select new.shop_id, new.pos_order_id, b.n, b.code, b.name, b.qty, b.rev, b.ucost, b.has_ucost, b.first_of_code, b.cost_day
  from public.order_lines_build(new) b
  on conflict (shop_id, pos_order_id, n) do update
    set code = excluded.code, name = excluded.name, qty = excluded.qty, rev = excluded.rev,
        ucost = excluded.ucost, has_ucost = excluded.has_ucost, first_of_code = excluded.first_of_code, cost_day = excluded.cost_day;
  return null;
end $$;
revoke all on function public.order_lines_sync() from public, anon, authenticated;

drop trigger if exists orders_lines on public.orders;
drop trigger if exists orders_lines_ins on public.orders;
drop trigger if exists orders_lines_upd on public.orders;
create trigger orders_lines_ins after insert on public.orders
  for each row execute function public.order_lines_sync();
-- Chỉ chạy khi các cột ảnh hưởng tới dòng hàng thực sự đổi (đánh dấu tính lại, đổi trạng thái... thì bỏ qua).
create trigger orders_lines_upd after update on public.orders
  for each row when (new.items is distinct from old.items or new.cod is distinct from old.cod
                     or new.total_price is distinct from old.total_price or new.platform_fee is distinct from old.platform_fee
                     or new.inserted_at is distinct from old.inserted_at)
  execute function public.order_lines_sync();

-- Tách sẵn cho các đơn đã có (bỏ qua đơn đã tách).
insert into public.order_lines (shop_id, pos_order_id, n, code, name, qty, rev, ucost, has_ucost, first_of_code, cost_day)
select o.shop_id, o.pos_order_id, b.n, b.code, b.name, b.qty, b.rev, b.ucost, b.has_ucost, b.first_of_code, b.cost_day
from public.orders o cross join lateral public.order_lines_build(o) b
where not exists (select 1 from public.order_lines l where l.shop_id = o.shop_id and l.pos_order_id = o.pos_order_id)
on conflict (shop_id, pos_order_id, n) do nothing;

analyze public.order_lines;

-- Tự kiểm tra trên toàn bộ đơn: cách tính mới phải ra đúng như cách tính cũ (từng mã × team × nhân sự × trạng thái).
do $$
declare bad int; sample text;
begin
  with o as (
    select o.*, coalesce(m.rate_vnd, 1) as rate,
           (select sum(coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1)) from jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i) as gross
    from public.orders o left join public.markets m on m.id = o.market_id
    where coalesce(o.status, 0) <> 7
  ), l as (
    select coalesce(nullif(i->>'code', ''), i->>'name', '?') as code, o.team_id, o.staff_id,
           case when o.status in (3,16) then 'ok' when o.status in (4,5,15) then 'ret' when o.status = 2 then 'ship'
                when o.status = 6 then 'cancel' else 'new' end as st_group,
           o.shop_id, o.pos_order_id, coalesce((i->>'quantity')::numeric, 1) as qty,
           case when coalesce(o.gross, 0) > 0 then coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1) / o.gross * (coalesce(o.cod, o.total_price, o.gross, 0) + coalesce(o.platform_fee, 0)) else 0 end * o.rate as rev,
           case when i ? 'ucost' then (i->>'ucost')::numeric
                else public.cost_at(coalesce(nullif(i->>'code', ''), i->>'name', '?'), i->>'name', (o.inserted_at at time zone 'Asia/Ho_Chi_Minh')::date) end as cost
    from o cross join lateral jsonb_array_elements(case when jsonb_typeof(o.items) = 'array' then o.items else '[]'::jsonb end) i
  ), old_r as (
    select code, team_id, staff_id, st_group, count(distinct (shop_id, pos_order_id)) as orders, sum(qty) as qty, sum(rev) as rev,
           sum(qty * coalesce(cost, 0)) as cogs, max(cost) as unit
    from l group by 1, 2, 3, 4
  ), new_r as (
    select l.code, o.team_id, o.staff_id,
           case when o.status in (3,16) then 'ok' when o.status in (4,5,15) then 'ret' when o.status = 2 then 'ship'
                when o.status = 6 then 'cancel' else 'new' end as st_group,
           count(*) filter (where l.first_of_code) as orders, sum(l.qty) as qty, sum(l.rev * coalesce(m.rate_vnd, 1)) as rev,
           sum(l.qty * coalesce(l.ucost, 0)) as cogs,
           max(l.ucost) as unit
    from public.orders o
    join public.order_lines l on l.shop_id = o.shop_id and l.pos_order_id = o.pos_order_id
    left join public.markets m on m.id = o.market_id
    where coalesce(o.status, 0) <> 7
    group by 1, 2, 3, 4
  ), d as (
    select coalesce(a.code, b.code) as code, a.orders ao, b.orders bo, a.rev ar, b.rev br
    from old_r a full join new_r b
      on a.code = b.code and a.team_id is not distinct from b.team_id and a.staff_id is not distinct from b.staff_id and a.st_group = b.st_group
    where a.code is null or b.code is null
       or a.orders <> b.orders or a.qty <> b.qty
       or abs(a.rev - b.rev) > 0.5 or abs(a.cogs - b.cogs) > 0.5
       or a.unit is distinct from b.unit
  )
  select count(*), string_agg(code || ' (' || coalesce(ao::text, '-') || '/' || coalesce(bo::text, '-') || ' đơn, ' || coalesce(round(ar)::text, '-') || '/' || coalesce(round(br)::text, '-') || ')', '; ')
    into bad, sample from (select * from d limit 5) x;
  if bad > 0 then
    raise exception 'Kiểm tra không khớp, đã huỷ toàn bộ thay đổi. Gửi dòng này cho người phát triển: %', sample;
  end if;
end $$;

-- Báo cáo sản phẩm đọc từ order_lines. Lọc quyền xem đúng như quyền xem đơn (orders_select).
create or replace function public.dash_products(p_from timestamptz, p_to timestamptz, p_project text default null, p_market text default null, p_channel text default null)
returns table (code text, name text, team_id text, staff_id text, st_group text, orders bigint, qty numeric, revenue_vnd numeric, cogs_vnd numeric, unit_cost_vnd numeric)
-- plpgsql + force_custom_plan: lập kế hoạch theo đúng khoảng ngày được hỏi (kế hoạch chung chung đoán sai số dòng).
-- enable_sort = off: gộp bằng bảng băm thay vì sắp xếp ~200 nghìn dòng chữ (nhanh gấp ~3 lần, chỉ áp dụng trong hàm này).
language plpgsql stable security definer set search_path = public set work_mem = '32MB' set plan_cache_mode = force_custom_plan set enable_sort = off as $$
#variable_conflict use_column
begin
  return query
  with sc as (select * from public.my_scope() limit 1)
  select l.code, max(l.name), o.team_id, o.staff_id,
         case when o.status in (3,16) then 'ok' when o.status in (4,5,15) then 'ret' when o.status = 2 then 'ship'
              when o.status = 6 then 'cancel' else 'new' end,
         count(*) filter (where l.first_of_code),   -- số đơn có mã này
         sum(l.qty), sum(l.rev * coalesce(m.rate_vnd, 1)),
         case when (select public.sees_cost()) then sum(l.qty * coalesce(l.ucost, 0)) end,
         case when (select public.sees_cost()) then max(l.ucost) end
  from public.orders o
  join public.order_lines l on l.shop_id = o.shop_id and l.pos_order_id = o.pos_order_id
  left join public.markets m on m.id = o.market_id
  cross join sc
  where o.local_day >= (p_from at time zone 'Asia/Ho_Chi_Minh')::date and o.local_day < (p_to at time zone 'Asia/Ho_Chi_Minh')::date
    and (p_project is null or o.project_id = p_project)
    and (p_market is null or o.market_id = any(string_to_array(p_market, ',')))
    and (p_channel is null or o.channel_id = any(string_to_array(p_channel, ',')) or ('__none' = any(string_to_array(p_channel, ',')) and o.channel_id is null))
    and coalesce(o.status, 0) <> 7
    and case sc.scope   -- giống hệt quyền xem đơn (orders_select)
          when 'all' then true
          when 'project' then array[o.project_id] <@ sc.project_ids
          when 'team' then o.team_id = sc.team_id
          when 'self' then o.staff_id = sc.staff_id
          else false
        end
  group by 1, 3, 4, 5;
end $$;
revoke all on function public.dash_products(timestamptz, timestamptz, text, text, text) from public, anon;
grant execute on function public.dash_products(timestamptz, timestamptz, text, text, text) to authenticated, service_role;

commit;
