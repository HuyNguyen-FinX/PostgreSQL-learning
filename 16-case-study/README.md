# Phần 16 — Case study production

> Mỗi case study theo cùng một khuôn: **bối cảnh → triệu chứng → dữ liệu quan sát → giả thuyết
> → kiểm chứng → nguyên nhân gốc → xử lý → phòng ngừa**.
>
> Hãy đọc tới phần "Dữ liệu quan sát được" rồi **dừng lại tự chẩn đoán** trước khi đọc tiếp.

---

## Case 1 — Query 20ms đột nhiên thành 8 giây sau đợt import

**Bối cảnh.** API danh sách đơn hàng theo quốc gia, chạy ổn định 20ms suốt 6 tháng. Sau một đợt
import 5 triệu user mới (chủ yếu từ một thị trường), query thành 8 giây.

**Triệu chứng.** Chỉ chậm với **một số** giá trị `country_code`, các giá trị khác vẫn nhanh.

**Dữ liệu quan sát được.**

```text
-- Nhanh (country_code = 'DE')
Index Scan using idx_country on users (cost=... rows=4160) (actual rows=4000)

-- Chậm (country_code = 'VN')
Index Scan using idx_country on users (cost=... rows=4160) (actual rows=3500000)
                                              ^^^^^^^^^           ^^^^^^^^^^^
```

**Giả thuyết.** Ước lượng giống nhau cho hai giá trị có tần suất chênh nhau 875 lần → planner
đang dùng **generic plan** (Phần 01), hoặc statistics đã lỗi thời (Phần 06).

**Kiểm chứng.**

```sql
SELECT last_analyze, last_autoanalyze, n_mod_since_analyze
FROM pg_stat_user_tables WHERE relname = 'users';

SELECT most_common_vals, most_common_freqs
FROM pg_stats WHERE tablename = 'users' AND attname = 'country_code';
```

MCV list vẫn phản ánh phân bố **trước** đợt import.

**Nguyên nhân gốc.** Đợt import làm `n_mod_since_analyze` vượt xa ngưỡng, nhưng
`autovacuum_analyze_scale_factor = 0.1` trên bảng 5 triệu row nghĩa là cần 500.000 thay đổi mới
kích hoạt `ANALYZE`. Trong khoảng đó, planner dùng statistics cũ.

**Xử lý.**

```sql
ANALYZE users;
ALTER TABLE users ALTER COLUMN country_code SET STATISTICS 1000;
ANALYZE users;
```

**Phòng ngừa.** Hạ ngưỡng cho bảng lớn (Phần 04), và **luôn `ANALYZE` ngay sau mỗi đợt import lớn**:

```sql
ALTER TABLE users SET (autovacuum_analyze_scale_factor = 0.01);
```

---

## Case 2 — Bảng 200 GB nhưng dữ liệu thật chỉ 30 GB

**Bối cảnh.** Bảng `session` lưu phiên đăng nhập, mỗi phiên được `UPDATE` mỗi lần người dùng
thao tác.

**Triệu chứng.** Đĩa gần đầy. `count(*)` cho khoảng 40 triệu row, nhưng bảng chiếm 200 GB —
tương đương 5 KB mỗi row cho một bảng chỉ có vài column.

**Dữ liệu quan sát được.**

```sql
SELECT n_live_tup, n_dead_tup, last_autovacuum FROM pg_stat_user_tables WHERE relname='session';
```

```text
 n_live_tup | n_dead_tup | last_autovacuum
------------+------------+-----------------
   40000000 |  310000000 | 2026-06-02 ...     ← hai tháng trước
```

**Giả thuyết.** Autovacuum không chạy, hoặc chạy mà không dọn được (Phần 04).

**Kiểm chứng.**

```sql
VACUUM (VERBOSE) session;
```

```text
tuples: 0 removed, 350000000 remain, 310000000 are dead but not yet removable
```

**`dead but not yet removable`** → có ai đó đang giữ snapshot cũ.

```sql
SELECT slot_name, active, age(xmin) FROM pg_replication_slots;
```

```text
 slot_name  | active |    age
------------+--------+------------
 replica_cu | f      | 1840000000
```

