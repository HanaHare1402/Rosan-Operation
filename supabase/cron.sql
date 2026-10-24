-- Lịch tự đồng bộ đơn từ POS, 2 tiếng một lần (phút 0 của giờ chẵn, giờ UTC). Chạy trong SQL Editor sau khi đã deploy function `pos`.
-- Muốn đổi tần suất: sửa '0 */2 * * *' (VD '0 * * * *' = mỗi giờ, '*/30 * * * *' = 30 phút) rồi chạy lại file.
-- Dự án khác thì thay aiigqdwhqstnyiopdxrt trong URL bên dưới bằng mã dự án (https://<mã>.supabase.co).

create extension if not exists pg_cron;
create extension if not exists pg_net;

-- Sinh mã bí mật ngẫu nhiên, cất vào Vault; function pos so mã này với header của lịch gọi.
select vault.create_secret(replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''), 'cron_secret', 'Mã để pg_cron gọi function pos')
where not exists (select 1 from vault.secrets where name = 'cron_secret');

-- Bỏ lịch 15 phút cũ (nếu có). Chạy lại file này thì lịch được thay bằng lịch mới (cùng tên).
select cron.unschedule(jobid) from cron.job where jobname = 'pos-sync-15m';

select cron.schedule('pos-sync', '0 */2 * * *', $$
  select net.http_post(
    url := 'https://aiigqdwhqstnyiopdxrt.supabase.co/functions/v1/pos',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'x-cron-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'cron_secret')
    ),
    body := '{"action":"sync"}'::jsonb,
    timeout_milliseconds := 150000
  );
$$);

-- Xem lịch đã chạy chưa:   select * from cron.job_run_details order by start_time desc limit 10;
-- Tắt lịch:                select cron.unschedule('pos-sync');
