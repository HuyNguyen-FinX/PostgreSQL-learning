# Phần 07 — Lab: tự tạo ra từng dấu hiệu bệnh

> Chạy trên `lab_big`. Nhiều bài tắt parallel để số liệu đọc thẳng được.
> Bài 2 cần index: `CREATE INDEX idx_orders_user ON orders(user_id); ANALYZE orders;`

---

## Bài 1 — `Buffers` nói thật khi tên node nói dối

Đây là bài quan trọng nhất của Phần 07.

```bash
make psql-big
```

```sql
CREATE INDEX idx_orders_user ON orders(user_id);
ANALYZE orders;

SET max_parallel_workers_per_gather = 0;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT sum(total_amount) FROM orders WHERE user_id <= 20000;
```

```text
 Aggregate (actual rows=1 loops=1)
   Buffers: shared hit=314799
   ->  Index Scan using idx_orders_user on orders (actual rows=315397 loops=1)
         Index Cond: (user_id <= 20000)
         Buffers: shared hit=314799
 Execution Time: 358.236 ms
```

Trông có vẻ ổn: dùng index, không có filter bị vứt bỏ. Nhưng hãy tra kích thước bảng:

```sql
SELECT relpages FROM pg_class WHERE relname = 'orders';
```

```text
 relpages
----------
     9163
```

**314.799 buffer trên một bảng chỉ có 9.163 page.** Mỗi page bị đọc lại trung bình **34 lần**.

Ép Bitmap Heap Scan để so sánh:

```sql
SET enable_indexscan = off;
SET enable_seqscan = off;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT sum(total_amount) FROM orders WHERE user_id <= 20000;
```

```text
 ->  Bitmap Heap Scan on orders (actual rows=315397 loops=1)
       Heap Blocks: exact=9163
       Buffers: shared hit=9486
 Execution Time: 50.406 ms
```

| Plan | Buffer | Thời gian |
|---|---:|---:|
| Index Scan (planner tự chọn) | **314.799** | 358 ms |
| Bitmap Heap Scan (bị ép) | **9.486** | **50 ms** |

**Planner chọn sai. Chậm hơn 7 lần.**

Nguyên nhân: Index Scan nhảy vào heap theo thứ tự của index. Vì `user_id` gần như không tương
quan với thứ tự vật lý (`correlation ≈ −0,004`, xem Phần 06), cùng một page bị ghé đi ghé lại.
Bitmap Heap Scan gom hết địa chỉ, sắp theo số page, đọc mỗi page **đúng một lần** — đúng bằng
`relpages = 9163`.

> **Quy tắc chẩn đoán rút ra:** khi `Buffers` của một node lớn hơn nhiều lần `relpages` của
> bảng, node đó đang đọc lại cùng những page. Gần như luôn là Index Scan lẽ ra nên là Bitmap.

```sql
RESET enable_indexscan; RESET enable_seqscan;
```

**Câu hỏi tự trả lời:** vì sao planner chọn Index Scan dù nó đắt hơn? Gợi ý: xem lại
`random_page_cost = 1.1` trong `postgresql.conf` của Phần 00, và thử đặt lại thành `4.0` rồi
chạy lại.

---

## Bài 2 — Sort tràn ra đĩa

```sql
SET max_parallel_workers_per_gather = 0;
RESET work_mem;      -- về 4MB mặc định của môi trường lab

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM orders ORDER BY total_amount;
```

```text
 Sort (actual rows=1000000 loops=1)
   Sort Key: total_amount
   Sort Method: external merge  Disk: 55408kB
   Buffers: shared hit=9166, temp read=13846 written=13867
   I/O Timings: temp read=13.356 write=51.898
   ->  Seq Scan on orders (actual rows=1000000 loops=1)
```

Ba dấu hiệu cùng chỉ về một nguyên nhân:

- `Sort Method: external merge` — từ khóa cần tìm.
- `Disk: 55408kB` — lượng ghi ra đĩa.
- `temp read=13846 written=13867` — xác nhận từ phía I/O.

Tăng `work_mem`:

```sql
SET work_mem = '256MB';

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM orders ORDER BY total_amount;
```