**Nguyên nhân gốc.** Một replica bị gỡ bỏ 2 tháng trước nhưng slot không được xóa. Slot giữ
`xmin` → VACUUM không dọn được dead tuple nào trên **toàn database**.

**Xử lý.**

```sql
SELECT pg_drop_replication_slot('replica_cu');
VACUUM (VERBOSE, ANALYZE) session;
-- sau đó, để lấy lại disk:
-- pg_repack -t session    (hoặc VACUUM FULL nếu chấp nhận downtime)
```

**Phòng ngừa.** Cảnh báo **ngay lập tức** khi có slot `active = false`. Đặt
`max_slot_wal_keep_size` (Phần 10). Đưa "xóa slot" vào quy trình gỡ replica.

---

## Case 3 — Autovacuum chạy liên tục mà bloat vẫn tăng

**Bối cảnh.** Bảng hàng đợi công việc, khoảng 5.000 job mỗi giây.

**Triệu chứng.** Autovacuum gần như luôn chạy trên bảng này, nhưng `n_dead_tup` vẫn tăng đều.

**Dữ liệu quan sát được.**

```text
VACUUM VERBOSE: index scans: 7
```

**Giả thuyết.** `index scans: > 1` là dấu hiệu thiếu `maintenance_work_mem` (Phần 04).

**Kiểm chứng.** `maintenance_work_mem = 64MB` mặc định, trong khi bảng có 5 index và hàng chục
triệu dead tuple mỗi vòng.

**Nguyên nhân gốc.** VACUUM không giữ hết danh sách dead tuple id trong bộ nhớ nên phải quét
toàn bộ 5 index **7 lần** mỗi vòng. Mỗi vòng vacuum mất hàng chục phút, trong khi dead tuple mới
sinh ra nhanh hơn tốc độ dọn.

**Xử lý.**

```sql
ALTER SYSTEM SET maintenance_work_mem = '1GB';
SELECT pg_reload_conf();

ALTER TABLE hang_doi SET (
    autovacuum_vacuum_scale_factor = 0,
    autovacuum_vacuum_threshold    = 10000,
    autovacuum_vacuum_cost_delay   = 0
);

DROP INDEX idx_khong_dung_1, idx_khong_dung_2;   -- bớt index cần quét
```

**Phòng ngừa.** Theo dõi `index scans` trong log autovacuum. Với bảng hàng đợi, cân nhắc
partitioning theo thời gian và `DROP` partition cũ thay vì `DELETE` (Phần 12).

---

## Case 4 — `ALTER TABLE ADD COLUMN` làm treo API 4 phút

**Bối cảnh.** Migration thêm một column nullable — thao tác được cho là tức thì.

**Triệu chứng.** Ngay khi migration chạy, **mọi** API kể cả API chỉ đọc đều timeout. Kéo dài 4
phút rồi tự hết.

**Dữ liệu quan sát được.**

```text
 pid | state  |        mode         | granted | bi_chan_boi
-----+--------+---------------------+---------+-------------
 926 | idle in transaction | AccessShareLock | t   | {}
 932 | active | AccessExclusiveLock | f       | {926}
 946 | active | AccessShareLock     | f       | {932}
 ... 200 dòng tương tự
```

**Giả thuyết.** Lock queue (Phần 08).

**Nguyên nhân gốc.** `ADD COLUMN` nullable thật sự tức thì — nhưng nó cần `ACCESS EXCLUSIVE`
trong một khoảnh khắc. Một job báo cáo đang mở transaction 4 phút giữ `AccessShareLock`.
Migration phải xếp hàng, và **mọi `SELECT` phía sau xếp hàng sau migration** — dù chúng hoàn
toàn tương thích với job báo cáo.

**Xử lý ngay lúc đó.** `pg_cancel_backend()` cho migration → hàng đợi thông ngay.

**Phòng ngừa.**

```sql
SET lock_timeout = '3s';
ALTER TABLE orders ADD COLUMN ghi_chu text;
```

Cộng với `idle_in_transaction_session_timeout` ở mức cluster, và kiểm tra transaction dài trước
khi deploy.

---

## Case 5 — Connection pool đầy trong khi CPU database chỉ 15%

