-- Siết bảo mật:
--   1) Người CHƯA đăng nhập (vai trò anon, dùng khoá publishable công khai) không đọc / ghi bảng nào và không gọi hàm nào.
--      Web chỉ gọi dữ liệu sau khi đăng nhập; trang đăng nhập chỉ dùng phần Auth của Supabase nên không bị ảnh hưởng.
--   2) Các hàm trong schema public: bỏ quyền mặc định PUBLIC (mà anon thừa hưởng), chỉ cấp cho người đã đăng nhập
--      (authenticated) và service_role. Hàm nội bộ đọc khoá POS / mã cron (internal_*) giữ nguyên: chỉ service_role.
--   3) Bảng / hàm tạo sau này cũng không tự cấp cho anon.
-- Chạy sau 20261112000000_speed_json.sql. Chạy lại nhiều lần không lỗi.

revoke all on all tables in schema public from anon;
revoke all on all sequences in schema public from anon;
alter default privileges in schema public revoke all on tables from anon;
alter default privileges in schema public revoke all on sequences from anon;
alter default privileges in schema public revoke execute on functions from anon;
alter default privileges revoke execute on functions from public;   -- quyền PUBLIC mặc định chỉ bỏ được ở mức toàn cục
alter default privileges in schema public grant execute on functions to authenticated, service_role;

do $$
declare f record;
begin
  for f in
    select p.oid::regprocedure as sig, p.proname
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.prokind = 'f'
      and not exists (select 1 from pg_depend d where d.objid = p.oid and d.deptype = 'e')   -- bỏ qua hàm của extension
  loop
    execute format('revoke all on function %s from public, anon', f.sig);
    if f.proname not like 'internal\_%' then
      execute format('grant execute on function %s to authenticated, service_role', f.sig);
    end if;
  end loop;
end $$;
