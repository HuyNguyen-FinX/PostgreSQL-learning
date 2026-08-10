# Phần 06 — Lab: đọc suy nghĩ của planner

> Chạy trên `lab` và `lab_big`. Nhiều bài tắt parallel query để số liệu đọc thẳng được:
> `SET max_parallel_workers_per_gather = 0;`

---

## Bài 1 — Đọc statistics

```bash
make psql-big
```

```sql
SELECT attname, n_distinct,
       most_common_vals::text  AS mcv,
       most_common_freqs::text AS tan_suat
FROM pg_stats WHERE tablename = 'users' AND attname = 'country_code';
```

```text
   attname    | n_distinct |       mcv        |                   tan_suat
--------------+------------+------------------+----------------------------------------------
 country_code |          5 | {VN,US,JP,SG,DE} | {0.6971,0.15113333,0.0785,0.05246667,0.0208}
```

So với thiết kế của script seed (70/15/8/5/2): sai số dưới 0,5%. `ANALYZE` chỉ **lấy mẫu**
chứ không đọc toàn bộ bảng, nhưng lấy mẫu đủ tốt.

```sql
SELECT attname, n_distinct, round(correlation::numeric, 3) AS correlation
FROM pg_stats WHERE tablename = 'users';
```

```text
   attname    | n_distinct | correlation
--------------+------------+-------------
 country_code |          5 |       0.519
 status       |          3 |       0.727
 id           |         -1 |       1.000
 email        |         -1 |      -0.398
```

Hai điều cần đọc ra:

- **`n_distinct = -1`** nghĩa là mọi giá trị đều khác nhau (tỷ lệ 100%). Ký hiệu âm tự co giãn
  khi bảng lớn lên; số dương thì lỗi thời ngay khi dữ liệu tăng.
- **`correlation = 1.000` của `id`** nghĩa là thứ tự `id` trùng thứ tự vật lý — đây là con số
  quyết định Index Scan rẻ hay đắt, và quyết định BRIN có dùng được không (Phần 05).

**Kiểm chứng ước lượng cho từng giá trị:**

```sql
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM users WHERE country_code = 'DE';
```

Lặp với `VN`, `US`, `JP`, `SG`. Vì cả 5 giá trị đều nằm trong MCV list, ước lượng bám sát
thực tế ở **mọi** giá trị — dù chúng chênh nhau 35 lần về tần suất.

---

## Bài 2 — Tự tính lại cost của planner

Đây là bài chứng minh cost model không phải hộp đen.

```bash
make psql
```

```sql
SET max_parallel_workers_per_gather = 0;

SELECT relpages, reltuples::bigint FROM pg_class WHERE relname = 'dia_chi';
```

Nếu chưa có bảng `dia_chi`, tạo trước (dùng lại ở Bài 3):

```sql
DROP TABLE IF EXISTS dia_chi;
CREATE TABLE dia_chi (id int, quoc_gia text, thanh_pho text, ghi_chu text);
INSERT INTO dia_chi
SELECT g,
       (ARRAY['VN','JP','US'])[1 + g % 3],
       (ARRAY['Ha Noi','Tokyo','New York'])[1 + g % 3],
       md5(g::text)
FROM generate_series(1, 900000) g;
ANALYZE dia_chi;
```

```text
 relpages | reltuples
----------+-----------
     8738 |    900000
```

**Không điều kiện:**

```sql
EXPLAIN SELECT * FROM dia_chi;
```

```text
 Seq Scan on dia_chi  (cost=0.00..17738.00 rows=900000 width=47)
```

Tính tay:

```text
relpages × seq_page_cost   = 8738  × 1.0  = 8738
reltuples × cpu_tuple_cost = 900000 × 0.01 = 9000
                                    tổng   = 17738   ✓
```

**Có một điều kiện:**

```sql
EXPLAIN SELECT * FROM dia_chi WHERE quoc_gia = 'VN';
```

```text
 Seq Scan on dia_chi  (cost=0.00..19988.00 rows=298440 width=47)
   Filter: (quoc_gia = 'VN'::text)
```

```text
17738 + reltuples × cpu_operator_cost = 17738 + 900000 × 0.0025 = 19988   ✓
```

Kiểm chứng bằng SQL:

```sql
SELECT (SELECT relpages FROM pg_class WHERE relname='dia_chi')
         * current_setting('seq_page_cost')::float8      AS doc_page,
       (SELECT reltuples FROM pg_class WHERE relname='dia_chi')
         * current_setting('cpu_tuple_cost')::float8     AS xu_ly_tuple,
       (SELECT reltuples FROM pg_class WHERE relname='dia_chi')
         * current_setting('cpu_operator_cost')::float8  AS mot_dieu_kien;
```

```text
 doc_page | xu_ly_tuple | mot_dieu_kien
----------+-------------+---------------
     8738 |        9000 |          2250
```

**Bài tập nhỏ:** thêm điều kiện thứ hai và dự đoán cost **trước** khi chạy `EXPLAIN`.

---

## Bài 3 — Giả định độc lập và `CREATE STATISTICS`

Trong bảng `dia_chi`, `thanh_pho` **quyết định hoàn toàn** `quoc_gia`.

```sql
SET max_parallel_workers_per_gather = 0;

-- A. Một column
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM dia_chi WHERE quoc_gia = 'VN';
```

```text
 ->  Seq Scan on dia_chi  (cost=0.00..19988.00 rows=300900) (actual rows=300000 loops=1)
```

Ước lượng 300.900, thực tế 300.000 — **sai 0,3%**.

```sql
-- B. Hai column phụ thuộc
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM dia_chi WHERE quoc_gia = 'VN' AND thanh_pho = 'Ha Noi';
```

```text
 ->  Seq Scan on dia_chi  (cost=0.00..22238.00 rows=100601) (actual rows=300000 loops=1)
       Filter: ((quoc_gia = 'VN'::text) AND (thanh_pho = 'Ha Noi'::text))
```

**Ước lượng 100.601, thực tế 300.000 — hụt 3 lần.**

Nguồn gốc con số 100.601: planner nhân hai selectivity `1/3 × 1/3 = 1/9`, rồi `900000 / 9 =
100000`. Nhưng điều kiện thứ hai **không lọc thêm row nào** — mọi row có `quoc_gia = 'VN'`
đều có `thanh_pho = 'Ha Noi'`.

```sql
-- C. Sửa bằng extended statistics
CREATE STATISTICS st_dia_chi (dependencies, ndistinct)
ON quoc_gia, thanh_pho FROM dia_chi;
ANALYZE dia_chi;

EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM dia_chi WHERE quoc_gia = 'VN' AND thanh_pho = 'Ha Noi';
```

```text
 ->  Seq Scan on dia_chi  (cost=0.00..22238.00 rows=298440) (actual rows=300000 loops=1)
```

**298.440 so với 300.000 — sai 0,5%.**

| | Ước lượng | Thực tế | Sai số |
|---|---:|---:|---:|
| Một column | 300.900 | 300.000 | 0,3% |
| Hai column, chưa có statistics | **100.601** | 300.000 | **3 lần** |
| Hai column, có statistics | 298.440 | 300.000 | 0,5% |

Xem PostgreSQL đã học được gì:

```sql
SELECT stxname, stxddependencies, stxdndistinct
FROM pg_statistic_ext s JOIN pg_statistic_ext_data d ON d.stxoid = s.oid
WHERE stxname = 'st_dia_chi';
```

Kết quả cho thấy độ phụ thuộc giữa hai column gần 1,0 — PostgreSQL đã phát hiện `thanh_pho`
xác định `quoc_gia`.

---

## Bài 4 — Ba thuật toán join

Trên `lab_big`:

```sql
SET max_parallel_workers_per_gather = 0;
```

Query dùng chung:

```sql
SELECT count(*) FROM orders o JOIN users u ON u.id = o.user_id
WHERE u.country_code = 'DE';
```

Chạy bốn lần, mỗi lần ép một thuật toán:

```sql
-- 1. Để planner tự chọn
EXPLAIN (ANALYZE, BUFFERS) <query>;

-- 2. Ép Nested Loop
SET enable_hashjoin = off; SET enable_mergejoin = off;
EXPLAIN (ANALYZE, BUFFERS) <query>;

-- 3. Ép Hash Join
RESET ALL; SET max_parallel_workers_per_gather = 0;
SET enable_mergejoin = off; SET enable_nestloop = off;
EXPLAIN (ANALYZE, BUFFERS) <query>;

-- 4. Ép Merge Join
RESET ALL; SET max_parallel_workers_per_gather = 0;
SET enable_hashjoin = off; SET enable_nestloop = off;
EXPLAIN (ANALYZE, BUFFERS) <query>;

RESET ALL;
```

