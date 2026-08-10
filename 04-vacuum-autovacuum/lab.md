# Phần 04 — Lab: tự tạo bloat rồi tự xử lý

> Cần môi trường Phần 00. Bài 4 cần **hai terminal**.

---

## Bài 1 — Tạo bloat có chủ ý

Tắt autovacuum trên bảng thí nghiệm để quan sát rõ ràng, không bị dọn giữa chừng:

```sql
DROP TABLE IF EXISTS bloat;
CREATE TABLE bloat (id int PRIMARY KEY, v int, pad text)
  WITH (autovacuum_enabled = false);

INSERT INTO bloat SELECT g, 0, repeat('x', 100) FROM generate_series(1, 200000) g;
VACUUM ANALYZE bloat;

SELECT pg_size_pretty(pg_relation_size('bloat'))  AS heap,
       pg_size_pretty(pg_indexes_size('bloat'))   AS idx,
       tuple_count AS song, dead_tuple_count AS chet,
       round(free_percent::numeric, 1) AS free_pct
FROM pgstattuple('bloat');
```

```text
 heap  |   idx   |  song  | chet | free_pct
-------+---------+--------+------+----------
 27 MB | 4408 kB | 200000 |    0 |      0.6
```

Đây là trạng thái lành mạnh: 0 dead tuple, 0,6% trống.

Bây giờ update toàn bảng ba lần:

```sql
UPDATE bloat SET v = v + 1;
UPDATE bloat SET v = v + 1;
UPDATE bloat SET v = v + 1;
```

```text
  heap  |   idx   |  song  |  chet  | free_pct
--------+---------+--------+--------+----------
 108 MB | 8792 kB | 200000 | 200000 |     48.7
```

**27 MB → 108 MB.** Gấp 4 lần. Số row logic không đổi một chút nào. Index cũng phình gấp đôi.

Đây chính xác là hình ảnh của một bảng bị job chạy định kỳ update mà autovacuum không theo kịp.

---

## Bài 2 — `VACUUM` làm gì và không làm gì

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

**Bốn dòng cần đọc:**

| Dòng | Ý nghĩa |
|---|---|
| `pages: 0 removed, 13793 remain` | **Không page nào được trả về OS** |
| `tuples: 200000 removed` | Dead tuple đã được dọn |
| `0 are dead but not yet removable` | Không ai giữ snapshot cũ — tốt |
| `index scans: 1` | Chỉ quét index một lượt — `maintenance_work_mem` đủ |

Kết quả:

```sql
SELECT pg_size_pretty(pg_relation_size('bloat')) AS heap,
       dead_tuple_count AS chet, round(free_percent::numeric,1) AS free_pct
FROM pgstattuple('bloat');
```

```text
  heap  | chet | free_pct
--------+------+----------
 108 MB |    0 |     74.8
```

Dead tuple về 0, nhưng **bảng vẫn 108 MB**. Không gian trống nhảy lên 74,8%.

### Chứng minh không gian đó dùng lại được

```sql
INSERT INTO bloat SELECT g, 0, repeat('x', 100)
FROM generate_series(200001, 400000) g;
```

```text
  heap  | free_pct
--------+----------
 108 MB |     50.1
```

**Bảng không lớn thêm một byte.** 200.000 row mới nằm gọn trong chỗ VACUUM vừa giải phóng.

> Đây là điều quan trọng nhất của Phần 04:
> **VACUUM không thu nhỏ bảng, nhưng nó ngăn bảng lớn thêm.**

Hệ quả cho việc vận hành: một bảng có `free_percent` ổn định ở 40–50% mà tốc độ ghi đều đặn
là bảng **khỏe mạnh**, không cần can thiệp. Chỉ khi con số đó **tăng đều** mới là dấu hiệu
autovacuum không theo kịp.

---

## Bài 3 — `VACUUM FULL` và cái giá của nó

```sql
\timing on
VACUUM FULL bloat;
\timing off
```

```text
Time: 349.718 ms

 heap  |   idx   | free_pct
-------+---------+----------
 54 MB | 8792 kB |      0.5
```