```text
 Sort (actual rows=1000000 loops=1)
   Sort Key: total_amount
   Sort Method: quicksort  Memory: 85677kB
   Buffers: shared hit=9166
```

`temp` biến mất hoàn toàn.

**Chi tiết quan trọng:** trên đĩa cần **55 MB**, nhưng trong bộ nhớ cần **85 MB**. Sort trong
RAM tốn nhiều hơn dữ liệu thô vì phải giữ thêm con trỏ và cấu trúc phụ.

> Đừng đặt `work_mem` bằng đúng con số `Disk:`. Đó là mức **tối thiểu**, không phải mức đủ.

**Tìm ngưỡng của chính bạn:**

```sql
SET work_mem = '32MB';   -- vẫn external merge?
SET work_mem = '64MB';
SET work_mem = '96MB';
```

Chạy lại sau mỗi lần và tìm giá trị nhỏ nhất khiến `Sort Method` chuyển sang `quicksort`.

**Nhắc lại rủi ro:** `work_mem` là giới hạn cho **mỗi node**, không phải mỗi query. Dùng
`SET LOCAL` trong transaction, hoặc `ALTER ROLE` cho user chạy báo cáo — đừng tăng toàn cục.

```sql
RESET work_mem;
```

---

## Bài 3 — Bitmap lossy

```sql
SET max_parallel_workers_per_gather = 0;
SET enable_indexscan = off;
SET enable_seqscan = off;

SET work_mem = '64kB';
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT sum(total_amount) FROM orders WHERE user_id <= 20000;
```

```text
 ->  Bitmap Heap Scan on orders (actual rows=315397 loops=1)
       Heap Blocks: exact=887 lossy=8276
 Execution Time: 59.063 ms
```

```sql
SET work_mem = '16MB';
-- chạy lại
```

```text
 ->  Bitmap Heap Scan on orders (actual rows=315397 loops=1)
       Heap Blocks: exact=9163
 Execution Time: 50.406 ms
```

| `work_mem` | `Heap Blocks` |
|---|---|
| 64kB | `exact=887 lossy=8276` |
| 16MB | `exact=9163` |

Khi bitmap không đủ chỗ, PostgreSQL chuyển sang chế độ **lossy**: chỉ nhớ *"page này có row
khớp"* thay vì nhớ từng row, rồi phải đọc và lọc lại toàn bộ row trong page đó.

`lossy` lớn hơn `exact` nhiều là tín hiệu tăng `work_mem`.

```sql
RESET ALL;
```

---

## Bài 4 — `loops` và cái bẫy thời gian

```sql
SET max_parallel_workers_per_gather = 0;

EXPLAIN (ANALYZE, BUFFERS)
SELECT count(*)
FROM orders o JOIN users u ON u.id = o.user_id
WHERE u.country_code = 'DE';
```

Tìm node bên trong Nested Loop và nhìn hai con số:

```text
->  Index Scan using users_pkey on users (actual time=0.002..0.002 rows=1 loops=20819)
                                                      ^^^^^              ^^^^^^^^^^^^
```

Thời gian thật của node này = `0.002 × 20819 ≈ 42 ms`, **không phải 0,002 ms**.

Đây là cách một node trông vô hại chiếm phần lớn thời gian query.

**Bài tập:** với plan bạn vừa chạy, tính thời gian riêng của node Nested Loop:

```text
thời gian riêng = actual time của node
                − tổng (actual time × loops) của tất cả node con
```

---

## Bài 5 — `Rows Removed by Filter`

```sql
RESET ALL;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM orders WHERE status = 'cancelled';
```

```text
 ->  Parallel Seq Scan on orders (actual rows=10000 loops=3)
       Filter: (status = 'cancelled'::text)
       Rows Removed by Filter: 323333
```

Mỗi worker đọc 333.333 row và vứt đi 323.333 — chỉ **3%** số row đọc lên là có ích.

Thử tạo index và đo lại:

```sql
CREATE INDEX idx_orders_status ON orders(status);
ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT count(*) FROM orders WHERE status = 'cancelled';
```

