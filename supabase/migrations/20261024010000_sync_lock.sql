-- Cập nhật khi mở trang: nhiều người mở cùng lúc thì mỗi shop chỉ một lượt kéo đơn chạy tại một thời điểm.
alter table public.pos_shops add column if not exists sync_lock_at timestamptz;

-- Trả true nếu giữ được khoá; khoá quá 3 phút coi như lượt trước đã chết.
create or replace function public.internal_lock_shop(p_shop text) returns boolean
language sql security definer set search_path = public as $$
  with u as (
    update public.pos_shops set sync_lock_at = now()
    where id = p_shop and (sync_lock_at is null or sync_lock_at < now() - interval '3 minutes')
    returning 1
  )
  select exists (select 1 from u)
$$;
revoke all on function public.internal_lock_shop(text) from public, anon, authenticated;
grant execute on function public.internal_lock_shop(text) to service_role;
