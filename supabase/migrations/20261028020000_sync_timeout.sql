-- Đồng bộ POS bị dừng với lỗi "canceling statement due to statement timeout" khi ghi nhiều đơn
-- (nhất là lúc đang tính lại đơn cũ sau 20261028010000_speed.sql).
-- Function đồng bộ (vai trò service_role) được chạy mỗi lệnh tối đa 120 giây; tài khoản đăng nhập giữ 30 giây.
-- Chạy sau 20261028010000_speed.sql. Chạy lại nhiều lần không lỗi.
alter role service_role set statement_timeout = '120s';
alter role authenticated set statement_timeout = '30s';
notify pgrst, 'reload config';
