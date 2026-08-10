# Phần 00 — Lab: dựng và kiểm chứng môi trường

> Toàn bộ output trong bài này được chạy thật trên **PostgreSQL 17.10** (image
> `postgres:17-bookworm`, máy Apple Silicon). Con số trên máy bạn có thể lệch ở phần thời
> gian, nhưng **cấu trúc plan và số buffer phải giống hệt** — dữ liệu được sinh với
> `setseed()` cố định.

**Yêu cầu:** Docker đang chạy. Không cần cài `psql` trên máy — ta dùng `psql` bên trong
container.

---

## Bài 1 — Dựng môi trường

Từ thư mục gốc của repository:

```bash
make up
```

Lần đầu chạy sẽ mất một chút để tải image `postgres:17-bookworm`. Sau khi container khởi
động, các script trong `00-moi-truong/docker/init/` tự chạy: tạo database `lab_big`, cài
extension, tạo schema ở cả hai database, và nạp dataset nhỏ vào `lab`.

Kiểm tra:

```bash
make ps
```

Cột trạng thái phải là `Up ... (healthy)`. Nếu là `unhealthy` hoặc container thoát ra ngay,
xem log:

```bash
make logs
```

**Điều cần nhớ:** các script trong `docker/init/` chỉ chạy **một lần duy nhất**, khi volume
`pgdata` còn rỗng. Sửa chúng rồi `make restart` sẽ không có tác dụng. Muốn chúng chạy lại
phải `make reset` (xóa sạch dữ liệu).

---

## Bài 2 — Kiểm chứng cấu hình đã được áp dụng

Đây là bước hay bị bỏ qua, và cũng là nguyên nhân của rất nhiều giờ debug vô ích: bạn sửa
`postgresql.conf` nhưng PostgreSQL đang đọc một file khác.

```bash
make psql
```

Bên trong `psql`:

```sql
SELECT name, setting, unit, context
FROM pg_settings
WHERE name IN (
    'config_file', 'data_directory', 'shared_buffers', 'work_mem',
    'wal_level', 'shared_preload_libraries', 'autovacuum_naptime', 'log_temp_files'
)
ORDER BY name;
```

Kết quả mong đợi:

```text
           name           |               setting                | unit |  context
--------------------------+--------------------------------------+------+------------
 autovacuum_naptime       | 10                                   | s    | sighup
 config_file              | /etc/postgresql/postgresql.conf      |      | postmaster
 data_directory           | /var/lib/postgresql/data             |      | postmaster
 log_temp_files           | 0                                    | kB   | sighup
 shared_buffers           | 32768                                | 8kB  | postmaster
 shared_preload_libraries | pg_stat_statements,auto_explain      |      | postmaster
 wal_level                | logical                              |      | postmaster
 work_mem                 | 4096                                 | kB   | user
```

Ba điều cần đọc ra từ bảng này:

1. **`config_file` trỏ đúng vào file ta mount vào**, chứ không phải file mặc định trong
   thư mục dữ liệu. Nếu nó trỏ vào `/var/lib/postgresql/data/postgresql.conf` thì cấu hình
   của bạn đang không được dùng.

2. **Đơn vị của `setting` không phải lúc nào cũng là đơn vị bạn viết trong file.**
   `shared_buffers = 32768` với `unit = 8kB` nghĩa là `32768 × 8kB = 256MB`. PostgreSQL lưu
   tham số này theo số page. Đây là lý do đọc `pg_settings` cần nhìn cả cột `unit`.
   Muốn đọc ở dạng người đọc được, dùng `current_setting`:

   ```sql
   SELECT current_setting('shared_buffers'), current_setting('work_mem');
   ```

   ```text
    current_setting | current_setting
   -----------------+-----------------
    256MB           | 4MB
   ```

3. **Cột `context` cho biết cách áp dụng thay đổi.** `work_mem` là `user` — đổi được ngay
   trong session bằng `SET`. `autovacuum_naptime` là `sighup` — chỉ cần
   `SELECT pg_reload_conf();`. `shared_buffers` và `shared_preload_libraries` là
   `postmaster` — bắt buộc `make restart`.

Thử ngay sự khác biệt đó:

```sql
SET work_mem = '64MB';
SELECT current_setting('work_mem');
```

```text
 current_setting
-----------------
 64MB
```

```sql
SET shared_buffers = '512MB';
```

```text
ERROR:  parameter "shared_buffers" cannot be changed without restarting the server
```

