# Phần 11 — Connection & Resource Management

> **Mục tiêu:** trả lời được câu hỏi "vì sao tăng `max_connections` lại làm hệ thống chậm hơn".

---

## 1. Chi phí thật của một connection

Phần 01 đã đo bằng `pgbench`, cùng câu `SELECT 1`, 8 client, 5 giây:

| Cách chạy | Latency | TPS |
|---|---:|---:|
| Dùng lại connection | 0,067 ms | 119.016 |
| Mở mới mỗi transaction (`-C`) | 5,003 ms | 1.599 |

**74 lần.** Đó là chi phí bắt tay TCP, xác thực, `fork()` một process mới, và dựng lại cache
cục bộ của backend.

Nhưng chi phí mở connection **chưa phải** vấn đề lớn nhất. Vấn đề lớn hơn là chi phí **duy trì**
quá nhiều connection cùng lúc.

---

## 2. Vì sao nhiều connection làm chậm hệ thống

**Level 1 — Trực giác.** Một quán ăn có 4 đầu bếp. Nhận 4 đơn cùng lúc thì mỗi đơn xong nhanh.
Nhận 400 đơn cùng lúc thì tổng thời gian không đổi, nhưng **mỗi** đơn đều chậm, và đầu bếp mất
thêm thời gian chỉ để nhớ mình đang làm dở món nào.

**Level 2 — Backend Engineer.** Mỗi connection là một process (Phần 01). 500 process trên máy
8 core nghĩa là:

- Hệ điều hành liên tục context switch — chi phí thuần túy, không sinh ra công việc hữu ích.
- Cache CPU liên tục bị đẩy ra.
- Tranh chấp lock trong shared memory tăng theo bình phương số process.
- Mỗi process có thể dùng nhiều lần `work_mem`.

Kết quả: TPS **giảm** khi vượt quá một ngưỡng, và latency tăng cho mọi người.

**Level 3 — Internals.** Nút thắt nằm ở các lightweight lock bảo vệ cấu trúc trong shared
memory, đặc biệt là buffer mapping table. Mỗi lần một backend cần tra một page trong
`shared_buffers`, nó phải lấy một lock trên bucket tương ứng. Với hàng trăm backend, tranh chấp
trên các lock này trở thành nút thắt lớn hơn cả I/O.

Dấu hiệu trong `pg_stat_activity`:

```sql
SELECT wait_event_type, wait_event, count(*)
FROM pg_stat_activity
WHERE wait_event IS NOT NULL AND backend_type = 'client backend'
GROUP BY 1, 2 ORDER BY 3 DESC;
```

`wait_event_type = 'LWLock'` chiếm tỷ trọng lớn là dấu hiệu quá nhiều connection.

### Công thức khởi điểm

```text
max_connections ≈ số_core × 2  đến  số_core × 4
```

Số dư nên **xếp hàng ở connection pool phía ứng dụng**, không phải mở thêm process trong
database. Hàng đợi ở pooler rẻ hơn hàng đợi trong hệ điều hành rất nhiều.

**Tự đo ngưỡng của bạn:**

```bash
docker compose exec -T db sh -c 'echo "SELECT 1;" > /tmp/q.sql'
for c in 1 2 4 8 16 32 64 128; do
  docker compose exec -T db pgbench -U lab -d lab -n -f /tmp/q.sql -c $c -T 10 \
    | grep -E "^tps" | sed "s/^/clients=$c /"
done
```

Lập bảng `số client → TPS → latency`, tìm điểm TPS ngừng tăng và điểm TPS bắt đầu giảm.

---

## 3. PgBouncer

### 3.1. Ba chế độ pooling

| Chế độ | Connection được trả lại pool khi nào | Tỷ lệ gom |
|---|---|---|
| `session` | Khi client ngắt kết nối | Thấp |
| **`transaction`** | Khi mỗi transaction kết thúc | **Cao — nên dùng** |
| `statement` | Sau mỗi câu lệnh | Cao nhất, nhiều hạn chế |

`transaction` là lựa chọn đúng cho gần như mọi ứng dụng web/API: giữa hai transaction, ứng
dụng thường đang chờ mạng hoặc xử lý logic, và connection đó có thể phục vụ người khác.

