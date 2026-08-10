# Phần 05 — Lab: tự đo giá trị và cái giá của index

> Chạy trên `lab_big`. Các index tạo trong lab này được giữ lại cho Phần 06 và Phần 07.
> Muốn quay về trạng thái gốc: `make seed-big`.

---

## Bài 1 — Tìm ngưỡng planner bỏ index

```bash
make psql-big
```

```sql
CREATE INDEX idx_orders_user ON orders(user_id);
ANALYZE orders;
```

Chạy cùng một dạng query với độ chọn lọc tăng dần. Dùng `sum(total_amount)` để buộc phải đọc
heap — nếu dùng `count(*)` thì Index Only Scan sẽ che mất hiện tượng cần thấy:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT sum(total_amount) FROM orders WHERE user_id <= 100;
```

Lặp lại với `1000`, `5000`, `10000`, `20000`, `60000` và lập bảng:

| Điều kiện | Số row | Tỷ lệ | Plan | Buffer |
|---|---:|---:|---|---:|
| `<= 100` | 22.486 | 2,25% | Bitmap Heap Scan | 8.407 |
| `<= 1000` | 70.668 | 7,07% | Bitmap Heap Scan | 9.225 |
| `<= 5000` | 158.129 | 15,81% | Bitmap Heap Scan | 9.310 |
| `<= 10000` | 223.367 | 22,34% | Bitmap Heap Scan | 9.379 |
| `<= 20000` | 315.397 | 31,54% | Bitmap Heap Scan | 9.486 |
| `<= 60000` | 547.147 | 54,71% | **Parallel Seq Scan** | 9.163 |

Bây giờ so con số cuối với kích thước bảng:

```sql
SELECT relpages FROM pg_class WHERE relname = 'orders';
```

```text
 relpages
----------
     9163
```

**Dòng 31,54% đọc 9.486 buffer — nhiều hơn cả 9.163 page của toàn bảng.** Index ở đó không
còn giúp gì; nó chỉ là chi phí cộng thêm. Planner chuyển sang Seq Scan ở mức tiếp theo là
quyết định đúng.

**Ép planner làm sai để thấy rõ hơn:**

```sql
SET enable_seqscan = off;
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT sum(total_amount) FROM orders WHERE user_id <= 60000;
RESET enable_seqscan;
```

So thời gian và buffer với plan mà planner tự chọn. Đây là cách kiểm chứng planner có đúng
không, dùng rất nhiều ở Phần 06.

> `enable_seqscan = off` là **công cụ chẩn đoán**, không phải cách sửa lỗi. Đừng bao giờ đặt
> nó trong code production.

---

## Bài 2 — Ba kiểu scan

```sql
-- Rất ít row → Index Scan
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM orders WHERE user_id = 42;
```

```text
 Index Scan using idx_orders_user on orders (actual rows=171 loops=1)
   Index Cond: (user_id = 42)
   Buffers: shared hit=176
```

171 row nhưng đọc 176 buffer — gần như mỗi row nằm ở một page khác nhau. Đó là bản chất của
truy cập ngẫu nhiên qua index.

```sql
-- Nhiều row hơn → Bitmap
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM orders WHERE user_id <= 1000;
```

Chú ý dòng `Heap Blocks: exact=...`. Bitmap Heap Scan gom hết địa chỉ, **sắp theo số page**,
rồi đọc heap một lượt theo thứ tự — biến truy cập ngẫu nhiên thành gần tuần tự.

**Thí nghiệm bitmap lossy:**

```sql
SET work_mem = '64kB';
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT * FROM orders WHERE user_id <= 20000;
RESET work_mem;
```

Tìm dòng `Heap Blocks: exact=... lossy=...`. Khi bitmap không đủ chỗ trong `work_mem`,
PostgreSQL chỉ nhớ **số page** thay vì từng row, rồi phải lọc lại toàn bộ row trong các page
đó. `lossy` lớn là tín hiệu thiếu `work_mem`.

---

## Bài 3 — Leftmost prefix: bài học quan trọng nhất

```sql
CREATE INDEX idx_oi_composite ON order_items(order_id, product_id);
ANALYZE order_items;
```

Ba query, cùng index:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM order_items WHERE order_id = 500;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM order_items WHERE product_id = 500;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM order_items WHERE order_id = 500 AND product_id = 500;
```

