-- Tăng tốc mở trang: trả cả bảng số liệu trong MỘT lần gọi (dạng JSON).
--   API giới hạn 1.000 dòng mỗi lần; đọc nhiều trang thì mỗi trang máy chủ phải tính lại cả khoảng thời gian từ đầu.
--   Các hàm *_json gọi đúng hàm cũ một lần rồi gói kết quả lại; phân quyền giữ nguyên như hàm cũ.
-- Chạy sau 20261111020000_feedback.sql. Chạy lại nhiều lần không lỗi.

create or replace function public.dash_orders_json(p_from timestamptz, p_to timestamptz, p_project text default null, p_market text default null, p_channel text default null)
returns jsonb language sql stable security invoker set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.dash_orders(p_from, p_to, p_project, p_market, p_channel) t
$$;
create or replace function public.dash_products_json(p_from timestamptz, p_to timestamptz, p_project text default null, p_market text default null, p_channel text default null)
returns jsonb language sql stable security invoker set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.dash_products(p_from, p_to, p_project, p_market, p_channel) t
$$;
create or replace function public.kpi_report_json(p_from timestamptz, p_to timestamptz, p_mode text default 'ads', p_project text default null,
  p_market text default null, p_channel text default null)
returns jsonb language sql stable security invoker set search_path = public as $$
  select coalesce(jsonb_agg(to_jsonb(t)), '[]'::jsonb) from public.kpi_report(p_from, p_to, p_mode, p_project, p_market, p_channel) t
$$;
revoke all on function public.dash_orders_json(timestamptz, timestamptz, text, text, text) from public, anon;
revoke all on function public.dash_products_json(timestamptz, timestamptz, text, text, text) from public, anon;
revoke all on function public.kpi_report_json(timestamptz, timestamptz, text, text, text, text) from public, anon;
grant execute on function public.dash_orders_json(timestamptz, timestamptz, text, text, text) to authenticated;
grant execute on function public.dash_products_json(timestamptz, timestamptz, text, text, text) to authenticated;
grant execute on function public.kpi_report_json(timestamptz, timestamptz, text, text, text, text) to authenticated;
