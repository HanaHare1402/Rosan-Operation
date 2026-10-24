-- Tổ chức công ty: dự án → team → nhân sự; thị trường; kênh bán.
-- Đơn POS là dữ liệu thô; trigger tự gán đơn vào nhân sự / team / dự án / kênh / thị trường.
-- Sửa khai báo (VD đổi team của một marketer) thì các đơn liên quan được tính lại ngay.
-- Chạy sau 20261024000000_init.sql và 20261024010000_sync_lock.sql. Chạy lại nhiều lần không lỗi.

-- Vai trò trưởng team. Không dùng giá trị mới này trong cùng file (Postgres không cho).
alter type public.app_role add value if not exists 'truong_team';

-- ---------- danh mục ----------
create table if not exists public.projects (
  id text primary key default gen_random_uuid()::text,
  name text not null unique,
  note text not null default '',
  sort int not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists public.teams (
  id text primary key default gen_random_uuid()::text,
  name text not null,
  project_id text references public.projects(id) on delete set null,
  target_vnd numeric not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (project_id, name)
);

create table if not exists public.markets (
  id text primary key default gen_random_uuid()::text,
  name text not null unique,
  currency text not null default 'PHP',
  rate_vnd numeric not null default 1,   -- 1 đơn vị tiền của thị trường = ? VNĐ
  timezone text not null default 'Asia/Ho_Chi_Minh',
  created_at timestamptz not null default now()
);

-- Kênh nhận ra từ "nguồn đơn" trên POS: nguồn chứa một trong các từ khoá là thuộc kênh đó.
create table if not exists public.channels (
  id text primary key default gen_random_uuid()::text,
  name text not null unique,
  keywords text[] not null default '{}',
  color text not null default '#8a9289',
  sort int not null default 0,
  created_at timestamptz not null default now()
);

-- Nhân sự: tên marketer trên POS (và các tên khác / page phụ trách) → team → dự án.
create table if not exists public.staff (
  id text primary key default gen_random_uuid()::text,
  name text not null,
  pos_names text[] not null default '{}',  -- tên marketer / người được gán trên POS (không phân biệt hoa thường)
  pages text[] not null default '{}',      -- page ID hoặc tên page phụ trách, dùng khi đơn không có marketer
  team_id text references public.teams(id) on delete set null,
  project_id text references public.projects(id) on delete set null, -- khi chưa thuộc team nào
  user_id uuid references auth.users(id) on delete set null,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists staff_team on public.staff (team_id);

alter table public.pos_shops add column if not exists market_id text references public.markets(id) on delete set null;
grant insert (market_id), update (market_id) on public.pos_shops to authenticated;

-- Phạm vi xem của từng tài khoản.
alter table public.profiles add column if not exists scope text not null default 'self';
alter table public.profiles add column if not exists project_ids text[] not null default '{}';
alter table public.profiles add column if not exists team_id text references public.teams(id) on delete set null;
alter table public.profiles add column if not exists staff_id text references public.staff(id) on delete set null;
do $$ begin
  alter table public.profiles add constraint profiles_scope_chk check (scope in ('all','project','team','self'));
exception when duplicate_object then null; end $$;
update public.profiles set scope = 'all' where role::text in ('admin','ke_toan') and scope = 'self';
update public.profiles set scope = 'project' where role::text in ('quan_ly','van_don','kho') and scope = 'self';

-- ---------- quyền xem theo phạm vi ----------
create or replace function public.my_scope() returns table (scope text, project_ids text[], team_id text, staff_id text)
language sql stable security definer set search_path = public as $$
  select p.scope, p.project_ids, p.team_id, p.staff_id from public.profiles p where p.id = auth.uid() and p.role is not null
$$;

create or replace function public.can_see(p_project text, p_team text, p_staff text) returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((
    select case s.scope
      when 'all' then true
      when 'project' then p_project = any(s.project_ids)
      when 'team' then p_team is not null and p_team = s.team_id
      when 'self' then p_staff is not null and p_staff = s.staff_id
      else false end
    from public.my_scope() s), false)
$$;

-- Quản lý được sửa team / nhân sự trong dự án mình phụ trách.
create or replace function public.can_manage_project(p_project text) returns boolean
language sql stable security definer set search_path = public as $$
  select public.is_admin() or (public.has_role('quan_ly') and p_project = any(coalesce((select project_ids from public.my_scope()), '{}')))
$$;

alter table public.projects enable row level security;
alter table public.teams enable row level security;
alter table public.markets enable row level security;
alter table public.channels enable row level security;
alter table public.staff enable row level security;
grant select, insert, update, delete on public.projects, public.teams, public.markets, public.channels, public.staff to authenticated;

drop policy if exists projects_read on public.projects;
create policy projects_read on public.projects for select to authenticated using (public.my_role() is not null);
drop policy if exists projects_write on public.projects;
create policy projects_write on public.projects for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists markets_read on public.markets;
create policy markets_read on public.markets for select to authenticated using (public.my_role() is not null);
drop policy if exists markets_write on public.markets;
create policy markets_write on public.markets for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists channels_read on public.channels;
create policy channels_read on public.channels for select to authenticated using (public.my_role() is not null);
drop policy if exists channels_write on public.channels;
create policy channels_write on public.channels for all to authenticated using (public.is_admin()) with check (public.is_admin());

drop policy if exists teams_read on public.teams;
create policy teams_read on public.teams for select to authenticated using (public.my_role() is not null);
drop policy if exists teams_write on public.teams;
create policy teams_write on public.teams for all to authenticated
  using (public.can_manage_project(project_id)) with check (public.can_manage_project(project_id));

drop policy if exists staff_read on public.staff;
create policy staff_read on public.staff for select to authenticated using (public.my_role() is not null);
drop policy if exists staff_write on public.staff;
create policy staff_write on public.staff for all to authenticated
  using (public.can_manage_project(coalesce((select t.project_id from public.teams t where t.id = team_id), project_id)))
  with check (public.can_manage_project(coalesce((select t.project_id from public.teams t where t.id = team_id), project_id)));

-- ---------- đơn: trường lấy từ dữ liệu thô + phân bổ ----------
alter table public.orders
  add column if not exists marketer_name text,
  add column if not exists seller_name text,
  add column if not exists page_id text,
  add column if not exists page_name text,
  add column if not exists source_name text,
  add column if not exists staff_id text,
  add column if not exists team_id text,
  add column if not exists project_id text,
  add column if not exists channel_id text,
  add column if not exists market_id text;
create index if not exists orders_project_time on public.orders (project_id, inserted_at desc);
create index if not exists orders_team_time on public.orders (team_id, inserted_at desc);
create index if not exists orders_staff_time on public.orders (staff_id, inserted_at desc);
create index if not exists orders_marketer on public.orders (lower(marketer_name));

-- Tên trường trên đơn POS có thể khác nhau giữa các bản; thử lần lượt. Sửa ở đây rồi chạy
-- `select public.admin_recompute_orders();` để áp lại cho đơn cũ, không cần kéo lại từ POS.
create or replace function public.order_derive() returns trigger
language plpgsql security definer set search_path = public as $$
declare r jsonb := new.raw; st record;
begin
  new.marketer_name := nullif(btrim(coalesce(r->'marketer'->>'name', r->>'marketer_name', r->'marketer'->>'fb_name', r->'marketer'->>'email', '')), '');
  new.seller_name := nullif(btrim(coalesce(r->'assigning_seller'->>'name', r->>'assigning_seller_name', r->'assigning_care'->>'name', '')), '');
  new.page_id := nullif(coalesce(r->>'page_id', r->'page'->>'id', ''), '');
  new.page_name := nullif(coalesce(r->'page'->>'name', r->>'page_name', ''), '');
  new.source_name := nullif(btrim(coalesce(r->>'order_sources_name', r->'order_sources'->>'name', r->>'source_name',
                       case when jsonb_typeof(r->'order_sources') in ('string','number') then r->>'order_sources' end,
                       r->>'p_utm_source', r->>'ad_source', '')), '');

  -- Nhân sự: theo marketer, rồi người được gán, rồi page.
  select s.id, s.team_id, coalesce(t.project_id, s.project_id) as project_id into st
  from public.staff s left join public.teams t on t.id = s.team_id
  where s.active and (
        (new.marketer_name is not null and lower(new.marketer_name) in (select lower(x) from unnest(s.pos_names || s.name) x))
     or (new.marketer_name is null and new.seller_name is not null and lower(new.seller_name) in (select lower(x) from unnest(s.pos_names || s.name) x))
     or (new.marketer_name is null and new.seller_name is null and (new.page_id = any(s.pages) or new.page_name = any(s.pages))))
  order by (new.marketer_name is not null and lower(new.marketer_name) in (select lower(x) from unnest(s.pos_names || s.name) x)) desc
  limit 1;
  new.staff_id := st.id; new.team_id := st.team_id; new.project_id := st.project_id;

  select c.id into new.channel_id from public.channels c
  where new.source_name is not null and exists (select 1 from unnest(c.keywords) k where k <> '' and lower(new.source_name) like '%' || lower(k) || '%')
  order by c.sort, c.name limit 1;

  select s.market_id into new.market_id from public.pos_shops s where s.id = new.shop_id;
  return new;
end $$;

drop trigger if exists orders_derive on public.orders;
create trigger orders_derive before insert or update on public.orders
  for each row execute function public.order_derive();

-- Tính lại phân bổ khi danh mục đổi. "Chạm" vào dòng để trigger chạy lại.
create or replace function public.recompute_orders_staff() returns trigger
language plpgsql security definer set search_path = public as $$
declare names text[]; pg text[];
begin
  names := coalesce((case when tg_op <> 'INSERT' then old.pos_names || old.name end), '{}') || coalesce((case when tg_op <> 'DELETE' then new.pos_names || new.name end), '{}');
  pg := coalesce((case when tg_op <> 'INSERT' then old.pages end), '{}') || coalesce((case when tg_op <> 'DELETE' then new.pages end), '{}');
  update public.orders o set synced_at = o.synced_at
  where lower(o.marketer_name) in (select lower(x) from unnest(names) x)
     or (o.marketer_name is null and lower(o.seller_name) in (select lower(x) from unnest(names) x))
     or (o.marketer_name is null and o.seller_name is null and (o.page_id = any(pg) or o.page_name = any(pg)))
     or o.staff_id = (case when tg_op <> 'INSERT' then old.id end);
  return null;
end $$;
drop trigger if exists staff_recompute on public.staff;
create trigger staff_recompute after insert or update or delete on public.staff
  for each row execute function public.recompute_orders_staff();

create or replace function public.recompute_orders_team() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.project_id is distinct from old.project_id then
    update public.orders set project_id = new.project_id where team_id = new.id;
  end if;
  return null;
end $$;
drop trigger if exists teams_recompute on public.teams;
create trigger teams_recompute after update on public.teams
  for each row execute function public.recompute_orders_team();

create or replace function public.recompute_orders_channels() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update public.orders o set synced_at = o.synced_at where o.source_name is not null;
  return null;
end $$;
drop trigger if exists channels_recompute on public.channels;
create trigger channels_recompute after insert or update or delete on public.channels
  for each statement execute function public.recompute_orders_channels();

create or replace function public.recompute_orders_shop_market() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.market_id is distinct from old.market_id then
    update public.orders set market_id = new.market_id where shop_id = new.id;
  end if;
  return null;
end $$;
drop trigger if exists pos_shops_market_recompute on public.pos_shops;
create trigger pos_shops_market_recompute after update on public.pos_shops
  for each row execute function public.recompute_orders_shop_market();

create or replace function public.admin_recompute_orders() returns bigint
language plpgsql security definer set search_path = public as $$
declare n bigint;
begin
  -- Gọi từ SQL Editor (không có người dùng đăng nhập) hoặc admin.
  if auth.uid() is not null and not public.is_admin() then raise exception 'Chỉ admin' using errcode = '42501'; end if;
  update public.orders set synced_at = synced_at;
  get diagnostics n = row_count;
  return n;
end $$;
revoke all on function public.admin_recompute_orders() from public, anon;
grant execute on function public.admin_recompute_orders() to authenticated;

-- Đơn: xem theo phạm vi. Đơn chưa gán nhân sự chỉ người xem toàn bộ (admin, kế toán) thấy.
drop policy if exists orders_select on public.orders;
create policy orders_select on public.orders for select to authenticated
  using (public.can_see(project_id, team_id, staff_id));

-- ---------- số liệu cho bảng điều hành ----------
-- Chạy với quyền người gọi (security invoker) nên chỉ cộng đơn người đó được xem.
create or replace function public.dash_orders(p_from timestamptz, p_to timestamptz, p_project text default null, p_market text default null, p_channel text default null)
returns table (day date, project_id text, team_id text, staff_id text, marketer text, channel_id text, market_id text, shop_id text,
               st_group text, orders bigint, revenue_vnd numeric, cod_vnd numeric)
language sql stable security invoker set search_path = public as $$
  select (o.inserted_at at time zone coalesce(m.timezone, 'Asia/Ho_Chi_Minh'))::date,
         o.project_id, o.team_id, o.staff_id, coalesce(o.marketer_name, o.seller_name), o.channel_id, o.market_id, o.shop_id,
         case when o.status in (3,16) then 'ok' when o.status in (4,5,15) then 'ret' when o.status = 2 then 'ship'
              when o.status in (6,7) then 'cancel' else 'new' end,
         count(*), sum(coalesce(o.total_price,0) * coalesce(m.rate_vnd,1)), sum(coalesce(o.cod,0) * coalesce(m.rate_vnd,1))
  from public.orders o left join public.markets m on m.id = o.market_id
  where o.inserted_at >= p_from and o.inserted_at < p_to
    and (p_project is null or o.project_id = p_project)
    and (p_market is null or o.market_id = p_market)
    and (p_channel is null or o.channel_id = p_channel)
  group by 1,2,3,4,5,6,7,8,9
$$;

create or replace function public.dash_products(p_from timestamptz, p_to timestamptz, p_project text default null, p_market text default null, p_channel text default null)
returns table (code text, name text, team_id text, staff_id text, st_group text, orders bigint, qty numeric, revenue_vnd numeric)
language sql stable security invoker set search_path = public as $$
  select coalesce(nullif(i->>'code',''), i->>'name', '?'), max(i->>'name'), o.team_id, o.staff_id,
         case when o.status in (3,16) then 'ok' when o.status in (4,5,15) then 'ret' when o.status = 2 then 'ship'
              when o.status in (6,7) then 'cancel' else 'new' end,
         count(distinct o.pos_order_id), sum(coalesce((i->>'quantity')::numeric, 1)),
         sum(coalesce((i->>'quantity')::numeric, 1) * coalesce((i->>'price')::numeric, 0) * coalesce(m.rate_vnd,1))
  from public.orders o
  left join public.markets m on m.id = o.market_id
  cross join lateral jsonb_array_elements(coalesce(o.items, '[]'::jsonb)) i
  where o.inserted_at >= p_from and o.inserted_at < p_to
    and (p_project is null or o.project_id = p_project)
    and (p_market is null or o.market_id = p_market)
    and (p_channel is null or o.channel_id = p_channel)
  group by 1,3,4,5
$$;

-- Admin: tên marketer / nguồn đơn chưa khai báo, để thêm nhanh.
create or replace function public.admin_unmapped() returns table (kind text, value text, orders bigint, last_at timestamptz)
language sql stable security definer set search_path = public as $$
  select 'marketer', coalesce(marketer_name, seller_name), count(*), max(inserted_at) from public.orders
   where public.has_role('admin','quan_ly') and staff_id is null and coalesce(marketer_name, seller_name) is not null group by 2
  union all
  select 'no_name', coalesce(page_name, page_id, '(trống)'), count(*), max(inserted_at) from public.orders
   where public.has_role('admin','quan_ly') and staff_id is null and marketer_name is null and seller_name is null group by 2
  union all
  select 'source', source_name, count(*), max(inserted_at) from public.orders
   where public.has_role('admin','quan_ly') and channel_id is null and source_name is not null group by 2
  union all
  select 'no_source', '(không có nguồn)', count(*), max(inserted_at) from public.orders
   where public.has_role('admin','quan_ly') and source_name is null having count(*) > 0
  order by 1, 3 desc
$$;
revoke all on function public.admin_unmapped() from public, anon;
grant execute on function public.admin_unmapped() to authenticated;

-- ---------- dữ liệu ban đầu ----------
insert into public.markets (id, name, currency, rate_vnd, timezone) values ('ph','Philippines','PHP',403,'Asia/Manila')
on conflict (id) do nothing;
insert into public.channels (id, name, keywords, color, sort) values
  ('fb','Facebook','{facebook,messenger,fb}','#3461c1',1),
  ('shopee','Shopee','{shopee}','#d4582a',2),
  ('tiktok','TikTok','{tiktok}','#1b211d',3),
  ('lazada','Lazada','{lazada}','#7a3fb0',4),
  ('web','Website / Ladipage','{ladipage,website,landing}','#1e8e5a',5)
on conflict (id) do nothing;
update public.pos_shops set market_id = 'ph' where market_id is null;

do $$ begin
  alter publication supabase_realtime add table public.projects, public.teams, public.markets, public.channels, public.staff;
exception when others then null; end $$;
