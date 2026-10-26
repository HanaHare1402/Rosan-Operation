# Rosan Operation — hướng dẫn cho Claude

Bảng điều hành vận hành Team Vương (Philippines): trang tĩnh (`index.html`, `admin.html`, `login.html`, `js/`, `css/app.css`) trên GitHub Pages + Supabase (database, Auth, Edge Functions trong `supabase/`). Người dùng là quản lý, trưởng team, marketing, kế toán, vận đơn, kho — **không phải dân kỹ thuật**. Giao diện và mọi lời nhắn viết bằng tiếng Việt, xưng "cậu / tớ" với chủ dự án.

## Luật thiết kế giao diện (bắt buộc với mọi thay đổi giao diện)

Nguồn: 10 nguyên tắc khả dụng của Nielsen (NN/g), Stephen Few *Information Dashboard Design*, Shneiderman "overview first, zoom and filter, details on demand", luật Hick + progressive disclosure, WCAG 2.2.

1. **Trả lời trong 5 giây.** Màn tổng quan cho thấy ngay điều quan trọng nhất và điều gì cần chú ý. Tối đa ~4–7 chỉ số chính, chỉ số quan trọng nhất ở trên cùng, bên trái.
2. **Số luôn có bối cảnh.** Mỗi chỉ số chính kèm so sánh (kỳ trước / target) bằng mũi tên **và** chữ **và** màu; màu tốt / xấu theo hướng của chỉ số (tỷ lệ hoàn giảm là tốt). Không đưa con số trơ trọi.
3. **Tổng quan trước, chi tiết khi cần.** Tóm tắt → lọc → bấm để đi sâu. Đi sâu phải có đường quay lại (breadcrumb). Bảng mặc định ít cột (≤ 6); cột phụ, thao tác phụ (menu "⋯"), form thêm / sửa ẩn sau nút cho tới khi cần.
4. **Ngôn ngữ của người dùng.** Không viết tắt khó hiểu ("Giao TC" → "Đã giao"), không lộ thuật ngữ kỹ thuật (API, sync, recompute, RLS…) ở màn người dùng thường; nếu buộc phải có thì giải thích ngắn. Mỗi chỉ số có nút (?) nêu cách tính (`DEF` + `tip()` trong `index.html`).
5. **Luôn cho biết hệ thống đang làm gì.** Có trạng thái đang tải (khung chờ / spinner + chữ), thanh tiến độ cho việc lâu, thời điểm dữ liệu cập nhật. Khối trống phải nói lý do và có nút dẫn tới việc cần làm (`Shell.empty`).
6. **Phòng lỗi, cho phép hoàn tác.** Kiểm tra dữ liệu trước khi gửi, thông báo lỗi nói rõ sai gì và cách sửa (không đưa mã lỗi trơ). Thao tác xoá: có hoàn tác hoặc xác nhận nêu rõ hậu quả.
7. **Nhất quán.** Chỉ dùng token màu, khoảng cách, thành phần có sẵn trong `css/app.css` (`.card`, `.kpi`, `.btn`, `.btn.ghost`, `.btn.sm`, `.lnk`, `.pill p-good/p-warn/p-bad/p-mute/p-info`, `.msg`, `.seg`, `.chip`, `.empty`, `.skel`, `.more`, `.tip`, `.delta`). Thanh điều hướng, thẻ người dùng dựng bằng `js/shell.js`; không tự viết lại sidebar trong từng trang. Định dạng thống nhất: tiền `M()` ("73,0 tr"), số `N()`, phần trăm `P()` (1 chữ số thập phân), ngày `dd/mm/yyyy`.
8. **Biểu đồ dễ đọc.** Dùng độ dài / vị trí (cột, đường); một trục, không dùng hai trục; màu nổi chỉ dành cho điểm cần chú ý; có chú thích và giá trị khi rê / chạm.
9. **Dễ tiếp cận (WCAG 2.2 AA).** Chữ tương phản ≥ 4,5:1 (chữ lớn ≥ 3:1), biểu tượng / đường biểu đồ / viền ô nhập ≥ 3:1; **không chỉ dùng màu** để truyền thông tin (kèm chữ hoặc biểu tượng); mọi thao tác dùng được bằng bàn phím, có viền focus; nút chỉ có biểu tượng phải có `aria-label`.
10. **Giao diện tối và điện thoại.** Mọi màu đi qua biến CSS có bản tối (`prefers-color-scheme` + `[data-theme]`). Bố cục chạy được ở bề rộng 360px: lề 16px, không cuộn ngang trang (bảng được cuộn ngang trong khung `.tw`), vùng bấm ≥ 32px.
11. **Theo vai trò.** Mỗi vai trò chỉ thấy màn và số mình cần (`Auth.VIEWS`, `Auth.ADMIN_TABS`, phạm vi `scope`); trang mở đầu hợp với vai trò. Ẩn trên giao diện **không thay** cho phân quyền trong database (RLS).
12. **Kiểm tra trước khi giao.** Chạy thử với Supabase giả lập ở nhiều vai trò, chụp màn hình sáng / tối, 1360px và 390px, rà theo danh sách trên.

## Kỹ thuật

- Database: thêm thay đổi bằng file mới trong `supabase/migrations/` (đặt tên theo thời gian, chạy lại nhiều lần không lỗi). Người dùng tự chạy SQL trong Supabase SQL Editor — luôn đưa link raw GitHub và hướng dẫn từng bước.
- Supabase chặn `UPDATE`/`DELETE` không có `WHERE` (safeupdate) và giới hạn ~8 giây mỗi lệnh cho người dùng đăng nhập: việc nặng chia đợt (`recompute_batch`), policy RLS bọc hàm trong `(select …)`.
- Edge Functions (`supabase/functions/`) tự deploy qua GitHub Actions khi gộp vào `main`.
- Sửa `css/app.css` hoặc `js/*.js` thì đổi mã phiên bản `?v=…` ở thẻ `<link>` / `<script>` trong `index.html`, `admin.html`, `login.html` (trình duyệt và GitHub Pages lưu đệm file cũ).
- Không đưa khoá bí mật vào repo hay chat; `config.js` chỉ chứa URL + publishable key.