**Bối cảnh.** API dùng PgBouncer, `default_pool_size = 50`. Giờ cao điểm, ứng dụng báo hết
connection.

**Triệu chứng.** `cl_waiting` cao, nhưng CPU database chỉ 15% và không query nào chậm.

**Dữ liệu quan sát được.**

```sql
SELECT state, count(*) FROM pg_stat_activity GROUP BY 1;
```

```text
 state               | count
---------------------+-------
 idle in transaction |    47
 active              |     3
```

**Giả thuyết.** Transaction bị giữ mở mà không làm gì (Phần 11, Phần 15).

**Kiểm chứng.**

```sql
SELECT pid, now() - xact_start AS tuoi, wait_event_type, wait_event, left(query, 60)
FROM pg_stat_activity WHERE state = 'idle in transaction' ORDER BY xact_start;
```

```text
 tuoi     | wait_event_type | wait_event | query
----------+-----------------+------------+---------------------------
 00:00:02 | Client          | ClientRead | INSERT INTO orders ...
```

`wait_event = ClientRead` — database đang **chờ ứng dụng**.

**Nguyên nhân gốc.** Code gọi API thanh toán **bên trong** transaction. Mỗi request giữ một
connection 2 giây chỉ để chờ HTTP. 50 connection × 2 giây = trần khoảng 25 request/giây.

**Xử lý.** Tách lệnh gọi HTTP ra ngoài transaction; dùng outbox pattern nếu cần đảm bảo nhất
quán (Phần 15).

**Phòng ngừa.**

```sql
ALTER ROLE api_user SET idle_in_transaction_session_timeout = '10s';
```

Biến bug âm thầm thành lỗi rõ ràng trong log.

---

## Case 6 — Replica lag tăng dần vào mỗi 3 giờ sáng

**Bối cảnh.** Replica phục vụ dashboard. Mỗi đêm 3 giờ, lag tăng từ vài trăm ms lên 40 phút,
rồi tự hết lúc 5 giờ.

**Dữ liệu quan sát được.**

```sql
SELECT pg_size_pretty(pg_wal_lsn_diff(sent_lsn, write_lsn))  AS chua_ghi,
       pg_size_pretty(pg_wal_lsn_diff(flush_lsn, replay_lsn)) AS chua_replay
FROM pg_stat_replication;
```

```text
 chua_ghi | chua_replay
----------+-------------
 0 bytes  | 12 GB
```

**Giả thuyết.** WAL tới nơi bình thường (`chua_ghi = 0`) nhưng replay không kịp (Phần 10). Nghẽn
nằm ở replica, không phải mạng.

**Kiểm chứng.** Trên replica lúc 3 giờ có một báo cáo lớn chạy 2 tiếng. Trên primary lúc 3 giờ
có job dọn dữ liệu cũ sinh lượng WAL khổng lồ.

```sql
SHOW hot_standby_feedback;    -- off
SHOW max_standby_streaming_delay;  -- 30s
```

**Nguyên nhân gốc.** Replay là **một tiến trình đơn luồng**. Job dọn dữ liệu trên primary sinh
WAL nhanh hơn khả năng replay, cộng thêm xung đột với báo cáo dài khiến replay bị hoãn liên tục.

**Xử lý.**

1. Đổi job dọn thành `DROP PARTITION` thay vì `DELETE` — gần như không sinh WAL (Phần 12).
2. Chuyển báo cáo nặng sang một replica riêng.
3. Cân nhắc `hot_standby_feedback = on` — nhưng phải theo dõi `backend_xmin` trên primary, vì
   nó sẽ chặn VACUUM ở đó (Phần 10).

**Phòng ngừa.** Cảnh báo dựa trên `chua_replay` theo byte, không chỉ theo thời gian — và nhớ
điều kiện `CASE` để không cảnh báo sai lúc primary rảnh.

---

## Case 7 — Deadlock chỉ xảy ra khi có khuyến mãi

**Bối cảnh.** Ngày thường không có deadlock. Ngày khuyến mãi, hàng trăm deadlock mỗi phút.

**Dữ liệu quan sát được** (từ server log — nơi có đủ thông tin):