```ini
[databases]
lab = host=postgres port=5432 dbname=lab

[pgbouncer]
pool_mode = transaction
max_client_conn = 1000        # số connection ứng dụng được mở tới PgBouncer
default_pool_size = 25        # số connection THẬT tới PostgreSQL
```

1.000 connection từ ứng dụng gom lại thành 25 connection thật.

### 3.2. Transaction pooling phá vỡ những gì

Đây là phần bắt buộc phải nắm trước khi bật.

| Tính năng | Vì sao hỏng |
|---|---|
| `PREPARE` / prepared statement | Chuẩn bị trên connection này, chạy trên connection khác |
| `SET` mức session | Mất khi connection được trả lại pool |
| Temporary table | Gắn với session, biến mất bất ngờ |
| `pg_advisory_lock` (mức session) | Nhả lock trên connection khác — **lock kẹt vĩnh viễn** |
| `LISTEN` / `NOTIFY` | Cần session ổn định |
| Cursor giữ qua nhiều transaction | Cần session ổn định |

Cách xử lý:

- **Prepared statement:** PgBouncer 1.21+ hỗ trợ prepared statement ở chế độ transaction
  (`max_prepared_statements`). Với bản cũ hơn, tắt ở driver — JDBC dùng
  `prepareThreshold=0`, psycopg dùng `prepare_threshold=None`.
- **Advisory lock:** luôn dùng `pg_advisory_xact_lock` (Phần 08).
- **`SET`:** dùng `SET LOCAL` bên trong transaction.

### 3.3. Đặt `default_pool_size` bao nhiêu

```text
default_pool_size ≈ số_core × 2  đến  số_core × 4
```

Đúng bằng con số `max_connections` lý tưởng ở mục 2 — vì đây mới là số connection **thật** tới
PostgreSQL. Ngưỡng tối ưu không đổi; PgBouncer chỉ giúp bạn giữ được nó trong khi ứng dụng vẫn
mở hàng nghìn connection.

Theo dõi:

```sql
-- Kết nối vào database ảo 'pgbouncer'
SHOW POOLS;
SHOW STATS;
```

Cột `cl_waiting` lớn nghĩa là client đang xếp hàng chờ connection — cân nhắc tăng
`default_pool_size`, nhưng chỉ khi CPU database chưa bão hòa.

> **Nghịch lý cần nhớ:** "connection pool đầy trong khi CPU database chỉ 15%" thường **không**
> phải do pool quá nhỏ. Nó thường do transaction bị giữ quá lâu — ứng dụng gọi HTTP bên trong
> transaction, hoặc quên commit. Xem Phần 15.

---

## 4. `work_mem`

### 4.1. Là giới hạn cho mỗi node, không phải mỗi query

Đây là hiểu lầm tốn kém nhất về bộ nhớ PostgreSQL.

`work_mem` áp dụng cho **mỗi node cần bộ nhớ** trong Execution Plan: mỗi `Sort`, mỗi `Hash`,
mỗi `HashAggregate`, mỗi `Bitmap Heap Scan`.

```text
Bộ nhớ tối đa của một query ≈ số_node_cần_bộ_nhớ
                            × (1 + số_parallel_worker)
                            × work_mem
```

Một query có 3 node sort chạy với 2 worker: `3 × 3 × work_mem`. Với `work_mem = 256MB`, đó là
**2,3 GB cho một query**.

Nhân với số connection đồng thời và bạn hiểu vì sao tăng `work_mem` toàn cục là cách nhanh nhất
để gặp OOM.

### 4.2. Cách đặt đúng

Giữ mặc định thấp toàn cục, nâng có chọn lọc:

```sql
-- Trong một transaction cụ thể
SET LOCAL work_mem = '256MB';

-- Cho user chuyên chạy báo cáo
ALTER ROLE bao_cao SET work_mem = '512MB';
```

Tìm query cần nhiều `work_mem` bằng cách bật `log_temp_files` (môi trường Phần 00 đã đặt `0` —
ghi mọi temp file):

```text
LOG:  temporary file: path "base/pgsql_tmp/...", size 55408128
STATEMENT:  SELECT * FROM orders ORDER BY total_amount;
```

Và trong plan (Phần 07):

```text
Sort Method: external merge  Disk: 55408kB
```

