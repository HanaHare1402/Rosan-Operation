-- Rosan Operation: tài khoản, phân quyền, shop POS (key cất trong Vault), đơn hàng đồng bộ từ Pancake POS.
-- Chạy một lần trong Supabase: SQL Editor → dán toàn bộ file → Run (hoặc `supabase db push`).

create extension if not exists supabase_vault with schema vault;

-- ---------- vai trò ----------
do $$ begin
  create type public.app_role as enum ('admin','quan_ly','marketing','ke_toan','van_don','kho','sale');
exception when duplicate_object then null; end $$;

-- Mỗi tài khoản đăng nhập có một dòng ở đây. role = null nghĩa là chưa được admin cấp quyền.
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  full_name text not null default '',
  role public.app_role,
  team text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, email, full_name)
  values (new.id, coalesce(new.email,''), coalesce(new.raw_user_meta_data->>'full_name',''))
  on conflict (id) do nothing;
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- Các hàm kiểm tra quyền dùng trong RLS. security definer để không bị đệ quy RLS trên profiles.
create or replace function public.my_role() returns public.app_role
language sql stable security definer set search_path = public as $$
  select role from public.profiles where id = auth.uid()
$$;

create or replace function public.has_role(variadic roles public.app_role[]) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select role = any(roles) from public.profiles where id = auth.uid()), false)
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select public.has_role('admin')
$$;

alter table public.profiles enable row level security;
drop policy if exists profiles_select on public.profiles;
create policy profiles_select on public.profiles for select to authenticated
  using (id = auth.uid() or public.has_role('admin','quan_ly'));
-- Không ai sửa trực tiếp được role: chỉ admin, qua Edge Function admin-users (service role).
revoke insert, update, delete on public.profiles from anon, authenticated;
grant update (full_name) on public.profiles to authenticated;
drop policy if exists profiles_update_self on public.profiles;
create policy profiles_update_self on public.profiles for update to authenticated
  using (id = auth.uid()) with check (id = auth.uid());

