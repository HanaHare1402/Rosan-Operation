-- Lịch tự đồng bộ đơn từ POS, 15 phút một lần. Chạy MỘT LẦN trong SQL Editor, sau khi đã deploy function `pos`.
-- Thay 2 chỗ trước khi chạy:
--   <PROJECT_REF>   : mã dự án, phần đầu của Project URL (https://<PROJECT_REF>.supabase.co)
--   <MA_BI_MAT>     : một chuỗi ngẫu nhiên dài bất kỳ, tự nghĩ (VD gõ lung tung 40 ký tự). Không cần nhớ.

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Cất mã bí mật vào Vault; function pos so mã này với header của lịch gọi.
select vault.create_secret('<MA_BI_MAT>', 'cron_secret', 'Mã để pg_cron gọi function pos');

select cron.schedule('pos-sync-15m', '*/15 * * * *', $$
  select net.http_post(
    url := 'https://<PROJECT_REF>.supabase.co/functions/v1/pos',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
    ),
    body := '{"action":"sync"}'::jsonb,
    timeout_milliseconds := 150000
  );
$$);

-- Xem lịch đã chạy chưa:   select * from cron.job_run_details order by start_time desc limit 10;
-- Tắt lịch:                select cron.unschedule('pos-sync-15m');
