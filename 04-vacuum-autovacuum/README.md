# Phần 04 — VACUUM & Autovacuum

> **Mục tiêu:** hiểu vì sao bảng phình to dù đã xóa dữ liệu, và biết chẩn đoán khi autovacuum
> không theo kịp.

---

## 1. Vấn đề

Phần 03 đã chứng minh: `UPDATE` tạo version mới, `DELETE` chỉ ghi `xmax`. Không thao tác nào
thực sự giải phóng chỗ. Nếu không có ai dọn, bảng chỉ có một chiều: **to lên**.

VACUUM là bộ phận dọn dẹp đó. Nó làm bốn việc:

| Việc | Mục đích |
|---|---|
| Thu hồi dead tuple | Lấy lại không gian trong page cho row mới |
| Cập nhật Free Space Map | Để `INSERT` biết page nào còn chỗ |
| Cập nhật Visibility Map | Để Index Only Scan hoạt động |
| Freeze tuple cũ | Chống transaction ID wraparound |

Việc thứ tư quan trọng đến mức nếu bỏ qua, cluster sẽ **ngừng nhận ghi**.

---

## 2. VACUUM và VACUUM FULL: khác biệt căn bản

### 2.1. Thí nghiệm

Bảng 200.000 row, tắt autovacuum để quan sát rõ:

```sql
CREATE TABLE bloat (id int PRIMARY KEY, v int, pad text)
  WITH (autovacuum_enabled = false);
INSERT INTO bloat SELECT g, 0, repeat('x', 100) FROM generate_series(1, 200000) g;
VACUUM ANALYZE bloat;
```

```text
=== TRƯỚC ===
 heap  |   idx   |  song  | chet | free_pct
-------+---------+--------+------+----------
 27 MB | 4408 kB | 200000 |    0 |      0.6
```

Ba lần `UPDATE` toàn bảng:

```sql
UPDATE bloat SET v = v + 1;
UPDATE bloat SET v = v + 1;
UPDATE bloat SET v = v + 1;
```

```text
=== SAU 3 LẦN UPDATE ===
  heap  |   idx   |  song  |  chet  | free_pct
--------+---------+--------+--------+----------
 108 MB | 8792 kB | 200000 | 200000 |     48.7
```

**27 MB → 108 MB. Gấp 4 lần. Số row logic không đổi.**

Index cũng phình gấp đôi. Đây là hình ảnh chính xác của một bảng bị update nhiều mà không
được dọn.

### 2.2. `VACUUM` thường

```sql
VACUUM (VERBOSE) bloat;
```

```text
INFO:  finished vacuuming "lab.public.bloat": index scans: 1
pages: 0 removed, 13793 remain, 13793 scanned (100.00% of total)
tuples: 200000 removed, 200000 remain, 0 are dead but not yet removable
index scan needed: 10345 pages from table (75.00% of total) had 599944 dead item identifiers removed
buffer usage: 39088 hits, 0 misses, 0 dirtied
WAL usage: 28683 records, 0 full page images, 4064242 bytes
Time: 234.315 ms
```

Kết quả sau đó:

```text
  heap  |   idx   | chet | free_pct
--------+---------+------+----------
 108 MB | 8792 kB |    0 |     74.8
```

Đọc kỹ hai con số:

- **`pages: 0 removed`** — không page nào được trả về hệ điều hành.
- **Bảng vẫn 108 MB**, nhưng `free_percent` nhảy từ 48,7% lên **74,8%**.

VACUUM đã dọn sạch dead tuple (`chet = 0`), nhưng **không làm file nhỏ lại**. Nó chỉ biến
không gian chết thành không gian **có thể dùng lại**.

### 2.3. Chứng minh "dùng lại được" là thật

```sql
INSERT INTO bloat SELECT g, 0, repeat('x', 100)
FROM generate_series(200001, 400000) g;      -- thêm 200.000 row MỚI
```

```text
  heap  | free_pct
--------+----------
 108 MB |     50.1
```