Plan của hai câu đầu **trông giống hệt nhau**:

```text
 Aggregate
   ->  Index Only Scan using idx_oi_composite on order_items
         Index Cond: (order_id = 500)

 Aggregate
   ->  Index Only Scan using idx_oi_composite on order_items
         Index Cond: (product_id = 500)
```

Cùng tên index, cùng loại node, cùng có `Index Cond`. Nhưng:

| Query | Buffer đọc |
|---|---:|
| `order_id = 500` (column đầu) | **7** |
| `product_id = 500` (column thứ hai) | **9.582** |
| cả hai | **6** |

**Chênh 1.370 lần.**

> **Đây là cái bẫy nguy hiểm nhất khi đọc `EXPLAIN`.** Nhìn thấy tên index trong plan rồi kết
> luận "index đang chạy tốt" là sai. Câu thứ hai vẫn dùng index — nhưng nó **quét toàn bộ
> index** thay vì seek.
>
> **Luôn đọc `Buffers`. Tên node có thể lừa bạn, số buffer thì không.**

Chứng minh index đúng sẽ khác thế nào:

```sql
CREATE INDEX idx_oi_product ON order_items(product_id);
ANALYZE order_items;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM order_items WHERE product_id = 500;
```

Buffer tụt xuống hai chữ số.

---

## Bài 4 — Partial index

```sql
CREATE INDEX idx_full    ON orders(created_at);
CREATE INDEX idx_partial ON orders(created_at) WHERE status = 'cancelled';
ANALYZE orders;

SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS kich_thuoc
FROM pg_stat_user_indexes WHERE indexrelname IN ('idx_full', 'idx_partial');
```

```text
 indexrelname | kich_thuoc
--------------+------------
 idx_full     | 21 MB
 idx_partial  | 672 kB
```

**Nhỏ hơn 32 lần**, vì chỉ 3% order có `status = 'cancelled'`.

Kiểm tra planner có dùng nó không:

```sql
EXPLAIN (COSTS OFF)
SELECT * FROM orders WHERE status = 'cancelled' AND created_at > '2026-01-01';
```

Bây giờ thử **không** nêu điều kiện `status`:

```sql
EXPLAIN (COSTS OFF)
SELECT * FROM orders WHERE created_at > '2026-01-01';
```

Partial index không được dùng. Planner chỉ dùng nó khi **chứng minh được** điều kiện query
bao hàm điều kiện của index.

**Thí nghiệm quan trọng — tham số làm mất partial index:**

```sql
PREPARE p(text) AS SELECT * FROM orders WHERE status = $1 AND created_at > '2026-01-01';
EXPLAIN (COSTS OFF) EXECUTE p('cancelled');
```

Với generic plan, planner không biết `$1` sẽ là `'cancelled'` nên **không** dùng được partial
index. Đây là lý do partial index đôi khi "không hoạt động" khi gọi từ application dù chạy
tay trong `psql` thì tốt.

```sql
DEALLOCATE p;
```

---

## Bài 5 — Covering index với `INCLUDE`

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT user_id, total_amount, status FROM orders WHERE user_id = 42;
```

```text
 Bitmap Heap Scan on orders (actual rows=171 loops=1)
   Recheck Cond: (user_id = 42)
   Heap Blocks: exact=170
   Buffers: shared hit=176
```

170 page heap phải đọc chỉ để lấy `total_amount` và `status`.

```sql
CREATE INDEX idx_cover ON orders(user_id) INCLUDE (total_amount, status);
ANALYZE orders;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT user_id, total_amount, status FROM orders WHERE user_id = 42;
```

```text
 Index Only Scan using idx_cover on orders (actual rows=171 loops=1)
   Index Cond: (user_id = 42)
   Heap Fetches: 0
   Buffers: shared hit=4 read=4
```

**176 → 8 buffer. Nhanh hơn 22 lần.**

Thử thêm một column **không** có trong index:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT user_id, total_amount, status, created_at FROM orders WHERE user_id = 42;
```

Index Only Scan biến mất. Covering index chỉ hoạt động khi nó chứa **mọi** column query cần.

