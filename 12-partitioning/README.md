# Phần 12 — Partitioning & Scale

> **Mục tiêu:** biết khi nào partitioning giúp thật, và khi nào nó chỉ thêm phức tạp mà không
> giải quyết gì.

---

## 1. Partitioning giải quyết vấn đề gì

Trước hết, hãy nói rõ nó **không** giải quyết vấn đề gì.

> **Partitioning không làm query nhanh lên nếu vấn đề thật là thiếu index.** Một Seq Scan trên
> 10 partition vẫn là một Seq Scan.

Nó giải quyết bốn vấn đề khác, đều liên quan tới **vận hành**:

| Vấn đề | Vì sao partitioning giúp |
|---|---|
| Xóa dữ liệu cũ | `DROP TABLE` một partition là tức thì, **không sinh dead tuple** |
| Bảo trì quá lâu | VACUUM, ANALYZE, REINDEX chạy trên từng partition nhỏ |
| Chỉ truy vấn dữ liệu gần đây | Partition pruning bỏ qua phần lớn dữ liệu |
| Index quá lớn | Mỗi partition có index riêng, nhỏ và nóng trong cache |

Vấn đề đầu tiên thường là lý do chính đáng nhất. `DELETE FROM su_kien WHERE luc < '2025-01-01'`
trên bảng 500 GB tạo ra hàng trăm triệu dead tuple và khiến autovacuum vật lộn hàng ngày.
`DROP TABLE su_kien_2024_12` mất **21 mili-giây** và không tạo dead tuple nào.

---

## 2. Dựng partition

```sql
CREATE TABLE su_kien (
    id      bigserial,
    luc     timestamptz NOT NULL,
    loai    text,
    payload text
) PARTITION BY RANGE (luc);

CREATE TABLE su_kien_2026_01 PARTITION OF su_kien
    FOR VALUES FROM ('2026-01-01') TO ('2026-02-01');
CREATE TABLE su_kien_2026_02 PARTITION OF su_kien
    FOR VALUES FROM ('2026-02-01') TO ('2026-03-01');
CREATE TABLE su_kien_2026_03 PARTITION OF su_kien
    FOR VALUES FROM ('2026-03-01') TO ('2026-04-01');

CREATE INDEX ON su_kien (luc);     -- tự động tạo trên MỌI partition
```

Nạp dữ liệu và kiểm tra:

```sql
INSERT INTO su_kien(luc, loai, payload)
SELECT '2026-01-01'::timestamptz + (g || ' minutes')::interval, 'x', md5(g::text)
FROM generate_series(1, 129000) g;
ANALYZE su_kien;

SELECT tableoid::regclass AS partition, count(*),
       pg_size_pretty(pg_relation_size(tableoid)) AS kich_thuoc
FROM su_kien GROUP BY 1 ORDER BY 1;
```

```text
    partition    | count | kich_thuoc
-----------------+-------+------------
 su_kien_2026_01 | 44639 | 3688 kB
 su_kien_2026_02 | 40320 | 3328 kB
 su_kien_2026_03 | 44041 | 3640 kB
```

PostgreSQL tự định tuyến row vào đúng partition dựa trên `luc`. Ứng dụng chỉ làm việc với bảng
`su_kien`, không cần biết partition nào tồn tại.

**Ba kiểu partition:**

| Kiểu | Dùng khi | Ví dụ |
|---|---|---|
| `RANGE` | Dữ liệu theo thời gian hoặc dải số | Log, sự kiện, đơn hàng theo tháng |
| `LIST` | Giá trị rời rạc, hữu hạn | Theo quốc gia, theo tenant |
| `HASH` | Cần chia đều, không có tiêu chí tự nhiên | Phân tán tải ghi |

---

## 3. Partition pruning — lợi ích chính khi truy vấn

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM su_kien WHERE luc >= '2026-02-05' AND luc < '2026-02-06';
```

```text
 Aggregate (actual rows=1 loops=1)
   Buffers: shared hit=22
   ->  Index Only Scan using su_kien_2026_02_luc_idx on su_kien_2026_02 su_kien
         Index Cond: ((luc >= '2026-02-05...') AND (luc < '2026-02-06...'))
         Heap Fetches: 1440
         Buffers: shared hit=22
```

**Chỉ `su_kien_2026_02` xuất hiện trong plan.** Hai partition kia bị loại bỏ hoàn toàn ngay ở
giai đoạn lập plan — PostgreSQL thậm chí không mở file của chúng.

Bây giờ query **không** có điều kiện trên partition key:

```sql
EXPLAIN (COSTS OFF) SELECT count(*) FROM su_kien WHERE loai = 'x';
```

```text
 Aggregate
   ->  Append
         ->  Seq Scan on su_kien_2026_01 su_kien_1
               Filter: (loai = 'x'::text)
         ->  Seq Scan on su_kien_2026_02 su_kien_2
               Filter: (loai = 'x'::text)
         ->  Seq Scan on su_kien_2026_03 su_kien_3
               Filter: (loai = 'x'::text)
