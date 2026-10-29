-- Tồn kho: tách "Tồn thực tế" và "Có thể bán".
--   * Tồn thực tế (on_hand): hàng đang nằm trong kho; đơn trừ lúc "Đã gửi hàng".
--   * Chờ gửi (cho_gui): hàng của đơn đã lên nhưng chưa gửi (mới, đã xác nhận, đóng gói, chờ lấy…), đơn 60 ngày gần nhất.
--   * Có thể bán = tồn thực tế − chờ gửi (tính ở giao diện); âm khi đã nhận đơn vượt số hàng.
-- Chạy sau 20261029010000_stock_kits.sql. Chạy lại nhiều lần không lỗi.

drop function if exists public.stock_report();
create or replace function public.stock_report()
returns table (wh_id text, product_key text, code text, name text, as_of date, base numeric, nhap numeric, chuyen numeric,
               dieu_chinh numeric, ban numeric, hoan numeric, on_hand numeric, sold_30d numeric, last_sale date, unit_cost numeric,
               cho_gui numeric)
language sql stable security definer set search_path = public as $$
  with w as (
    select w.id, (select max(c.as_of) from public.stock_counts c where c.wh_id = w.id) as as_of,
           array(select lower(btrim(x)) from unnest(w.pos_names) x where btrim(x) <> '') as names
    from public.warehouses w where w.active
  ),
  since as (select least(coalesce(min(as_of), current_date), current_date - 31) - 1 as d from w),
  c as (
    select c.wh_id, c.product_key, max(c.code) as code, max(c.name) as name, sum(c.qty) as qty
    from public.stock_counts c join w on w.id = c.wh_id and c.as_of = w.as_of group by 1, 2
  ),
  m as (
    select m.wh_id, m.product_key, max(m.code) as code, max(m.name) as name,
           sum(m.qty) filter (where m.kind = 'nhap') as nhap,
           sum(m.qty) filter (where m.kind in ('chuyen_di', 'chuyen_den')) as chuyen,
           sum(m.qty) filter (where m.kind = 'dieu_chinh') as dc
    from public.stock_moves m join w on w.id = m.wh_id and m.day >= w.as_of group by 1, 2
  ),
  li as (
    select w.id as wid, w.as_of, lower(btrim(p.code)) as pk, p.code as code,
           case when lower(btrim(p.code)) = lower(btrim(i->>'code')) then i->>'name' end as name,
           coalesce((i->>'quantity')::numeric, 1) * p.qty as q,
           p.qty * case when o.status = 5 then coalesce(nullif((i->>'ret')::numeric, 0), coalesce((i->>'quantity')::numeric, 1))
                when o.status = 15 then coalesce((i->>'ret')::numeric, 0) else 0 end as rq,
           (o.shipped_at at time zone coalesce(mk.timezone, 'Asia/Ho_Chi_Minh'))::date as sd,
           (o.returned_at at time zone coalesce(mk.timezone, 'Asia/Ho_Chi_Minh'))::date as rd
    from public.orders o
    join w on lower(btrim(o.warehouse)) = any(w.names)
    left join public.markets mk on mk.id = o.market_id
    cross join lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i
    cross join lateral public.stock_parts(i->>'code') p
    where o.shipped_at >= (select d from since) and o.status in (2,3,4,5,15,16) and coalesce(btrim(i->>'code'), '') <> ''
  ),
  s as (
    select wid as wh_id, pk as product_key, max(code) as code, max(name) as name,
           sum(q) filter (where sd >= as_of) as ban,
           sum(rq) filter (where rd >= as_of) as hoan,
           sum(q) filter (where sd >= current_date - 30) as sold_30d,
           max(sd) as last_sale
    from li group by 1, 2
  ),
  -- Chờ gửi: hàng của đơn đã lên nhưng chưa rời kho (mới, đã xác nhận, đóng gói, chờ lấy…), không tính đơn huỷ / xoá.
  pe as (
    select w.id as wh_id, lower(btrim(p.code)) as product_key, max(p.code) as code,
           max(case when lower(btrim(p.code)) = lower(btrim(i->>'code')) then i->>'name' end) as name,
           sum(coalesce((i->>'quantity')::numeric, 1) * p.qty) as q
    from public.orders o
    join w on lower(btrim(o.warehouse)) = any(w.names)
    cross join lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i
    cross join lateral public.stock_parts(i->>'code') p
    where o.inserted_at >= now() - interval '60 days' and coalesce(o.status, 0) not in (2,3,4,5,15,16,6,7)
      and coalesce(btrim(i->>'code'), '') <> ''
    group by 1, 2
  ),
  k as (select wh_id, product_key from c union select wh_id, product_key from m union select wh_id, product_key from s
        union select wh_id, product_key from pe)
  select k.wh_id, k.product_key, coalesce(c.code, m.code, s.code, pe.code), coalesce(c.name, m.name, s.name, pe.name), w.as_of,
         coalesce(c.qty, 0), coalesce(m.nhap, 0), coalesce(m.chuyen, 0), coalesce(m.dc, 0), coalesce(s.ban, 0), coalesce(s.hoan, 0),
         case when w.as_of is not null then coalesce(c.qty, 0) + coalesce(m.nhap, 0) + coalesce(m.chuyen, 0) + coalesce(m.dc, 0) - coalesce(s.ban, 0) + coalesce(s.hoan, 0) end,
         coalesce(s.sold_30d, 0), s.last_sale,
         case when (select public.sees_cost()) then public.cost_at(coalesce(c.code, m.code, s.code, pe.code), coalesce(c.name, m.name, s.name, pe.name), current_date) end,
         coalesce(pe.q, 0)
  from k join w on w.id = k.wh_id
  left join c on c.wh_id = k.wh_id and c.product_key = k.product_key
  left join m on m.wh_id = k.wh_id and m.product_key = k.product_key
  left join s on s.wh_id = k.wh_id and s.product_key = k.product_key
  left join pe on pe.wh_id = k.wh_id and pe.product_key = k.product_key
  where (select public.has_role('admin','lanh_dao','quan_ly','ke_toan','kho','truong_team','marketing'))
$$;

revoke all on function public.stock_report() from public, anon;
grant execute on function public.stock_report() to authenticated;

create or replace function public.stock_report_all() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.stock_report() t
$$;
revoke all on function public.stock_report_all() from public, anon;
grant execute on function public.stock_report_all() to authenticated;
