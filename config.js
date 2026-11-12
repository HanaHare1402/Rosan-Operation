// Điền 2 giá trị lấy từ Supabase: Project Settings → API (hoặc Data API).
// Đây là khoá "anon / publishable": được phép công khai, dữ liệu được bảo vệ bằng RLS trong database.
// TUYỆT ĐỐI không dán service_role / secret key vào đây.
window.APP_CONFIG = {
  SUPABASE_URL: "https://aiigqdwhqstnyiopdxrt.supabase.co",
  SUPABASE_ANON_KEY: "sb_publishable_BCWZTbf9-5crkIIQAUuvoQ_YtR5ZThU",
  // Ô xác minh chống bot ở trang đăng nhập (Cloudflare Turnstile, khoá công khai). Để trống = tắt.
  TURNSTILE_SITE_KEY: "0x4AAAAAAF93sWC2zatcqCU4"
};
