-- Doanh số đơn sàn (Shopee, TikTok, Lazada…).
--   Với đơn sàn, COD (và có khi cả giá trị đơn) POS trả về là tiền đã trừ phí sàn. Doanh số thực = COD + phí sàn.
--   * orders.platform_fee: phí sàn của đơn (trường fee_marketplace của POS), theo tiền của thị trường.
--   * orders.total_price của đơn sàn = max(giá trị đơn, COD + phí sàn) → mọi báo cáo doanh số dùng số này.
--   * KPI: doanh số gửi đi / thành công / hoàn = COD + phí sàn; trả thêm cột platform_fee (phí sàn của đơn đã giao)
--     để trừ ở lợi nhuận gộp, nên lợi nhuận tính lương không bị đội lên.
-- Chạy sau 20261029020000_stock_available.sql. Chạy lại nhiều lần không lỗi.

alter table public.orders add column if not exists platform_fee numeric;

-- Phí sàn trong dữ liệu POS: số, chuỗi số, hoặc một nhóm khoản (cộng các khoản là số).
create or replace function public.mkt_fee(r jsonb) returns numeric
language sql immutable as $$
  select case jsonb_typeof(r->'fee_marketplace')
    when 'number' then (r->>'fee_marketplace')::numeric
    when 'string' then case when btrim(r->>'fee_marketplace') ~ '^-?[0-9]+(\.[0-9]+)?$' then btrim(r->>'fee_marketplace')::numeric end
    when 'object' then (select sum(v::text::numeric) from jsonb_each(r->'fee_marketplace') e(k, v) where jsonb_typeof(v) = 'number')
    else null end
$$;
-- Đơn từ sàn: POS ghi mã sàn (marketplace_id), hoặc nguồn đơn là Shopee / TikTok / Lazada.
create or replace function public.is_marketplace(r jsonb, p_source text) returns boolean
language sql immutable as $$
  select coalesce(nullif(btrim(r->>'marketplace_id'), ''), '') not in ('', '0', 'null')
      or coalesce(p_source, '') ~* '(shopee|tiktok|lazada)'
$$;

