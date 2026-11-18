-- Chi phí ads theo tiền của từng kênh: Shopee nhập bằng peso (₱), Facebook / TikTok… vẫn nhập bằng USD.
--   * channels.ad_currency: tiền nhập chi phí ads của kênh ('USD' hoặc mã tiền của một thị trường, VD 'PHP').
--     Lần đầu chạy file: kênh có chữ "shopee" (tên / mã / từ khoá) đặt 'PHP', kênh khác 'USD'. Admin đổi được ở
--     Quản trị → Danh mục → Kênh bán.
--   * ad_spend thêm currency + amount (số gốc người nhập). Cột usd giữ vai trò cũ: số USD tương đương mà mọi báo cáo
--     đang đọc (× tỷ giá USD của tháng). Dòng tiền khác USD: usd = amount × tỷ giá tiền đó / tỷ giá USD của tháng,
--     nên quy ra VNĐ đúng bằng amount × tỷ giá tiền đó. Các báo cáo không cần sửa.
--   * Đổi tỷ giá USD (Cài đặt KPI) hoặc tỷ giá thị trường: các dòng không phải USD tự tính lại usd.
--   * Các dòng đã nhập trước đây giữ nguyên là USD (kể cả Shopee).
-- Chạy sau 20261118000000_ad_shop.sql. Chạy lại nhiều lần không lỗi.

begin;
set local statement_timeout = '2min';

-- ---------- tiền nhập chi phí ads của kênh ----------
do $$
begin
  if not exists (select 1 from information_schema.columns
                 where table_schema = 'public' and table_name = 'channels' and column_name = 'ad_currency') then
    alter table public.channels add column ad_currency text not null default 'USD';
    update public.channels set ad_currency = 'PHP'
    where name ~* 'shopee' or id ~* 'shopee' or array_to_string(keywords, ',') ~* 'shopee';
  end if;
end $$;

-- ---------- số gốc + loại tiền của từng khoản chi ----------
alter table public.ad_spend add column if not exists currency text not null default 'USD';
alter table public.ad_spend add column if not exists amount numeric;
update public.ad_spend set amount = usd where amount is null;
alter table public.ad_spend drop constraint if exists ad_spend_amount_check;
alter table public.ad_spend add constraint ad_spend_amount_check check (amount >= 0);

-- 1 đơn vị tiền = ? VNĐ vào ngày p_day. USD: tỷ giá ở Cài đặt KPI của tháng gần nhất ≤ tháng đó (giống trang web).
-- Tiền khác: tỷ giá của thị trường dùng tiền đó (ưu tiên thị trường 'ph').
create or replace function public.ad_rate_vnd(p_cur text, p_day date) returns numeric
language sql stable security definer set search_path = public as $$
  select case when upper(coalesce(p_cur, 'USD')) = 'USD' then
    coalesce((select k.usd_vnd from public.kpi_settings k where k.month <= date_trunc('month', p_day)::date
              order by k.month desc limit 1), 27000)
  else
    (select m.rate_vnd from public.markets m where upper(m.currency) = upper(p_cur)
     order by (m.id = 'ph') desc, m.name limit 1)
  end
$$;
revoke all on function public.ad_rate_vnd(text, date) from public, anon;
grant execute on function public.ad_rate_vnd(text, date) to authenticated, service_role;

create or replace function public.ad_spend_currency() returns trigger
language plpgsql security definer set search_path = public as $$
declare r numeric; u numeric;
begin
  new.currency := upper(coalesce(nullif(btrim(new.currency), ''), 'USD'));
  -- Trang web bản cũ (chưa tải lại) chỉ gửi usd: sửa số usd của dòng peso thì coi như nhập lại bằng USD.
  if tg_op = 'UPDATE' and new.currency <> 'USD' and new.currency = old.currency
     and new.amount is not distinct from old.amount and new.usd is distinct from old.usd then
    new.currency := 'USD';
  end if;
  if new.currency = 'USD' then
    new.amount := new.usd;
    return new;
  end if;
  if new.amount is null then
    raise exception 'Thiếu số tiền chi phí (%).', new.currency;
  end if;
  r := public.ad_rate_vnd(new.currency, new.day);
  u := public.ad_rate_vnd('USD', new.day);
  if r is null then
    raise exception 'Chưa có tỷ giá cho tiền %. Admin thêm ở Quản trị → Danh mục → Thị trường.', new.currency;
  end if;
  new.usd := round(new.amount * r / u, 6);
  return new;
end $$;
drop trigger if exists ad_spend_currency on public.ad_spend;
create trigger ad_spend_currency before insert or update on public.ad_spend
  for each row execute function public.ad_spend_currency();

-- ---------- đổi tỷ giá thì tính lại các dòng không phải USD ----------
-- "set amount = amount": trigger ở trên tính lại usd theo tỷ giá mới.
create or replace function public.ad_spend_rate_changed() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_table_name = 'kpi_settings' then
    update public.ad_spend set amount = amount
    where currency <> 'USD' and day >= coalesce(case when tg_op = 'DELETE' then old.month else new.month end, '1900-01-01'::date);
  else
    update public.ad_spend set amount = amount where currency <> 'USD';
  end if;
  return null;
end $$;
drop trigger if exists ad_spend_rate_kpi on public.kpi_settings;
create trigger ad_spend_rate_kpi after insert or delete or update of usd_vnd, month on public.kpi_settings
  for each row execute function public.ad_spend_rate_changed();
drop trigger if exists ad_spend_rate_market on public.markets;
create trigger ad_spend_rate_market after update of rate_vnd, currency on public.markets
  for each row execute function public.ad_spend_rate_changed();

-- ---------- tự kiểm tra ----------
do $$
declare bad int;
begin
  select count(*) into bad from public.ad_spend where amount is null or (currency = 'USD' and amount <> usd);
  if bad > 0 then
    raise exception 'Kiểm tra không khớp (% dòng chi phí), đã huỷ toàn bộ thay đổi. Gửi dòng này cho người phát triển.', bad;
  end if;
  raise notice 'Xong: chi phí ads nhập được theo tiền của kênh. Kênh dùng peso: %',
    coalesce((select string_agg(name, ', ') from public.channels where ad_currency <> 'USD'), '(chưa có)');
end $$;

commit;
