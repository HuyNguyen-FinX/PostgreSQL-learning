# Phần 01 — Lab: quan sát kiến trúc đang chạy

> Output trong bài được chạy thật trên PostgreSQL 17.10 với môi trường của Phần 00.
> Cần `lab_big` đã có dữ liệu: `make seed-big`.

---

## Bài 1 — Nhìn thấy toàn bộ process

```bash
make psql
```

```sql
SELECT pid, backend_type, backend_start::time(0) AS bat_dau, state
FROM pg_stat_activity
ORDER BY pid;
```

```text
 pid  |         backend_type         | bat_dau  | state
------+------------------------------+----------+--------
   70 | checkpointer                 | 12:37:28 |
   71 | background writer            | 12:37:28 |
   73 | walwriter                    | 12:37:28 |
   74 | autovacuum launcher          | 12:37:28 |
   75 | logical replication launcher | 12:37:28 |
 2137 | client backend               | 12:56:22 | active
```

Năm process nền có `backend_start` giống hệt nhau — chúng được `postmaster` fork ra cùng
lúc khi cluster khởi động. `client backend` có thời điểm muộn hơn hẳn: nó sinh ra đúng lúc
bạn chạy `make psql`.

Đối chiếu với process thật của hệ điều hành trong container:

```bash
docker compose -f 00-moi-truong/docker/docker-compose.yml exec -T db \
  sh -c 'for p in /proc/[0-9]*; do cmd=$(tr "\0" " " < $p/cmdline 2>/dev/null); [ -n "$cmd" ] && echo "${p#/proc/}  $cmd"; done' | sort -n
```

```text
1     postgres -c config_file=/etc/postgresql/postgresql.conf
70    postgres: checkpointer
71    postgres: background writer
73    postgres: walwriter
74    postgres: autovacuum launcher
75    postgres: logical replication launcher
```

PID trùng khớp với `pg_stat_activity`. PID 1 là `postmaster` — process cha, cũng chính là
PID 1 của container.

Chú ý PostgreSQL đặt tên process rất tử tế: `postgres: checkpointer`. Trên một server thật,
`ps -ef | grep postgres` cho bạn biết ngay ai đang làm gì mà chưa cần vào database.

---

## Bài 2 — Một connection là một process thật

Mở 20 connection bằng `pgbench` và giữ chúng trong 10 giây:

```bash
cd 00-moi-truong/docker
docker compose exec -T db sh -c 'echo "SELECT pg_sleep(10);" > /tmp/sleep.sql'
docker compose exec -T db pgbench -U lab -d lab -n -f /tmp/sleep.sql -c 20 -T 10 &
```

Trong lúc nó chạy, ở terminal khác:

```sql
SELECT backend_type, count(*) FROM pg_stat_activity GROUP BY backend_type ORDER BY 2 DESC;
```

```text
         backend_type         | count
------------------------------+-------
 client backend               |    21
 walwriter                    |     1
 autovacuum launcher          |     1
 logical replication launcher |     1
 background writer            |     1
 checkpointer                 |     1
```

Và đếm process ở tầng hệ điều hành:

```bash
docker compose exec -T db sh -c 'ls -d /proc/[0-9]* | wc -l'
```

```text
29
```

21 client backend (20 của `pgbench` + 1 của chính bạn) + 5 process nền + `postmaster` +
vài process phụ của container.

**Kết luận cần rút ra:** `max_connections` không phải một con số cấu hình vô hại. Đặt nó
bằng 500 nghĩa là cho phép hệ điều hành tạo tới 500 process, mỗi process có bộ nhớ riêng và
đều tranh nhau CPU. Trên máy 8 core, 500 process đồng thời chủ yếu dành thời gian để
context switch.

---

## Bài 3 — Đo chi phí của việc mở connection

Đây là phép đo có ảnh hưởng lớn nhất tới cách bạn viết application.

