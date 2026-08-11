# PROGRESS

Theo dõi tiến độ biên soạn giáo trình.

**Cập nhật lần cuối:** 2026-08-10

---

## Chú thích trạng thái

| Ký hiệu | Ý nghĩa |
|---|---|
| ⬜ | Chưa bắt đầu |
| 🟨 | Đang viết |
| ✅ | Hoàn thành (đã đủ 7 tiêu chí chất lượng trong `CLAUDE.md`) |

Một module chỉ được đánh ✅ khi cả lý thuyết, lab, bài tập và phần kiểm tra đều xong, và
mọi câu SQL trong đó đã được chạy thử thật.

---

## Khung repository

| Hạng mục | Trạng thái |
|---|---|
| `CLAUDE.md` — quy ước viết nội dung | ✅ |
| `README.md` — giới thiệu, cách học | ✅ |
| `ROADMAP.md` — lộ trình chi tiết | ✅ |
| `PROGRESS.md` — theo dõi tiến độ | ✅ |

---

## Nội dung theo module

| Phần | Module | Lý thuyết | Lab | Bài tập | Kiểm tra | Troubleshooting |
|---|---|---|---|---|---|---|
| 00 | Môi trường thực hành | ✅ | ✅ | — | — | — |
| 01 | Kiến trúc tổng quan | ✅ | ✅ | ✅ | ✅ | — |
| 02 | Storage layer | ✅ | ✅ | ✅ | (gộp vào bài tập) | — |
| 03 | MVCC & Transaction | ✅ | ✅ | ✅ | (gộp vào bài tập) | ⬜ |
| 04 | VACUUM & Autovacuum | ✅ | ✅ | ⬜ | (gộp vào bài tập) | ⬜ |
| 05 | Index | ✅ | ✅ | ⬜ | (gộp vào bài tập) | ⬜ |
| 06 | Query Planner & Optimizer | ✅ | ✅ | ⬜ | (gộp vào bài tập) | ⬜ |
| 07 | Đọc EXPLAIN chuyên sâu | ✅ | ✅ | ⬜ | (gộp vào bài tập) | ⬜ |
| 08 | Lock & Concurrency | ✅ | ✅ | ⬜ | (gộp vào bài tập) | ⬜ |
| 09 | WAL, Checkpoint, Durability | ✅ | (lồng trong README) | ⬜ | — | ⬜ |
| 10 | Replication & HA | ✅ | (lồng trong README) | ⬜ | — | ⬜ |
| 11 | Connection & Resource | ✅ | (lồng trong README) | ⬜ | — | ⬜ |
| 12 | Partitioning & Scale | ✅ | (lồng trong README) | ⬜ | — | ⬜ |
| 13 | Schema & Data Modeling | ✅ | (lồng trong README) | ⬜ | — | ⬜ |
| 14 | Monitoring & Debug | ✅ | (lồng trong README) | ⬜ | — | ⬜ |
| 15 | Phía application | ✅ | (lồng trong README) | ⬜ | — | — |
| 16 | Case study production | ✅ | — | — | — | — |

---

## Case study

| # | Case study | Trạng thái |
|---|---|---|
| 1 | Query 20ms đột nhiên thành 8 giây sau đợt import | ✅ |
| 2 | Bảng 200GB nhưng dữ liệu thật chỉ 30GB | ✅ |
| 3 | Autovacuum chạy liên tục mà bloat vẫn tăng | ✅ |
| 4 | `ALTER TABLE ADD COLUMN` làm treo API 4 phút | ✅ |
| 5 | Connection pool đầy trong khi CPU chỉ 15% | ✅ |
| 6 | Replica lag tăng dần vào mỗi 3 giờ sáng | ✅ |
| 7 | Deadlock chỉ xảy ra khi có khuyến mãi | ✅ |
| 8 | Index vừa tạo nhưng planner không dùng | ✅ |
| 9 | Disk đầy vì replication slot bị bỏ quên | ✅ |
| 10 | Job queue xử lý trùng message | ✅ |
| 11 | `COUNT(*)` trên bảng lớn làm nghẽn dashboard | ✅ |
| 12 | Batch job đêm làm chậm traffic ban ngày | ✅ |

---

## Phụ lục

| File | Trạng thái |
|---|---|
| `appendix/parameters.md` | ✅ |
| `appendix/checklist-review-query.md` | ✅ |
| `appendix/checklist-review-migration.md` | ✅ |
| `appendix/checklist-truoc-khi-len-production.md` | ✅ |
| `appendix/thuat-ngu.md` | ✅ |
| `appendix/tai-lieu-tham-khao.md` | ✅ |

---

## Nhật ký

| Ngày | Nội dung |
|---|---|
| 2026-08-09 | Khởi tạo repository: `CLAUDE.md`, `README.md`, `ROADMAP.md`, `PROGRESS.md` |
| 2026-08-09 | Hoàn thành Phần 00: môi trường Docker, schema, script seed, `Makefile`, lý thuyết và lab |
| 2026-08-09 | Hoàn thành Phần 01 (kiến trúc), Phần 02 (storage); Phần 03 (MVCC) và Phần 04 (VACUUM) xong lý thuyết + lab |
| 2026-08-10 | Hoàn thành Phần 05 (Index), 06 (Planner), 07 (EXPLAIN), 08 (Lock) — lý thuyết + lab |
| 2026-08-10 | Hoàn thành Phần 09–16 và toàn bộ phụ lục. **Đi hết lộ trình.** Từ Phần 09, lab được lồng vào README |