create or replace function public.order_derive() returns trigger
language plpgsql security definer set search_path = public as $$
declare r jsonb; st record; keys text[]; h jsonb; hs timestamptz; hr timestamptz;
begin
  -- Chỉ đánh dấu "cần tính lại" (derived_at → null): bỏ qua, đợt tính lại sẽ xử lý.
  if tg_op = 'UPDATE' and new.derived_at is null and old.derived_at is not null and new.raw is not distinct from old.raw then
    return new;
  end if;
  -- Đường nhanh: raw không đổi (chỉ tính lại gán nhân sự / kênh) thì bỏ qua phần dựng cột từ raw.
  -- Dựng lại khi: đơn mới, raw đổi (kéo lại từ POS), hoặc raw cũ chưa được cắt gọn / chưa có cột sản phẩm.
  if tg_op = 'INSERT' or new.raw is distinct from old.raw or old.items is null
     or old.raw ? 'customer' or old.raw ? 'status_history' or old.raw ? 'histories' then
  -- Lịch sử trạng thái của POS (bị cắt khỏi raw ngay dưới đây): lấy lúc hàng rời kho / về kho cho tồn kho.
  h := coalesce(new.raw->'status_history', new.raw->'histories');
  r := public.pos_slim(new.raw);
  new.raw := r;

  -- Cột số liệu, lấy lại từ raw để đơn cũ cũng đúng khi tính lại.
  new.status := coalesce((r->>'status')::int, new.status);
  new.status_name := coalesce(r->>'status_name', new.status_name);
  -- Đơn đã xoá trên POS (lấy về nhờ include_removed=1): coi như huỷ, mã 7 "Đã xoá", không tính doanh số.
  if coalesce(r->>'is_removed', r->>'is_deleted', r->>'removed', 'false') in ('true', '1')
     or nullif(coalesce(r->>'removed_at', r->>'deleted_at', ''), '') is not null then
    new.status := 7; new.status_name := 'removed';
  end if;
  new.total_price := coalesce((r->>'total_price_after_sub_discount')::numeric, (r->>'total_price')::numeric, new.total_price);
  new.discount := (r->>'total_discount')::numeric;
  new.cod := coalesce((r->>'cod')::numeric, (r->>'money_to_collect')::numeric, new.cod);
  new.shipping_fee := coalesce((r->>'shipping_fee')::numeric, new.shipping_fee);
  new.warehouse := coalesce(r->'warehouse_info'->>'name', r->>'warehouse_id', new.warehouse);
  new.province := coalesce(r->'shipping_address'->>'province_name', new.province);
  new.tracking := coalesce(nullif(r->'partner'->>'extend_code', ''), new.tracking);
  if jsonb_typeof(r->'items') = 'array' then
    new.items := (select coalesce(jsonb_agg(jsonb_build_object(
        'code', coalesce(nullif(i->'variation_info'->>'product_display_id', ''), nullif(i->'variation_info'->>'display_id', ''), i->>'product_id'),
        'name', coalesce(i->'variation_info'->>'name', i->>'product_name'),
        'quantity', coalesce((i->>'quantity')::numeric, 1),
        'price', coalesce((i->'variation_info'->>'retail_price')::numeric, (i->>'retail_price')::numeric, 0),
        'cost', (i->'variation_info'->>'last_imported_price')::numeric,
        'bonus', coalesce((i->>'is_bonus_product')::boolean, false),
        'ret', (i->>'return_quantity')::numeric)), '[]'::jsonb)
      from jsonb_array_elements(r->'items') i);
  end if;

  -- Ai, kênh nào.
  new.marketer_id := nullif(coalesce(r->'marketer'->>'id', r->>'pke_mkter', ''), '');
  new.marketer_name := nullif(btrim(coalesce(r->'marketer'->>'name', '')), '');
  new.seller_name := nullif(btrim(coalesce(r->'assigning_seller'->>'name', r->'assigning_care'->>'name', '')), '');
  new.utm_code := case when position(' - ' in coalesce(r->>'p_utm_medium', '')) > 0
                       then nullif(btrim(split_part(r->>'p_utm_medium', ' - ', 1)), '') end;
  new.utm_campaign := nullif(r->>'p_utm_campaign', '');
  new.ad_id := nullif(coalesce(r->>'ad_id', r->>'p_utm_content', ''), '');
  new.page_id := nullif(coalesce(r->>'page_id', ''), '');
  new.page_name := nullif(coalesce(r->>'account_name', ''), '');
  new.source_name := coalesce(nullif(btrim(r->>'order_sources_name'), ''), nullif(btrim(r->>'ads_source'), ''),
                              nullif(btrim(r->>'p_utm_source'), ''));

  -- Đơn sàn (Shopee, TikTok…): COD là tiền đã trừ phí sàn. Doanh số = COD + phí sàn; phí sàn ghi riêng để trừ ở lợi nhuận.
  if public.is_marketplace(r, new.source_name) then
    new.platform_fee := nullif(public.mkt_fee(r), 0);
    if new.platform_fee is not null then
      new.total_price := greatest(coalesce(new.total_price, 0), coalesce(new.cod, 0) + new.platform_fee);
    end if;
  else
    new.platform_fee := null;
  end if;

  -- Tồn kho: lúc hàng rời kho (đã gửi hàng trở đi) và lúc hàng hoàn về kho.
  -- Ưu tiên lịch sử trạng thái của POS; không có thì giữ mốc đã ghi, hoặc lấy lúc web thấy đơn đổi sang trạng thái đó.
  if jsonb_typeof(h) = 'array' then
    select min(public.try_ts(coalesce(x->>'updated_at', x->>'inserted_at', x->>'created_at', x->>'time'))) filter (where public.try_int(x->>'status') in (2,3,4,5,15,16)),
           min(public.try_ts(coalesce(x->>'updated_at', x->>'inserted_at', x->>'created_at', x->>'time'))) filter (where public.try_int(x->>'status') in (5,15))
      into hs, hr
    from jsonb_array_elements(h) x;
  end if;
  if new.status in (2,3,4,5,15,16) then
    new.shipped_at := coalesce(hs, case when tg_op = 'UPDATE' then old.shipped_at end,
      case when tg_op = 'UPDATE' and old.status is not null and old.status not in (2,3,4,5,15,16) then now() end,
      new.updated_at, new.inserted_at, now());
  else
    new.shipped_at := null;
  end if;
  if new.status in (5,15) then
    new.returned_at := coalesce(hr, case when tg_op = 'UPDATE' then old.returned_at end,
      case when tg_op = 'UPDATE' and old.status is not null and old.status not in (5,15) then now() end,
      new.updated_at, now());
  else
    new.returned_at := null;
  end if;

  end if;

  -- Nhân sự: mã marketer / tên marketer → mã trong tên camp → người được gán → page.
  select s.id, s.team_id, coalesce(t.project_id, s.project_id) as project_id,
         case when lower(new.marketer_id) = any(k.keys) or lower(new.marketer_name) = any(k.keys) then 1
              when lower(new.utm_code) = any(k.keys) then 2
              when lower(new.seller_name) = any(k.keys) then 3 else 4 end as pri
    into st
  from public.staff s
  left join public.teams t on t.id = s.team_id
  cross join lateral (select array(select lower(btrim(x)) from unnest(s.pos_names || s.name) x where btrim(x) <> '') as keys) k
  where s.active and (
       lower(new.marketer_id) = any(k.keys) or lower(new.marketer_name) = any(k.keys)
    or lower(new.utm_code) = any(k.keys)
    or lower(new.seller_name) = any(k.keys)
    or new.page_id = any(s.pages) or new.page_name = any(s.pages))
  order by pri
  limit 1;
  new.staff_id := st.id; new.team_id := st.team_id; new.project_id := st.project_id;

  select c.id into new.channel_id from public.channels c
  where new.source_name is not null and exists (select 1 from unnest(c.keywords) kw where kw <> '' and lower(new.source_name) like '%' || lower(kw) || '%')
  order by c.sort, c.name limit 1;

  select s.market_id into new.market_id from public.pos_shops s where s.id = new.shop_id;
  -- Ngày của đơn theo giờ của thị trường (Philippines theo giờ Philippines...): mọi báo cáo lọc theo cột này.
  new.local_day := (coalesce(new.inserted_at, now()) at time zone coalesce((select m.timezone from public.markets m where m.id = new.market_id), 'Asia/Ho_Chi_Minh'))::date;
  -- Giá vốn: mỗi dòng sản phẩm × đơn giá lần nhập gần nhất tính đến ngày tạo đơn (giờ VN).
  -- Ghi luôn đơn giá vào từng dòng hàng (ucost) để báo cáo đọc thẳng, không phải tra lại bảng nhập hàng.
  if jsonb_typeof(new.items) = 'array' then
    select coalesce(jsonb_agg(t.i || jsonb_build_object('ucost', x.c) order by t.n), '[]'::jsonb),
           sum(coalesce((t.i->>'quantity')::numeric, 1) * x.c), count(*) filter (where x.c is null)
      into new.items, new.cogs_vnd, new.cogs_missing
    from jsonb_array_elements(new.items) with ordinality t(i, n)
    cross join lateral (select public.cost_at(t.i->>'code', t.i->>'name', (coalesce(new.inserted_at, now()) at time zone 'Asia/Ho_Chi_Minh')::date) as c) x;
  else
    new.cogs_vnd := null; new.cogs_missing := 0;
  end if;
  -- Sản phẩm chính của đơn (dòng hàng giá trị lớn nhất, không tính hàng tặng): KPI và bảng theo ngày tính theo cột này.
  select lower(btrim(i->>'name')), btrim(i->>'name') into new.main_pk, new.main_name
  from jsonb_array_elements(coalesce(new.items, '[]'::jsonb)) i
  where not coalesce((i->>'bonus')::boolean, false) and coalesce(btrim(i->>'name'), '') <> ''
  order by coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1) desc limit 1;
  new.derived_at := clock_timestamp();
  return new;
