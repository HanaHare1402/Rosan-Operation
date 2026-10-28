-- Tăng tốc báo cáo khi nhiều đơn (lỗi "canceling statement due to statement timeout").
--   1) Bảng đơn có thêm cột sản phẩm chính (main_pk / main_name), tính một lần khi lưu đơn;
--      giá vốn từng dòng hàng ghi sẵn vào items (ucost). Báo cáo đọc thẳng, không phải mở JSON / tra bảng nhập hàng mỗi lần.
--   2) KPI, theo dõi theo ngày, sản phẩm dùng các cột trên (đơn chưa tính lại vẫn ra đúng, chỉ chậm hơn).
--   3) Giới hạn thời gian mỗi lệnh của tài khoản đăng nhập: 8 giây → 30 giây.
--   4) Xoá đơn cũ theo từng đợt để không quá giờ.
--   5) Đánh dấu tính lại mọi đơn: lịch đồng bộ / nút "Đồng bộ" tự điền cột mới dần dần.
-- Chạy sau 20261028000000_lanh_dao_role.sql. Chạy lại nhiều lần không lỗi.

alter role authenticated set statement_timeout = '30s';
notify pgrst, 'reload config';

alter table public.orders add column if not exists main_pk text;
alter table public.orders add column if not exists main_name text;
create index if not exists orders_main_pk_time on public.orders (main_pk, inserted_at);
create index if not exists orders_time_status on public.orders (inserted_at, status);

create or replace function public.order_derive() returns trigger
language plpgsql security definer set search_path = public as $$
declare r jsonb; st record; keys text[];
begin
  -- Chỉ đánh dấu "cần tính lại" (derived_at → null): bỏ qua, đợt tính lại sẽ xử lý.
  if tg_op = 'UPDATE' and new.derived_at is null and old.derived_at is not null and new.raw is not distinct from old.raw then
    return new;
  end if;
  -- Đường nhanh: raw không đổi (chỉ tính lại gán nhân sự / kênh) thì bỏ qua phần dựng cột từ raw.
  -- Dựng lại khi: đơn mới, raw đổi (kéo lại từ POS), hoặc raw cũ chưa được cắt gọn / chưa có cột sản phẩm.
  if tg_op = 'INSERT' or new.raw is distinct from old.raw or old.items is null
     or old.raw ? 'customer' or old.raw ? 'status_history' or old.raw ? 'histories' then
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
        'bonus', coalesce((i->>'is_bonus_product')::boolean, false))), '[]'::jsonb)
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
           -- Đơn giá vốn đã ghi sẵn trong dòng hàng (ucost); đơn chưa tính lại thì tra như cũ.
           case when i ? 'ucost' then (i->>'ucost')::numeric
                else public.cost_at(coalesce(nullif(i->>'code', ''), i->>'name', '?'), i->>'name', (o.inserted_at at time zone 'Asia/Ho_Chi_Minh')::date) end as cost
    from o cross join lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i
  )
  select l.code, max(l.name), l.team_id, l.staff_id, l.st_group, count(distinct l.pos_order_id), sum(l.qty), sum(l.rev),
         case when (select public.sees_cost()) then sum(l.qty * coalesce(l.cost, 0)) end,
         case when (select public.sees_cost()) then max(l.cost) end
  from l
  group by l.code, l.team_id, l.staff_id, l.st_group
$$;

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
           coalesce(o.main_name, (select btrim(i->>'name') from jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i where not coalesce((i->>'bonus')::boolean, false) and coalesce(btrim(i->>'name'), '') <> '' order by coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1) desc limit 1), '(không rõ sản phẩm)') as name
    from public.orders o
    left join public.markets m on m.id = o.market_id
    , sc
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

create or replace function public.team_daily(p_from timestamptz, p_to timestamptz, p_project text default null, p_team text default null,
  p_market text default null, p_channel text default null)