| Thuật toán | Cost | Thời gian | Buffer |
|---|---:|---:|---:|
| **Nested Loop** (planner chọn) | 9.291 | **16,4 ms** | 14.273 |
| Hash Join | 24.057 | 70,9 ms | 3.682 |
| Merge Join | 24.359 | 63,5 ms | 3.682 |

Planner chọn đúng — Nested Loop nhanh hơn 4 lần.

**Điều phản trực giác cần chú ý:** Nested Loop đọc **nhiều buffer nhất** (14.273 so với 3.682)
nhưng vẫn nhanh nhất, vì toàn bộ là `shared hit` — lấy từ cache. Hash Join phải dựng hash
table, một chi phí CPU không hiện ra ở cột buffer.

> **Đừng tối ưu theo một chỉ số duy nhất.** Buffer thấp không đồng nghĩa với nhanh.

---

## Bài 5 — Cost không phải thời gian

Query lớn hơn: `orders` join `order_items` (1 triệu × 2,5 triệu).

```sql
SET max_parallel_workers_per_gather = 0;

SELECT count(*) FROM orders o JOIN order_items oi ON oi.order_id = o.id
WHERE o.status = 'completed';
```

| Plan | Cost | Thời gian | Buffer |
|---|---:|---:|---:|
| Merge Join (planner chọn) | 111.834 | 1.252 ms | 1.011.998 |
| Nested Loop (bị ép) | **445.848** | **1.169 ms** | 2.413.767 |

Planner cho rằng Nested Loop đắt gấp **4 lần**. Thời gian thực tế **gần bằng nhau**, thậm chí
Nested Loop nhanh hơn chút.

Vì sao: cost model giả định một tỷ lệ page phải đọc từ đĩa. Ở đây dữ liệu đã nằm hết trong
cache nên phần chi phí đó không xảy ra.

**Kết luận cần mang theo suốt đời làm nghề:**

> Cost là đơn vị nội bộ để planner **so sánh các phương án của cùng một query**. Nó không dự
> báo thời gian, và **không so sánh được giữa hai query khác nhau**. Khi debug, chỉ nhìn
> `actual time` và `Buffers`.

---

## Bài 6 — Tái hiện Nested Loop nổ

Đây là kịch bản của gần như mọi sự cố "query chạy mãi không xong".

```sql
DROP TABLE IF EXISTS ngoai, trong;
CREATE TABLE ngoai (id int, nhom int, pad text);
CREATE TABLE trong (id int, nhom int, pad text);

INSERT INTO ngoai SELECT g, g % 1000, md5(g::text) FROM generate_series(1, 500000) g;
INSERT INTO trong SELECT g, g % 1000, md5(g::text) FROM generate_series(1, 500000) g;
CREATE INDEX ON trong(nhom);
ANALYZE ngoai; ANALYZE trong;
```

Bây giờ tạo một điều kiện mà planner ước lượng sai nghiêm trọng:

```sql
SET max_parallel_workers_per_gather = 0;

EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*)
FROM ngoai n JOIN trong t ON t.nhom = n.nhom
WHERE n.nhom < 5;
```

Đọc plan và tìm:

1. Node `Nested Loop`: so `rows=` với `actual rows=`.
2. Node bên trong: nhìn **`loops=`**.

```text
->  Index Scan using trong_nhom_idx on trong  (actual rows=500 loops=2500)
                                                            ^^^^^^^^^^^^
```

`loops` lớn ở node trong là **dấu hiệu không thể nhầm lẫn** của Nested Loop đang chạy quá
nhiều vòng. Tổng số row thật là `actual rows × loops`.

So với Hash Join:

```sql
SET enable_nestloop = off;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF)
SELECT count(*) FROM ngoai n JOIN trong t ON t.nhom = n.nhom WHERE n.nhom < 5;
RESET enable_nestloop;
```

**Cách chữa cháy trên production:**

```sql
SET enable_nestloop = off;    -- chỉ trong session đang gặp sự cố
```

**Cách sửa gốc rễ:** `ANALYZE`, tăng `STATISTICS`, hoặc `CREATE STATISTICS` — tức là sửa
nguyên nhân làm planner ước lượng sai, chứ không phải bịt triệu chứng.

