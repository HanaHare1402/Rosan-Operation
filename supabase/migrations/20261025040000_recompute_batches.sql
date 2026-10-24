-- Tính lại đơn theo từng đợt nhỏ, tránh lỗi "statement timeout" (Supabase giới hạn ~8 giây/lệnh
-- cho tài khoản đăng nhập). Đổi kênh / bấm "Tính lại toàn bộ đơn" chỉ đánh dấu cần tính lại;
-- trang Quản trị và lịch 15 phút xử lý dần, mỗi đợt vài nghìn đơn.
-- Chạy sau 20261025030000_sync_progress.sql.

alter table public.orders add column if not exists derived_at timestamptz;
create index if not exists orders_derived_at on public.orders (derived_at);
create index if not exists orders_marketer_id_l on public.orders (lower(marketer_id));
create index if not exists orders_marketer_name_l on public.orders (lower(marketer_name));
create index if not exists orders_utm_code_l on public.orders (lower(utm_code));

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
  new.derived_at := clock_timestamp();
  return new;
end $$;

-- Đánh dấu: mọi đơn dựng trước thời điểm này cần tính lại.
create or replace function public.request_recompute() returns void
language sql security definer set search_path = public as $$
  insert into public.app_settings (key, value, updated_at) values ('recompute_after', jsonb_build_object('at', clock_timestamp()), now())
  on conflict (key) do update set value = excluded.value, updated_at = now()
$$;
revoke all on function public.request_recompute() from public, anon, authenticated;

-- Tính lại một đợt; trả về số đơn vừa tính và số còn lại.
create or replace function public.recompute_batch(p_limit int default 2000) returns table (done bigint, remaining bigint)
language plpgsql security definer set search_path = public as $$
declare since timestamptz; n bigint;
begin
  if auth.uid() is not null and not public.has_role('admin','quan_ly') then raise exception 'Chỉ admin hoặc quản lý' using errcode = '42501'; end if;
  since := coalesce((select (value->>'at')::timestamptz from public.app_settings where key = 'recompute_after'), '-infinity');
  with c as (
    select shop_id, pos_order_id from public.orders
    where derived_at is null or derived_at < since
    limit greatest(1, least(p_limit, 20000))
    for update skip locked
  )
  update public.orders o set synced_at = o.synced_at from c
  where o.shop_id = c.shop_id and o.pos_order_id = c.pos_order_id;
  get diagnostics n = row_count;
  return query select n, (select count(*) from public.orders where derived_at is null or derived_at < since);
end $$;
revoke all on function public.recompute_batch(int) from public, anon;
grant execute on function public.recompute_batch(int) to authenticated, service_role;

-- Nút "Tính lại toàn bộ đơn": chỉ đánh dấu, trả về số đơn cần tính.
create or replace function public.admin_recompute_orders() returns bigint
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null and not public.is_admin() then raise exception 'Chỉ admin' using errcode = '42501'; end if;
  perform public.request_recompute();
  return (select count(*) from public.orders);
end $$;

-- Sửa nhân sự: đánh dấu các đơn khớp mã cũ hoặc mới; đợt tính lại gán lại sau.
create or replace function public.recompute_orders_staff() returns trigger
language plpgsql security definer set search_path = public as $$
declare names text[]; pg text[];
begin
  names := array(select lower(btrim(x)) from unnest(
    coalesce((case when tg_op <> 'INSERT' then old.pos_names || old.name end), '{}') ||
    coalesce((case when tg_op <> 'DELETE' then new.pos_names || new.name end), '{}')) x);
  pg := coalesce((case when tg_op <> 'INSERT' then old.pages end), '{}') || coalesce((case when tg_op <> 'DELETE' then new.pages end), '{}');
  update public.orders o set derived_at = null
  where o.derived_at is not null and (
        lower(o.marketer_id) = any(names) or lower(o.marketer_name) = any(names) or lower(o.utm_code) = any(names)
     or lower(o.seller_name) = any(names) or o.page_id = any(pg) or o.page_name = any(pg)
     or o.staff_id = (case when tg_op <> 'INSERT' then old.id end));
  return null;
end $$;

create or replace function public.recompute_orders_team() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.project_id is distinct from old.project_id then
    update public.orders set derived_at = null where team_id = new.id and derived_at is not null;
  end if;
  return null;
end $$;

create or replace function public.recompute_orders_shop_market() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.market_id is distinct from old.market_id then
    update public.orders set derived_at = null where shop_id = new.id and derived_at is not null;
  end if;
  return null;
end $$;

-- Quyền xem đơn: đọc phạm vi của người xem MỘT lần mỗi câu lệnh (subquery không phụ thuộc dòng),
-- thay vì gọi hàm cho từng đơn; trước đây báo cáo 50.000 đơn mất ~5 giây.
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders for select to authenticated using (
  case (select scope from public.my_scope())
    when 'all' then true
    when 'project' then array[project_id] <@ (select project_ids from public.my_scope())
    when 'team' then team_id = (select team_id from public.my_scope())
    when 'self' then staff_id = (select staff_id from public.my_scope())
    else false
  end
);

-- Đổi kênh (từ khoá) ảnh hưởng mọi đơn: đánh dấu thay vì sửa ngay.
create or replace function public.recompute_orders_channels() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.request_recompute();
  return null;
end $$;

-- Đơn hiện có chưa có derived_at nên sẽ được dựng lại một lần theo từng đợt (cắt raw cũ còn to, gán theo quy tắc mới).