-- ---------- shop trên POS ----------
-- id dạng text để khớp với màn Cài đặt của trang. api_key_secret_id trỏ vào vault.secrets.
create table if not exists public.pos_shops (
  id text primary key default gen_random_uuid()::text,
  channel text not null default 'fb',
  name text not null,
  pos_shop_id text not null default '',
  team text not null default '',
  staff text not null default '',
  active boolean not null default true,
  api_key_secret_id uuid,
  api_key_hint text,
  last_synced_at timestamptz,
  sync_window_start timestamptz,
  sync_window_end timestamptz,
  sync_page int,
  last_sync_status text,
  last_sync_error text,
  last_sync_count int,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.pos_shops enable row level security;
drop policy if exists pos_shops_select on public.pos_shops;
create policy pos_shops_select on public.pos_shops for select to authenticated
  using (public.my_role() is not null);
drop policy if exists pos_shops_write on public.pos_shops;
create policy pos_shops_write on public.pos_shops for all to authenticated
  using (public.has_role('admin','quan_ly')) with check (public.has_role('admin','quan_ly'));
-- Chỉ được sửa các cột cấu hình. Cột key và trạng thái đồng bộ chỉ hàm bên dưới và server ghi.
revoke insert, update on public.pos_shops from anon, authenticated;
grant insert (id, channel, name, pos_shop_id, team, staff, active),
      update (channel, name, pos_shop_id, team, staff, active) on public.pos_shops to authenticated;

-- Admin đặt key: key đi thẳng vào Vault, bảng chỉ giữ 4 ký tự cuối để nhận biết.
create or replace function public.admin_set_pos_key(p_shop text, p_key text) returns void
language plpgsql security definer set search_path = public, vault as $$
declare sid uuid;
begin
  if not public.is_admin() then raise exception 'Chỉ admin được đặt API key' using errcode = '42501'; end if;
  p_key := btrim(coalesce(p_key,''));
  select api_key_secret_id into sid from public.pos_shops where id = p_shop;
  if not found then raise exception 'Không tìm thấy shop %', p_shop; end if;
  if p_key = '' then
    if sid is not null then delete from vault.secrets where id = sid; end if;
    update public.pos_shops set api_key_secret_id = null, api_key_hint = null, updated_at = now() where id = p_shop;
    return;
  end if;
  if sid is null then
    sid := vault.create_secret(p_key, 'pos_api_key_' || p_shop || '_' || extract(epoch from now())::bigint, 'Pancake POS API key');
  else
    perform vault.update_secret(sid, p_key);
  end if;
  update public.pos_shops set api_key_secret_id = sid, api_key_hint = right(p_key, 4), updated_at = now() where id = p_shop;
end $$;
revoke all on function public.admin_set_pos_key(text, text) from public, anon;
grant execute on function public.admin_set_pos_key(text, text) to authenticated;

-- Xoá shop thì xoá luôn key trong Vault.
create or replace function public.pos_shops_drop_secret() returns trigger
language plpgsql security definer set search_path = public, vault as $$
begin
  if old.api_key_secret_id is not null then delete from vault.secrets where id = old.api_key_secret_id; end if;
  return old;
end $$;
drop trigger if exists pos_shops_drop_secret on public.pos_shops;
create trigger pos_shops_drop_secret after delete on public.pos_shops
  for each row execute function public.pos_shops_drop_secret();

-- Chỉ server (service_role, trong Edge Function) đọc được key.
create or replace function public.internal_get_pos_key(p_shop text) returns text
language sql stable security definer set search_path = public, vault as $$
  select ds.decrypted_secret from public.pos_shops s
  join vault.decrypted_secrets ds on ds.id = s.api_key_secret_id
  where s.id = p_shop
$$;
revoke all on function public.internal_get_pos_key(text) from public, anon, authenticated;
grant execute on function public.internal_get_pos_key(text) to service_role;

-- Lịch đồng bộ (pg_cron) gửi mã bí mật này; Edge Function so với bản trong Vault.
create or replace function public.internal_check_cron_secret(p_secret text) returns boolean
language sql stable security definer set search_path = public, vault as $$
  select coalesce(p_secret <> '' and exists(select 1 from vault.decrypted_secrets where name = 'cron_secret' and decrypted_secret = p_secret), false)
$$;
revoke all on function public.internal_check_cron_secret(text) from public, anon, authenticated;
grant execute on function public.internal_check_cron_secret(text) to service_role;

-- ---------- đơn vị FFM ----------
create table if not exists public.ffm_units (
  id text primary key,
  name text not null,
  warehouse text not null default '',
  fee_pct numeric not null default 0,
  ship_php numeric not null default 0,
  share numeric not null default 0,
  note text not null default '',
  updated_at timestamptz not null default now()
);
alter table public.ffm_units enable row level security;
drop policy if exists ffm_select on public.ffm_units;
create policy ffm_select on public.ffm_units for select to authenticated using (public.my_role() is not null);
drop policy if exists ffm_write on public.ffm_units;
create policy ffm_write on public.ffm_units for all to authenticated
  using (public.has_role('admin','quan_ly','ke_toan')) with check (public.has_role('admin','quan_ly','ke_toan'));
grant select, insert, update, delete on public.ffm_units to authenticated;

insert into public.ffm_units (id, name, warehouse, fee_pct, ship_php, share, note) values
  ('gip','GIP','Kho GIP',2.5,48,70,'Phí giả định, sửa theo hợp đồng'),
  ('gpx','GPX','Kho GPX',3,52,30,'Phí giả định, sửa theo hợp đồng')
on conflict (id) do nothing;

-- ---------- đơn hàng từ POS ----------
create table if not exists public.orders (
  shop_id text not null references public.pos_shops(id) on delete cascade,
  pos_order_id text not null,
  status int,
  status_name text,
  inserted_at timestamptz,
  updated_at timestamptz,
  total_price numeric,
  cod numeric,
  shipping_fee numeric,
  bill_full_name text,
  bill_phone_number text,
  province text,
  tracking text,
  warehouse text,
  seller text,
  items jsonb,
  raw jsonb not null,
  synced_at timestamptz not null default now(),
  primary key (shop_id, pos_order_id)
);
create index if not exists orders_inserted_at on public.orders (inserted_at desc);
create index if not exists orders_status on public.orders (status);

alter table public.orders enable row level security;
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders for select to authenticated
  using (public.has_role('admin','quan_ly','ke_toan','van_don','kho','sale','marketing'));
revoke insert, update, delete on public.orders from anon, authenticated;

-- Nhật ký mỗi lần đồng bộ, để admin xem lỗi.
create table if not exists public.sync_runs (
  id bigint generated always as identity primary key,
  shop_id text references public.pos_shops(id) on delete cascade,
  started_at timestamptz not null default now(),
  finished_at timestamptz,
  trigger text,
  pages int,
  orders int,
  status text,
  error text
);
alter table public.sync_runs enable row level security;
drop policy if exists sync_runs_select on public.sync_runs;
create policy sync_runs_select on public.sync_runs for select to authenticated using (public.has_role('admin','quan_ly'));
revoke insert, update, delete on public.sync_runs from anon, authenticated;

-- Realtime cho màn Cài đặt (nhiều người sửa cùng lúc thấy ngay).
do $$ begin
  alter publication supabase_realtime add table public.pos_shops, public.ffm_units;
exception when others then null; end $$;
