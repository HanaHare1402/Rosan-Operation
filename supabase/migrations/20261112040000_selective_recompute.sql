-- Tính lại có chọn lọc: trước đây đổi giá nhập / mã gán giá vốn / từ khoá kênh là đánh dấu tính lại TOÀN BỘ đơn
-- (50.000 đơn hôm nay, cả chục triệu đơn sau này). Nay chỉ đánh dấu các đơn bị ảnh hưởng:
--   * Giá nhập (purchases): đơn có dòng hàng trùng mã / mã gán / tên tiếng Anh của các dòng nhập vừa thêm, sửa, xoá.
--   * Mã gán giá vốn (product_alias): đơn có dòng hàng mang mã POS vừa gán / bỏ gán.
--   * Kênh (channels): đơn đang thuộc kênh vừa sửa / xoá, và đơn có nguồn khớp từ khoá cũ hoặc mới của kênh đó.
-- Đơn được đánh dấu sẽ được tính lại theo từng đợt như trước (sau mỗi lần đồng bộ POS).
-- Nút "Tính lại toàn bộ đơn" ở Quản trị vẫn giữ nguyên để dùng khi cần.
-- Chạy sau 20261112030000_order_daily.sql. Chạy lại nhiều lần không lỗi. Chạy nhanh (vài giây).

begin;
set local statement_timeout = '5min';

-- Tra nhanh dòng hàng theo mã / tên (dùng khi đổi giá nhập).
create index if not exists order_lines_code_lower on public.order_lines (lower(code));
create index if not exists order_lines_name_lower on public.order_lines (lower(name));

-- Đánh dấu tính lại các đơn có dòng hàng khớp: mã (chữ thường) thuộc p_codes, hoặc mã POS được gán sang mã thuộc p_codes,
-- hoặc mã POS thuộc p_pos_keys, hoặc tên thuộc p_names. Trả về số đơn được đánh dấu.
create or replace function public.mark_orders_by_products(p_codes text[], p_names text[], p_pos_keys text[])
returns bigint language plpgsql security definer set search_path = public as $$
declare keys text[]; n bigint;
begin
  p_codes := coalesce(array(select distinct lower(btrim(x)) from unnest(p_codes) x where coalesce(btrim(x), '') <> ''), '{}');
  p_names := coalesce(array(select distinct lower(btrim(x)) from unnest(p_names) x where coalesce(btrim(x), '') <> ''), '{}');
  keys := coalesce(array(select distinct lower(btrim(x)) from unnest(p_pos_keys) x where coalesce(btrim(x), '') <> ''), '{}')
          || coalesce(array(select a.pos_key from public.product_alias a where lower(a.cost_code) = any(p_codes)), '{}')
          || p_codes;
  if cardinality(keys) = 0 and cardinality(p_names) = 0 then return 0; end if;
  update public.orders o set derived_at = null
  from (
    select distinct l.shop_id, l.pos_order_id from public.order_lines l
    where lower(l.code) = any(keys)
    union
    select distinct l.shop_id, l.pos_order_id from public.order_lines l
    where cardinality(p_names) > 0 and lower(l.name) = any(p_names)
  ) x
  where o.shop_id = x.shop_id and o.pos_order_id = x.pos_order_id and o.derived_at is not null;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.mark_orders_by_products(text[], text[], text[]) from public, anon, authenticated;

-- Giá nhập đổi.
create or replace function public.recompute_on_purchases() returns trigger
language plpgsql security definer set search_path = public as $$
declare c text[] := '{}'; nm text[] := '{}';
begin
  if tg_op in ('INSERT', 'UPDATE') then
    select coalesce(array_agg(code), '{}'), coalesce(array_agg(name_en), '{}') into c, nm from new_rows;
  end if;
  if tg_op in ('DELETE', 'UPDATE') then
    select c || coalesce(array_agg(code), '{}'), nm || coalesce(array_agg(name_en), '{}') into c, nm from old_rows;
  end if;
  perform public.mark_orders_by_products(c, nm, '{}');
  return null;
