-- Tên tiếng Việt của sản phẩm (tên trên POS là tiếng Anh).
--   * product_names: mỗi sản phẩm (product_key = tên POS viết thường) một tên tiếng Việt. Không theo tháng.
--   * Mọi tài khoản đăng nhập đọc được (để màn Chi phí ads gợi ý theo tên tiếng Việt);
--     admin / quản lý / kế toán sửa ở Quản trị → Nhóm sản phẩm.
-- Chạy lại nhiều lần không lỗi.

create table if not exists public.product_names (
  product_key text primary key,
  name_vi text not null check (btrim(name_vi) <> ''),
  updated_by uuid default auth.uid(),
  updated_at timestamptz not null default now()
);

alter table public.product_names enable row level security;
grant select, insert, update, delete on public.product_names to authenticated;

drop policy if exists product_names_read on public.product_names;
create policy product_names_read on public.product_names for select to authenticated
  using ((select public.my_role()) is not null);

drop policy if exists product_names_write on public.product_names;
create policy product_names_write on public.product_names for all to authenticated
  using ((select public.has_role('admin','quan_ly','ke_toan')))
  with check ((select public.has_role('admin','quan_ly','ke_toan')));
