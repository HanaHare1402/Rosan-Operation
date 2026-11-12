# Kế hoạch mở rộng cho hàng chục triệu đơn

Mục tiêu: web vẫn nhanh khi có **hàng chục triệu đơn**, và **giữ đầy đủ chi tiết từng đơn ít nhất 12 tháng**.

Quy tắc chung cho mọi bước:

- Mỗi bước là 1 file trong `supabase/migrations/`, chạy lại nhiều lần không lỗi.
- File tự so sánh số liệu với cách tính cũ; lệch dù 1 dòng thì huỷ toàn bộ thay đổi của file.
- Việc nặng chia thành nhiều đợt nhỏ. Không làm một lần trên toàn bộ dữ liệu, vì sẽ làm nghẽn ổ cứng máy chủ (sự cố ngày 12/11/2026 trên máy Nano).
- Chạy lúc ít người dùng. Trước khi chạy, xem cỡ máy chủ ở Supabase → Settings → Compute and Disk.
- Trước khi giao, thử trên database giả lập có số đơn lớn hơn số thật.

## Đã làm

| Bước | File | Nội dung |
|---|---|---|
| Tăng tốc bảng sản phẩm | `20261112020000_order_lines.sql` | Tách sẵn dòng hàng vào `order_lines`, giữ khớp bằng trigger |
| 1. Bảng tổng hợp sẵn | `20261112030000_order_daily.sql` | `order_daily` + `order_daily_dirty`. Báo cáo đọc phần đã tổng hợp và tính thẳng phần vừa đổi, nên số luôn đúng. Hàm `pos` tổng hợp dần sau mỗi lần đồng bộ |
| 2. Tính lại có chọn lọc | `20261112040000_selective_recompute.sql` | Đổi giá nhập, mã gán giá vốn hoặc kênh: chỉ đánh dấu các đơn bị ảnh hưởng, không tính lại toàn bộ |

## Bước 3: Tách dữ liệu gốc POS (`raw`) ra bảng riêng

**Khi nào làm:** tổng số đơn vượt khoảng 1 triệu, hoặc dung lượng database vượt khoảng 3 GB.

**Vì sao:** mỗi đơn đang chiếm khoảng 4 KB, phần lớn là cột `raw` (JSON gốc từ POS). Báo cáo không dùng `raw`, nhưng vẫn phải đọc qua nên bộ nhớ chứa được ít đơn hơn.

**Cách làm:**

1. Tạo bảng `order_raw (shop_id, pos_order_id, raw jsonb, fetched_at)`, khoá ngoại tới `orders`, `on delete cascade`.
2. Sửa hàm `pos` (`mapOrder`, `writeBatch`, `onlyChanged`) để ghi `raw` vào `order_raw`. Bảng `orders` chỉ giữ các cột đã tách sẵn (trạng thái, COD, items, nhân sự…).
3. Sửa `order_derive`: phần dựng cột từ `raw` đọc từ `NEW.raw`, nên vẫn nhận `raw` qua bảng đệm. Cách gọn hơn: hàm `pos` gửi lên các cột đã tách sẵn và `raw` đi đường riêng.
4. Chuyển `raw` cũ sang `order_raw` theo đợt, mỗi đợt 5.000 đơn, chạy bằng hàm kiểu `recompute_batch`. Sau đó `update orders set raw = null` theo đợt, rồi `vacuum`.
5. Màn Đơn hàng và công cụ đối chiếu POS (`diff`) đọc `raw` từ `order_raw` khi cần xem chi tiết.
6. Tuỳ chọn: chỉ giữ `raw` trong 90 ngày. Đơn cũ hơn vẫn đủ cột để báo cáo, chỉ mất bản gốc.

**Rủi ro:** `order_derive` và `onlyChanged` đang so `raw` để biết đơn có đổi không. Phải chuyển sang so `updated_at` của POS (đã có trong `onlyChanged`).

## Bước 4: Chia bảng `orders` theo tháng (partition)

**Khi nào làm:** nên làm sớm, khi dữ liệu còn nhỏ thì chuyển nhẹ nhất. Muộn nhất trước khi vượt 2–3 triệu đơn.