Thoát `psql` bằng `\q`.

---

## Bài 3 — `psql` ở mức đủ dùng

`psql` không phải là một công cụ tạm bợ để gõ SQL. Nó là công cụ chẩn đoán chính khi bạn
phải vào một database production lúc 2 giờ sáng. Vài meta-command đáng thuộc:

```bash
make psql
```

| Lệnh | Tác dụng |
|---|---|
| `\l` | Liệt kê database |
| `\dt` | Liệt kê bảng |
| `\d orders` | Xem cấu trúc bảng: column, index, constraint, foreign key |
| `\d+ orders` | Như trên, thêm kích thước, chiến lược lưu trữ, mô tả |
| `\di+` | Liệt kê index kèm kích thước |
| `\dx` | Liệt kê extension đã cài |
| `\x` | Bật/tắt chế độ hiển thị dọc — bắt buộc khi row có nhiều column |
| `\timing` | Bật/tắt hiển thị thời gian chạy của mỗi câu lệnh |
| `\watch 2` | Chạy lại câu lệnh vừa rồi mỗi 2 giây |
| `\e` | Mở editor để soạn câu query dài |
| `\c lab_big` | Chuyển sang database khác |
| `\?` | Danh sách toàn bộ meta-command |
| `\q` | Thoát |

Hãy chạy thử:

```sql
\d orders
```

```text
                                       Table "public.orders"
    Column    |           Type           | Collation | Nullable |             Default
--------------+--------------------------+-----------+----------+----------------------------------
 id           | bigint                   |           | not null | generated by default as identity
 user_id      | bigint                   |           | not null |
 status       | text                     |           | not null |
 total_amount | numeric(12,2)            |           | not null | 0
 created_at   | timestamp with time zone |           | not null |
Indexes:
    "orders_pkey" PRIMARY KEY, btree (id)
Foreign-key constraints:
    "orders_user_id_fkey" FOREIGN KEY (user_id) REFERENCES users(id)
Referenced by:
    TABLE "order_items" CONSTRAINT "order_items_order_id_fkey" FOREIGN KEY (order_id) REFERENCES orders(id)
    TABLE "payments" CONSTRAINT "payments_order_id_fkey" FOREIGN KEY (order_id) REFERENCES orders(id)
```

**Hãy dừng lại và đọc kỹ mục `Indexes`.** Bảng `orders` có foreign key trỏ tới `users`,
nhưng chỉ có **đúng một index** là `orders_pkey` trên `id`. Không có index nào trên
`user_id`.

