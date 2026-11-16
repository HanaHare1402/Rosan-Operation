-- Doanh số theo sản phẩm (màn Sản phẩm, bảng sản phẩm trong Team / Nhân sự) bị thấp hơn POS ở các đơn mà
-- dòng hàng trên POS có giá bán lẻ = 0 (thường gặp khi giá bán đặt theo cả đơn / combo, VD "Oxy Stain Remover x 8 = ₱399").
--   * Trước: doanh số đơn được chia cho từng dòng theo tỷ lệ (giá × số lượng); mọi dòng giá 0 thì chia ra 0 → mất doanh số.
--   * Nay: đơn có giá dòng hàng → chia như cũ (không đổi số). Đơn mọi dòng giá 0 → chia theo số lượng,
--     không chia cho hàng tặng (trừ khi đơn chỉ có hàng tặng). Tổng doanh số các dòng luôn bằng doanh số của đơn
--     (COD, không có COD thì giá trị đơn, + phí sàn) - giống Tổng quan / KPI.
--   * Chỉ tách lại các đơn có mọi dòng giá 0; đơn khác giữ nguyên.
--   * Tự kiểm tra: với MỌI đơn, tổng doanh số các dòng = doanh số của đơn (lệch quá 0,01 đ thì huỷ cả file).
-- Chạy sau 20261112040000_selective_recompute.sql. Chạy lại nhiều lần không lỗi.

begin;
set local statement_timeout = '10min';

create or replace function public.order_lines_build(o public.orders)
returns table (n int, code text, name text, qty numeric, rev numeric, ucost numeric, has_ucost boolean, first_of_code boolean, cost_day date)
language sql stable set search_path = public as $$
  with it as (select case when jsonb_typeof(o.items) = 'array' then o.items else '[]'::jsonb end as items),
  g as (
    select sum(coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1)) as gross,
           sum(case when coalesce((i->>'bonus')::boolean, false) then 0 else coalesce((i->>'quantity')::numeric, 1) end) as wq,
           sum(coalesce((i->>'quantity')::numeric, 1)) as tq,
           count(*) as cnt
    from it, jsonb_array_elements(it.items) i
  )
  select t.n::int,
         coalesce(nullif(t.i->>'code', ''), t.i->>'name', '?'),
         t.i->>'name',
         coalesce((t.i->>'quantity')::numeric, 1),
         case when coalesce(g.gross, 0) > 0
              -- Có giá dòng hàng: chia theo giá × số lượng (như trước).
              then coalesce((t.i->>'price')::numeric, 0) * coalesce((t.i->>'quantity')::numeric, 1) / g.gross
                   * (coalesce(o.cod, o.total_price, g.gross, 0) + coalesce(o.platform_fee, 0))
              -- Mọi dòng giá 0: chia theo số lượng, bỏ hàng tặng; đơn chỉ có hàng tặng thì chia đều theo số lượng.
              else (coalesce(o.cod, o.total_price, 0) + coalesce(o.platform_fee, 0))
                   * case when coalesce(g.wq, 0) > 0
                          then (case when coalesce((t.i->>'bonus')::boolean, false) then 0 else coalesce((t.i->>'quantity')::numeric, 1) end) / g.wq
                          when coalesce(g.tq, 0) > 0 then coalesce((t.i->>'quantity')::numeric, 1) / g.tq
                          else 1.0 / g.cnt end
         end,
         -- Khi giá nhập đổi, mọi đơn được tính lại (ghi ucost mới) nên dòng tách sẵn cũng được làm mới theo.
         case when t.i ? 'ucost' then (t.i->>'ucost')::numeric
              else public.cost_at(coalesce(nullif(t.i->>'code', ''), t.i->>'name', '?'), t.i->>'name', (o.inserted_at at time zone 'Asia/Ho_Chi_Minh')::date) end,
         t.i ? 'ucost',
         row_number() over (partition by coalesce(nullif(t.i->>'code', ''), t.i->>'name', '?') order by t.n) = 1,
         (o.inserted_at at time zone 'Asia/Ho_Chi_Minh')::date
  from it, g, jsonb_array_elements(it.items) with ordinality t(i, n)
$$;
revoke all on function public.order_lines_build(public.orders) from public, anon, authenticated;

-- Tách lại các đơn có dòng hàng mà mọi dòng giá 0.
create temp table fix_orders on commit drop as
select o.shop_id, o.pos_order_id
from public.orders o
where jsonb_typeof(o.items) = 'array' and jsonb_array_length(o.items) > 0
  and coalesce((select sum(coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1))
                from jsonb_array_elements(o.items) i), 0) <= 0;

delete from public.order_lines l using fix_orders f
where l.shop_id = f.shop_id and l.pos_order_id = f.pos_order_id;

insert into public.order_lines (shop_id, pos_order_id, n, code, name, qty, rev, ucost, has_ucost, first_of_code, cost_day)
select o.shop_id, o.pos_order_id, b.n, b.code, b.name, b.qty, b.rev, b.ucost, b.has_ucost, b.first_of_code, b.cost_day
from fix_orders f
join public.orders o on o.shop_id = f.shop_id and o.pos_order_id = f.pos_order_id
cross join lateral public.order_lines_build(o) b
on conflict (shop_id, pos_order_id, n) do update
  set code = excluded.code, name = excluded.name, qty = excluded.qty, rev = excluded.rev,
      ucost = excluded.ucost, has_ucost = excluded.has_ucost, first_of_code = excluded.first_of_code, cost_day = excluded.cost_day;

-- Tự kiểm tra: tổng doanh số các dòng của mỗi đơn = doanh số của đơn.
do $$
declare bad bigint; sample text;
begin
  with s as (
    select l.shop_id, l.pos_order_id, sum(l.rev) as rev from public.order_lines l group by 1, 2
  ), x as (
    select o.pos_order_id, s.rev,
           coalesce(o.cod, o.total_price,
                    nullif(greatest((select sum(coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1))
                                     from jsonb_array_elements(o.items) i), 0), 0), 0) + coalesce(o.platform_fee, 0) as want
    from s join public.orders o on o.shop_id = s.shop_id and o.pos_order_id = s.pos_order_id
  )
  select count(*), string_agg(pos_order_id || ' (' || round(rev, 2) || '/' || round(want, 2) || ')', '; ')
    into bad, sample
  from (select * from x where abs(rev - want) > 0.01 limit 5) y;
  if bad > 0 then
    raise exception 'Kiểm tra không khớp, đã huỷ toàn bộ thay đổi. Gửi dòng này cho người phát triển: %', sample;
  end if;
end $$;

commit;
