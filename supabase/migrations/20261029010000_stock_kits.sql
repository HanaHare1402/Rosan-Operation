-- Combo / bộ sản phẩm: một mã bán trên POS gồm nhiều món trong kho.
--   * Tự tách theo tên: "A + B + C" → A, B, C mỗi thứ 1; "Tên x2" → Tên × 2; kết hợp được ("A x2 + B").
--   * Bảng stock_kits: khai báo / sửa tay (ghi đè cách tự tách). parts = [{"code": "...", "qty": 2}];
--     khai báo chính nó × 1 nghĩa là "không phải combo".
--   * Tồn kho trừ theo từng món sau khi tách; đổi khai báo combo thì số tính lại ngay (từ ngày kiểm kho).
-- Chạy sau 20261029000000_inventory.sql. Chạy lại nhiều lần không lỗi.

create table if not exists public.stock_kits (
  kit_key text primary key,                  -- lower(mã bán trên POS)
  kit_code text not null,
  parts jsonb not null,
  updated_by_name text,
  updated_at timestamptz not null default now()
);
alter table public.stock_kits enable row level security;
grant select, insert, update, delete on public.stock_kits to authenticated;
drop policy if exists stock_kits_read on public.stock_kits;
create policy stock_kits_read on public.stock_kits for select to authenticated
  using ((select public.has_role('admin','lanh_dao','quan_ly','ke_toan','kho','truong_team','marketing')));
drop policy if exists stock_kits_write on public.stock_kits;
create policy stock_kits_write on public.stock_kits for all to authenticated
  using ((select public.has_role('admin','quan_ly','ke_toan','kho'))) with check ((select public.has_role('admin','quan_ly','ke_toan','kho')));

-- Món trong kho của một mã bán: khai báo tay nếu có, không thì tự tách theo tên.
create or replace function public.stock_parts(p_code text) returns table (code text, qty numeric)
language sql stable security definer set search_path = public as $$
  with k as (select parts from public.stock_kits where kit_key = lower(btrim(p_code)))
  select btrim(e->>'code'), coalesce((e->>'qty')::numeric, 1)
  from k cross join lateral jsonb_array_elements(k.parts) e
  where coalesce(btrim(e->>'code'), '') <> ''
  union all
  select btrim(coalesce(m.v[1], s.v)), coalesce(m.v[2]::numeric, 1)
  from regexp_split_to_table(btrim(coalesce(p_code, '')), '\s*\+\s*') as s(v)
  cross join lateral (select regexp_match(btrim(s.v), '^(.+?)\s*[xX×]\s*(\d+)$') as v) m
  where not exists (select 1 from k) and btrim(s.v) <> ''
$$;
revoke all on function public.stock_parts(text) from public, anon;
grant execute on function public.stock_parts(text) to authenticated, service_role;

create or replace function public.stock_report()
returns table (wh_id text, product_key text, code text, name text, as_of date, base numeric, nhap numeric, chuyen numeric,
               dieu_chinh numeric, ban numeric, hoan numeric, on_hand numeric, sold_30d numeric, last_sale date, unit_cost numeric)
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
  k as (select wh_id, product_key from c union select wh_id, product_key from m union select wh_id, product_key from s)
  select k.wh_id, k.product_key, coalesce(c.code, m.code, s.code), coalesce(c.name, m.name, s.name), w.as_of,
         coalesce(c.qty, 0), coalesce(m.nhap, 0), coalesce(m.chuyen, 0), coalesce(m.dc, 0), coalesce(s.ban, 0), coalesce(s.hoan, 0),
         case when w.as_of is not null then coalesce(c.qty, 0) + coalesce(m.nhap, 0) + coalesce(m.chuyen, 0) + coalesce(m.dc, 0) - coalesce(s.ban, 0) + coalesce(s.hoan, 0) end,
         coalesce(s.sold_30d, 0), s.last_sale,
         case when (select public.sees_cost()) then public.cost_at(coalesce(c.code, m.code, s.code), coalesce(c.name, m.name, s.name), current_date) end
  from k join w on w.id = k.wh_id
  left join c on c.wh_id = k.wh_id and c.product_key = k.product_key
  left join m on m.wh_id = k.wh_id and m.product_key = k.product_key
  left join s on s.wh_id = k.wh_id and s.product_key = k.product_key
  where (select public.has_role('admin','lanh_dao','quan_ly','ke_toan','kho','truong_team','marketing'))
$$;

create or replace function public.stock_known_products()
returns table (code text, name text)
language sql stable security definer set search_path = public as $$
  select distinct on (lower(btrim(p.code))) btrim(p.code), case when lower(btrim(p.code)) = lower(btrim(i->>'code')) then i->>'name' else btrim(p.code) end
  from public.orders o cross join lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i
  cross join lateral public.stock_parts(i->>'code') p
  where o.inserted_at >= now() - interval '45 days' and coalesce(btrim(i->>'code'), '') <> ''
    and (select public.has_role('admin','lanh_dao','quan_ly','ke_toan','kho','truong_team','marketing'))
  order by lower(btrim(p.code)), (lower(btrim(p.code)) = lower(btrim(i->>'code'))) desc, o.inserted_at desc
$$;


-- Mã bán là combo (tự tách ra nhiều món hoặc số lượng > 1, hoặc đã khai báo tay) trong 45 ngày qua, kèm cách tách hiện tại.
create or replace function public.stock_kit_list_all() returns jsonb
language sql stable security definer set search_path = public as $$
  with c as (
    select btrim(i->>'code') as code, count(distinct o.pos_order_id) as orders
    from public.orders o cross join lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i
    where o.inserted_at >= now() - interval '45 days' and coalesce(btrim(i->>'code'), '') <> ''
      and (select public.has_role('admin','lanh_dao','quan_ly','ke_toan','kho','truong_team','marketing'))
    group by 1
  ),
  allc as (
    select code, orders from c
    union all
    select k.kit_code, 0 from public.stock_kits k where not exists (select 1 from c where lower(c.code) = k.kit_key)
      and (select public.has_role('admin','lanh_dao','quan_ly','ke_toan','kho','truong_team','marketing'))
  ),
  x as (
    select a.code, a.orders, exists (select 1 from public.stock_kits k where k.kit_key = lower(a.code)) as manual,
           (select jsonb_agg(jsonb_build_object('code', p.code, 'qty', p.qty)) from public.stock_parts(a.code) p) as parts,
           (select count(*) from public.stock_parts(a.code) p) as n,
           (select sum(p.qty) from public.stock_parts(a.code) p) as q,
           (select bool_and(lower(p.code) = lower(a.code)) from public.stock_parts(a.code) p) as self
    from allc a
  )
  select coalesce(jsonb_agg(jsonb_build_object('code', code, 'orders', orders, 'manual', manual, 'parts', parts) order by orders desc, code), '[]'::jsonb)
  from x where manual or not (n = 1 and q = 1 and self)
$$;
revoke all on function public.stock_kit_list_all() from public, anon;
grant execute on function public.stock_kit_list_all() to authenticated;
