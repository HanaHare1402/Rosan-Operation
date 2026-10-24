-- Khoảng đồng bộ do admin chọn: chỉ kéo / giữ đơn tạo từ mốc này trở đi.
-- Chạy sau 20261025010000_pos_fields.sql.

create table if not exists public.app_settings (
  key text primary key,
  value jsonb not null,
  updated_at timestamptz not null default now()
);
alter table public.app_settings enable row level security;
grant select, insert, update on public.app_settings to authenticated;
drop policy if exists app_settings_read on public.app_settings;
create policy app_settings_read on public.app_settings for select to authenticated using (public.has_role('admin','quan_ly'));
drop policy if exists app_settings_write on public.app_settings;
create policy app_settings_write on public.app_settings for all to authenticated using (public.is_admin()) with check (public.is_admin());

-- mode: month = từ đầu tháng hiện tại; months = từ đầu tháng cách đây n-1 tháng (n=2: tháng trước);
--       days = n ngày gần nhất; date = từ ngày cố định. purge = tự xoá đơn cũ hơn mốc.
insert into public.app_settings (key, value) values ('sync_range', '{"mode":"month","n":1,"date":null,"purge":true}')
on conflict (key) do nothing;

-- Mốc đồng bộ của một shop, theo múi giờ thị trường của shop.
create or replace function public.sync_cutoff(p_shop text) returns timestamptz
language sql stable security definer set search_path = public as $$
  with cfg as (select coalesce((select value from public.app_settings where key = 'sync_range'), '{"mode":"month"}'::jsonb) v),
       tz as (select coalesce((select m.timezone from public.pos_shops s join public.markets m on m.id = s.market_id where s.id = p_shop), 'Asia/Ho_Chi_Minh') z)
  select case cfg.v->>'mode'
    when 'months' then (date_trunc('month', now() at time zone tz.z) - make_interval(months => greatest(coalesce((cfg.v->>'n')::int, 1), 1) - 1)) at time zone tz.z
    when 'days' then (date_trunc('day', now() at time zone tz.z) - make_interval(days => greatest(coalesce((cfg.v->>'n')::int, 30), 1) - 1)) at time zone tz.z
    when 'date' then coalesce((cfg.v->>'date')::date::timestamp at time zone tz.z, date_trunc('month', now() at time zone tz.z) at time zone tz.z)
    else date_trunc('month', now() at time zone tz.z) at time zone tz.z
  end
  from cfg, tz
$$;
grant execute on function public.sync_cutoff(text) to authenticated, service_role;

-- Xoá đơn cũ hơn mốc (khi bật purge) và nhật ký đồng bộ quá 30 ngày.
create or replace function public.purge_old_orders() returns bigint
language plpgsql security definer set search_path = public as $$
declare n bigint := 0;
begin
  if auth.uid() is not null and not public.is_admin() then raise exception 'Chỉ admin' using errcode = '42501'; end if;
  if coalesce((select (value->>'purge')::boolean from public.app_settings where key = 'sync_range'), false) then
    delete from public.orders o using public.pos_shops s
    where s.id = o.shop_id and o.inserted_at < public.sync_cutoff(s.id);
    get diagnostics n = row_count;
  end if;
  delete from public.sync_runs where started_at < now() - interval '30 days';
  return n;
end $$;
revoke all on function public.purge_old_orders() from public, anon;
grant execute on function public.purge_old_orders() to authenticated, service_role;

-- Dung lượng hiện tại, cho admin theo dõi.
create or replace function public.admin_storage() returns table (orders bigint, oldest timestamptz, db_bytes bigint)
language sql stable security definer set search_path = public as $$
  select (select count(*) from public.orders), (select min(inserted_at) from public.orders), pg_database_size(current_database())
  where public.has_role('admin','quan_ly')
$$;
revoke all on function public.admin_storage() from public, anon;
grant execute on function public.admin_storage() to authenticated;
