-- Tồn kho.
--   * Bảng kho (warehouses) + tên kho trên POS để biết đơn xuất từ kho nào. Thêm / sửa kho ở màn Tồn kho → Kho.
--   * Kiểm kho (stock_counts): số đếm thực tế là tồn ĐẦU NGÀY as_of; mọi thứ từ ngày đó trở đi được cộng / trừ.
--   * Phiếu kho (stock_moves): nhập kho, chuyển kho (một cặp đi / đến), điều chỉnh.
--   * Bán: đơn trừ kho lúc hàng rời kho (orders.shipped_at, từ "đã gửi hàng" trở đi); hoàn cộng lại lúc hàng về (orders.returned_at).
--   * Tồn hiện tại = số kiểm kho gần nhất + nhập ± chuyển ± điều chỉnh − bán + hoàn (tính từ ngày kiểm kho).
-- Chạy sau 20261028050000_multi_filter.sql. Chạy lại nhiều lần không lỗi.

-- ---------- tiện ích ----------
create or replace function public.try_ts(t text) returns timestamptz
language plpgsql immutable as $$
begin
  if t is null or t = '' then return null; end if;
  if t ~ '^\d{10,13}$' then return to_timestamp(case when length(t) > 10 then t::numeric / 1000 else t::numeric end); end if;
  return t::timestamptz;
exception when others then return null;
end $$;
create or replace function public.try_int(t text) returns int
language sql immutable as $$ select case when t ~ '^-?\d+$' then t::int end $$;

-- ---------- kho ----------
create table if not exists public.warehouses (
  id text primary key,
  name text not null,
  pos_names text[] not null default '{}',   -- tên kho trên POS (đơn xuất từ các kho này thì trừ vào kho này)
  active boolean not null default true,
  sort int not null default 0,
  note text,
  created_at timestamptz not null default now()
);
alter table public.warehouses enable row level security;
grant select, insert, update, delete on public.warehouses to authenticated;
drop policy if exists warehouses_read on public.warehouses;
create policy warehouses_read on public.warehouses for select to authenticated using (true);
drop policy if exists warehouses_write on public.warehouses;
create policy warehouses_write on public.warehouses for all to authenticated
  using ((select public.has_role('admin','quan_ly'))) with check ((select public.has_role('admin','quan_ly')));
insert into public.warehouses (id, name, sort) values
  ('giadung', 'Kho gia dụng', 1), ('shopee', 'Kho Shopee', 2), ('sach', 'Kho sách', 3)
on conflict (id) do nothing;

-- ---------- kiểm kho ----------
create table if not exists public.stock_counts (
  id bigint generated always as identity primary key,
  wh_id text not null references public.warehouses(id) on delete cascade,
  as_of date not null,                       -- số đếm là tồn đầu ngày này
  product_key text not null,                 -- lower(mã sản phẩm POS)
  code text not null,
  name text,
  qty numeric not null,
  created_by uuid default auth.uid(),
  created_by_name text,
  created_at timestamptz not null default now(),
  unique (wh_id, as_of, product_key)
);
-- ---------- phiếu kho ----------
create table if not exists public.stock_moves (
  id bigint generated always as identity primary key,
  day date not null,
  wh_id text not null references public.warehouses(id) on delete cascade,
  kind text not null check (kind in ('nhap', 'chuyen_di', 'chuyen_den', 'dieu_chinh')),
  product_key text not null,
  code text not null,
  name text,
  qty numeric not null,                      -- có dấu: + vào kho, − ra kho
  transfer_id uuid,                          -- cặp phiếu chuyển kho
  note text,
  created_by uuid default auth.uid(),
  created_by_name text,
  created_at timestamptz not null default now()
);
create index if not exists stock_moves_wh_day on public.stock_moves (wh_id, day);
create index if not exists stock_moves_transfer on public.stock_moves (transfer_id);