54 MB cho 400.000 row — đúng gấp đôi 27 MB của 200.000 row ban đầu. Disk đã được trả về hệ
điều hành.

Nhưng kiểm tra Visibility Map:

```sql
SELECT count(*) FILTER (WHERE all_visible) AS all_visible, count(*) AS tong_page
FROM pg_visibility_map('bloat');
```

```text
 all_visible | tong_page
-------------+-----------
           0 |      6897
```

**0 / 6897.** `VACUUM FULL` xóa sạch Visibility Map. Mọi Index Only Scan trên bảng này vừa
ngừng hoạt động.

```sql
VACUUM (ANALYZE) bloat;

SELECT count(*) FILTER (WHERE all_visible) AS all_visible, count(*) AS tong_page
FROM pg_visibility_map('bloat');
```

Bây giờ mới đầy đủ.

**Quy tắc:** sau `VACUUM FULL` hoặc `pg_repack`, luôn chạy `VACUUM (ANALYZE)` ngay. Nếu
không, hệ thống sẽ chậm đi một cách khó hiểu cho tới lần autovacuum kế tiếp.

Trong lúc `VACUUM FULL` chạy, ở terminal khác thử:

```sql
SELECT count(*) FROM bloat;
```

Nó **bị chặn** — `VACUUM FULL` giữ `ACCESS EXCLUSIVE LOCK`. Trên bảng 500 GB, đó là hàng chục
phút hệ thống không đọc được. Đây là lý do `pg_repack` tồn tại.

---

## Bài 4 — Vì sao VACUUM chạy mà không dọn được gì

Bài quan trọng nhất của Phần 04, vì đây là sự cố thật hay gặp nhất.

**Terminal A** — mở một transaction rồi bỏ đó:

```sql
BEGIN;
SELECT 1;
-- KHÔNG commit, để nguyên
```

**Terminal B** — tạo dead tuple rồi vacuum:

```sql
UPDATE bloat SET v = v + 1;
VACUUM (VERBOSE) bloat;
```

```text
tuples: 0 removed, 400000 remain, 400000 are dead but not yet removable
removable cutoff: 1234, which was 15 XIDs old when operation ended
```

**`0 removed` … `400000 are dead but not yet removable`.**

VACUUM chạy, tốn I/O, tốn thời gian, và dọn được **đúng 0 tuple**. Nguyên nhân là session A —
một session chỉ chạy `SELECT 1` và không hề chạm tới bảng `bloat`.

### Tìm thủ phạm

```sql
SELECT pid,
       now() - xact_start   AS transaction_mo_bao_lau,
       state,
       backend_xmin,
       left(query, 40)      AS query_cuoi
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
ORDER BY xact_start;
```

```text
 pid  | transaction_mo_bao_lau |        state        | backend_xmin | query_cuoi
------+------------------------+---------------------+--------------+------------
 1042 | 00:02:13               | idle in transaction |         1234 | SELECT 1
```

`backend_xmin` là snapshot cũ nhất session đó đang giữ. VACUUM không được phép dọn tuple nào
còn hiển thị với snapshot đó — **ở mọi bảng trong toàn database**.

**Terminal A:** `COMMIT;`

**Terminal B:**

```sql
VACUUM (VERBOSE) bloat;
```

```text
tuples: 400000 removed, 400000 remain, 0 are dead but not yet removable
```

Ngay lập tức dọn sạch.

### Ba nguồn cần theo dõi trên production

```sql
-- 1. Transaction dài / idle in transaction
SELECT pid, now() - xact_start AS tuoi, state, backend_xmin
FROM pg_stat_activity WHERE backend_xmin IS NOT NULL
ORDER BY xact_start LIMIT 5;

-- 2. Replication slot bị bỏ quên  ← nguy hiểm nhất vì im lặng
SELECT slot_name, active, age(xmin) AS tuoi_xmin,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_bi_giu
FROM pg_replication_slots ORDER BY age(xmin) DESC NULLS LAST;

-- 3. Prepared transaction treo
SELECT gid, prepared, age(transaction) AS tuoi FROM pg_prepared_xacts;
```