```

**Quét toàn bộ mọi partition.** Không có pruning, và giờ bạn có 3 lần Seq Scan thay vì 1.

> **Quy tắc quan trọng nhất của partitioning:** partition key phải xuất hiện trong `WHERE` của
> **những query quan trọng nhất**. Nếu workload chính của bạn không lọc theo partition key,
> partitioning sẽ **làm chậm đi**, không nhanh lên.

Chọn partition key theo **cách dữ liệu được truy vấn**, không theo cách dữ liệu được sinh ra.

### Pruning ở hai thời điểm

| Loại | Xảy ra khi | Điều kiện |
|---|---|---|
| Plan-time pruning | Lúc lập plan | Điều kiện là hằng số |
| **Execution-time pruning** | Lúc chạy | Điều kiện là tham số `$1`, hoặc từ subquery |

Execution-time pruning (PostgreSQL 11+) hiện trong plan dạng:

```text
Subplans Removed: 11
```

Nghĩa là 11 partition bị loại **lúc chạy**. Đây là lý do prepared statement vẫn hưởng lợi từ
partitioning, dù plan chung không biết trước giá trị tham số.

---

## 4. Bảo trì partition

### 4.1. Xóa dữ liệu cũ — lợi ích lớn nhất

```sql
\timing on
DROP TABLE su_kien_2026_01;
```

```text
Time: 21.133 ms
```

**21 mili-giây, không dead tuple nào.** So với `DELETE` 44.639 row: chậm hơn nhiều lần, tạo
44.639 dead tuple, và autovacuum phải dọn sau đó.

An toàn hơn — tách ra trước rồi mới xóa:

```sql
ALTER TABLE su_kien DETACH PARTITION su_kien_2026_01 CONCURRENTLY;
-- kiểm tra, backup nếu cần
DROP TABLE su_kien_2026_01;
```

`CONCURRENTLY` (PostgreSQL 14+) không giữ `ACCESS EXCLUSIVE` trên bảng cha — quan trọng, vì
theo Phần 08, một `ACCESS EXCLUSIVE` phải chờ sẽ chặn toàn bộ traffic đọc phía sau.

### 4.2. Tạo partition trước — nếu không sẽ mất dữ liệu

```sql
INSERT INTO su_kien(luc, loai, payload) VALUES ('2026-05-01', 'x', 'y');
```

```text
ERROR:  no partition of relation "su_kien" found for row
DETAIL:  Partition key of the failing row contains (luc) = (2026-05-01 00:00:00+07).
```

**Đây là sự cố production kinh điển:** hệ thống chạy êm nhiều tháng, rồi đúng 0 giờ ngày đầu
tháng, mọi `INSERT` đều lỗi vì không ai tạo partition cho tháng mới.

Ba cách phòng:

**1. Tạo trước nhiều tháng** bằng job định kỳ:

```sql
DO $$
DECLARE thang date;
BEGIN
  FOR i IN 0..5 LOOP
    thang := date_trunc('month', now())::date + (i || ' months')::interval;
    EXECUTE format(
      'CREATE TABLE IF NOT EXISTS su_kien_%s PARTITION OF su_kien
       FOR VALUES FROM (%L) TO (%L)',
      to_char(thang, 'YYYY_MM'), thang, thang + interval '1 month');
  END LOOP;
END $$;
```

**2. `DEFAULT` partition** làm lưới an toàn:

```sql
CREATE TABLE su_kien_default PARTITION OF su_kien DEFAULT;
```

Row không khớp partition nào rơi vào đây thay vì lỗi. Nhưng nhớ theo dõi nó — dữ liệu nằm trong
`DEFAULT` nghĩa là bạn đã quên tạo partition. Và khi thêm partition mới, PostgreSQL phải quét
`DEFAULT` để kiểm tra xung đột, giữ lock trong lúc đó.

**3. `pg_partman`** — extension tự động hóa toàn bộ việc tạo và xóa partition theo lịch. Đây là
lựa chọn tiêu chuẩn cho hệ thống production.

### 4.3. Cảnh báo về số lượng partition

Mỗi partition là một bảng thật với catalog entry, file, và lock riêng.

| Số partition | Ảnh hưởng |
|---|---|
| < 100 | Không vấn đề |
| 100–1.000 | Thời gian lập plan tăng rõ; cần `enable_partition_pruning` hoạt động tốt |
| > 1.000 | Lập plan chậm hẳn, `max_locks_per_transaction` có thể không đủ |

Query chạm nhiều partition phải lấy lock trên **từng** partition. Với 5.000 partition, một
`SELECT` không pruning được sẽ lấy 5.000 lock — dễ vượt `max_locks_per_transaction`.

> Phân hoạch theo **tháng** thường hợp lý hơn theo **ngày**, trừ khi thật sự cần độ chi tiết đó.

---

## 5. Ràng buộc và index trên bảng phân hoạch

| Đặc điểm | Hỗ trợ |
|---|---|
| `PRIMARY KEY` | **Phải chứa partition key** |
| `UNIQUE` | **Phải chứa partition key** |
| Foreign key trỏ **tới** bảng phân hoạch | Có (PostgreSQL 12+) |
| Foreign key **từ** bảng phân hoạch | Có |
| `CREATE INDEX` trên bảng cha | Có, tự lan xuống mọi partition |
| `CREATE INDEX CONCURRENTLY` trên bảng cha | **Không** — phải làm từng partition |

Hạn chế đầu tiên là hạn chế đau nhất. Với bảng phân hoạch theo `luc`, bạn **không thể** có
`UNIQUE (id)` — chỉ có `UNIQUE (id, luc)`.

Hệ quả thực tế: nếu nghiệp vụ cần `id` duy nhất toàn cục, phải đảm bảo bằng cách khác (sequence,
UUID) chứ không dựa vào constraint.

Tạo index không downtime trên bảng phân hoạch:

```sql
-- 1. Tạo index trên từng partition, CONCURRENTLY
CREATE INDEX CONCURRENTLY idx_p1 ON su_kien_2026_02 (loai);
CREATE INDEX CONCURRENTLY idx_p2 ON su_kien_2026_03 (loai);