```text
Process 100 waits for ShareLock on transaction 5001; blocked by process 200.
Process 200 waits for ShareLock on transaction 5000; blocked by process 100.
Process 100: UPDATE ton_kho SET so_luong = so_luong - 1 WHERE san_pham_id = 55;
Process 200: UPDATE ton_kho SET so_luong = so_luong - 1 WHERE san_pham_id = 88;
```

**Giả thuyết.** Hai transaction cập nhật nhiều sản phẩm theo **thứ tự khác nhau** (Phần 08).

**Kiểm chứng.** Code duyệt giỏ hàng theo thứ tự người dùng thêm vào — mỗi người một thứ tự khác.
Ngày thường ít trùng sản phẩm nên không xung đột; ngày khuyến mãi mọi người mua cùng vài sản
phẩm hot.

**Nguyên nhân gốc.** Không có thứ tự khóa nhất quán.

**Xử lý.**

```sql
-- Khóa mọi sản phẩm trong giỏ theo thứ tự id, TRƯỚC khi cập nhật
SELECT san_pham_id FROM ton_kho
WHERE san_pham_id = ANY($1) ORDER BY san_pham_id FOR UPDATE;
```

Hoặc gom vào một câu lệnh:

```sql
UPDATE ton_kho SET so_luong = so_luong - c.sl
FROM (SELECT unnest($1::int[]) AS id, unnest($2::int[]) AS sl) c
WHERE ton_kho.san_pham_id = c.id;
```

**Phòng ngừa.** Quy tắc trong codebase: **mọi thao tác nhiều row phải `ORDER BY` khóa chính**.
Kèm retry cho `40P01`.

---

## Case 8 — Index vừa tạo nhưng planner không dùng

**Bối cảnh.** Tạo `CREATE INDEX ON orders(user_id, status)` để tăng tốc một query, nhưng không
có gì thay đổi.

**Dữ liệu quan sát được.**

```sql
EXPLAIN SELECT * FROM orders WHERE status = 'pending';
```

```text
 Seq Scan on orders
   Filter: (status = 'pending'::text)
```

**Giả thuyết.** Kiểm tra lần lượt sáu nguyên nhân ở Phần 05 mục 6.

**Kiểm chứng.**

```sql
-- Index có hợp lệ không?
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;   -- rỗng, OK

-- Ép dùng thử
SET enable_seqscan = off;
EXPLAIN SELECT * FROM orders WHERE status = 'pending';
```

Index vẫn không được dùng ngay cả khi tắt Seq Scan → **không phải vấn đề cost**, mà là index
không dùng được cho điều kiện này.

**Nguyên nhân gốc.** Quy tắc leftmost prefix (Phần 05). Index là `(user_id, status)`, query chỉ
lọc theo `status` — column thứ hai. PostgreSQL không seek được.

Trong một biến thể khác của case này, index **có** được dùng nhưng đọc 9.582 buffer thay vì 7 —
và plan trông y hệt. Đó là lý do phải đọc `Buffers`.

**Xử lý.**

```sql
CREATE INDEX CONCURRENTLY ON orders(status, user_id);   -- đảo thứ tự
-- hoặc, nếu 'pending' chỉ chiếm vài %:
CREATE INDEX CONCURRENTLY ON orders(created_at) WHERE status = 'pending';
```

**Phòng ngừa.** Khi thiết kế composite index, viết ra danh sách query cần phục vụ và kiểm tra
từng cái theo quy tắc leftmost prefix. Luôn xác nhận bằng `EXPLAIN (ANALYZE, BUFFERS)`.

---

## Case 9 — Disk đầy vì replication slot bị bỏ quên

**Bối cảnh.** Cluster primary hết sạch dung lượng lúc 2 giờ sáng, ngừng nhận ghi.

**Dữ liệu quan sát được.**

```sql
SELECT count(*), pg_size_pretty(sum(size)) FROM pg_ls_waldir();
```

```text
 count | pg_size_pretty
-------+----------------
 28000 | 437 GB
```

**Nguyên nhân gốc.** Một slot logical replication tạo cho một thử nghiệm CDC ba tuần trước,
không ai xóa. Nó giữ toàn bộ WAL kể từ đó.