```bash
docker compose exec -T db sh -c 'echo "SELECT 1;" > /tmp/q.sql'

# A. Dùng lại connection
docker compose exec -T db pgbench -U lab -d lab -n -f /tmp/q.sql -c 8 -T 5

# B. Mở connection mới cho mỗi transaction
docker compose exec -T db pgbench -U lab -d lab -n -f /tmp/q.sql -c 8 -T 5 -C
```

```text
A:  latency average = 0.067 ms      tps = 119016.329902
B:  latency average = 5.003 ms      tps =   1599.120054
```

| | Latency | TPS |
|---|---:|---:|
| Dùng lại connection | 0,067 ms | 119.016 |
| Mở mới mỗi lần (`-C`) | 5,003 ms | 1.599 |
| **Tỷ lệ** | **75×** | **74×** |

Cùng một câu `SELECT 1`, cùng một database, cùng một máy. Toàn bộ khác biệt là chi phí bắt
tay TCP, xác thực, `fork()` một process mới, và dựng lại cache cục bộ của backend.

5 mili-giây nghe có vẻ nhỏ. Nhưng nếu API của bạn mở connection mới cho mỗi request và mục
tiêu p99 là 50ms, bạn vừa tiêu 10% ngân sách latency trước khi chạy câu query đầu tiên. Và
dưới tải cao, chi phí `fork()` còn tăng thêm.

**Đây là lý do connection pool là yêu cầu cơ bản, không phải tối ưu hóa nâng cao.**

---

## Bài 4 — Parser và Analyzer là hai chặng khác nhau

```sql
SELEC * FROM orders;
```

```text
ERROR:  syntax error at or near "SELEC"
LINE 1: SELEC * FROM orders;
        ^
```

```sql
SELECT khong_ton_tai FROM orders;
```

```text
ERROR:  column "khong_ton_tai" does not exist
LINE 1: SELECT khong_ton_tai FROM orders;
               ^
```

Câu thứ nhất chết ở **Parser** — nó chỉ kiểm tra ngữ pháp SQL và hoàn toàn không biết trong
database của bạn có bảng nào. Câu thứ hai qua được Parser (đúng ngữ pháp) nhưng chết ở
**Analyzer**, chặng tra catalog để phân giải tên.

Kiểm chứng rằng Parser thật sự không tra catalog:

```sql
SELECT * FROM bang_hoan_toan_khong_ton_tai;
```

```text
ERROR:  relation "bang_hoan_toan_khong_ton_tai" does not exist
```

Vẫn là lỗi của Analyzer, không phải syntax error — dù bảng không hề tồn tại.

**Vì sao điều này hữu ích trong công việc:** khi log ứng dụng báo `syntax error`, vấn đề
nằm ở chuỗi SQL mà code sinh ra (thường là nối chuỗi sai, hoặc thiếu tham số). Khi báo
`does not exist`, chuỗi SQL đúng nhưng schema hoặc `search_path` không như bạn tưởng —
thường gặp khi migration chưa chạy, hoặc khi kết nối nhầm database.

---

## Bài 5 — Rewriter làm view biến mất

```sql
CREATE VIEW v_don_hang_lon AS
SELECT id, user_id, total_amount FROM orders WHERE total_amount > 5000;

EXPLAIN (COSTS OFF)
SELECT count(*) FROM v_don_hang_lon WHERE user_id = 42;
```

```text
                              QUERY PLAN
-----------------------------------------------------------------------
 Aggregate
   ->  Seq Scan on orders
         Filter: ((total_amount > '5000'::numeric) AND (user_id = 42))
```

Trong plan không còn chữ `v_don_hang_lon` nào. Rewriter đã thay view bằng định nghĩa của nó,
và Planner gộp hai điều kiện thành một `Filter` duy nhất.

Đây là bằng chứng cho câu trả lời của một tranh luận thường gặp: **view không tự nó làm
query chậm đi.**