**Vì sao:** xem tháng này thì chỉ chạm vào phần dữ liệu tháng này. Dọn hoặc lưu trữ tháng cũ chỉ là tách cả phần ra, không phải xoá từng dòng.

**Cách làm:**

1. Tạo `orders_p` partitioned theo `range (local_day)`, mỗi tháng một partition, cùng cột với `orders`. Khoá chính phải chứa cột chia: `(shop_id, pos_order_id, local_day)`. Vì vậy cần đổi khoá ngoại của `order_lines` và `order_raw`: thêm `local_day`, hoặc bỏ khoá ngoại và dọn bằng trigger.
2. Lưu ý `local_day` có thể đổi, khi shop đổi thị trường hoặc múi giờ. Postgres tự chuyển dòng sang partition khác khi update cột chia (có hỗ trợ), nhưng chậm hơn.
3. Tạo sẵn partition cho 2 tháng tới bằng một hàm chạy mỗi tháng (gọi từ lịch `pos` sync), cộng một partition `default`.
4. Chép dữ liệu theo đợt từng tháng, đổi tên `orders` thành `orders_old` và `orders_p` thành `orders` trong một giao dịch, rồi tạo lại trigger, policy và index.
5. Kiểm tra tất cả hàm đang tham chiếu `orders`: các báo cáo, `recompute_batch`, `purge_old_orders`, `sync_cutoff`, `admin_*`, `stock_*`.

**Rủi ro:** đây là thay đổi lớn nhất. Cần một buổi tối, có kế hoạch quay lại: giữ `orders_old` tới khi chắc chắn.

## Bước 5: Đồng bộ POS chạy theo lịch trên máy chủ

**Khi nào làm:** khi mỗi ngày có hơn khoảng 20 nghìn đơn, hoặc thấy số "Cập nhật lúc…" trên web hay trễ.

**Hiện nay:** đã có lịch gọi `pos` với `action: "sync"` (mã `x-cron-secret`). Ngoài ra mỗi tab đang mở còn gọi `refresh` 2 phút một lần (`index.html`, `refreshPOS`).

**Cách làm:**

1. Kiểm tra lịch hiện tại (pg_cron + pg_net, hoặc GitHub Actions) và đặt 1–2 phút một lần.
2. Bỏ việc trình duyệt gọi `refresh`. Web chỉ đọc mốc `last_synced_at` để hiện "Cập nhật lúc…" và tải lại số khi mốc đổi.
3. Nếu một lần chạy không kịp (giới hạn khoảng 150 giây của Edge Function), chia shop thành nhiều lịch, hoặc mỗi lần chỉ làm một nhóm shop.
4. Thời gian dành cho việc tổng hợp `order_daily` (`drainDaily`) tăng theo lượng đơn đổi.

## Bước 6: Lưu trữ đơn cũ hơn 12 tháng

**Khi nào làm:** khi có dữ liệu hơn 12 tháng.

**Cách làm:**

1. Mỗi tháng, xuất partition của tháng cũ hơn 12 tháng ra file nén (CSV/Parquet) lên Supabase Storage, bucket riêng tư `archive`. Làm bằng Edge Function hoặc script.
2. `order_daily` (bảng tổng) **giữ vĩnh viễn**, vì nhỏ. Báo cáo các năm trước vẫn xem được.
3. Sau khi xuất xong và kiểm tra số dòng khớp, tách (detach) rồi xoá partition đó.
4. Màn Đơn hàng: khi tìm đơn cũ hơn 12 tháng, báo "đơn đã lưu trữ" kèm nút tải file của tháng đó.

## Máy chủ Supabase

| Tổng số đơn | Cỡ máy gợi ý |
|---|---|
| dưới 300 nghìn | Micro |
| 300 nghìn – 2 triệu | Small |
| 2 – 10 triệu | Medium |
| trên 10 triệu | Large |

Cách theo dõi: Supabase → Reports → Database → **CPU usage**. Nếu đường **IOwait** (màu hồng) hay vượt 30% thì nâng thêm một nấc. Trong web, vào Quản trị → Kết nối POS → **Kiểm tra tốc độ**.
