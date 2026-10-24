// Điền 2 giá trị lấy từ Supabase: Project Settings → API (hoặc Data API).
// Đây là khoá "anon / publishable": được phép công khai, dữ liệu được bảo vệ bằng RLS trong database.
// TUYỆT ĐỐI không dán service_role / secret key vào đây.
window.APP_CONFIG = {
  SUPABASE_URL: "",       // VD: https://abcdxyz.supabase.co
  SUPABASE_ANON_KEY: ""   // VD: eyJhbGciOi... hoặc sb_publishable_...
};