---

## Bài 6 — Nhưng không phải view nào cũng vậy: optimization fence

Tạo một view có window function:

```sql
CREATE VIEW v_xep_hang AS
SELECT id, user_id, total_amount,
       row_number() OVER (ORDER BY total_amount DESC) AS hang
FROM orders;

EXPLAIN (COSTS OFF) SELECT * FROM v_xep_hang WHERE user_id = 42;
```

```text
                    QUERY PLAN
--------------------------------------------------
 Subquery Scan on v_xep_hang
   Filter: (v_xep_hang.user_id = 42)
   ->  WindowAgg
         ->  Sort
               Sort Key: orders.total_amount DESC
               ->  Seq Scan on orders
```

Lần này khác hẳn. Hãy đọc plan **từ dưới lên**:

1. `Seq Scan on orders` — đọc toàn bộ 1 triệu row.
2. `Sort` — sắp xếp cả 1 triệu row theo `total_amount`.
3. `WindowAgg` — đánh số thứ tự cho cả 1 triệu row.
4. `Filter: (user_id = 42)` — **bây giờ mới** lọc, còn lại vài chục row.

Điều kiện `user_id = 42` **không** được đẩy vào trong. Và nó không được đẩy vào là **đúng**:
`row_number()` được tính trên toàn bộ bảng; nếu lọc trước rồi mới đánh số, kết quả sẽ khác
hẳn về mặt ngữ nghĩa. PostgreSQL buộc phải làm đúng thứ tự.

Đây gọi là **optimization fence** — một rào chắn mà điều kiện không vượt qua được. Các cấu
trúc tạo ra fence:

| Cấu trúc | Có phải fence không |
|---|---|
| View đơn giản (chỉ `SELECT ... WHERE`) | Không |
| Window function | **Có** |
| `DISTINCT` | **Có** trong đa số trường hợp |
| `LIMIT` bên trong subquery hoặc view | **Có** |
| `GROUP BY` | Điều kiện trên **grouping column** vẫn đẩy vào được; trên aggregate thì không |
| CTE `WITH ... AS (...)` | Từ PostgreSQL 12: **không** (được inline). Trước đó: có |
| CTE `WITH ... AS MATERIALIZED (...)` | **Có** — bạn tự yêu cầu như vậy |

Bài học mang sang production: khi một view "đơn giản" đột nhiên chậm khủng khiếp, hãy kiểm
tra xem trong định nghĩa của nó có window function, `DISTINCT` hay `LIMIT` không. Đó thường
là nguyên nhân.

Dọn dẹp:

```sql
DROP VIEW v_xep_hang;
DROP VIEW v_don_hang_lon;
```

---

## Bài 7 — `shared_buffers` đang giữ những gì

Trong `lab_big`:

```sql
SELECT COALESCE(c.relname, '(trống / hệ thống)') AS doi_tuong,
       count(*) AS so_buffer,
       pg_size_pretty(count(*) * 8192::bigint) AS dung_luong
FROM pg_buffercache b
LEFT JOIN pg_class c ON c.relfilenode = b.relfilenode
GROUP BY 1
ORDER BY 2 DESC
LIMIT 6;
```

```text
     doi_tuong      | so_buffer | dung_luong
--------------------+-----------+------------
 (trống / hệ thống) |     20314 | 159 MB
 payments           |      8665 | 68 MB
 users              |      2276 | 18 MB
 payments_pkey      |       698 | 5584 kB
 order_items        |       423 | 3384 kB
 orders             |       102 | 816 kB
```

Kết quả trên máy bạn sẽ khác, vì nó phụ thuộc vào việc bạn vừa chạy query nào. Đó chính là
điểm cần thấy: **buffer cache phản ánh lịch sử truy cập gần đây**, không phản ánh cấu trúc
database.

Hai điều đáng chú ý:

- `order_items` là bảng lớn nhất (216 MB) nhưng chỉ chiếm 3.384 kB trong cache. Bảng lớn
  không đồng nghĩa với chiếm nhiều cache.
- 159 MB trong tổng 256 MB đang trống hoặc giữ catalog. Cluster này vừa khởi động lại và
  chưa chạy tải thật.

Thử làm nóng cache có chủ ý:

```sql
SELECT pg_prewarm('orders');
```

```text
 pg_prewarm
------------
       9163
```

9.163 page (72 MB) vừa được nạp thẳng vào `shared_buffers`. Chạy lại câu query đếm buffer ở
trên, `orders` sẽ nhảy lên đầu bảng.

`pg_prewarm` rất hữu ích khi so sánh hiệu năng: nó đảm bảo hai lần đo cùng xuất phát từ
trạng thái cache giống nhau, thay vì lần đầu đo tốc độ đĩa còn lần sau đo tốc độ RAM.

---

## Bài 8 — Generic plan và custom plan

Bài này tái hiện một loại sự cố rất khó chẩn đoán: query nhanh vài lần đầu rồi chậm hẳn.

Trong `lab_big`, tạo index tạm và chuẩn bị một prepared statement:

```sql
CREATE INDEX idx_tam_country ON users(country_code);
ANALYZE users;

PREPARE p(char(2)) AS SELECT count(*) FROM users WHERE country_code = $1;
```

Chạy 7 lần liên tiếp và xem plan:

```sql
EXPLAIN (COSTS OFF) EXECUTE p('DE');
```

Kết quả: cả 7 lần đều giữ nguyên custom plan, với `Index Cond: (country_code = 'DE'::bpchar)`.

**Vì sao không chuyển sang generic plan sau 5 lần?** Vì PostgreSQL có so sánh chi phí.
Sau 5 lần chạy custom, nó thử lập generic plan, thấy generic **đắt hơn hẳn**, nên quyết định
tiếp tục dùng custom. Đây là hành vi đúng.

Giờ ép nó dùng generic plan để thấy điều gì bị tránh:

```sql
SET plan_cache_mode = force_generic_plan;
EXPLAIN (ANALYZE, TIMING OFF, SUMMARY OFF) EXECUTE p('DE');
```

Đặt cạnh nhau:

```text
-- auto (custom plan)
 Aggregate  (cost=87.90..87.91 rows=1)                     (actual rows=1)
   ->  Index Only Scan using idx_tam_country on users
         (cost=0.29..77.50 rows=4160)                      (actual rows=4000)
         Index Cond: (country_code = 'DE'::bpchar)

-- force_generic_plan
 Aggregate  (cost=838.79..838.80 rows=1)                   (actual rows=1)
   ->  Index Only Scan using idx_tam_country on users
         (cost=0.29..738.79 rows=40000)                    (actual rows=4000)
         Index Cond: (country_code = $1)
```

| | Ước lượng row | Thực tế | Sai số | Cost |
|---|---:|---:|---:|---:|
| Custom plan | 4.160 | 4.000 | 4% | 87,90 |
| Generic plan | 40.000 | 4.000 | **10 lần** | 838,79 |

Con số 40.000 không ngẫu nhiên: `users` có 200.000 row và `country_code` có 5 giá trị khác
nhau. Không biết tham số là gì, planner chỉ còn cách giả định phân bố đều: `200000 / 5 = 40000`.

Nhưng dữ liệu **không** phân bố đều — `DE` chỉ chiếm 2%.

Ở ví dụ này cả hai vẫn ra cùng một hình dạng plan, nên hậu quả chưa nghiêm trọng. Trong một
câu query có join, sai số 10 lần ở tầng dưới sẽ nhân lên qua từng tầng, và planner có thể
chọn Nested Loop thay vì Hash Join — chênh lệch khi đó tính bằng phút chứ không phải mili-giây.
Phần 06 và Phần 07 sẽ dựng lại đúng tình huống đó.