**Số liệu đã kiểm chứng thật, dùng xuyên suốt các phần:**

| Phần | Phép đo | Kết quả |
|---|---|---|
| 01 | `pgbench` có/không dùng lại connection | 119.016 vs 1.599 tps — **74 lần** |
| 01 | Generic plan vs custom plan (`country_code='DE'`) | ước lượng 40.000 vs thực tế 4.000 — sai **10 lần** |
| 02 | Thứ tự column ảnh hưởng kích thước bảng | 6672 kB vs 5096 kB — **31%** |
| 02 | HOT update: fillfactor 100 / 70 / 70+index | 0% / 42,1% / 0% |
| 02 | TOAST: 100k ký tự lặp vs 96k ký tự ngẫu nhiên | 1.156 byte inline vs 96.000 byte ra TOAST |
| 03 | Write skew dưới REPEATABLE READ | 0 người trực — ràng buộc bị phá |
| 03 | Cùng kịch bản dưới SERIALIZABLE | lỗi `40001`, ràng buộc được giữ |
| 04 | 3 lần update toàn bảng 200k row | 27 MB → **108 MB** |
| 04 | Sau `VACUUM`, chèn thêm 200k row | vẫn 108 MB — không gian được tái sử dụng |
| 04 | Sau `VACUUM FULL` (400k row) | 54 MB, nhưng Visibility Map về **0/6897** |
| 05 | Ngưỡng planner bỏ index (`orders`, 9163 page) | tại 31,5% bitmap đọc **9.486** buffer > cả bảng |
| 05 | Leftmost prefix: `order_id=` vs `product_id=` | 7 vs **9.582** buffer, plan trông giống hệt nhau |
| 05 | Partial index vs index đầy đủ | 672 kB vs 21 MB — **32 lần** |
| 05 | Covering index `INCLUDE` | 176 → **8** buffer — 22 lần |
| 05 | Chi phí ghi: 0 / 3 / 6 index | 342 / 733 / **1.714** ms; index 54 MB > heap 27 MB |
| 05 | BRIN vs B-tree (correlation = 1,0) | **24 kB** vs 64 MB, đọc 1.033 vs 1.131 buffer |
| 06 | Công thức cost tự tính lại | 8738 + 9000 = **17.738** — khớp `EXPLAIN` chính xác |
| 06 | Hai column phụ thuộc, chưa có extended statistics | ước lượng **100.601** vs thực tế 300.000 |
| 06 | Sau `CREATE STATISTICS` | **298.440** vs 300.000 — sai 0,5% |
| 06 | Cost vs thời gian thật (Merge vs Nested Loop) | cost chênh **4 lần**, thời gian gần bằng nhau |
| 07 | Planner chọn Index Scan thay vì Bitmap | **314.799** buffer trên bảng chỉ 9.163 page — chậm 7 lần |
| 07 | Sort tràn đĩa vs trong RAM | `external merge Disk: 55408kB` vs `quicksort Memory: 85677kB` |
| 07 | Bitmap lossy khi thiếu `work_mem` | `exact=887 lossy=8276` vs `exact=9163` |
| 07 | WAL của 100.000 row `INSERT` | `records=100000 bytes=9200000` — 92 byte/row |
| 08 | Lock queue ba tầng | `SELECT` bị chặn bởi `ALTER TABLE` đang chờ, không phải bởi `SELECT` đang giữ |
| 08 | Deadlock | phát hiện sau ~1s, server log có **cả hai** câu lệnh và vòng lặp |
| 08 | `SKIP LOCKED` | W1 lấy job 1,2 — W2 lấy ngay 3,4 thay vì timeout |
| 09 | Full page writes sau checkpoint | cùng câu lệnh: **6.897 kB** vs 4.949 kB WAL |
| 09 | Tỷ lệ checkpoint bị ép | `num_requested` 4 / 41 ≈ 10% — ngưỡng đáng xem lại |
| 12 | Partition pruning | chỉ 1 trong 3 partition xuất hiện trong plan, 22 buffer |
| 12 | `DROP` partition vs `DELETE` | **21 ms**, không sinh dead tuple |
| 12 | Thiếu partition cho tương lai | `ERROR: no partition of relation found for row` |

**Ghi chú kỹ thuật của Phần 00** — toàn bộ nội dung được chạy kiểm chứng trên
PostgreSQL 17.10 (`postgres:17-bookworm`), máy Apple Silicon:

- Dataset sinh bằng `setseed(0.42)` nên tất định giữa các máy.
- Script seed ban đầu để lại `orders` bloat 47,61%; đã thêm `VACUUM FULL`.
- `VACUUM FULL` để lại Visibility Map trống (0/9163 page) khiến `lab_big` mất Index Only
  Scan; đã thêm `VACUUM (ANALYZE)` chạy sau. Phát hiện này được đưa vào bài giảng
  (`README.md` mục 6.6 và `lab.md` Bài 9).
- Thời gian nạp `lab_big`: khoảng 35 giây, dung lượng khoảng 443 MB.