returns table (day date, team_id text, grp smallint, orders bigint, revenue numeric, ad_usd numeric)
language sql stable security definer set search_path = public as $$
  with sc as (select * from public.my_scope() limit 1),
  mon as (select date_trunc('month', p_from at time zone 'Asia/Ho_Chi_Minh')::date as m),
  pg as (
    select distinct on (g.product_key) g.product_key, g.grp
    from public.product_groups g, mon where g.month <= mon.m
    order by g.product_key, g.month desc
  ),
  o as (
    select (o.inserted_at at time zone coalesce(m.timezone, 'Asia/Ho_Chi_Minh'))::date as d, o.team_id, pg.grp,
           coalesce(o.total_price, 0) * coalesce(m.rate_vnd, 1) as rev
    from public.orders o
    left join public.markets m on m.id = o.market_id
    left join pg on pg.product_key = coalesce(o.main_pk, (select lower(btrim(i->>'name')) from jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i where not coalesce((i->>'bonus')::boolean, false) and coalesce(btrim(i->>'name'), '') <> '' order by coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1) desc limit 1)), sc
    where o.inserted_at >= p_from and o.inserted_at < p_to
      and coalesce(o.status, 0) not in (6, 7)
      and (p_project is null or o.project_id = p_project)
      and (p_team is null or o.team_id = p_team)
      and (p_market is null or o.market_id = p_market)
      and (p_channel is null or o.channel_id = p_channel)
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
      and (p_channel is null or x.channel_id = p_channel)
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
revoke all on function public.team_daily(timestamptz, timestamptz, text, text, text, text) from public, anon;
grant execute on function public.team_daily(timestamptz, timestamptz, text, text, text, text) to authenticated;

create or replace function public.staff_daily(p_from timestamptz, p_to timestamptz, p_staff text,
  p_market text default null, p_channel text default null)
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
    left join pg on pg.product_key = coalesce(o.main_pk, (select lower(btrim(i->>'name')) from jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i where not coalesce((i->>'bonus')::boolean, false) and coalesce(btrim(i->>'name'), '') <> '' order by coalesce((i->>'price')::numeric, 0) * coalesce((i->>'quantity')::numeric, 1) desc limit 1))
    where o.staff_id = p_staff and o.inserted_at >= p_from and o.inserted_at < p_to
      and coalesce(o.status, 0) not in (6, 7)
      and (p_market is null or o.market_id = p_market)
      and (p_channel is null or o.channel_id = p_channel)
  ),
  oa as (select d, grp, count(*) as n, sum(rev) as rev from o group by 1, 2),
  a as (
    select x.day as d, pg.grp, sum(x.usd) as usd
    from public.ad_spend x left join pg on pg.product_key = x.product_key
    where x.staff_id = p_staff
      and (p_channel is null or x.channel_id = p_channel)
      and x.day >= (p_from at time zone 'Asia/Ho_Chi_Minh')::date and x.day < (p_to at time zone 'Asia/Ho_Chi_Minh')::date
    group by 1, 2
  )
  select coalesce(oa.d, a.d), coalesce(oa.grp, a.grp), coalesce(oa.n, 0), coalesce(oa.rev, 0), coalesce(a.usd, 0)
  from oa full join a on a.d = oa.d and a.grp is not distinct from oa.grp
  where public.can_see_staff(p_staff)
$$;
revoke all on function public.staff_daily(timestamptz, timestamptz, text, text, text) from public, anon;
grant execute on function public.staff_daily(timestamptz, timestamptz, text, text, text) to authenticated;

-- Xoá đơn cũ hơn mốc theo đợt 5.000 đơn, tối đa ~50 giây mỗi lần gọi (lần sau xoá tiếp).
create or replace function public.purge_old_orders() returns bigint
language plpgsql security definer set search_path = public as $$
declare n bigint := 0; k bigint; t0 timestamptz := clock_timestamp();
begin
  if auth.uid() is not null and not public.is_admin() then raise exception 'Chỉ admin' using errcode = '42501'; end if;
  if coalesce((select (value->>'purge')::boolean from public.app_settings where key = 'sync_range'), false) then
    loop
      delete from public.orders o where (o.shop_id, o.pos_order_id) in (
        select x.shop_id, x.pos_order_id from public.orders x join public.pos_shops s on s.id = x.shop_id
        where x.inserted_at < public.sync_cutoff(s.id) limit 5000);
      get diagnostics k = row_count; n := n + k;
      exit when k = 0 or clock_timestamp() - t0 > interval '50 seconds';
    end loop;
  end if;
  delete from public.sync_runs where started_at < now() - interval '30 days';
  return n;
end $$;
revoke all on function public.purge_old_orders() from public, anon;
grant execute on function public.purge_old_orders() to authenticated, service_role;

-- Điền cột mới cho đơn đã có: đánh dấu tính lại, chạy dần theo đợt.
select public.request_recompute();