-- 2. Tạo index "rỗng" trên bảng cha
CREATE INDEX idx_cha ON ONLY su_kien (loai);

-- 3. Gắn các index con vào
ALTER INDEX idx_cha ATTACH PARTITION idx_p1;
ALTER INDEX idx_cha ATTACH PARTITION idx_p2;
```

Sau bước 3, `idx_cha` trở thành hợp lệ.

---

## 6. Partition-wise join và aggregate

```sql
SET enable_partitionwise_join = on;       -- mặc định OFF
SET enable_partitionwise_aggregate = on;  -- mặc định OFF
```

Khi hai bảng phân hoạch **cùng cách**, PostgreSQL join từng cặp partition tương ứng thay vì
gộp tất cả rồi join. Với 12 partition, đó là 12 hash table nhỏ thay vì một hash table khổng lồ
— thường tránh được spill to disk (Phần 07).

Cả hai mặc định **tắt** vì làm tăng thời gian lập plan. Bật khi thật sự có join giữa các bảng
phân hoạch cùng khóa.

---

## 7. Khi nào partitioning là câu trả lời sai

Trước khi phân hoạch một bảng, hãy kiểm tra ba điều:

1. **Vấn đề có phải là thiếu index không?** Đây là nguyên nhân thật trong đa số trường hợp.
   Partitioning không sửa được nó.
2. **Query có lọc theo partition key không?** Nếu không, bạn đang biến 1 Seq Scan thành N Seq Scan.
3. **Bảng có thật sự lớn không?** Dưới ~50–100 GB, chi phí vận hành thường lớn hơn lợi ích.

Dấu hiệu partitioning là lựa chọn **đúng**:

- Bảng theo thời gian, chỉ ghi thêm, và cần xóa dữ liệu cũ định kỳ.
- Query hầu hết lọc theo khoảng thời gian gần đây.
- VACUUM hoặc REINDEX trên bảng đó mất quá lâu để chạy trong cửa sổ bảo trì.

---

## 8. Vượt giới hạn một node

Khi một node không còn đủ, thứ tự ưu tiên nên là:

| Bước | Việc cần làm | Chi phí |
|---|---|---|
| 1 | Tối ưu query, index, schema (Phần 05–07) | Thấp, hiệu quả cao nhất |
| 2 | Tăng phần cứng | Thấp về công sức |
| 3 | Tách đọc sang replica (Phần 10) | Trung bình |
| 4 | Partitioning | Trung bình |
| 5 | Tách theo nghiệp vụ (mỗi service một database) | Cao |
| 6 | Sharding | **Rất cao** |

Sharding đưa vào những vấn đề mới rất khó: transaction phân tán, join xuyên shard, rebalance
khi thêm shard, khóa duy nhất toàn cục. Các công cụ như Citus giải quyết được phần lớn, nhưng
vẫn là một quyết định kiến trúc lớn.

> Phần lớn hệ thống nghĩ mình cần sharding thực ra cần bước 1.

---

## 9. Những gì bạn nên rút ra từ phần này

1. Partitioning giải quyết vấn đề **vận hành**, không phải vấn đề tốc độ query.
2. `DROP TABLE` một partition mất **21 ms** và không sinh dead tuple; `DELETE` tương đương tạo
   hàng chục nghìn dead tuple.
3. Query **không** lọc theo partition key sẽ quét **mọi** partition — chậm hơn khi chưa phân hoạch.
4. Quên tạo partition cho tháng tới làm mọi `INSERT` lỗi. Dùng job tạo trước, `DEFAULT`
   partition, hoặc `pg_partman`.
5. `PRIMARY KEY` và `UNIQUE` **bắt buộc phải chứa** partition key.
6. `DETACH PARTITION CONCURRENTLY` tránh được `ACCESS EXCLUSIVE` trên bảng cha.
7. Quá nhiều partition (>1.000) làm chậm lập plan và cạn lock.
8. Trước khi phân hoạch, hãy chắc vấn đề thật không phải là thiếu index.

---

**Tiếp theo:** Phần 13 — Schema & Data Modeling.