**Xử lý khẩn cấp.**

```sql
SELECT slot_name, active,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn))
FROM pg_replication_slots ORDER BY 3 DESC;

SELECT pg_drop_replication_slot('cdc_thu_nghiem');
CHECKPOINT;    -- giải phóng WAL
```

> **Tuyệt đối không xóa file WAL bằng tay.** Xóa nhầm file mà PostgreSQL cần là mất khả năng
> khôi phục.

**Phòng ngừa.**

```sql
ALTER SYSTEM SET max_slot_wal_keep_size = '50GB';
```

Cộng cảnh báo trên `pg_replication_slots WHERE active = false`. Case 2 và Case 9 là **cùng một
nguyên nhân** biểu hiện thành hai sự cố khác nhau — một bên bloat, một bên đầy đĩa.

---

## Case 10 — Job queue xử lý trùng message

**Bối cảnh.** Hệ thống gửi email dùng bảng hàng đợi trên PostgreSQL. Khách hàng báo nhận email
trùng.

**Dữ liệu quan sát được.** Code lấy việc:

```sql
SELECT id, payload FROM hang_doi WHERE trang_thai = 'pending' ORDER BY id LIMIT 10;
-- ứng dụng xử lý...
UPDATE hang_doi SET trang_thai = 'done' WHERE id = ANY($1);
```

**Nguyên nhân gốc.** Có **khoảng hở** giữa `SELECT` và `UPDATE`. Hai worker cùng `SELECT` ra
cùng 10 job trước khi ai kịp `UPDATE`.

**Xử lý.** Lấy việc và đánh dấu trong **một** câu lệnh, dùng `FOR UPDATE SKIP LOCKED` (Phần 08):

```sql
UPDATE hang_doi SET trang_thai = 'processing'
WHERE id IN (
    SELECT id FROM hang_doi WHERE trang_thai = 'pending'
    ORDER BY id LIMIT 10 FOR UPDATE SKIP LOCKED
)
RETURNING id, payload;
```

**Phòng ngừa.** Hàng đợi luôn là **at-least-once** — kể cả sửa đúng, worker vẫn có thể chết sau
khi gửi email nhưng trước khi commit. Bên nhận phải idempotent (Phần 15):

```sql
ALTER TABLE email_da_gui ADD CONSTRAINT uniq_key UNIQUE (idempotency_key);
```

Và đừng quên cấu hình autovacuum cho bảng hàng đợi (Case 3).

---

## Case 11 — `COUNT(*)` trên bảng lớn làm nghẽn dashboard

**Bối cảnh.** Dashboard hiển thị "Tổng số đơn hàng", chạy `SELECT count(*) FROM orders` mỗi 10
giây. Bảng 800 triệu row.

**Dữ liệu quan sát được.**

```text
Finalize Aggregate (actual time=42000)
  ->  Parallel Seq Scan on orders (actual rows=266666666 loops=3)
   Buffers: shared hit=1200000 read=6800000
```

Mỗi lần chạy đọc 8 triệu page và mất 42 giây. Chạy mỗi 10 giây nghĩa là **luôn có 4 lần chạy
chồng nhau**, chiếm hết buffer cache và đẩy dữ liệu nóng ra ngoài.

**Nguyên nhân gốc.** MVCC khiến `count(*)` không thể đọc từ metadata — mỗi transaction có thể
thấy số row khác nhau, nên phải kiểm tra tính hiển thị của **từng** tuple (Phần 03).

**Xử lý.**

```sql
-- 1. Ước lượng, gần như tức thì
SELECT reltuples::bigint FROM pg_class WHERE relname = 'orders';

-- 2. Nếu cần chính xác: bảng đếm cập nhật bằng trigger
-- 3. Nếu chỉ cần "hơn 10.000": đặt trần
SELECT count(*) FROM (SELECT 1 FROM orders LIMIT 10000) t;
```

Dashboard chuyển sang phương án 1 — sai số dưới 1% và mất 0,1 ms.

**Phòng ngừa.** Với dashboard, luôn hỏi: **con số này cần chính xác tới đâu?** Gần như luôn là
"khoảng chừng". Và đặt `statement_timeout` cho role của dashboard để một query hỏng không kéo
sập cache.