**Kiểm chứng phụ thuộc vào Visibility Map:**

```sql
UPDATE orders SET status = status WHERE user_id BETWEEN 40 AND 50;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT user_id, total_amount, status FROM orders WHERE user_id = 42;
```

`Heap Fetches` bây giờ **lớn hơn 0** — các page vừa bị ghi không còn `all-visible`.

```sql
VACUUM (ANALYZE) orders;
```

Chạy lại, `Heap Fetches` về 0. Index Only Scan chỉ thật sự "only" khi autovacuum theo kịp.

---

## Bài 6 — Bốn cách làm mất index

```sql
-- 1. Function bọc quanh column
EXPLAIN (COSTS OFF) SELECT count(*) FROM orders WHERE abs(user_id) = 42;
```

```text
 Parallel Seq Scan on orders     ← index bị bỏ qua
```

```sql
-- Sửa: expression index
CREATE INDEX idx_abs_user ON orders (abs(user_id));
ANALYZE orders;
EXPLAIN (COSTS OFF) SELECT count(*) FROM orders WHERE abs(user_id) = 42;
DROP INDEX idx_abs_user;
```

```sql
-- 2. Ép kiểu trên COLUMN
EXPLAIN (COSTS OFF) SELECT count(*) FROM orders WHERE user_id::text = '42';   -- mất index

-- Ép kiểu trên GIÁ TRỊ thì không sao
EXPLAIN (COSTS OFF) SELECT count(*) FROM orders WHERE user_id = '42';         -- vẫn dùng index
```

Khác biệt: ép kiểu column phá vỡ khả năng so khớp với index; ép kiểu hằng số thì PostgreSQL
chuyển hằng số về kiểu của column.

```sql
-- 3. date_trunc — lỗi hay gặp nhất trong thực tế
EXPLAIN (COSTS OFF)
SELECT count(*) FROM orders WHERE date_trunc('day', created_at) = '2026-08-09';

-- Viết lại thành khoảng
EXPLAIN (COSTS OFF)
SELECT count(*) FROM orders
WHERE created_at >= '2026-08-09' AND created_at < '2026-08-10';
```

```sql
-- 4. LIKE với ký tự đại diện ở đầu
EXPLAIN (COSTS OFF) SELECT count(*) FROM users WHERE email LIKE 'user123%';   -- dùng được
EXPLAIN (COSTS OFF) SELECT count(*) FROM users WHERE email LIKE '%example%';  -- không dùng được
```

Cho `LIKE '%...%'`, giải pháp là trigram index:

```sql
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE INDEX idx_email_trgm ON users USING gin (email gin_trgm_ops);
ANALYZE users;
EXPLAIN (COSTS OFF) SELECT count(*) FROM users WHERE email LIKE '%example%';
DROP INDEX idx_email_trgm;
```

> Lưu ý về `prefix LIKE`: chỉ dùng được index khi database dùng collation `C`, hoặc khi index
> được tạo với `text_pattern_ops`. Với collation khác, dùng:
> `CREATE INDEX ON users (email text_pattern_ops);`

---

## Bài 7 — Đo chi phí ghi của index

Chuyển sang `lab` cho nhanh:

```bash
make psql
```

```sql
DROP TABLE IF EXISTS w0, w3, w6;
CREATE TABLE w0 (id int, a int, b int, c int, d int, e int, f text);
CREATE TABLE w3 (LIKE w0);
CREATE TABLE w6 (LIKE w0);

CREATE INDEX ON w3(a); CREATE INDEX ON w3(b); CREATE INDEX ON w3(c);
CREATE INDEX ON w6(a); CREATE INDEX ON w6(b); CREATE INDEX ON w6(c);
CREATE INDEX ON w6(d); CREATE INDEX ON w6(e); CREATE INDEX ON w6(f);

\timing on
INSERT INTO w0 SELECT g,g,g,g,g,g,md5(g::text) FROM generate_series(1,300000) g;
INSERT INTO w3 SELECT g,g,g,g,g,g,md5(g::text) FROM generate_series(1,300000) g;
INSERT INTO w6 SELECT g,g,g,g,g,g,md5(g::text) FROM generate_series(1,300000) g;
\timing off
```