---

## Bài 7 — Đọc plan parallel cho đúng

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

**`actual rows=10000` là trung bình mỗi lần lặp, không phải tổng.**

Tổng thật: `10000 × 3 = 30.000` — đúng 3% của 1 triệu order, khớp thiết kế dataset.

Kiểm chứng:

```sql
SELECT count(*) FROM orders WHERE status = 'cancelled';
```

Đây là lỗi đọc plan phổ biến nhất với parallel query. Quên nhân với `loops` sẽ dẫn tới kết
luận sai rằng planner ước lượng lệch 3 lần.

**Thí nghiệm về chi phí khởi tạo worker:**

```sql
SET max_parallel_workers_per_gather = 0;
EXPLAIN (ANALYZE, BUFFERS, TIMING OFF, SUMMARY ON)
SELECT count(*) FROM orders WHERE id = 500;

RESET max_parallel_workers_per_gather;
```

Với query trả về 1 row, parallel không giúp gì — và planner biết điều đó nên không dùng.

---

## Bài 8 — CTE inline và `MATERIALIZED`

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
WITH d AS (SELECT id, user_id FROM orders)
SELECT * FROM d WHERE user_id = 42;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
WITH d AS MATERIALIZED (SELECT id, user_id FROM orders)
SELECT * FROM d WHERE user_id = 42;
```

Bản inline đẩy được `user_id = 42` xuống tận Seq Scan. Bản `MATERIALIZED` phải vật chất hóa
toàn bộ 1 triệu row rồi mới lọc — so `Buffers` của hai bản.

**Khi nào `MATERIALIZED` là đúng:** khi CTE được tham chiếu nhiều lần và tính lại đắt hơn lưu
trữ, hoặc khi CTE có side effect (`INSERT ... RETURNING`).

---

## Bài 9 — Quy trình chẩn đoán chuẩn

Áp dụng vào một query bất kỳ trong `lab_big`:

```sql
EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS)
SELECT u.country_code, count(*), sum(o.total_amount)
FROM users u
JOIN orders o ON o.user_id = u.id
JOIN order_items oi ON oi.order_id = o.id
WHERE u.country_code = 'DE' AND o.status = 'completed'
GROUP BY u.country_code;
```

Sáu bước:

1. **Tìm node có `rows` lệch nhiều nhất so với `actual rows`.** Nhớ nhân với `loops`.
2. **Đi xuống dưới** — sai số bắt nguồn từ node thấp nhất bị lệch, các tầng trên chỉ kế thừa.
3. Điều kiện trên **một** column → `ANALYZE`, rồi `ALTER TABLE ... SET STATISTICS`.
4. Điều kiện trên **nhiều** column → `CREATE STATISTICS`.
5. Dùng `enable_*` để **xác nhận** plan khác thật sự tốt hơn.
6. Sửa gốc rễ, rồi **bỏ `enable_*` đi**.

`SETTINGS` trong `EXPLAIN` cho biết tham số nào đang khác mặc định — rất hữu ích khi query
chạy khác nhau giữa hai môi trường:

```text
Settings: random_page_cost = '1.1', work_mem = '4MB'
```

> **`enable_*` không bao giờ là giải pháp cuối cùng.** Để chúng trong code production nghĩa là
> bạn đã đóng băng một quyết định mà planner lẽ ra phải tự điều chỉnh khi dữ liệu đổi.

Dọn dẹp:

```sql
DROP TABLE IF EXISTS ngoai, trong;
```

---

## Checklist trước khi sang Phần 07

- [ ] Đọc được MCV list và giải thích `n_distinct` âm.
- [ ] **Tự tính lại được cost của một Seq Scan và khớp với `EXPLAIN`.**
- [ ] Giải thích được con số 100.601 đến từ đâu.
- [ ] Dùng được `CREATE STATISTICS` và đo lại sai số.
- [ ] Ép được cả ba thuật toán join và so sánh.
- [ ] Giải thích được vì sao cost chênh 4 lần mà thời gian bằng nhau.
- [ ] Nhận ra `loops` lớn nghĩa là gì.
- [ ] Nhân đúng `actual rows × loops` trong plan parallel.

---

**Tiếp theo:** Phần 07 — Đọc EXPLAIN chuyên sâu.