Đây không phải thiếu sót của schema mẫu mà là chủ ý (xem [README.md](README.md#62-schema-cố-tình-thiếu-index)).
Điều quan trọng cần rút ra: **PostgreSQL tự tạo index cho `PRIMARY KEY` và `UNIQUE`, nhưng
không tự tạo index cho `FOREIGN KEY`.** Rất nhiều người tưởng ngược lại. Hệ quả của việc
này sẽ xuất hiện ở Phần 05, Phần 06 và Phần 08.

`\watch` là meta-command đáng giá nhất khi theo dõi sự cố. Ví dụ, theo dõi các connection
đang hoạt động, cập nhật mỗi 2 giây:

```sql
SELECT pid, state, wait_event_type, wait_event, left(query, 50) AS query
FROM pg_stat_activity
WHERE datname = 'lab' AND pid <> pg_backend_pid();
\watch 2
```

Nhấn `Ctrl-C` để dừng.

---

## Bài 4 — Execution Plan đầu tiên

Vẫn trong `psql` ở database `lab`:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM orders WHERE id BETWEEN 1 AND 5000;
```

```text
                                  QUERY PLAN
------------------------------------------------------------------------------
 Aggregate (actual rows=1 loops=1)
   Buffers: shared hit=6 read=13
   ->  Index Only Scan using orders_pkey on orders (actual rows=5000 loops=1)
         Index Cond: ((id >= 1) AND (id <= 5000))
         Heap Fetches: 0
         Buffers: shared hit=6 read=13
 Planning:
   Buffers: shared hit=67 read=6
```

Chưa cần hiểu hết. Ba thứ đáng chú ý ngay từ bây giờ:

- **`Index Only Scan`** — PostgreSQL lấy được toàn bộ dữ liệu cần thiết từ index mà không
  cần đọc bảng.
- **`Heap Fetches: 0`** — xác nhận điều trên: không lần nào phải quay về heap. Nếu con số
  này lớn, "Index Only" chỉ còn là cái tên.
- **`Buffers: shared hit=6 read=13`** — đọc tổng cộng 19 page 8KB. `hit` là lấy được từ
  buffer cache, `read` là phải đi xuống tầng dưới. Chạy lại câu query lần thứ hai, `read`
  sẽ về gần 0 vì dữ liệu đã nằm trong cache.

Hãy chạy lại đúng câu đó lần nữa và so sánh `Buffers`. Đây là lý do **mọi phép đo hiệu năng
đều phải chạy ít nhất hai lần**: lần đầu bạn đang đo tốc độ đĩa, không phải đo query.

Bây giờ chạy đúng câu query đó trên dataset lớn:

```bash
make psql-big
```

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM orders WHERE id BETWEEN 1 AND 5000;
```

Plan giống hệt, `Buffers` gần như y nguyên — dù bảng lớn gấp 50 lần. Đó chính là điều
index làm được: chi phí không tỷ lệ với kích thước bảng.

Giờ thử một câu **không có index nào giúp được**:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM orders WHERE status = 'cancelled';
```

```text
                                QUERY PLAN
---------------------------------------------------------------------------
 Finalize Aggregate (actual rows=1 loops=1)
   Buffers: shared hit=17496
   ->  Gather (actual rows=3 loops=1)
         Workers Planned: 2
         Workers Launched: 2
         Buffers: shared hit=17496
         ->  Partial Aggregate (actual rows=1 loops=3)
               Buffers: shared hit=17496
               ->  Parallel Seq Scan on orders (actual rows=10000 loops=3)
                     Filter: (status = 'cancelled'::text)
                     Rows Removed by Filter: 323333
                     Buffers: shared hit=17496
```

So sánh hai plan:

| | `WHERE id BETWEEN 1 AND 5000` | `WHERE status = 'cancelled'` |
|---|---:|---:|
| Buffer phải đọc | 20 | 17.496 |
| Số row bị loại bỏ | 0 | 970.000 |

Ba điều cần đọc ra:

- **`Rows Removed by Filter: 323333`** — mỗi worker đọc 333.333 row rồi vứt đi 323.333 row.
  Đây là chỉ số bị bỏ qua nhiều nhất khi đọc plan: nó cho biết PostgreSQL đang làm bao nhiêu
  công vô ích.
- **`loops=3`** — có 3 process cùng làm (1 leader + 2 worker), nên `actual rows` là số row
  **trung bình mỗi lần lặp**, không phải tổng. Tổng thật là `10000 × 3 = 30.000`, đúng bằng
  3% của 1 triệu order như thiết kế dataset.
- **`Parallel Seq Scan`** — parallel query chỉ hoạt động vì `docker-compose.yml` đã đặt
  `shm_size: 1gb`. Với mức mặc định 64MB của Docker, nhiều query parallel sẽ lỗi.

---

## Bài 5 — Nạp dataset lớn (nếu chưa có)

Nếu bạn vừa `make reset`, `lab_big` chỉ có schema rỗng. Nạp dữ liệu:

```bash
make seed-big
```

Mất khoảng **35 giây** và tạo ra khoảng **443 MB** dữ liệu. Kiểm tra:

```bash
make sizes
```

```text
── lab ──
    bang     | so_row | kich_thuoc
-------------+--------+------------
 order_items | 50,000 | 4480 kB
 orders      | 20,000 | 1968 kB
 payments    | 18,000 | 1848 kB
 users       | 5,000  | 968 kB
 products    | 1,000  | 224 kB
 categories  | 20     | 64 kB
── lab_big ──
    bang     |  so_row   | kich_thuoc
-------------+-----------+------------
 order_items | 2,500,000 | 216 MB
 orders      | 1,000,000 | 93 MB
 payments    | 900,000   | 87 MB
 users       | 200,000   | 36 MB
 products    | 20,000    | 2952 kB
 categories  | 200       | 72 kB
```

Muốn nạp kích thước khác, truyền biến trực tiếp cho script seed:

```bash
docker compose -f 00-moi-truong/docker/docker-compose.yml exec -T db \
  psql -U lab -d lab_big -v ON_ERROR_STOP=1 \
    -v n_categories=500 -v n_users=1000000 \
    -v n_products=50000 -v n_orders=5000000 \
    -f /sql/02-seed.sql
```

Script seed chạy lại được nhiều lần: nó `TRUNCATE` trước khi nạp.

---

## Bài 6 — Hai session song song

Đây là kỹ năng nền tảng cho toàn bộ Phần 03 (MVCC) và Phần 08 (Lock). Bạn cần **hai
terminal** cùng lúc.

**Terminal A:**

```bash
make psql
```

```sql
BEGIN;
UPDATE users SET status = 'banned' WHERE id = 1;
SELECT status FROM users WHERE id = 1;
```

```text
 status
--------
 banned
```

**Chưa `COMMIT`.** Giữ nguyên terminal A như vậy.

**Terminal B:**

```bash
make psql
```

```sql
SELECT status FROM users WHERE id = 1;
```

```text
 status
--------
 active
```

Hai session, cùng một row, cùng một thời điểm, **hai giá trị khác nhau**.

Đây là MVCC (Multi-Version Concurrency Control). Session A đã ghi ra một version mới của
row, nhưng version đó chưa được commit nên chưa transaction nào khác nhìn thấy. Session B
vẫn đọc version cũ — và quan trọng hơn: **session B không phải chờ**. Nó không bị chặn bởi
việc A đang ghi.

Đây là điểm khác biệt căn bản giữa PostgreSQL và các database dùng khóa đọc: trong
PostgreSQL, **đọc không chặn ghi và ghi không chặn đọc**. Cái giá phải trả là mỗi lần ghi
đều sinh ra một version cũ cần được dọn — chính là dead tuple ở Phần 04.

Vẫn ở terminal B, xem session A đang làm gì:

```sql
SELECT pid, state, wait_event_type, wait_event, left(query, 40) AS query
FROM pg_stat_activity
WHERE datname = 'lab' AND pid <> pg_backend_pid();
```

```text
 pid | state               | wait_event_type | wait_event |                query
-----+---------------------+-----------------+------------+---------------------------------
 978 | idle in transaction | Client          | ClientRead | UPDATE users SET status = 'ban...
```

Trạng thái **`idle in transaction`** đáng để ghi nhớ ngay bây giờ. Nó nghĩa là: có một
transaction đang mở, đã làm gì đó, nhưng hiện không chạy câu lệnh nào — đang chờ client gửi
lệnh tiếp theo.

Trên production, `idle in transaction` kéo dài là một trong những nguyên nhân sự cố phổ
biến nhất: nó giữ lock, và nó chặn VACUUM dọn dead tuple trên **toàn bộ** database. Một
connection bị bỏ quên ở trạng thái này có thể khiến cả cluster phình ra. Phần 04 và Phần 08
sẽ quay lại.

**Terminal A** — trả lại trạng thái ban đầu:

```sql
ROLLBACK;
```

**Terminal B** — kiểm tra lại:

```sql
SELECT status FROM users WHERE id = 1;
```

Giá trị vẫn là `active`, vì A đã rollback.

---

## Bài 7 — Đọc log của PostgreSQL

Mở một terminal riêng để theo dõi log:

```bash
make logs
```

Ở terminal khác, chạy một câu query đủ nặng trên `lab_big`:

```bash
docker compose -f 00-moi-truong/docker/docker-compose.yml exec -T db \
  psql -U lab -d lab_big -c \
  "SELECT o.status, count(*), sum(oi.quantity * oi.unit_price)
   FROM orders o JOIN order_items oi ON oi.order_id = o.id
   GROUP BY o.status ORDER BY 3 DESC;"
```

Trong terminal đang xem log, bạn sẽ thấy hai loại dòng.

**Loại 1 — `log_min_duration_statement` ghi lại câu lệnh chậm:**

```text
2026-08-09 05:25:29.391 GMT [201] lab@lab_big LOG:  duration: 18634.033 ms  statement: INSERT INTO order_items ...
```

**Loại 2 — `auto_explain` ghi lại cả Execution Plan:**

```text
2026-08-09 05:25:29.387 GMT [201] lab@lab_big LOG:  duration: 18238.689 ms  plan:
	Query Text: INSERT INTO order_items (order_id, product_id, quantity, unit_price)
	...
```

Giá trị thật của `auto_explain` nằm ở chỗ này: nó cho bạn plan **của chính lần chạy chậm
đó**, trên production, với dữ liệu và tham số thật. Nếu chỉ có câu query, bạn phải chạy lại
`EXPLAIN ANALYZE` — mà lần chạy lại đó có thể ra plan khác, vì cache đã ấm, vì statistics đã
đổi, vì tham số khác. Rất nhiều sự cố "không tái hiện được" là do vậy.

Nếu query của bạn chạy nhanh hơn 200ms thì sẽ không có gì trong log. Hạ ngưỡng xuống để
thấy mọi thứ:

```sql
SET auto_explain.log_min_duration = 0;
SET log_min_duration_statement = 0;
```

(Nhớ đặt lại sau, nếu không log sẽ ngập.)

Dừng theo dõi log bằng `Ctrl-C`.

---

## Bài 8 — `pg_stat_statements` và một phát hiện bất ngờ

`make psql-big`, rồi:

```sql
SELECT round(mean_exec_time::numeric, 1) AS trung_binh_ms,
       calls,
       rows,
       left(regexp_replace(query, '\s+', ' ', 'g'), 60) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 5;
```

```text
 trung_binh_ms |  calls  |  rows   |                            query
---------------+---------+---------+--------------------------------------------------------------
       18238.7 |       1 | 2500000 | INSERT INTO order_items (order_id, product_id, quantity, uni
        6523.0 |       1 | 1000000 | UPDATE orders o SET total_amount = t.amount FROM ( SELECT or
        5471.6 |       1 |  900000 | INSERT INTO payments (order_id, method, amount, status, crea
           0.0 | 3400000 | 3400000 | SELECT $2 FROM ONLY "public"."orders" x WHERE "id" OPERATOR(
        4581.6 |       1 | 1000000 | INSERT INTO orders (id, user_id, status, total_amount, creat
```

Bốn dòng đầu là các câu lệnh trong script seed. **Dòng thứ tư mới là dòng đáng nói:**

```text
calls = 3.400.000
SELECT $2 FROM ONLY "public"."orders" x WHERE "id" OPERATOR(pg_catalog.=) $1 FOR KEY SHARE OF x
```

Câu này không có trong script seed. Bạn chưa từng viết nó. Nó là **trigger kiểm tra foreign
key** do PostgreSQL tự sinh ra.

Con số 3.400.000 khớp chính xác: 2.500.000 row `order_items` + 900.000 row `payments`. Mỗi
row được insert vào bảng con, PostgreSQL phải chạy một câu query để xác nhận `order_id`
tương ứng có tồn tại trong `orders` hay không, đồng thời giữ `FOR KEY SHARE` để row cha
không bị xóa giữa chừng.

Đây là bài học đầu tiên về **chi phí ẩn**:

- Mỗi foreign key là một chi phí trên đường ghi, không phải một khai báo miễn phí.
- Chi phí đó **không xuất hiện** trong `EXPLAIN ANALYZE` của câu `INSERT` ở dạng dễ thấy.
- Nó chỉ lộ ra khi nhìn vào `pg_stat_statements`.

Điều này **không** có nghĩa là nên bỏ foreign key. Nó có nghĩa là khi bulk insert hàng triệu
row, bạn cần biết mình đang trả giá gì, và cân nhắc các lựa chọn như `COPY`, hoặc tạm bỏ
constraint rồi thêm lại có kiểm chứng. Phần 13 và Phần 15 sẽ bàn kỹ.

Xóa thống kê để bắt đầu đo lại từ đầu:

```sql
SELECT pg_stat_statements_reset();
```

---

## Bài 9 — Kiểm chứng Visibility Map

Bài này chứng minh một điều mà [README.md](README.md#66-vì-sao-ngay-sau-vacuum-full-lại-phải-vacuum-thêm-một-lần-nữa)
đã nêu: `VACUUM FULL` xong thì Index Only Scan ngừng hoạt động cho tới lần `VACUUM` kế tiếp.

Trong `lab_big`:

```sql
SELECT count(*) FILTER (WHERE all_visible) AS page_all_visible,
       (SELECT relpages FROM pg_class WHERE relname = 'orders') AS tong_so_page
FROM pg_visibility_map('orders');
```

```text
 page_all_visible | tong_so_page
------------------+--------------
             9163 |         9163
```

Toàn bộ page đang all-visible. Giờ phá nó bằng `VACUUM FULL`:

```sql
VACUUM FULL orders;

SELECT count(*) FILTER (WHERE all_visible) AS page_all_visible,
       (SELECT relpages FROM pg_class WHERE relname = 'orders') AS tong_so_page
FROM pg_visibility_map('orders');
```

```text
 page_all_visible | tong_so_page
------------------+--------------
                0 |         9163
```

Không còn page nào all-visible. Xem hậu quả:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM orders WHERE id BETWEEN 1 AND 5000;
```

```text
 Aggregate (actual rows=1 loops=1)
   Buffers: shared hit=7 read=188
   ->  Bitmap Heap Scan on orders (actual rows=5000 loops=1)
         Recheck Cond: ((id >= 1) AND (id <= 5000))
         Heap Blocks: exact=176
         ...
```

Index Only Scan đã biến mất, thay bằng Bitmap Heap Scan, và số buffer tăng từ 20 lên 195.

Khôi phục:

```sql
VACUUM (ANALYZE) orders;

EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM orders WHERE id BETWEEN 1 AND 5000;
```

```text
 Aggregate (actual rows=1 loops=1)
   Buffers: shared hit=20
   ->  Index Only Scan using orders_pkey on orders (actual rows=5000 loops=1)
         Index Cond: ((id >= 1) AND (id <= 5000))
         Heap Fetches: 0
         Buffers: shared hit=20
```

Cùng một dữ liệu, cùng một index, cùng một câu query. Chênh lệch gần **10 lần** về số buffer
phải đọc, chỉ vì trạng thái của Visibility Map.

Bài học mang sang production: sau `VACUUM FULL` hoặc `pg_repack`, phải chạy `VACUUM ANALYZE`
ngay, nếu không hệ thống sẽ chậm đi một cách khó hiểu cho tới lần autovacuum kế tiếp.

---

## Bài 10 — Reset

Khi làm hỏng một cái gì đó, hoặc muốn quay về trạng thái sạch:

```bash
make reset
```

Lệnh này xóa hẳn volume `pgdata` rồi dựng lại: chạy lại toàn bộ script init, tạo lại schema,
nạp lại dataset nhỏ. Dataset lớn phải nạp lại bằng `make seed-big`.

Nếu chỉ muốn nạp lại dữ liệu mà không dựng lại container:

```bash
make seed-small
make seed-big
```

Đừng ngại dùng những lệnh này. Môi trường này sinh ra để bị phá.

---

## Checklist trước khi sang Phần 01

- [ ] `make ps` báo `healthy`.
- [ ] `config_file` trỏ đúng vào `/etc/postgresql/postgresql.conf`.
- [ ] `\dx` liệt kê 8 dòng: 7 extension chẩn đoán cộng với `plpgsql` (luôn có sẵn).
- [ ] `make sizes` cho ra đúng số row như trong Bài 5.
- [ ] Bạn đã tự chạy được hai session song song và nhìn thấy hai giá trị khác nhau của cùng một row.
- [ ] Bạn đã thấy `auto_explain` ghi plan ra log.
- [ ] Bạn giải thích được vì sao `Heap Fetches: 0` là điều tốt.

---

## Sự cố hay gặp

| Triệu chứng | Nguyên nhân | Cách xử lý |
|---|---|---|
| `Cannot connect to the Docker daemon` | Docker Desktop chưa chạy | Mở Docker Desktop, chờ đến khi biểu tượng báo running |
| `port is already allocated` | Cổng 5433 đã bị chiếm | Đổi cổng phía host trong `docker-compose.yml`, ví dụ `"5434:5432"` |
| Container `unhealthy`, log báo lỗi trong file `.sql` | Script init lỗi cú pháp | `make logs` để xem dòng lỗi, sửa file, rồi `make reset` |
| Sửa `docker/init/*.sql` mà không thấy tác dụng | Init chỉ chạy khi volume rỗng | `make reset` |
| Sửa `postgresql.conf` mà không thấy tác dụng | Tham số thuộc nhóm `postmaster` | `make restart`; kiểm tra lại cột `context` trong `pg_settings` |
| `could not resize shared memory segment` | `/dev/shm` quá nhỏ | Kiểm tra `shm_size: 1gb` có trong `docker-compose.yml` không |
| `make psql` báo `the input device is not a TTY` | Đang chạy trong môi trường không có TTY | Dùng `docker compose exec -T db psql -U lab -d lab -c "..."` |
| Số liệu khác hoàn toàn so với tài liệu | Dataset được seed bằng version script khác | `make seed-small && make seed-big` |

---

**Tiếp theo:** Phần 01 — Kiến trúc tổng quan PostgreSQL.
