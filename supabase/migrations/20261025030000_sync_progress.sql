-- Tiến độ đồng bộ để trang Quản trị hiện thanh tiến độ.
-- sync_total: số đơn POS báo có trong lượt kéo hiện tại; sync_done: đã xử lý bao nhiêu.
alter table public.pos_shops
  add column if not exists sync_total int,
  add column if not exists sync_done int;

-- Số đơn đang lưu của từng shop.
create or replace function public.admin_shop_counts() returns table (shop_id text, orders bigint)
language sql stable security definer set search_path = public as $$
  select o.shop_id, count(*) from public.orders o where public.has_role('admin','quan_ly') group by o.shop_id
$$;
revoke all on function public.admin_shop_counts() from public, anon;
grant execute on function public.admin_shop_counts() to authenticated;

-- Lượt kéo lần đầu đang dở theo cách cũ (theo ngày cập nhật) thì bắt đầu lại theo cách mới (theo ngày tạo).
update public.pos_shops set sync_window_start = null, sync_window_end = null, sync_page = null, sync_total = null, sync_done = null
where last_synced_at is null and sync_window_start is not null;