So `Buffers` trước và sau. Rồi thử với giá trị phổ biến:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY ON)
SELECT count(*) FROM orders WHERE status = 'completed';   -- 80% số row
```

Index **không** được dùng cho `completed`. Đây là hành vi đúng — quay lại Phần 05 mục 1.

```sql
DROP INDEX idx_orders_status;
```

---

## Bài 6 — Đo WAL của câu ghi

```bash
make psql
```

```sql
DROP TABLE IF EXISTS wal_t;
CREATE TABLE wal_t (id int, v text);

EXPLAIN (ANALYZE, BUFFERS, WAL, COSTS OFF, TIMING OFF, SUMMARY OFF)
INSERT INTO wal_t SELECT g, md5(g::text) FROM generate_series(1, 100000) g;
```

```text
 Insert on wal_t (actual rows=0 loops=1)
   Buffers: shared hit=101664 dirtied=834 written=837, temp read=171 written=171
   WAL: records=100000 bytes=9200000
```

**9.200.000 byte cho 100.000 row — 92 byte mỗi row.**

So sánh với `COPY`:

```sql
TRUNCATE wal_t;
\timing on
COPY wal_t FROM PROGRAM 'seq 1 100000 | while read i; do echo "$i	x$i"; done';
\timing off

SELECT pg_size_pretty(pg_current_wal_lsn() - '0/0'::pg_lsn) AS wal_da_ghi;
```

Cách đo chênh lệch WAL giữa hai cách viết:

```sql
SELECT pg_current_wal_lsn() AS truoc \gset
-- chạy câu lệnh cần đo
SELECT pg_size_pretty(pg_current_wal_lsn() - :'truoc'::pg_lsn) AS wal_sinh_ra;
```

Vì sao quan tâm WAL: nó quyết định lượng dữ liệu truyền sang replica (Phần 10), tần suất
checkpoint (Phần 09), và dung lượng WAL archive cho PITR.

**Thí nghiệm về `full_page_writes`:**

```sql
CHECKPOINT;
-- đo WAL của câu UPDATE ngay sau checkpoint
SELECT pg_current_wal_lsn() AS truoc \gset
UPDATE wal_t SET v = v WHERE id <= 10000;
SELECT pg_size_pretty(pg_current_wal_lsn() - :'truoc'::pg_lsn) AS lan_1;

-- chạy lại NGAY, không checkpoint
SELECT pg_current_wal_lsn() AS truoc \gset
UPDATE wal_t SET v = v WHERE id <= 10000;
SELECT pg_size_pretty(pg_current_wal_lsn() - :'truoc'::pg_lsn) AS lan_2;
```

Lần đầu sinh nhiều WAL hơn hẳn, vì mỗi page bị chạm lần đầu sau checkpoint phải ghi **nguyên
page 8KB** vào WAL. Đây là nội dung Phần 09.

---

## Bài 7 — `pg_stat_statements` trong thực chiến

```bash
make psql-big
```

```sql
SELECT pg_stat_statements_reset();
```

Chạy một loạt query khác nhau, rồi:

```sql
SELECT round(total_exec_time::numeric, 0)   AS tong_ms,
       calls,
       round(mean_exec_time::numeric, 2)    AS trung_binh_ms,
       round(stddev_exec_time::numeric, 2)  AS do_lech,
       rows,
       round(100.0 * shared_blks_hit /
             NULLIF(shared_blks_hit + shared_blks_read, 0), 1) AS cache_hit_pct,
       left(regexp_replace(query, '\s+', ' ', 'g'), 50) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 10;
```

**Sắp xếp theo `total_exec_time`, không phải `mean_exec_time`.** Một query 10ms chạy 1 triệu
lần gây hại nhiều hơn một query 5 giây chạy 10 lần.

Bốn tín hiệu cần tìm:

| Tín hiệu | Nghĩa là gì |
|---|---|
| `do_lech` lớn so với `trung_binh_ms` | Cùng query, hai plan khác nhau — nghi generic plan |
| `rows / calls` rất lớn | Thiếu `LIMIT`, hoặc join nổ |
| `cache_hit_pct` < 95% trên query nóng | Thiếu RAM, hoặc quét bảng lớn |
| `calls` rất lớn với query đơn giản | Nghi N+1 từ phía application (Phần 15) |

---

## Bài 8 — `auto_explain` bắt plan chậm

Mở một terminal theo dõi log:

```bash
make logs
```

Ở terminal khác, hạ ngưỡng và chạy query chậm:

```sql
SET auto_explain.log_min_duration = '100ms';
SET auto_explain.log_analyze = on;
SET auto_explain.log_buffers = on;