**Bảng không lớn thêm một byte nào.** 200.000 row mới nằm gọn trong không gian mà VACUUM đã
giải phóng; `free_percent` giảm từ 74,8% xuống 50,1%.

Đây là điều quan trọng nhất của phần này:

> **VACUUM không thu nhỏ bảng, nhưng nó ngăn bảng lớn thêm.**

Một bảng có `free_percent` cao **không nhất thiết là vấn đề** — nếu tốc độ ghi ổn định, phần
trống đó sẽ được dùng lại liên tục. Bảng ở trạng thái cân bằng đó là bình thường và lành mạnh.

### 2.4. `VACUUM FULL`

```sql
VACUUM FULL bloat;
```

```text
Time: 349.718 ms

 heap  |   idx   | free_pct
-------+---------+----------
 54 MB | 8792 kB |      0.5
```

54 MB cho 400.000 row — gấp đôi 27 MB ban đầu của 200.000 row. Chính xác như mong đợi.
`free_percent` về 0,5%.

`VACUUM FULL` viết lại toàn bộ bảng sang file mới rồi tráo chỗ. Ba hệ quả:

1. **Giữ `ACCESS EXCLUSIVE LOCK`** — chặn cả đọc lẫn ghi suốt thời gian chạy.
2. **Cần dung lượng trống bằng cỡ bảng** — dễ gây sự cố khi disk đã gần đầy.
3. **Xóa sạch Visibility Map:**

```sql
SELECT count(*) FILTER (WHERE all_visible) AS all_visible, count(*) AS tong_page
FROM pg_visibility_map('bloat');
```

```text
 all_visible | tong_page
-------------+-----------
           0 |      6897
```

Đúng hiện tượng đã gặp ở Phần 00: sau `VACUUM FULL`, mọi Index Only Scan ngừng hoạt động cho
tới lần `VACUUM` tiếp theo. **Luôn chạy `VACUUM (ANALYZE)` ngay sau `VACUUM FULL`.**

### 2.5. Bảng so sánh

| | `VACUUM` | `VACUUM FULL` | `pg_repack` |
|---|---|---|---|
| Lock | `SHARE UPDATE EXCLUSIVE` — không chặn đọc/ghi | `ACCESS EXCLUSIVE` — chặn tất cả | Ngắn, chỉ ở đầu và cuối |
| Trả disk về OS | Không (trừ page trống ở cuối bảng) | Có | Có |
| Cần chỗ trống thêm | Không | Bằng cỡ bảng | Bằng cỡ bảng |
| Dựng lại Visibility Map | Có | **Không** | Không |
| Dùng khi nào | Thường xuyên, tự động | Sự cố, có downtime | Production, không downtime |

`pg_repack` là extension bên ngoài, không có sẵn trong PostgreSQL. Nó đạt được kết quả của
`VACUUM FULL` mà gần như không khóa, bằng cách dựng bảng mới song song và dùng trigger đồng
bộ thay đổi. Đây là công cụ tiêu chuẩn để xử lý bloat trên production.

---

## 3. Vì sao VACUUM "chạy rồi mà bảng vẫn phình"

Đây là câu hỏi hay gặp nhất, và câu trả lời gần như luôn là: **có ai đó đang giữ một snapshot cũ.**

Dấu hiệu nằm ngay trong output của `VACUUM VERBOSE`:

```text
tuples: 0 removed, 200000 remain, 200000 are dead but not yet removable
```

**`dead but not yet removable`** — tuple đã chết, nhưng VACUUM không được phép dọn vì còn
transaction có thể nhìn thấy chúng.

### 3.1. Ba thủ phạm

**1. Transaction chạy lâu hoặc `idle in transaction`**

```sql
SELECT pid, now() - xact_start AS tuoi, state, backend_xmin, left(query, 50)
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
ORDER BY xact_start LIMIT 5;
```

Một transaction mở ở bảng A chặn VACUUM ở **mọi** bảng trong database. Phần 03 Bài 5 đã
chứng minh.

**2. Replication slot bị bỏ quên**

