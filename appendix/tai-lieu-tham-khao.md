# Phụ lục — Tài liệu tham khảo

> Giáo trình này được viết bằng cách đọc, chạy thử và **diễn giải lại**, không dịch. Dưới đây là
> các nguồn nên đọc khi muốn đi sâu hơn từng chủ đề.

---

## 1. Tài liệu chính thức

Tài liệu PostgreSQL là nguồn chuẩn xác nhất, nhưng nó được tổ chức theo **tính năng**, không
theo **vấn đề**. Dùng nó để tra cứu, không phải để học từ đầu.

| Chương | Nội dung | Liên quan phần |
|---|---|---|
| *Internals → Overview of PostgreSQL Internals* | Vòng đời câu SQL | 01 |
| *Internals → Database Physical Storage* | Page layout, tuple header, TOAST, VM, FSM | 02 |
| *Concurrency Control* | MVCC, isolation level, lock mode | 03, 08 |
| *Routine Database Maintenance Tasks* | VACUUM, freeze, autovacuum | 04 |
| *Indexes* | Các loại index, partial, expression, `INCLUDE` | 05 |
| *Performance Tips* | Planner, statistics, `EXPLAIN` | 06, 07 |
| *Server Configuration* | Toàn bộ tham số | Phụ lục parameters |
| *High Availability, Load Balancing, and Replication* | Replication, failover | 10 |
| *Table Partitioning* | Partitioning | 12 |
| *Monitoring Database Activity* | Các view `pg_stat_*`, wait event | 14 |

Đọc `Appendix` phần *Release Notes* của mỗi major version — đây là nơi nhanh nhất để biết hành
vi nào vừa thay đổi.

---

## 2. Source code

Khi tài liệu không trả lời được, source code trả lời được. Các file đáng đọc:

| Đường dẫn | Nội dung |
|---|---|
| `src/backend/access/heap/heapam.c` | Đọc/ghi tuple trong heap |
| `src/backend/access/heap/pruneheap.c` | HOT pruning |
| `src/include/access/htup_details.h` | **Định nghĩa tuple header và toàn bộ cờ `infomask`** |
| `src/backend/storage/page/bufpage.c` | Cấu trúc page 8KB |
| `src/backend/optimizer/path/costsize.c` | **Toàn bộ công thức cost** — kiểm chứng ở Phần 06 |
| `src/backend/utils/adt/selfuncs.c` | Ước lượng selectivity |
| `src/backend/commands/vacuumlazy.c` | VACUUM |
| `src/backend/storage/lmgr/lock.c` | Lock manager và hàng đợi lock |
| `src/backend/storage/lmgr/predicate.c` | SSI — thuật toán Serializable |
| `src/backend/access/transam/xlog.c` | WAL, checkpoint |

`htup_details.h` và `costsize.c` là hai file đáng đọc nhất nếu chỉ chọn hai — chúng giải thích
trực tiếp những thứ Phần 02 và Phần 06 đã đo.

---

## 3. Công cụ

| Công cụ | Dùng để | Ghi chú |
|---|---|---|
| `pg_stat_statements` | Tìm query tốn nhất | Contrib, bắt buộc có |
| `auto_explain` | Bắt plan của query chậm trên production | Contrib, bắt buộc có |
| `pageinspect` | Mổ page 8KB | Contrib, cần superuser |
| `pgstattuple` | Đo bloat chính xác | Contrib. Quét toàn bảng — cẩn thận |
| `pg_buffercache` | Xem buffer cache đang giữ gì | Contrib |
| `pg_visibility` | Kiểm tra Visibility Map | Contrib |
| `amcheck` | Kiểm tra toàn vẹn B-tree | Contrib |
| `pg_repack` | Xử lý bloat **không downtime** | Bên thứ ba, thay `VACUUM FULL` |
| `pg_partman` | Tự động tạo/xóa partition | Bên thứ ba |
| `PgBouncer` | Connection pooling | Bên thứ ba, gần như bắt buộc |
| `Patroni` | Failover tự động | Bên thứ ba. **Đừng tự viết script failover** |
| `pgbench` | Đo tải | Đi kèm PostgreSQL |
| `explain.depesz.com` | Trực quan hóa `EXPLAIN` | Web. Không dán plan chứa dữ liệu nhạy cảm |
| `pgbadger` | Phân tích log | Bên thứ ba |