end $$;
revoke all on function public.recompute_on_purchases() from public, anon, authenticated;

-- Mã gán giá vốn đổi.
create or replace function public.recompute_on_alias() returns trigger
language plpgsql security definer set search_path = public as $$
declare k text[] := '{}';
begin
  if tg_op in ('INSERT', 'UPDATE') then select coalesce(array_agg(pos_key), '{}') into k from new_rows; end if;
  if tg_op in ('DELETE', 'UPDATE') then select k || coalesce(array_agg(pos_key), '{}') into k from old_rows; end if;
  perform public.mark_orders_by_products('{}', '{}', k);
  return null;
end $$;
revoke all on function public.recompute_on_alias() from public, anon, authenticated;

-- Kênh đổi: đơn đang thuộc các kênh đó + đơn có nguồn khớp từ khoá cũ / mới (cùng cách so khớp như lúc gán kênh).
create or replace function public.recompute_on_channels() returns trigger
language plpgsql security definer set search_path = public as $$
declare ids text[] := '{}'; kws text[] := '{}';
begin
  if tg_op in ('INSERT', 'UPDATE') then
    select coalesce(array_agg(id), '{}') into ids from new_rows;
    select coalesce(array_agg(distinct lower(kw)), '{}') into kws from new_rows, unnest(keywords) kw where kw <> '';
  end if;
  if tg_op in ('DELETE', 'UPDATE') then
    select ids || coalesce(array_agg(id), '{}') into ids from old_rows;
    select kws || coalesce(array_agg(distinct lower(kw)), '{}') into kws from old_rows, unnest(keywords) kw where kw <> '';
  end if;
  update public.orders o set derived_at = null
  where o.derived_at is not null
    and (o.channel_id = any(ids)
         or (o.source_name is not null and exists (select 1 from unnest(kws) kw where lower(o.source_name) like '%' || kw || '%')));
  return null;
end $$;
revoke all on function public.recompute_on_channels() from public, anon, authenticated;

-- Thay các trigger "tính lại toàn bộ" cũ.
drop trigger if exists purchases_recompute on public.purchases;
drop trigger if exists purchases_recompute_ins on public.purchases;
drop trigger if exists purchases_recompute_upd on public.purchases;
drop trigger if exists purchases_recompute_del on public.purchases;
create trigger purchases_recompute_ins after insert on public.purchases referencing new table as new_rows
  for each statement execute function public.recompute_on_purchases();
create trigger purchases_recompute_upd after update on public.purchases referencing old table as old_rows new table as new_rows
  for each statement execute function public.recompute_on_purchases();
create trigger purchases_recompute_del after delete on public.purchases referencing old table as old_rows
  for each statement execute function public.recompute_on_purchases();

drop trigger if exists product_alias_recompute on public.product_alias;
drop trigger if exists product_alias_recompute_ins on public.product_alias;
drop trigger if exists product_alias_recompute_upd on public.product_alias;
drop trigger if exists product_alias_recompute_del on public.product_alias;
create trigger product_alias_recompute_ins after insert on public.product_alias referencing new table as new_rows
  for each statement execute function public.recompute_on_alias();
create trigger product_alias_recompute_upd after update on public.product_alias referencing old table as old_rows new table as new_rows
  for each statement execute function public.recompute_on_alias();
create trigger product_alias_recompute_del after delete on public.product_alias referencing old table as old_rows
  for each statement execute function public.recompute_on_alias();

drop trigger if exists channels_recompute on public.channels;
drop trigger if exists channels_recompute_ins on public.channels;
drop trigger if exists channels_recompute_upd on public.channels;
drop trigger if exists channels_recompute_del on public.channels;
create trigger channels_recompute_ins after insert on public.channels referencing new table as new_rows
  for each statement execute function public.recompute_on_channels();
create trigger channels_recompute_upd after update on public.channels referencing old table as old_rows new table as new_rows
  for each statement execute function public.recompute_on_channels();
create trigger channels_recompute_del after delete on public.channels referencing old table as old_rows
  for each statement execute function public.recompute_on_channels();

commit;