do $$ declare t text; begin
  foreach t in array array['stock_counts', 'stock_moves'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('grant select, insert, delete on public.%I to authenticated', t);
    execute format('drop policy if exists %I on public.%I', t || '_read', t);
    execute format('create policy %I on public.%I for select to authenticated using ((select public.has_role(''admin'',''lanh_dao'',''quan_ly'',''ke_toan'',''kho'',''truong_team'',''marketing'')))', t || '_read', t);
    execute format('drop policy if exists %I on public.%I', t || '_ins', t);
    execute format('create policy %I on public.%I for insert to authenticated with check ((select public.has_role(''admin'',''quan_ly'',''ke_toan'',''kho'')))', t || '_ins', t);
    execute format('drop policy if exists %I on public.%I', t || '_del', t);
    execute format('create policy %I on public.%I for delete to authenticated using ((select public.has_role(''admin'',''quan_ly'',''ke_toan'',''kho'')))', t || '_del', t);
  end loop;
end $$;

-- ---------- lúc hàng rời kho / về kho ----------
alter table public.orders add column if not exists shipped_at timestamptz;
alter table public.orders add column if not exists returned_at timestamptz;
create index if not exists orders_shipped_at on public.orders (shipped_at) where shipped_at is not null;
create index if not exists orders_returned_at on public.orders (returned_at) where returned_at is not null;

-- Đơn đã có: lấy mốc gần đúng (lần cập nhật cuối). Chỉ ảnh hưởng đơn trước ngày kiểm kho nên không làm lệch tồn.
alter table public.orders disable trigger orders_derive;
update public.orders set shipped_at = coalesce(updated_at, inserted_at)
where shipped_at is null and status in (2,3,4,5,15,16);
update public.orders set returned_at = coalesce(updated_at, inserted_at)
where returned_at is null and status in (5,15);
alter table public.orders enable trigger orders_derive;

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

-- ---------- báo cáo tồn ----------
-- Mỗi dòng: một sản phẩm trong một kho. on_hand = null khi kho chưa kiểm kho lần nào.
-- unit_cost (giá vốn nhập gần nhất) chỉ trả cho người xem được chi phí.
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
    select w.id as wid, w.as_of, lower(btrim(i->>'code')) as pk, i->>'code' as code, i->>'name' as name,
           coalesce((i->>'quantity')::numeric, 1) as q,
           case when o.status = 5 then coalesce(nullif((i->>'ret')::numeric, 0), coalesce((i->>'quantity')::numeric, 1))
                when o.status = 15 then coalesce((i->>'ret')::numeric, 0) else 0 end as rq,
           (o.shipped_at at time zone coalesce(mk.timezone, 'Asia/Ho_Chi_Minh'))::date as sd,
           (o.returned_at at time zone coalesce(mk.timezone, 'Asia/Ho_Chi_Minh'))::date as rd
    from public.orders o
    join w on lower(btrim(o.warehouse)) = any(w.names)
    left join public.markets mk on mk.id = o.market_id
    cross join lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i
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
revoke all on function public.stock_report() from public, anon;
grant execute on function public.stock_report() to authenticated;

-- Kho trên POS có đơn trong 60 ngày và đang gán vào kho nào (để cấu hình).
create or replace function public.stock_pos_warehouses()
returns table (pos_name text, orders bigint, wh_id text)
language sql stable security definer set search_path = public as $$
  select o.warehouse, count(*),
         (select w.id from public.warehouses w where lower(btrim(o.warehouse)) = any(array(select lower(btrim(x)) from unnest(w.pos_names) x)) order by w.sort limit 1)
  from public.orders o
  where o.inserted_at >= now() - interval '60 days' and coalesce(o.warehouse, '') <> ''
    and (select public.has_role('admin','lanh_dao','quan_ly','ke_toan','kho','truong_team','marketing'))
  group by o.warehouse order by 2 desc
$$;
revoke all on function public.stock_pos_warehouses() from public, anon;
grant execute on function public.stock_pos_warehouses() to authenticated;

-- Mã sản phẩm đã có trong đơn 45 ngày qua: để kiểm tra file kiểm kho / phiếu kho gõ đúng mã.
create or replace function public.stock_known_products()
returns table (code text, name text)
language sql stable security definer set search_path = public as $$
  select distinct on (lower(btrim(i->>'code'))) btrim(i->>'code'), i->>'name'
  from public.orders o cross join lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i
  where o.inserted_at >= now() - interval '45 days' and coalesce(btrim(i->>'code'), '') <> ''
    and (select public.has_role('admin','lanh_dao','quan_ly','ke_toan','kho','truong_team','marketing'))
  order by lower(btrim(i->>'code')), o.inserted_at desc
$$;
revoke all on function public.stock_known_products() from public, anon;
grant execute on function public.stock_known_products() to authenticated;

-- Lưu một lần kiểm kho: thay toàn bộ số đếm của kho đó cho ngày đó (tải lại file thì ghi đè).
create or replace function public.stock_count_save(p_wh text, p_as_of date, p_rows jsonb, p_by text default null)
returns int language plpgsql security definer set search_path = public as $$
declare n int;
begin
  if not public.has_role('admin','quan_ly','ke_toan','kho') then raise exception 'Tài khoản này không có quyền nhập kiểm kho'; end if;
  if not exists (select 1 from public.warehouses where id = p_wh) then raise exception 'Không có kho %', p_wh; end if;
  delete from public.stock_counts where wh_id = p_wh and as_of = p_as_of;
  insert into public.stock_counts (wh_id, as_of, product_key, code, name, qty, created_by_name)
  select p_wh, p_as_of, lower(btrim(x->>'code')), (array_agg(btrim(x->>'code')))[1], max(x->>'name'), sum((x->>'qty')::numeric), p_by
  from jsonb_array_elements(p_rows) x
  where coalesce(btrim(x->>'code'), '') <> '' and (x->>'qty') is not null
  group by lower(btrim(x->>'code'));
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.stock_count_save(text, date, jsonb, text) from public, anon;
grant execute on function public.stock_count_save(text, date, jsonb, text) to authenticated;

-- Chuyển kho: mỗi sản phẩm tạo một cặp phiếu (đi − / đến +) cùng mã chuyển.
create or replace function public.stock_transfer(p_day date, p_from text, p_to text, p_items jsonb, p_note text default null, p_by text default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare t uuid := gen_random_uuid();
begin
  if not public.has_role('admin','quan_ly','ke_toan','kho') then raise exception 'Tài khoản này không có quyền chuyển kho'; end if;
  if p_from = p_to then raise exception 'Kho đi và kho đến phải khác nhau'; end if;
  if (select count(*) from public.warehouses where id in (p_from, p_to)) < 2 then raise exception 'Kho không tồn tại'; end if;
  insert into public.stock_moves (day, wh_id, kind, product_key, code, name, qty, transfer_id, note, created_by_name)
  select p_day, w.wh, w.kind, lower(btrim(x->>'code')), btrim(x->>'code'), x->>'name', w.sgn * abs((x->>'qty')::numeric), t, p_note, p_by
  from jsonb_array_elements(p_items) x
  cross join (values (p_from, 'chuyen_di', -1), (p_to, 'chuyen_den', 1)) w(wh, kind, sgn)
  where coalesce(btrim(x->>'code'), '') <> '' and coalesce((x->>'qty')::numeric, 0) <> 0;
  return t;
end $$;
revoke all on function public.stock_transfer(date, text, text, jsonb, text, text) from public, anon;
grant execute on function public.stock_transfer(date, text, text, jsonb, text, text) to authenticated;

-- Trả cả bảng tồn trong một lần gọi (API giới hạn 1.000 dòng mỗi lần; gọi nhiều trang sẽ phải tính lại nhiều lần).
create or replace function public.stock_report_all() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.stock_report() t
$$;
revoke all on function public.stock_report_all() from public, anon;
grant execute on function public.stock_report_all() to authenticated;
create or replace function public.stock_known_products_all() returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.stock_known_products() t
$$;
revoke all on function public.stock_known_products_all() from public, anon;
grant execute on function public.stock_known_products_all() to authenticated;