```text
 0 index :  341,9 ms
 3 index :  732,8 ms
 6 index : 1713,8 ms
```

```sql
SELECT relname,
       pg_size_pretty(pg_relation_size(relid))  AS heap,
       pg_size_pretty(pg_indexes_size(relid))   AS idx
FROM pg_stat_user_tables WHERE relname IN ('w0','w3','w6') ORDER BY relname;
```

```text
 relname | heap  |   idx
---------+-------+---------
 w0      | 27 MB | 0 bytes
 w3      | 27 MB | 19 MB
 w6      | 27 MB | 54 MB
```

| Số index | Thời gian | Tỷ lệ | Dung lượng index |
|---:|---:|---:|---:|
| 0 | 342 ms | 1,0× | 0 |
| 3 | 733 ms | 2,1× | 19 MB |
| 6 | 1.714 ms | **5,0×** | **54 MB** |

Với 6 index, **index chiếm gấp đôi dữ liệu thật**.

Và đừng quên chi phí thứ ba đã đo ở Phần 02: index trên column bị update làm tỷ lệ HOT tụt
từ 42,1% xuống 0%.

```sql
DROP TABLE w0, w3, w6;
```

---

## Bài 8 — BRIN

Vẫn trong `lab`, tạo một bảng log chỉ `INSERT` theo thứ tự thời gian:

```sql
DROP TABLE IF EXISTS nhat_ky;
CREATE TABLE nhat_ky (id bigint, luc timestamptz, muc text, noi_dung text);

INSERT INTO nhat_ky
SELECT g,
       '2026-01-01'::timestamptz + (g || ' seconds')::interval,
       (ARRAY['info','warn','error'])[1 + g % 3],
       md5(g::text)
FROM generate_series(1, 3000000) g;

CREATE INDEX idx_nk_brin  ON nhat_ky USING brin(luc);
CREATE INDEX idx_nk_btree ON nhat_ky USING btree(luc);
ANALYZE nhat_ky;
```

Kiểm tra correlation **trước tiên** — đây là bước quyết định:

```sql
SELECT attname, round(correlation::numeric, 4) AS correlation
FROM pg_stats WHERE tablename = 'nhat_ky' AND attname = 'luc';
```

```text
 attname | correlation
---------+-------------
 luc     |      1.0000
```

Hoàn hảo. So kích thước:

```sql
SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS kich_thuoc
FROM pg_stat_user_indexes WHERE relname = 'nhat_ky';

SELECT pg_size_pretty(pg_relation_size('nhat_ky')) AS kich_thuoc_bang;
```

```text
 indexrelname | kich_thuoc
--------------+------------
 idx_nk_brin  | 24 kB
 idx_nk_btree | 64 MB

 kich_thuoc_bang
-----------------
 242 MB
```

**24 kB so với 64 MB — nhỏ hơn 2.700 lần.**

Đo hiệu năng. Với cả hai index, planner chọn B-tree:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM nhat_ky WHERE luc BETWEEN '2026-01-05' AND '2026-01-06';
```

```text
 Index Only Scan using idx_nk_btree ... (actual rows=86401)
   Buffers: shared hit=892 read=239        → 1.131 buffer
```

Bỏ B-tree đi, buộc dùng BRIN:

```sql
DROP INDEX idx_nk_btree;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM nhat_ky WHERE luc BETWEEN '2026-01-05' AND '2026-01-06';
```

```text
 Bitmap Heap Scan on nhat_ky (actual rows=86401)
   Buffers: shared hit=1033               → 1.033 buffer
```

| Index | Kích thước | Buffer đọc |
|---|---:|---:|
| B-tree | 64 MB | 1.131 |
| BRIN | **24 kB** | **1.033** |

BRIN đọc **ít hơn** dù nhỏ hơn 2.700 lần.

### Chứng minh BRIN phụ thuộc correlation

Quay lại `lab_big`, nơi bảng `orders` đã bị `UPDATE` toàn bảng rồi `VACUUM FULL`:

```sql
SELECT attname, round(correlation::numeric, 4) AS correlation
FROM pg_stats WHERE tablename = 'orders' AND attname IN ('id','created_at','user_id');
```

```text
  attname   | correlation
------------+-------------
 id         |      0.1023
 user_id    |     -0.0037
 created_at |     -0.0012