SELECT o.status, count(*), sum(oi.quantity * oi.unit_price)
FROM orders o JOIN order_items oi ON oi.order_id = o.id
GROUP BY o.status;
```

Trong log xuất hiện toàn bộ plan kèm `actual rows` và `Buffers` — **của chính lần chạy đó**.

Đây là điểm khác biệt cốt lõi so với chạy `EXPLAIN` tay sau khi sự cố đã qua: lúc đó cache đã
ấm, statistics có thể đã đổi, tham số session có thể khác. Rất nhiều sự cố "không tái hiện
được" là vì lý do này.

Cấu hình production hợp lý:

```conf
auto_explain.log_min_duration = '1s'
auto_explain.log_analyze = on
auto_explain.log_timing = off      # giảm chi phí đo, vẫn giữ rows và Buffers
auto_explain.log_buffers = on
auto_explain.log_nested_statements = on
```

> `auto_explain.log_analyze = on` thêm chi phí đo cho **mọi** query, kể cả query nhanh. Tắt
> `log_timing` giảm phần lớn chi phí đó mà vẫn giữ được thông tin quan trọng nhất.

```sql
RESET auto_explain.log_min_duration;
```

---

## Bài 9 — Chẩn đoán một plan lạ

Áp dụng toàn bộ quy trình vào một query nhiều tầng:

```sql
RESET ALL;

EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS)
SELECT u.country_code,
       count(DISTINCT o.id)              AS so_don,
       sum(oi.quantity * oi.unit_price)  AS doanh_thu
FROM users u
JOIN orders o      ON o.user_id  = u.id
JOIN order_items oi ON oi.order_id = o.id
WHERE o.created_at > now() - interval '90 days'
GROUP BY u.country_code
ORDER BY doanh_thu DESC;
```

Sáu bước, theo đúng thứ tự:

1. **`Execution Time` tổng là bao nhiêu?** Ghi lại làm mốc.
2. **Node nào tốn thời gian riêng nhiều nhất?** Nhớ trừ node con và nhân `loops`.
3. **Node nào lệch `rows` nhiều nhất?** Đi từ **dưới lên**, sửa node thấp nhất bị lệch.
4. **Có `external merge`, `lossy`, hay `temp` không?** → `work_mem`.
5. **`Buffers` có lớn bất thường so với `relpages` không?** → xem lại kiểu scan.
6. **`SETTINGS` có gì khác thường không?**

```text
Settings: random_page_cost = '1.1', work_mem = '4MB'
```

Dòng `Settings` rất hữu ích khi cùng một query chạy khác nhau giữa staging và production —
nó chỉ thẳng ra tham số nào đang khác.

---

## Checklist trước khi sang Phần 08

- [ ] Luôn thêm `BUFFERS` vào `EXPLAIN` theo phản xạ.
- [ ] **Tự tìm ra được trường hợp `Buffers` ≫ `relpages` và giải thích được vì sao.**
- [ ] Tạo được `Sort Method: external merge` rồi tự chữa.
- [ ] Giải thích được vì sao `Disk: 55408kB` nhưng cần `Memory: 85677kB`.
- [ ] Tạo được `Heap Blocks: lossy` rồi tự chữa.
- [ ] Tính đúng thời gian thật của một node có `loops` lớn.
- [ ] Đọc được `WAL: records=... bytes=...` và biết dùng để làm gì.
- [ ] Biết vì sao sắp xếp `pg_stat_statements` theo `total_exec_time`.
- [ ] Cấu hình được `auto_explain` cho production mà không gây quá tải.

---

**Tiếp theo:** Phần 08 — Lock & Concurrency.