end $$;

-- Đơn sàn đã có: điền phí sàn và tính lại doanh số ngay (tắt tạm bước tính toán khi lưu để chạy nhanh).
alter table public.orders disable trigger orders_derive;
update public.orders o
set platform_fee = x.fee,
    total_price = greatest(coalesce(o.total_price, 0), coalesce(o.cod, 0) + x.fee)
from (select shop_id, pos_order_id, nullif(public.mkt_fee(raw), 0) as fee from public.orders
      where public.is_marketplace(raw, source_name)) x
where o.shop_id = x.shop_id and o.pos_order_id = x.pos_order_id and x.fee is not null
  and o.platform_fee is distinct from x.fee;
alter table public.orders enable trigger orders_derive;

drop function if exists public.kpi_report(timestamptz, timestamptz, text, text);
create or replace function public.kpi_report(p_from timestamptz, p_to timestamptz, p_mode text default 'ads', p_project text default null)
returns table (who text, product_key text, product text, grp smallint, orders bigint, sent numeric, ret numeric, ok numeric,
               cogs numeric, cogs_missing bigint, ship_rate numeric, ad_usd numeric, ok_n bigint, ret_n bigint, platform_fee numeric)
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
  where (j.who is null and sc.scope = 'all') or j.who in (select id from vis)
$$;
revoke all on function public.kpi_report(timestamptz, timestamptz, text, text) from public, anon;
grant execute on function public.kpi_report(timestamptz, timestamptz, text, text) to authenticated;
