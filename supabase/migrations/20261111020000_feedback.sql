-- Góp ý / báo lỗi từ người dùng gửi về admin, kèm ảnh chụp màn hình.
--   * Bảng feedback: người dùng tạo phản hồi của chính mình, xem lại phản hồi của mình; admin xem tất cả, đổi trạng thái, ghi trả lời.
--   * Kho ảnh "feedback" (Supabase Storage, riêng tư): ảnh lưu theo thư mục <user id>/<feedback id>/…;
--     người gửi xem ảnh của mình, admin xem mọi ảnh. Mỗi ảnh tối đa 5 MB, chỉ nhận ảnh.
-- Chạy sau 20261111010000_revenue_cod.sql. Chạy lại nhiều lần không lỗi.

create table if not exists public.feedback (
  id uuid primary key default gen_random_uuid(),
  created_at timestamptz not null default now(),
  user_id uuid not null default auth.uid(),
  user_email text,
  user_name text,
  user_role text,
  page text,                                  -- trang đang mở khi gửi (VD /#tongquan)
  category text not null default 'loi' check (category in ('loi', 'gop_y', 'cau_hoi')),
  message text not null check (length(btrim(message)) between 1 and 5000),
  images text[] not null default '{}',        -- đường dẫn ảnh trong kho "feedback"
  user_agent text,
  status text not null default 'moi' check (status in ('moi', 'dang_xu_ly', 'da_xong', 'khong_xu_ly')),
  admin_note text,
  handled_by text,
  updated_at timestamptz not null default now()
);
create index if not exists feedback_created on public.feedback (created_at desc);
create index if not exists feedback_user on public.feedback (user_id, created_at desc);

alter table public.feedback enable row level security;
grant select, insert, update on public.feedback to authenticated;
drop policy if exists feedback_read on public.feedback;
create policy feedback_read on public.feedback for select to authenticated
  using (user_id = (select auth.uid()) or (select public.has_role('admin')));
drop policy if exists feedback_insert on public.feedback;
create policy feedback_insert on public.feedback for insert to authenticated
  with check (user_id = (select auth.uid()) and status = 'moi' and admin_note is null);
drop policy if exists feedback_update on public.feedback;
create policy feedback_update on public.feedback for update to authenticated
  using ((select public.has_role('admin'))) with check ((select public.has_role('admin')));

-- Kho ảnh riêng tư.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('feedback', 'feedback', false, 5242880, array['image/png', 'image/jpeg', 'image/webp', 'image/gif'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists feedback_img_insert on storage.objects;
create policy feedback_img_insert on storage.objects for insert to authenticated
  with check (bucket_id = 'feedback' and (storage.foldername(name))[1] = (select auth.uid())::text);
drop policy if exists feedback_img_read on storage.objects;
create policy feedback_img_read on storage.objects for select to authenticated
  using (bucket_id = 'feedback' and ((storage.foldername(name))[1] = (select auth.uid())::text or (select public.has_role('admin'))));
drop policy if exists feedback_img_delete on storage.objects;
create policy feedback_img_delete on storage.objects for delete to authenticated
  using (bucket_id = 'feedback' and (select public.has_role('admin')));