Slot có `active = false` và `tuoi_xmin` lớn vừa gây bloat vô hạn vừa làm đầy disk bằng WAL.
Đây là nguyên nhân của Case study số 9 ở Phần 16.

Phòng ngừa ở mức cluster:

```sql
ALTER SYSTEM SET idle_in_transaction_session_timeout = '5min';
ALTER SYSTEM SET max_slot_wal_keep_size = '10GB';   -- PostgreSQL 13+
SELECT pg_reload_conf();
```

---

## Bài 5 — Ngưỡng autovacuum sai với bảng lớn

Xem ngưỡng thật của một bảng:

```sql
SELECT relname,
       n_live_tup,
       n_dead_tup,
       (50 + 0.2 * n_live_tup)::bigint AS nguong_kich_hoat,
       last_autovacuum
FROM pg_stat_user_tables
WHERE relname IN ('orders', 'order_items');
```

Trên `lab_big`:

| Bảng | Số row | Ngưỡng mặc định (20%) |
|---|---:|---:|
| `orders` | 1.000.000 | 200.050 |
| `order_items` | 2.500.000 | 500.050 |

`order_items` phải tích tụ **nửa triệu** dead tuple mới được autovacuum đụng tới. Với bảng
100 triệu row, con số là 20 triệu.

Sửa:

```sql
ALTER TABLE orders SET (
    autovacuum_vacuum_scale_factor = 0.02,
    autovacuum_vacuum_threshold    = 1000,
    autovacuum_analyze_scale_factor = 0.01
);

-- Kiểm tra đã áp dụng
SELECT relname, reloptions FROM pg_class WHERE relname = 'orders';
```

```text
 relname |                              reloptions
---------+-----------------------------------------------------------------------
 orders  | {autovacuum_vacuum_scale_factor=0.02,autovacuum_vacuum_threshold=1000,...}
```

Với bảng rất lớn, bỏ hẳn tỷ lệ:

```sql
ALTER TABLE su_kien SET (
    autovacuum_vacuum_scale_factor = 0,
    autovacuum_vacuum_threshold    = 50000
);
```

**Nguyên tắc:** vacuum thường xuyên hơn, mỗi lần nhẹ hơn — luôn tốt hơn hiếm khi vacuum
nhưng mỗi lần rất nặng.

---

## Bài 6 — Quan sát autovacuum đang chạy

Bật lại autovacuum và tạo tải:

```sql
ALTER TABLE bloat SET (autovacuum_enabled = true);
UPDATE bloat SET v = v + 1;
```

Ở terminal khác, theo dõi (môi trường Phần 00 đặt `autovacuum_naptime = 10s` nên không phải
chờ lâu):

```sql
SELECT p.pid, c.relname, p.phase,
       p.heap_blks_scanned, p.heap_blks_total,
       round(100.0 * p.heap_blks_scanned / NULLIF(p.heap_blks_total, 0), 1) AS pct
FROM pg_stat_progress_vacuum p
JOIN pg_class c ON c.oid = p.relid;
\watch 1
```

Các `phase` sẽ lần lượt đi qua:

```text
scanning heap → vacuuming indexes → vacuuming heap → cleaning up indexes
```

Đồng thời xem log (`make logs`) — cấu hình `log_autovacuum_min_duration = 0` ghi lại mọi lần chạy:

```text
LOG:  automatic vacuum of table "lab.public.bloat": index scans: 1
      pages: 0 removed, 6897 remain
      tuples: 400000 removed, 400000 remain, 0 are dead but not yet removable
      buffer usage: ... WAL usage: ... system usage: ...
```

Đây chính là dòng log bạn sẽ tìm khi debug trên production.

---

## Bài 7 — Phát hiện thiếu `maintenance_work_mem`

```sql
SET maintenance_work_mem = '1MB';        -- cố tình đặt rất thấp
UPDATE bloat SET v = v + 1;
VACUUM (VERBOSE) bloat;
```

Nhìn dòng `index scans:`. Với `maintenance_work_mem` quá nhỏ, VACUUM không giữ hết danh sách
dead tuple id trong bộ nhớ nên phải **quét index nhiều lượt**:

```text
INFO:  finished vacuuming "lab.public.bloat": index scans: 3
```

Đặt lại:

```sql
RESET maintenance_work_mem;
UPDATE bloat SET v = v + 1;
VACUUM (VERBOSE) bloat;
```

```text
INFO:  finished vacuuming "lab.public.bloat": index scans: 1
```

**`index scans: > 1` là dấu hiệu trực tiếp và không thể nhầm lẫn của việc thiếu
`maintenance_work_mem`.** Trên bảng lớn có nhiều index, chênh lệch này tính bằng giờ.

Lưu ý khi tăng: mỗi autovacuum worker có thể dùng tới `maintenance_work_mem` riêng, nên tổng
là `autovacuum_max_workers × maintenance_work_mem`.

---

## Bài 8 — Index bloat và `REINDEX CONCURRENTLY`

```sql
SELECT * FROM pgstatindex('bloat_pkey');
```

Con số cần nhìn là `avg_leaf_density`. Index khỏe thường ở 65–90%; dưới 50% là ứng viên dựng lại.

```sql
SELECT indexrelname,
       pg_size_pretty(pg_relation_size(indexrelid)) AS truoc
FROM pg_stat_user_indexes WHERE relname = 'bloat';

REINDEX INDEX CONCURRENTLY bloat_pkey;

SELECT indexrelname,
       pg_size_pretty(pg_relation_size(indexrelid)) AS sau
FROM pg_stat_user_indexes WHERE relname = 'bloat';
```

`CONCURRENTLY` không chặn đọc ghi, nhưng:

- Chậm hơn `REINDEX` thường vì quét bảng hai lượt.
- Nếu thất bại giữa chừng, để lại index hỏng có hậu tố `_ccnew`.

Kiểm tra sau mỗi lần reindex:

```sql
SELECT indexrelid::regclass AS index_hong
FROM pg_index WHERE NOT indisvalid;
```

Nếu có, xóa đi rồi làm lại.

---

## Bài 9 — Bảng theo dõi cho production

Câu query nên đưa vào dashboard:

```sql
SELECT relname,
       n_live_tup,
       n_dead_tup,
       round(100.0 * n_dead_tup / NULLIF(n_live_tup + n_dead_tup, 0), 1) AS pct_dead,
       pg_size_pretty(pg_total_relation_size(relid))                     AS kich_thuoc,
       last_autovacuum,
       last_autoanalyze,
       autovacuum_count
FROM pg_stat_user_tables
WHERE n_live_tup > 10000
ORDER BY n_dead_tup DESC
LIMIT 20;
```

Bốn tín hiệu cần cảnh báo:

| Tín hiệu | Nghĩa là gì |
|---|---|
| `pct_dead` tăng đều nhiều ngày | Autovacuum không theo kịp |
| `last_autovacuum` là `NULL` trên bảng lớn | Chưa từng tới lượt — kiểm tra ngưỡng |
| Có `backend_xmin` cũ hơn 1 giờ | Có snapshot đang chặn VACUUM |
| Replication slot `active = false` | Bloat vô hạn + disk đầy |

Dọn dẹp sau lab:

```sql
DROP TABLE bloat;
```

---

## Checklist trước khi sang Phần 05

- [ ] Tự tạo được bảng bloat gấp 4 lần và đo bằng `pgstattuple`.
- [ ] Giải thích được vì sao sau `VACUUM` bảng vẫn 108 MB mà vẫn gọi là thành công.
- [ ] Chứng minh được không gian VACUUM giải phóng thật sự được tái sử dụng.
- [ ] Chỉ ra được dòng `dead but not yet removable` và tìm ra thủ phạm.
- [ ] Chứng minh được `VACUUM FULL` xóa Visibility Map.
- [ ] Tính được ngưỡng autovacuum thật của một bảng và biết cách chỉnh.
- [ ] Nhận ra `index scans: > 1` nghĩa là gì.
- [ ] Biết ba nguồn giữ `xmin`.

---

**Tiếp theo:** Phần 05 — Index.