```sql
SELECT slot_name, active, age(xmin) AS tuoi_xmin,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_bi_giu
FROM pg_replication_slots
ORDER BY age(xmin) DESC NULLS LAST;
```

Đây là thủ phạm nguy hiểm nhất vì nó **im lặng**. Một replica bị tắt mà slot không bị xóa sẽ:

- Giữ `xmin` mãi mãi → VACUUM không dọn được gì → bloat tăng vô hạn.
- Giữ WAL mãi mãi → disk đầy.

Slot có `active = false` và `tuoi_xmin` lớn là báo động đỏ.

**3. Prepared transaction bị treo**

```sql
SELECT gid, prepared, age(transaction) AS tuoi FROM pg_prepared_xacts;
```

Thường do một distributed transaction lỗi giữa chừng. Nếu bảng này có dòng mà không ai biết
nó từ đâu ra, gần như chắc chắn cần `ROLLBACK PREPARED`.

### 3.2. Còn hai nguyên nhân khác

**Autovacuum bị đói tài nguyên.** Mặc định `autovacuum_max_workers = 3`. Database có 500
bảng lớn, mỗi lần vacuum mất 20 phút, thì có bảng cả ngày không tới lượt.

**Autovacuum bị throttle.** `autovacuum_vacuum_cost_delay` khiến worker tự ngủ sau mỗi lượng
I/O nhất định. Mặc định (2ms từ PostgreSQL 12) khá bảo thủ trên SSD.

---

## 4. Autovacuum

### 4.1. Khi nào nó chạy

Với mỗi bảng, autovacuum kích hoạt VACUUM khi:

```text
n_dead_tup > autovacuum_vacuum_threshold
             + autovacuum_vacuum_scale_factor × reltuples
```

Mặc định: `threshold = 50`, `scale_factor = 0.2`.

**Đây là công thức có vấn đề nghiêm trọng với bảng lớn:**

| Số row | Ngưỡng kích hoạt (mặc định 20%) |
|---:|---:|
| 1.000 | 250 dead tuple |
| 1.000.000 | 200.050 dead tuple |
| 100.000.000 | **20.000.050 dead tuple** |

Bảng 100 triệu row phải tích tụ **20 triệu** dead tuple mới được vacuum. Lúc đó bảng đã phình
đáng kể, và lần vacuum ấy sẽ rất nặng và rất lâu.

**Cách sửa: đặt `scale_factor` thấp cho bảng lớn.**

```sql
ALTER TABLE orders SET (
    autovacuum_vacuum_scale_factor = 0.02,   -- 2% thay vì 20%
    autovacuum_vacuum_threshold    = 1000
);

-- Với bảng rất lớn, bỏ hẳn tỷ lệ và dùng số tuyệt đối:
ALTER TABLE su_kien SET (
    autovacuum_vacuum_scale_factor = 0,
    autovacuum_vacuum_threshold    = 50000
);
```

Nguyên tắc: vacuum **thường xuyên hơn, mỗi lần nhẹ hơn** luôn tốt hơn là hiếm khi vacuum
nhưng mỗi lần rất nặng.

Tương tự cho ANALYZE: `autovacuum_analyze_scale_factor` mặc định 0,1 (10%). Trên bảng lớn có
dữ liệu thay đổi nhanh, statistics lỗi thời khiến planner chọn sai plan — nội dung Phần 06.

### 4.2. Các tham số cần biết

| Tham số | Mặc định | Ý nghĩa |
|---|---|---|
| `autovacuum_max_workers` | 3 | Số bảng được vacuum đồng thời |
| `autovacuum_naptime` | 1min | Bao lâu kiểm tra một vòng |
| `autovacuum_vacuum_cost_limit` | 200 (dùng `vacuum_cost_limit`) | "Ngân sách" I/O trước khi nghỉ |
| `autovacuum_vacuum_cost_delay` | 2ms | Nghỉ bao lâu khi hết ngân sách |
| `maintenance_work_mem` | 64MB | Bộ nhớ giữ danh sách dead tuple |