**Cách xử lý khi gặp trên production:**

```sql
SET plan_cache_mode = force_custom_plan;
```

Đặt được ở mức session, hoặc mức role bằng `ALTER ROLE ... SET`. Cái giá là phải lập plan
lại mỗi lần chạy — thường rẻ hơn nhiều so với việc chạy sai plan.

Dọn dẹp:

```sql
RESET plan_cache_mode;
DEALLOCATE p;
DROP INDEX idx_tam_country;
```

---

## Bài 9 — `pg_stat_activity` như một bảng điều khiển

Đây là câu query bạn nên thuộc, vì nó là thứ đầu tiên chạy khi có sự cố:

```sql
SELECT pid,
       state,
       wait_event_type,
       wait_event,
       now() - query_start          AS thoi_gian_chay,
       now() - xact_start           AS thoi_gian_transaction,
       left(query, 50)              AS query
FROM pg_stat_activity
WHERE backend_type = 'client backend'
  AND pid <> pg_backend_pid()
ORDER BY thoi_gian_chay DESC NULLS LAST;
```

Tự tạo một tình huống để nhìn thấy nó hoạt động. **Terminal A:**

```sql
BEGIN;
UPDATE users SET status = 'banned' WHERE id = 1;
-- không commit
```

**Terminal B** chạy câu query trên:

```text
 pid  |        state        | wait_event_type | wait_event | thoi_gian_chay | thoi_gian_transaction
------+---------------------+-----------------+------------+----------------+-----------------------
  978 | idle in transaction | Client          | ClientRead | 00:00:03.1     | 00:00:41.7
```

Hãy đọc kỹ hai cột thời gian:

- `thoi_gian_chay` = 3 giây — câu lệnh cuối cùng đã chạy xong 3 giây trước.
- `thoi_gian_transaction` = 41 giây — **transaction đã mở 41 giây**.

Chênh lệch giữa hai con số này chính là thời gian backend nằm không mà vẫn giữ transaction.

`idle in transaction` là trạng thái cần cảnh báo trên mọi hệ thống production, vì:

1. Nó giữ mọi lock mà transaction đã lấy.
2. Nó giữ một snapshot cũ, khiến VACUUM **không dọn được dead tuple trên toàn bộ database** —
   không chỉ bảng nó đang chạm. Phần 04 sẽ chứng minh.

Câu query tìm thủ phạm:

```sql
SELECT pid, now() - xact_start AS mo_bao_lau, state, left(query, 60) AS query_cuoi
FROM pg_stat_activity
WHERE state = 'idle in transaction'
  AND now() - xact_start > interval '1 minute'
ORDER BY 2 DESC;
```

Và biện pháp phòng ngừa ở mức cluster:

```sql
-- Tự động hủy transaction nằm không quá 5 phút
ALTER SYSTEM SET idle_in_transaction_session_timeout = '5min';
SELECT pg_reload_conf();
```

Nhớ `ROLLBACK;` ở terminal A khi xong.

---

## Checklist trước khi sang Phần 02

- [ ] Liệt kê được 5 process nền và nói được mỗi cái làm gì.
- [ ] Giải thích được vì sao `max_connections = 500` là quyết định tốn kém.
- [ ] Tự đo lại được chênh lệch ~74 lần giữa có và không có connection pool.
- [ ] Phân biệt được `syntax error` và `does not exist` thuộc chặng nào.
- [ ] Chỉ ra được trong plan chỗ nào chứng minh view đã bị Rewriter mở rộng.
- [ ] Nêu được ít nhất 3 cấu trúc tạo optimization fence.
- [ ] Giải thích được con số 40.000 trong generic plan đến từ đâu.
- [ ] Biết câu query tìm session `idle in transaction`.

---

**Tiếp theo:** [bai-tap.md](bai-tap.md), rồi Phần 02 — Storage layer.