**Nhớ bài học Phần 07:** cần `Disk: 55408kB` nhưng phải đặt `work_mem` lớn hơn thế nhiều —
thực đo cần `Memory: 85677kB`. Con số `Disk` là mức tối thiểu, không phải mức đủ.

### 4.3. Các tham số bộ nhớ khác

| Tham số | Mặc định | Ghi chú |
|---|---|---|
| `maintenance_work_mem` | 64MB | `VACUUM`, `CREATE INDEX`. Xem Phần 04 — thiếu thì `index scans: > 1` |
| `hash_mem_multiplier` | 2.0 | Hash node được dùng `work_mem × hệ số này` |
| `temp_buffers` | 8MB | Cache cho temporary table |
| `shared_buffers` | 25% RAM | Xem Phần 01 — đừng đặt quá lớn |
| `effective_cache_size` | 50–75% RAM | **Không cấp phát gì**, chỉ là gợi ý cho planner |

Lưu ý về `maintenance_work_mem`: mỗi autovacuum worker có thể dùng riêng một phần, nên tổng là
`autovacuum_max_workers × maintenance_work_mem`.

---

## 5. Temp file

```sql
SELECT datname, temp_files, pg_size_pretty(temp_bytes) AS temp_size
FROM pg_stat_database WHERE datname NOT LIKE 'template%'
ORDER BY temp_bytes DESC;
```

`temp_files` tăng đều là dấu hiệu `work_mem` không đủ cho workload thật. Kết hợp với
`log_temp_files` để biết **câu query nào** gây ra.

Từ PostgreSQL 16, `pg_stat_io` cho bức tranh chi tiết hơn:

```sql
SELECT backend_type, object, context, reads, writes, extends
FROM pg_stat_io
WHERE reads > 0 OR writes > 0
ORDER BY writes DESC NULLS LAST LIMIT 10;
```

`context = 'vacuum'` với `reads` cao nghĩa là autovacuum đang chiếm nhiều I/O — đối chiếu với
Phần 04.

---

## 6. Ngân sách RAM cho một cluster

```text
RAM cần ≈ shared_buffers
        + (số_connection_đồng_thời × số_node × work_mem)
        + (autovacuum_max_workers × maintenance_work_mem)
        + phần chừa cho OS page cache
```

Ví dụ máy 32 GB:

| Hạng mục | Giá trị |
|---|---:|
| `shared_buffers` (25%) | 8 GB |
| `work_mem` × 50 connection × 2 node | 50 × 2 × 32MB ≈ 3,2 GB |
| `maintenance_work_mem` × 3 worker | 3 × 512MB ≈ 1,5 GB |
| Chừa cho OS page cache | ~19 GB |

Phần chừa cho OS page cache **không** phải lãng phí — PostgreSQL dựa vào nó làm cache tầng hai
(Phần 01). Đó là lý do không nên đặt `shared_buffers` quá 25–40% RAM.

Câu hỏi quan trọng nhất khi ước lượng RAM: **working set lớn bao nhiêu?** Đó là phần dữ liệu
thực sự được truy cập thường xuyên, không phải tổng dung lượng database. Database 2 TB mà chỉ
truy cập 50 GB gần đây thì cần RAM cho 50 GB đó.

---

## 7. Những gì bạn nên rút ra từ phần này

1. Mở connection mới đắt hơn dùng lại **74 lần** — nhưng duy trì quá nhiều connection còn tệ hơn.
2. `max_connections` tối ưu ≈ `số core × 2` đến `× 4`. Phần dư xếp hàng ở pooler.
3. Transaction pooling là chế độ đúng, nhưng nó **phá vỡ** prepared statement, `SET` session,
   temp table, và advisory lock mức session.
4. `work_mem` là giới hạn **mỗi node**, không phải mỗi query. Nhân lên rất nhanh.
5. Đặt `work_mem` bằng đúng con số `Disk:` trong plan là chưa đủ.
6. `effective_cache_size` không cấp phát bộ nhớ, chỉ ảnh hưởng quyết định của planner.
7. "Pool đầy mà CPU thấp" thường là transaction bị giữ quá lâu, không phải pool nhỏ.

---

**Tiếp theo:** Phần 12 — Partitioning & Scale.