**`maintenance_work_mem` là tham số bị bỏ quên nhiều nhất.** VACUUM giữ danh sách các dead
tuple id trong bộ nhớ này. Nếu đầy, nó phải **quét index nhiều lần** — nhìn thấy trực tiếp
qua `index scans:` trong `VACUUM VERBOSE`.

```text
INFO:  finished vacuuming "lab.public.bloat": index scans: 1
```

`index scans: 1` là tốt. Nếu thấy 3, 5 hay 10, đó là dấu hiệu rõ ràng cần tăng
`maintenance_work_mem`:

```sql
ALTER SYSTEM SET maintenance_work_mem = '1GB';
SELECT pg_reload_conf();
```

Lưu ý mỗi autovacuum worker có thể dùng tới `maintenance_work_mem` riêng, nên tổng bộ nhớ là
`autovacuum_max_workers × maintenance_work_mem`.

### 4.3. Theo dõi autovacuum

Cấu hình của Phần 00 đặt `log_autovacuum_min_duration = 0`, nên **mọi** lần autovacuum đều
được ghi log. Xem bằng `make logs`.

Xem autovacuum đang chạy ngay lúc này:

```sql
SELECT pid, now() - xact_start AS chay_bao_lau, left(query, 60) AS query
FROM pg_stat_activity
WHERE backend_type = 'autovacuum worker';
```

Tiến độ chi tiết (PostgreSQL 9.6+):

```sql
SELECT p.pid, c.relname, p.phase,
       p.heap_blks_scanned, p.heap_blks_total,
       round(100.0 * p.heap_blks_scanned / NULLIF(p.heap_blks_total, 0), 1) AS pct
FROM pg_stat_progress_vacuum p
JOIN pg_class c ON c.oid = p.relid;
```

Bảng nào lâu chưa được vacuum:

```sql
SELECT relname,
       n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS pct_dead,
       last_autovacuum, last_autoanalyze
FROM pg_stat_user_tables
WHERE n_dead_tup > 1000
ORDER BY n_dead_tup DESC
LIMIT 20;
```

---

## 5. Đo bloat

### 5.1. Chính xác nhưng đắt: `pgstattuple`

```sql
SELECT pg_size_pretty(table_len) AS kich_thuoc,
       tuple_count, dead_tuple_count,
       round(free_percent::numeric, 1) AS free_pct
FROM pgstattuple('orders');
```

**Quét toàn bộ bảng.** Chính xác tuyệt đối, nhưng trên bảng 500 GB thì đây là một quyết định
tồi nếu chạy giữa giờ cao điểm.

Bản lấy mẫu, nhanh hơn nhiều:

```sql
SELECT * FROM pgstattuple_approx('orders');
```

### 5.2. Rẻ, dùng được mọi lúc: `pg_stat_user_tables`

```sql
SELECT relname, n_live_tup, n_dead_tup,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS pct_dead
FROM pg_stat_user_tables
ORDER BY n_dead_tup DESC LIMIT 10;
```

Đây là con số **ước lượng** từ bộ đếm thống kê, không quét bảng, nên chạy được liên tục.
Dùng nó cho dashboard và cảnh báo; dùng `pgstattuple` khi cần điều tra sâu một bảng cụ thể.

### 5.3. Đọc con số bloat như thế nào

`free_percent = 50%` **không tự động là vấn đề**. Câu hỏi đúng là:

1. Con số đó có **tăng đều** theo thời gian không? Ổn định ở 40% là bình thường; tăng từ 10%
   lên 60% trong một tuần là sự cố.
2. `n_dead_tup` có giảm sau mỗi lần autovacuum không? Nếu không, có ai đó đang giữ snapshot.
3. `last_autovacuum` có gần đây không? Nếu `NULL` hoặc rất cũ, autovacuum chưa từng tới lượt bảng này.

---

## 6. Index bloat

Index cũng bloat, và thường tệ hơn heap vì B-tree không gộp lại các page thưa.

