-- Kênh theo UTM Source (ưu tiên hơn nguồn đơn), dùng cho kênh Google.
--   * channels.utm_keywords: từ khoá so với UTM Source của đơn (p_utm_source trên POS). Đơn có UTM Source chứa
--     một từ khoá này thì thuộc kênh đó, kể cả khi nguồn đơn là Website / Ladipage. Để trống = không dùng (mặc định),
--     các kênh hiện có không đổi cách nhận.
--   * Tạo kênh "Google" nếu chưa có (từ khoá UTM: google, tiền nhập chi phí ads: USD).
--   * Trigger orders_derive_utm chạy ngay sau orders_derive (tên xếp sau theo bảng chữ cái) để đặt lại kênh.
--   * Sửa từ khoá UTM của kênh ở Quản trị → Danh mục → Kênh bán: các đơn liên quan được đánh dấu tính lại.
--   * Phân loại lại ngay các đơn cũ có UTM Source khớp (đọc toàn bộ đơn một lần: chạy lúc ít người dùng).
-- Chạy sau 20261125000000_product_names_vi.sql. Chạy lại nhiều lần không lỗi.

begin;
set local statement_timeout = '15min';

alter table public.channels add column if not exists utm_keywords text[] not null default '{}';

-- Kênh Google.
insert into public.channels (id, name, keywords, color, sort)
select 'google', 'Google', '{google}', '#ea4335', coalesce((select max(sort) from public.channels), 0) + 1
where not exists (select 1 from public.channels where lower(btrim(name)) = 'google' or id = 'google');
update public.channels set utm_keywords = '{google}'
where (lower(btrim(name)) = 'google' or id = 'google') and utm_keywords = '{}';

-- Đặt kênh theo UTM Source sau khi orders_derive đã gán kênh theo nguồn đơn.
create or replace function public.order_utm_channel() returns trigger
language plpgsql security definer set search_path = public as $$
declare u text; cid text;
begin
  -- Chỉ đánh dấu "cần tính lại": để đợt tính lại xử lý (giống orders_derive).
  if tg_op = 'UPDATE' and new.derived_at is null and old.derived_at is not null and new.raw is not distinct from old.raw then
    return new;
  end if;
  u := lower(btrim(coalesce(new.raw->>'p_utm_source', '')));
  if u = '' then return new; end if;
  select c.id into cid from public.channels c
  where exists (select 1 from unnest(c.utm_keywords) kw where btrim(kw) <> '' and u like '%' || lower(btrim(kw)) || '%')
  order by c.sort, c.name limit 1;
  if cid is not null then new.channel_id := cid; end if;
  return new;
end $$;
revoke all on function public.order_utm_channel() from public, anon, authenticated;
drop trigger if exists orders_derive_utm on public.orders;
create trigger orders_derive_utm before insert or update on public.orders
  for each row execute function public.order_utm_channel();

-- Sửa kênh: như cũ, thêm đơn có UTM Source khớp từ khoá UTM cũ / mới (chỉ khi từ khoá UTM có đổi).
create or replace function public.recompute_on_channels() returns trigger
language plpgsql security definer set search_path = public as $$
declare ids text[] := '{}'; kws text[] := '{}'; uk_new text[] := '{}'; uk_old text[] := '{}'; uks text[];
begin
  if tg_op in ('INSERT', 'UPDATE') then
    select coalesce(array_agg(id), '{}') into ids from new_rows;
    select coalesce(array_agg(distinct lower(kw)), '{}') into kws from new_rows, unnest(keywords) kw where kw <> '';
    select coalesce(array_agg(distinct lower(btrim(kw))), '{}') into uk_new from new_rows, unnest(utm_keywords) kw where btrim(kw) <> '';
  end if;
  if tg_op in ('DELETE', 'UPDATE') then
    select ids || coalesce(array_agg(id), '{}') into ids from old_rows;
    select kws || coalesce(array_agg(distinct lower(kw)), '{}') into kws from old_rows, unnest(keywords) kw where kw <> '';
    select coalesce(array_agg(distinct lower(btrim(kw))), '{}') into uk_old from old_rows, unnest(utm_keywords) kw where btrim(kw) <> '';
  end if;
  update public.orders o set derived_at = null
  where o.derived_at is not null
    and (o.channel_id = any(ids)
         or (o.source_name is not null and exists (select 1 from unnest(kws) kw where lower(o.source_name) like '%' || kw || '%')));
  -- Từ khoá UTM có đổi (thêm / bớt): đánh dấu đơn có UTM Source khớp từ khoá cũ hoặc mới.
  select array(select x from unnest(uk_new) x except select y from unnest(uk_old) y
               union select y from unnest(uk_old) y except select x from unnest(uk_new) x) into uks;
  if tg_op <> 'UPDATE' then uks := uk_new || uk_old; end if;
  if coalesce(array_length(uks, 1), 0) > 0 then
    update public.orders o set derived_at = null
    where o.derived_at is not null
      and exists (select 1 from unnest(uks) kw where lower(coalesce(o.raw->>'p_utm_source', '')) like '%' || kw || '%');
  end if;
  return null;
end $$;
revoke all on function public.recompute_on_channels() from public, anon, authenticated;

-- Phân loại lại ngay đơn cũ có UTM Source khớp mà đang ở kênh khác (tính lại đơn: orders_derive + orders_derive_utm,
-- bảng tổng hợp theo ngày tự cập nhật qua trigger của nó).
update public.orders o set synced_at = o.synced_at
where o.raw->>'p_utm_source' is not null
  and exists (select 1 from public.channels c, unnest(c.utm_keywords) kw
              where btrim(kw) <> '' and lower(o.raw->>'p_utm_source') like '%' || lower(btrim(kw)) || '%'
                and o.channel_id is distinct from c.id);

-- Tự kiểm tra: không còn đơn nào có UTM Source khớp mà nằm ngoài kênh theo UTM.
do $$
declare bad bigint; n bigint;
begin
  select count(*) into bad from public.orders o
  cross join lateral (select c.id from public.channels c
                      where exists (select 1 from unnest(c.utm_keywords) kw where btrim(kw) <> '' and lower(coalesce(o.raw->>'p_utm_source', '')) like '%' || lower(btrim(kw)) || '%')
                      order by c.sort, c.name limit 1) x
  where o.channel_id is distinct from x.id and o.derived_at is not null;
  if bad > 0 then
    raise exception 'Kiểm tra không khớp (% đơn chưa đúng kênh theo UTM), đã huỷ toàn bộ thay đổi. Gửi dòng này cho người phát triển.', bad;
  end if;
end $$;

commit;

-- Số đơn theo kênh Google (chạy xong sẽ hiện ở bảng kết quả).
select c.name as kenh, count(o.*) as so_don
from public.channels c left join public.orders o on o.channel_id = c.id
where c.utm_keywords <> '{}'
group by c.name;