```

Tạo BRIN trên `id` rồi thử:

```sql
CREATE INDEX idx_brin_id ON orders USING brin(id);
ANALYZE orders;
EXPLAIN (COSTS OFF) SELECT count(*) FROM orders WHERE id BETWEEN 500000 AND 600000;
```

Planner **từ chối** dùng nó — correlation 0,1023 quá thấp để BRIN loại bỏ được page nào.

> **Quy tắc BRIN:** luôn kiểm tra `pg_stats.correlation` trước khi tạo. Trên 0,9 thì rất tốt.
> Dưới 0,5 thì đừng.

```sql
DROP INDEX idx_brin_id;
```

---

## Bài 9 — Tìm index vô dụng

```sql
SELECT s.relname AS bang,
       s.indexrelname AS index_name,
       s.idx_scan AS so_lan_dung,
       pg_size_pretty(pg_relation_size(s.indexrelid)) AS kich_thuoc
FROM pg_stat_user_indexes s
JOIN pg_index i ON i.indexrelid = s.indexrelid
WHERE s.idx_scan = 0 AND NOT i.indisunique AND NOT i.indisprimary
ORDER BY pg_relation_size(s.indexrelid) DESC;
```

Trên `lab_big`, các index bạn vừa tạo trong lab mà chưa dùng tới sẽ hiện ra.

Trước khi xóa bất kỳ index nào trên production, kiểm tra ba điều:

```sql
-- 1. Thống kê đã chạy đủ lâu chưa?
SELECT datname, stats_reset FROM pg_stat_database WHERE datname = current_database();

-- 2. Có index trùng lặp không? (a) và (a,b) — cái đầu thường thừa
SELECT indrelid::regclass AS bang, array_agg(indexrelid::regclass) AS cac_index
FROM pg_index GROUP BY indrelid, indkey HAVING count(*) > 1;

-- 3. Index có đang phục vụ constraint không?
SELECT conname, conrelid::regclass FROM pg_constraint WHERE conindid = 'ten_index'::regclass;
```

Và nhớ: workload theo chu kỳ (báo cáo cuối tháng) có `idx_scan = 0` trong 29 ngày.

---

## Bài 10 — Tạo index không gây downtime

```sql
CREATE INDEX CONCURRENTLY idx_oi_product_cc ON order_items(product_id);
```

Trong lúc nó chạy, ở terminal khác:

```sql
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
VALUES (1, 1, 1, 10.00);
```

`INSERT` **không bị chặn** — đó là điểm khác biệt so với `CREATE INDEX` thường.

Luôn kiểm tra sau khi tạo:

```sql
SELECT indexrelid::regclass AS index_khong_hop_le
FROM pg_index WHERE NOT indisvalid;
```

Nếu `CREATE INDEX CONCURRENTLY` thất bại giữa chừng, nó để lại một index **không hợp lệ**:
vẫn tốn chi phí ghi nhưng planner không dùng — tệ nhất của cả hai thế giới. Phải `DROP` và
làm lại.

Kiểm tra toàn vẹn B-tree:

```sql
SELECT bt_index_check('orders_pkey');
```

Không lỗi nghĩa là index lành lặn.

---

## Checklist trước khi sang Phần 06

- [ ] Tự dựng được bảng ngưỡng selectivity và chỉ ra điểm Bitmap đọc nhiều buffer hơn Seq Scan.
- [ ] Giải thích được vì sao Bitmap Heap Scan tồn tại.
- [ ] **Chứng minh được hai plan giống hệt nhau có thể chênh 1.370 lần về buffer.**
- [ ] Sắp đúng thứ tự column cho index phục vụ `WHERE a = ? AND b = ? AND c > ? ORDER BY c`.
- [ ] Biết vì sao partial index đôi khi không được dùng khi gọi từ application.
- [ ] Chứng minh được `INCLUDE` biến Bitmap Heap Scan thành Index Only Scan.
- [ ] Nêu được 4 cách vô tình làm mất index.
- [ ] Đo lại được chi phí ghi khi thêm index.
- [ ] Kiểm tra `correlation` trước khi quyết định dùng BRIN.

---

**Tiếp theo:** Phần 06 — Query Planner & Optimizer.