```sql
SELECT indexrelname,
       pg_size_pretty(pg_relation_size(indexrelid)) AS kich_thuoc,
       idx_scan
FROM pg_stat_user_indexes
WHERE relname = 'orders'
ORDER BY pg_relation_size(indexrelid) DESC;
```

Đo chính xác:

```sql
SELECT * FROM pgstatindex('orders_pkey');
```

`avg_leaf_density` là con số cần nhìn. Index khỏe thường ở 65–90%. Dưới 50% là ứng viên cần
dựng lại.

Cách xử lý **không khóa** (PostgreSQL 12+):

```sql
REINDEX INDEX CONCURRENTLY orders_pkey;
```

Lưu ý:

- Chậm hơn `REINDEX` thường vì phải quét bảng hai lượt.
- Nếu thất bại giữa chừng, để lại index "hỏng" tên có hậu tố `_ccnew`. Tìm và xóa:

```sql
SELECT indexrelid::regclass FROM pg_index WHERE NOT indisvalid;
```

---

## 7. Freeze và xid wraparound

### 7.1. Aggressive vacuum

Khi `age(relfrozenxid)` của một bảng vượt `autovacuum_freeze_max_age` (mặc định 150 triệu),
autovacuum **bắt buộc** chạy trên bảng đó — kể cả khi bảng đã đặt `autovacuum_enabled = false`.

Lần vacuum này là **aggressive**: nó quét toàn bộ bảng thay vì chỉ những page có thay đổi
(bình thường VACUUM dùng Visibility Map để bỏ qua page `all_frozen`).

Đó là lý do một hệ thống đang chạy êm bỗng nhiên có một đợt I/O nặng bất thường: một bảng lớn
vừa tới hạn freeze.

### 7.2. Theo dõi

```sql
SELECT datname, age(datfrozenxid) AS tuoi_xid,
       round(100.0 * age(datfrozenxid) / 2000000000, 2) AS pct_toi_gioi_han
FROM pg_database ORDER BY 2 DESC;
```

Cảnh báo nên đặt ở khoảng 50% (1 tỷ). Đến 2 tỷ thì đã là tình huống khẩn cấp, và cách khắc
phục — chạy VACUUM trên bảng lớn — mất hàng giờ.

### 7.3. Giảm áp lực freeze

```sql
-- Với bảng chỉ ghi thêm, freeze sớm để tránh dồn cục
ALTER TABLE su_kien SET (autovacuum_freeze_min_age = 0);
```

Từ PostgreSQL 16 có `vacuum_freeze_strategy_threshold`: bảng lớn hơn ngưỡng sẽ được freeze
tích cực hơn ngay trong vacuum thường, giúp trải đều chi phí thay vì dồn vào một lần.

---

## 8. Những gì bạn nên rút ra từ phần này

1. `VACUUM` **không** thu nhỏ bảng — nó biến không gian chết thành không gian dùng lại được.
   Đo được: 108 MB giữ nguyên, nhưng 200.000 row mới chèn vào không làm bảng lớn thêm.
2. Chỉ `VACUUM FULL` và `pg_repack` mới trả disk về hệ điều hành.
3. `VACUUM FULL` xóa sạch Visibility Map — luôn `VACUUM ANALYZE` ngay sau đó.
4. `dead but not yet removable` trong `VACUUM VERBOSE` nghĩa là có ai đó giữ snapshot cũ.
5. Ba thủ phạm: transaction dài, replication slot bỏ quên, prepared transaction treo.
6. `autovacuum_vacuum_scale_factor = 0.2` là ngưỡng sai với bảng lớn. Hạ xuống 0,01–0,02
   hoặc dùng ngưỡng tuyệt đối.
7. `index scans: > 1` trong `VACUUM VERBOSE` nghĩa là thiếu `maintenance_work_mem`.
8. `free_percent` cao không tự nó là vấn đề; **xu hướng tăng** mới là vấn đề.

---

**Tiếp theo:** [lab.md](lab.md) — tự tạo bloat, tự chẩn đoán, tự xử lý.