---

## 4. Sách

| Sách | Phù hợp cho |
|---|---|
| *PostgreSQL 14 Internals* — Egor Rogov | **Nguồn tốt nhất về internals.** Bao trùm MVCC, buffer, WAL, lock, index, planner. Bản PDF miễn phí |
| *The Art of PostgreSQL* — Dimitri Fontaine | Viết SQL đúng cách từ góc nhìn ứng dụng |
| *Designing Data-Intensive Applications* — Martin Kleppmann | Không riêng PostgreSQL. Nền tảng về isolation, replication, phân tán |
| *Database Internals* — Alex Petrov | B-tree, LSM, đồng thuận phân tán |

Nếu chỉ đọc một cuốn để bổ sung cho giáo trình này: **PostgreSQL Internals** của Egor Rogov.

---

## 5. Nguồn theo dõi thường xuyên

| Nguồn | Nội dung |
|---|---|
| `pgsql-hackers` mailing list | Nơi các tính năng được thiết kế và tranh luận |
| Planet PostgreSQL | Tổng hợp blog của cộng đồng |
| Depesz (Hubert Lubaczewski) | Loạt bài "Waiting for PostgreSQL N" về tính năng mới |
| Cybertec, EDB, Percona blog | Bài phân tích sâu về vận hành |
| PGConf, PGCon (video) | Hội thảo, nhiều bài về sự cố thật |

---

## 6. Cách tự kiểm chứng khi đọc bất kỳ nguồn nào

Đây là điều quan trọng nhất trong phụ lục này.

Mọi lời khuyên về PostgreSQL đều **phụ thuộc bối cảnh**: version, phần cứng, kích thước dữ liệu,
phân bố dữ liệu, workload. Một lời khuyên đúng năm 2015 có thể sai hôm nay — ví dụ:

- "CTE là optimization fence" — **đúng trước PostgreSQL 12, sai từ 12 trở đi**.
- "`random_page_cost = 4` là mặc định hợp lý" — đúng với ổ cứng cơ, **sai với SSD**.
- "Tạo index cho mọi column trong `WHERE`" — sai, và Phần 05 đã đo được cái giá.
- "Bảng có 50% free space là bị bloat" — không nhất thiết; Phần 04 chứng minh đó có thể là
  trạng thái cân bằng lành mạnh.

Quy trình kiểm chứng, dùng chính môi trường của Phần 00:

```text
1. Dựng lại tình huống trên `lab` hoặc `lab_big`
2. Đo trạng thái TRƯỚC — EXPLAIN (ANALYZE, BUFFERS), pg_stat_*
3. Áp dụng thay đổi, MỘT thứ một lần
4. Đo lại và so sánh cùng chỉ số
5. Nếu số liệu không khớp với lời khuyên, tin số liệu
```

Giáo trình này được viết theo đúng quy trình đó. Mọi con số trong các phần đều là số đo thật
trên PostgreSQL 17.10, và có vài chỗ kết quả **không** khớp với kỳ vọng thông thường — chúng
được giữ nguyên và giải thích, thay vì lược bỏ:

- Planner chọn Index Scan chậm hơn Bitmap Heap Scan 7 lần *(Phần 07)*.
- Cost ước lượng chênh 4 lần nhưng thời gian thật gần bằng nhau *(Phần 06)*.
- Hai plan trông giống hệt nhau nhưng chênh 1.370 lần về buffer *(Phần 05)*.
- `VACUUM FULL` làm một số query **chậm đi** vì xóa Visibility Map *(Phần 00, 04)*.

> Mục tiêu cuối cùng của giáo trình không phải là bạn nhớ các con số này, mà là bạn có phản xạ
> **tự đo lại** khi gặp một khẳng định về hiệu năng — kể cả khẳng định trong chính giáo trình này.
