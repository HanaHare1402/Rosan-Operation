# Rosan-Operation

Bảng điều hành vận hành Team Vương (Phil): tổng quan, team, nhân sự, sản phẩm, đơn hàng, KQKD, cảnh báo, cài đặt.

**Trang web:** https://hanahare1402.github.io/Rosan-Operation/

## Cấu trúc

| Phần | File | Ghi chú |
|---|---|---|
| Đăng nhập | `login.html` | Supabase Auth, email + mật khẩu. Không cho tự đăng ký: tài khoản do admin tạo. |
| Bảng điều hành | `index.html` | Màn hiện ra tuỳ vai trò. Màn Đơn hàng đọc đơn thật khi đã có; các màn khác còn dữ liệu mẫu. |
| Quản trị (admin) | `admin.html` | Tạo tài khoản, cấp vai trò, khoá/xoá; thêm shop POS, đặt API key, thử kết nối, đồng bộ. |
| Database | `supabase/migrations/…_init.sql` | Bảng, phân quyền (RLS), lưu key vào Supabase Vault. |
| Server | `supabase/functions/admin-users`, `supabase/functions/pos` | Quản lý tài khoản; gọi API Pancake POS và kéo đơn về. |
| Lịch đồng bộ | `supabase/cron.sql` | 15 phút kéo đơn một lần. |

**Vai trò:** Admin · Quản lý · Marketing · Kế toán · Vận đơn · Kho · Sale. Bảng vai trò ↔ màn hình nằm trong `js/auth.js` (`VIEWS`) và hiện ở trang Quản trị.

**Khoá nhạy cảm ở đâu:**
- API key Pancake POS cất trong **Supabase Vault**. Chỉ Edge Function `pos` đọc được key, không trả về trình duyệt, kể cả admin cũng không xem lại được.
- `service_role` key chỉ có sẵn bên trong Edge Function.
- `config.js` chỉ chứa URL và **anon key**. Hai thứ này được phép công khai vì mọi bảng đã khoá bằng RLS.

## Cài đặt lần đầu

1. **Tạo project Supabase** ở https://supabase.com (gói Free là đủ). Chọn region Singapore.
2. **Tạo database:** SQL Editor → New query → dán toàn bộ `supabase/migrations/20261024000000_init.sql` → Run.
3. **Khoá đăng ký và đặt địa chỉ trang:**
   - Authentication → Sign In / Providers: tắt **Allow new users to sign up**.
   - Authentication → URL Configuration: *Site URL* = `https://hanahare1402.github.io/Rosan-Operation/`. Thêm `https://hanahare1402.github.io/Rosan-Operation/login.html` vào *Redirect URLs* để link quên mật khẩu hoạt động.
4. **Tạo admin đầu tiên:**
   - Authentication → Users → Add user → Create new user: nhập email và mật khẩu, tích *Auto Confirm User*.
   - Vào SQL Editor chạy lệnh sau (thay email):
     ```sql
     update public.profiles set role = 'admin' where email = 'email-cua-cau@gmail.com';
     ```
5. **Deploy Edge Functions** (tự động qua GitHub Actions):
   - Tạo access token ở https://supabase.com/dashboard/account/tokens.
   - Trên GitHub: repo → Settings → Secrets and variables → Actions → New repository secret, thêm 2 secret:
     - `SUPABASE_ACCESS_TOKEN`: token vừa tạo.
     - `SUPABASE_PROJECT_REF`: mã dự án, phần đầu của Project URL (`https://<mã>.supabase.co`).
   - Tab Actions → *Deploy Supabase functions* → Run workflow. Sau này mỗi lần sửa function trên `main`, workflow tự deploy lại.
6. **Nối trang với Supabase:** sửa `config.js`, điền `SUPABASE_URL` và `SUPABASE_ANON_KEY` lấy ở Project Settings → API. Dùng anon / publishable key, **không** dùng service_role.
7. **Bật lịch đồng bộ 15 phút:** dán toàn bộ `supabase/cron.sql` vào SQL Editor → Run (mã dự án đã điền sẵn, mã bí mật tự sinh).
8. **Nối POS:** đăng nhập bằng tài khoản admin → Quản trị → Kết nối POS:
   - Thêm shop, kèm Shop ID trên POS.
   - Đặt API key. Lấy key trên pos.pages.fm: Cấu hình → Cấu hình ứng dụng → API KEY → Thêm mới.
   - Bấm **Thử kết nối**, rồi **Đồng bộ**.
   - Bấm **Xem đơn mẫu** để xem POS trả về những trường nào. Dùng thông tin này để khớp nhân sự, sản phẩm, kho vào các màn báo cáo.
9. **Tạo tài khoản cho mọi người:** Quản trị → Tài khoản.

## Phát triển

Không cần build: trang là HTML/JS tĩnh, chạy trên GitHub Pages. Thư viện tải từ CDN: `@supabase/supabase-js@2.109.0`, `xlsx@0.18.5`.