---

## Case 12 — Batch job đêm làm chậm traffic ban ngày hôm sau

**Bối cảnh.** Job tổng hợp chạy 2–4 giờ sáng. Từ 8 giờ sáng, mọi query chậm gấp 3, kéo dài tới trưa.

**Dữ liệu quan sát được.**

```sql
SELECT round(100.0 * blks_hit / NULLIF(blks_hit + blks_read, 0), 2) AS cache_hit_pct
FROM pg_stat_database WHERE datname = 'production';
```

```text
 cache_hit_pct
---------------
 71.30           ← bình thường là 99,5
```

**Giả thuyết.** Batch job quét bảng lớn và **đẩy toàn bộ dữ liệu nóng ra khỏi buffer cache**
(Phần 01).

**Kiểm chứng.**

```sql
SELECT c.relname, count(*) AS buffer
FROM pg_buffercache b JOIN pg_class c ON c.relfilenode = b.relfilenode
GROUP BY 1 ORDER BY 2 DESC LIMIT 5;
```

Buffer cache chủ yếu chứa các bảng lịch sử mà job đêm quét, không phải bảng nóng của API.

**Nguyên nhân gốc.** `shared_buffers` bị chiếm bởi dữ liệu chỉ dùng một lần. PostgreSQL có ring
buffer riêng cho quét tuần tự lớn để giảm hiện tượng này, nhưng job dùng nhiều Index Scan nên
không được hưởng cơ chế đó.

**Xử lý.**

1. Chuyển batch job sang chạy trên **replica** (Phần 10) — cách sạch nhất.
2. Nếu bắt buộc chạy trên primary: làm nóng lại cache sau khi job xong.

```sql
SELECT pg_prewarm('orders');
SELECT pg_prewarm('users');
```

3. Chia job thành các lô nhỏ có nghỉ giữa chừng, để `background writer` kịp làm việc.

**Phòng ngừa.** Theo dõi `cache_hit_pct` như một metric hạng nhất. Sụt đột ngột luôn có nguyên
nhân, và nguyên nhân thường là một workload mới xuất hiện.

---

## Cách dùng phần này để tự rèn

Với mỗi case, hãy tự trả lời trước khi đọc đáp án:

1. **Câu query chẩn đoán đầu tiên bạn chạy là gì?**
2. **Bạn kỳ vọng thấy gì nếu giả thuyết đúng? Nếu sai?**
3. **Cách xử lý tức thời khác cách xử lý gốc rễ ở chỗ nào?**
4. **Metric nào lẽ ra đã cảnh báo trước khi người dùng phàn nàn?**

Câu hỏi thứ tư là câu quan trọng nhất. Gần như mọi case ở trên đều có một chỉ số đã âm thầm xấu
đi từ nhiều ngày hoặc nhiều tuần trước.

---

## Bản đồ: case study nào thuộc phần nào

| Case | Nguyên nhân gốc | Phần liên quan |
|---|---|---|
| 1 | Statistics lỗi thời sau import | 04, 06 |
| 2 | Replication slot giữ `xmin` | 04, 10 |
| 3 | Thiếu `maintenance_work_mem` | 04 |
| 4 | Lock queue FIFO | 08 |
| 5 | HTTP bên trong transaction | 11, 15 |
| 6 | Replay đơn luồng không kịp | 10, 12 |
| 7 | Thứ tự khóa không nhất quán | 08 |
| 8 | Leftmost prefix | 05 |
| 9 | Replication slot giữ WAL | 09, 10 |
| 10 | Khoảng hở giữa `SELECT` và `UPDATE` | 08, 15 |
| 11 | MVCC buộc `count(*)` quét toàn bảng | 03 |
| 12 | Batch job đẩy cache | 01, 10 |

Chú ý: **Case 2 và Case 9 cùng một nguyên nhân**, biểu hiện thành hai sự cố hoàn toàn khác nhau.
Đó là điều đáng nhớ nhất của Phần 16 — một nguyên nhân gốc có thể xuất hiện dưới nhiều triệu
chứng không liên quan gì tới nhau.
