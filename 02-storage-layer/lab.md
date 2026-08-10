# Phần 02 — Lab: mổ một page 8KB

> Cần môi trường Phần 00. Extension `pageinspect`, `pg_visibility`, `pg_freespace` đã cài sẵn.
> `pageinspect` yêu cầu quyền superuser — user `lab` có quyền này.

---

## Bài 1 — Tìm bảng của bạn trên đĩa

```bash
make psql-big
```

```sql
SELECT pg_relation_filepath('orders');
```

```text
 base/16385/16874
```

Xem các file thật:

```bash
docker compose -f 00-moi-truong/docker/docker-compose.yml exec -T db \
  ls -la /var/lib/postgresql/data/base/16385/16874*
```

```text
-rw------- 1 postgres postgres 75063296  .../16874
-rw------- 1 postgres postgres    40960  .../16874_fsm
-rw------- 1 postgres postgres     8192  .../16874_vm
```

Một bảng, ba file. Đối chiếu qua SQL:

```sql
SELECT pg_size_pretty(pg_relation_size('orders', 'main')) AS main,
       pg_size_pretty(pg_relation_size('orders', 'fsm'))  AS fsm,
       pg_size_pretty(pg_relation_size('orders', 'vm'))   AS vm;
```

```text
  main  |  fsm  |     vm
--------+-------+-------------
 72 MB  | 40 kB | 8192 bytes
```

**Tự kiểm chứng phép tính VM:** bảng có bao nhiêu page, và VM cần bao nhiêu byte?

```sql
SELECT relpages,
       relpages * 2 / 8 AS byte_vm_can_thiet
FROM pg_class WHERE relname = 'orders';
```

```text
 relpages | byte_vm_can_thiet
----------+-------------------
     9163 |              2290
```

2.290 byte nhu cầu, file VM 8.192 byte (một page). Visibility Map rẻ tới mức PostgreSQL có
thể tra nó liên tục mà không tốn gì đáng kể — đó là lý do Index Only Scan khả thi.

---

## Bài 2 — Đọc page header

```sql
SELECT * FROM page_header(get_raw_page('orders', 0));
```

```text
 lsn       | 0/3590860
 checksum  | 0
 flags     | 4
 lower     | 456
 upper     | 504
 special   | 8192
 pagesize  | 8192
 version   | 4
 prune_xid | 0
```

Tính ba con số từ đây:

```sql
SELECT lower,
       upper,
       upper - lower        AS byte_trong,
       (lower - 24) / 4     AS so_line_pointer
FROM page_header(get_raw_page('orders', 0));
```

```text
 lower | upper | byte_trong | so_line_pointer
-------+-------+------------+-----------------
   456 |   504 |         48 |             108
```

Kiểm chứng con số 108:

```sql
SELECT count(*) FROM heap_page_items(get_raw_page('orders', 0));
```

```text
 108
```

Khớp. Cách tính: page header chiếm 24 byte đầu, mỗi line pointer 4 byte, nên
`(lower - 24) / 4` chính là số line pointer.

Page này còn **48 byte** trống. Một tuple của `orders` cần khoảng 72 byte cộng 4 byte line
pointer. Vậy page đã thực sự đầy.

**Hệ quả:** một `UPDATE` bất kỳ trên row trong page này **không thể là HOT update** — không
đủ chỗ đặt version mới. Bài 6 sẽ chứng minh trực tiếp.

---

## Bài 3 — Đọc từng tuple

```sql
SELECT lp, lp_off, lp_len, t_xmin, t_xmax, t_ctid, t_hoff
FROM heap_page_items(get_raw_page('orders', 0)) LIMIT 5;
```

```text
 lp | lp_off | lp_len | t_xmin | t_xmax | t_ctid | t_hoff
----+--------+--------+--------+--------+--------+--------
  1 |   8120 |     72 |    773 |      0 | (0,1)  |     24
  2 |   8056 |     64 |    773 |      0 | (0,2)  |     24
  3 |   7984 |     72 |    773 |      0 | (0,3)  |     24
  4 |   7912 |     72 |    773 |      0 | (0,4)  |     24
```

Ba quan sát:

1. **`lp_off` giảm dần** (8120 → 8056 → 7984). Tuple được xếp từ cuối page ngược lên, trong
   khi line pointer xếp từ đầu page xuống.
2. **`lp_len` không đều** (72, 64). Vì `total_amount` kiểu `numeric` — độ dài thay đổi theo
   giá trị.
3. **`t_ctid` trỏ về chính nó** — `(0,1)` ở dòng `lp = 1`. Đây là version mới nhất, không có
   version nào mới hơn.

Nối `ctid` với dữ liệu thật:

```sql
SELECT ctid, id, status, total_amount FROM orders WHERE ctid = '(0,1)';
```

Thử ngược lại — xem `ctid` của một row cụ thể:

```sql
SELECT ctid, id FROM orders WHERE id = 1;
```

**Thí nghiệm nhỏ:** `ctid` có ổn định không?

```sql
BEGIN;
SELECT ctid FROM orders WHERE id = 1;
UPDATE orders SET status = status WHERE id = 1;
SELECT ctid FROM orders WHERE id = 1;
ROLLBACK;
```

`ctid` **thay đổi** dù giá trị `status` được gán lại y hệt. Vì `UPDATE` luôn tạo version mới,
kể cả khi nội dung không đổi. Đây là lý do:

- Không bao giờ dùng `ctid` làm khóa trong application.
- `UPDATE ... SET x = x` **không** phải thao tác vô hại — nó sinh dead tuple thật.

---

## Bài 4 — Đọc tiểu sử của một tuple qua `infomask`

```sql
SELECT t_infomask,
       heap_tuple_infomask_flags(t_infomask, t_infomask2) AS co
FROM heap_page_items(get_raw_page('orders', 0)) LIMIT 1;
```

```text
 t_infomask |                          co
------------+-------------------------------------------------------
      11010 | ("{HEAP_HASVARWIDTH,HEAP_XMIN_COMMITTED,
                 HEAP_XMIN_INVALID,HEAP_XMAX_INVALID,HEAP_UPDATED}",
                {HEAP_XMIN_FROZEN})
```

Từ các cờ này đọc ra được toàn bộ lịch sử của row, và nó khớp với những gì script seed đã làm:

| Cờ | Suy ra điều gì |
|---|---|
| `HEAP_HASVARWIDTH` | Row có column độ dài thay đổi → `total_amount` kiểu `numeric` |
| `HEAP_XMAX_INVALID` | Row chưa bị xóa hay cập nhật thêm lần nào |
| `HEAP_UPDATED` | **Version này sinh ra từ `UPDATE`** → câu `UPDATE orders SET total_amount = ...` trong seed |
| `HEAP_XMIN_FROZEN` | Đã được freeze → `VACUUM FULL` chạy ngay sau đó |

Chú ý `HEAP_XMIN_COMMITTED` và `HEAP_XMIN_INVALID` cùng bật. Trông như mâu thuẫn, nhưng bật
cả hai bit là **quy ước biểu diễn `HEAP_XMIN_FROZEN`**. Đây là lý do luôn dùng
`heap_tuple_infomask_flags()` thay vì tự dịch bit.

---

## Bài 5 — Thứ tự column làm bảng phình 31%

Đây là thí nghiệm có ứng dụng trực tiếp nhất trong phần này.

```sql
CREATE TEMP TABLE t_xau (a int2, b int8, c int2, d int8, e int2);
CREATE TEMP TABLE t_tot (b int8, d int8, a int2, c int2, e int2);

INSERT INTO t_xau SELECT 1,1,1,1,1 FROM generate_series(1, 100000);
INSERT INTO t_tot SELECT 1,1,1,1,1 FROM generate_series(1, 100000);

SELECT 't_xau' AS bang,
       pg_size_pretty(pg_relation_size('t_xau')) AS kich_thuoc,
       (SELECT count(*) FROM heap_page_items(get_raw_page('t_xau', 0))) AS tuple_moi_page
UNION ALL
SELECT 't_tot',
       pg_size_pretty(pg_relation_size('t_tot')),
       (SELECT count(*) FROM heap_page_items(get_raw_page('t_tot', 0)));
```

```text
 bang  | kich_thuoc | tuple_moi_page
-------+------------+----------------
 t_xau | 6672 kB    |            120
 t_tot | 5096 kB    |            157
```

**Cùng column, cùng kiểu, cùng dữ liệu. Chỉ khác thứ tự khai báo. Chênh 31%.**

Xem kích thước một row:

```sql
SELECT pg_column_size(t.*) FROM t_xau t LIMIT 1;
SELECT pg_column_size(t.*) FROM t_tot t LIMIT 1;
```

Nguyên nhân là alignment padding: `int8` phải bắt đầu ở địa chỉ chia hết cho 8, nên mỗi
`int2` đứng ngay trước một `int8` kéo theo 6 byte đệm bị bỏ phí.

**Quy tắc rút ra:** khai báo column theo thứ tự **kích thước giảm dần**, các kiểu độ dài
thay đổi (`text`, `numeric`, `jsonb`) để cuối.

Với bảng 500 GB, 31% là 155 GB — chỉ nhờ sắp lại thứ tự column lúc thiết kế. Sửa sau thì
phải viết lại toàn bộ bảng.

---

## Bài 6 — HOT update và `fillfactor`

Ba bảng khác nhau đúng hai biến số:

```sql
DROP TABLE IF EXISTS h100, h70, h70i;

CREATE TABLE h100 (id int PRIMARY KEY, v int, pad text) WITH (fillfactor = 100);
CREATE TABLE h70  (id int PRIMARY KEY, v int, pad text) WITH (fillfactor = 70);
CREATE TABLE h70i (id int PRIMARY KEY, v int, pad text) WITH (fillfactor = 70);
CREATE INDEX ON h70i(v);          -- CHỈ bảng này có index trên v

INSERT INTO h100 SELECT g, 0, repeat('x', 60) FROM generate_series(1, 20000) g;
INSERT INTO h70  SELECT g, 0, repeat('x', 60) FROM generate_series(1, 20000) g;
INSERT INTO h70i SELECT g, 0, repeat('x', 60) FROM generate_series(1, 20000) g;
VACUUM ANALYZE h100, h70, h70i;
```

Kích thước trước khi update:

```text
 h100    | 1976 kB       ← fillfactor 100: nhét đầy
 h70     | 2808 kB       ← fillfactor 70: chừa 30% chỗ trống
 h70i    | 2808 kB
```

Update toàn bộ:

```sql
UPDATE h100 SET v = v + 1;
UPDATE h70  SET v = v + 1;
UPDATE h70i SET v = v + 1;
```

Chờ vài giây cho bộ đếm thống kê được ghi (nó cập nhật bất đồng bộ), rồi:

```sql
SELECT relname, n_tup_upd AS tong_update, n_tup_hot_upd AS hot_update,
       round(100.0 * n_tup_hot_upd / NULLIF(n_tup_upd, 0), 1) AS ty_le_hot_pct,
       pg_size_pretty(pg_relation_size(relid))  AS heap,
       pg_size_pretty(pg_indexes_size(relid))   AS index_size
FROM pg_stat_user_tables WHERE relname IN ('h100','h70','h70i') ORDER BY relname;
```

```text
 relname | tong_update | hot_update | ty_le_hot_pct |  heap   | index_size
---------+-------------+------------+---------------+---------+------------
 h100    |       20000 |          0 |           0.0 | 3952 kB | 896 kB
 h70     |       20000 |       8424 |          42.1 | 4432 kB | 888 kB
 h70i    |       20000 |          0 |           0.0 | 4432 kB | 1216 kB
```

Ba dòng chứng minh **hai điều kiện độc lập** của HOT update:

| Bảng | Có chỗ trong page? | Column bị sửa không có index? | HOT |
|---|---|---|---|
| `h100` | ✗ (fillfactor 100) | ✓ | **0%** |
| `h70` | ✓ | ✓ | **42,1%** |
| `h70i` | ✓ | ✗ (`v` có index) | **0%** |

Thiếu **bất kỳ** điều kiện nào cũng đủ để HOT không xảy ra.

Chú ý cột `index_size`: `h70i` phình lên 1.216 kB so với 888 kB của `h70`. Đó chính là chi
phí mà HOT giúp tránh — mỗi update phải thêm một entry vào index.

**Bài học cho thiết kế:** mỗi index thừa không chỉ tốn disk và tốn thời gian ghi, nó còn có
thể **vô hiệu hóa HOT update trên toàn bộ bảng**. Trước khi tạo index trên một column bị
update thường xuyên, hãy cân nhắc cái giá này.

Tìm ứng viên cần hạ `fillfactor` trên hệ thống thật:

```sql
SELECT relname, n_tup_upd, n_tup_hot_upd,
       round(100.0 * n_tup_hot_upd / NULLIF(n_tup_upd, 0), 1) AS ty_le_hot_pct
FROM pg_stat_user_tables
WHERE n_tup_upd > 1000
ORDER BY n_tup_upd DESC;
```

Bảng update nhiều mà tỷ lệ HOT thấp là chỗ đáng xem xét.

---

## Bài 7 — TOAST

```sql
DROP TABLE IF EXISTS t_toast;
CREATE TABLE t_toast (id int, mo_ta text, du_lieu text);

INSERT INTO t_toast VALUES (1, 'lặp lại 100k ký tự', repeat('a', 100000));
INSERT INTO t_toast VALUES (2, 'ngẫu nhiên 96k ký tự',
  (SELECT string_agg(md5(g::text || random()::text), '')
   FROM generate_series(1, 3000) g));

SELECT id, length(du_lieu) AS so_ky_tu,
       pg_column_size(du_lieu) AS byte_thuc_luu,
       round(100.0 * pg_column_size(du_lieu) / length(du_lieu), 1) AS ty_le_pct
FROM t_toast ORDER BY id;
```

```text
 id |        mo_ta         | so_ky_tu | byte_thuc_luu | ty_le_pct
----+----------------------+----------+---------------+-----------
  1 | lặp lại 100k ký tự   |   100000 |          1156 |       1.2
  2 | ngẫu nhiên 96k ký tự |    96000 |         96000 |     100.0
```

```sql
SELECT pg_size_pretty(pg_relation_size(c.oid))            AS bang_chinh,
       pg_size_pretty(pg_relation_size(c.reltoastrelid))  AS bang_toast
FROM pg_class c WHERE c.relname = 't_toast';
```

```text
 bang_chinh | bang_toast
------------+------------
 8192 bytes | 104 kB
```

Hai row có số ký tự gần bằng nhau nhưng số phận hoàn toàn khác:

- **Row 1** nén còn 1,2% → dưới ngưỡng ~2 KB → **ở lại page chính**, TOAST không đụng tới.
- **Row 2** gần như ngẫu nhiên, không nén được → **bị đẩy ra bảng TOAST**, tạo 104 kB ở đó.

Bảng chính vẫn chỉ 1 page cho cả hai row.

**Bài học:** `length()` đếm ký tự, `pg_column_size()` đếm byte thật sự lưu. Khi ước lượng
dung lượng hay chi phí I/O, chỉ `pg_column_size()` có ý nghĩa.

Xem chiến lược lưu trữ của từng column:

```sql
SELECT attname, atttypid::regtype AS kieu, attstorage
FROM pg_attribute
WHERE attrelid = 't_toast'::regclass AND attnum > 0;
```

```text
 attname |  kieu   | attstorage
---------+---------+------------
 id      | integer | p            ← PLAIN
 mo_ta   | text    | x            ← EXTENDED
 du_lieu | text    | x            ← EXTENDED
```

**Thí nghiệm về chi phí đọc TOAST.** So sánh `SELECT *` với việc chỉ lấy column cần:

```sql
EXPLAIN (ANALYZE, BUFFERS) SELECT * FROM t_toast;
EXPLAIN (ANALYZE, BUFFERS) SELECT id, mo_ta FROM t_toast;
```

Câu thứ hai không chạm bảng TOAST. Trên bảng thật có column `jsonb` hay `text` lớn, đây là
một trong số ít trường hợp `SELECT *` gây hại thật sự về hiệu năng, chứ không chỉ về phong
cách code.

---

## Bài 8 — Free Space Map và Visibility Map

### FSM

```sql
SELECT count(*) AS page_con_cho,
       pg_size_pretty(sum(avail)::bigint) AS tong_cho_trong
FROM pg_freespace('orders')
WHERE avail > 0;
```

Trên bảng vừa `VACUUM FULL` xong, con số này rất nhỏ — bảng đã được nén chặt.

Giờ tạo chỗ trống rồi xem FSM phản ứng:

```sql
DELETE FROM orders WHERE id % 100 = 0;      -- xóa 1%

-- Ngay sau DELETE, TRƯỚC khi VACUUM:
SELECT count(*) FROM pg_freespace('orders') WHERE avail > 0;
```

Chỗ trống **chưa** xuất hiện trong FSM. Tuple đã chết nhưng chưa ai ghi nhận không gian đó.

```sql
VACUUM orders;

SELECT count(*) AS page_con_cho,
       pg_size_pretty(sum(avail)::bigint) AS tong_cho_trong
FROM pg_freespace('orders') WHERE avail > 0;
```

Bây giờ mới có. Chuỗi nhân quả:

```text
DELETE  →  tuple thành dead, FSM chưa biết
VACUUM  →  ghi không gian trống vào FSM
INSERT  →  đọc FSM, tái sử dụng không gian đó
```

Bỏ VACUUM thì không gian trống vẫn có nhưng **không ai biết để dùng lại**, và bảng cứ dài
mãi ra. Đó chính là cơ chế bloat — nội dung Phần 04.

### VM

```sql
SELECT count(*) FILTER (WHERE all_visible) AS all_visible,
       count(*) FILTER (WHERE all_frozen)  AS all_frozen,
       count(*)                            AS tong_page
FROM pg_visibility_map('orders');
```

Sau `DELETE` ở trên, số `all_visible` giảm mạnh — những page bị chạm không còn "mọi tuple
đều hiển thị với mọi người".

Xem hậu quả lên plan:

```sql
EXPLAIN (ANALYZE, BUFFERS, COSTS OFF, TIMING OFF, SUMMARY OFF)
SELECT count(*) FROM orders WHERE id BETWEEN 1 AND 5000;
```

`Heap Fetches` bây giờ **lớn hơn 0** — Index Only Scan phải quay về heap để kiểm tra từng
tuple. Khôi phục:

```sql
VACUUM (ANALYZE) orders;
```

Chạy lại `EXPLAIN`, `Heap Fetches` về 0.

**Đây là chỉ số cần theo dõi trên production:** `Heap Fetches` lớn trong một Index Only Scan
nghĩa là autovacuum không theo kịp tốc độ ghi, và bạn đang trả tiền cho một Index Only Scan
mà không nhận được lợi ích của nó.

Nạp lại dữ liệu cho các phần sau:

```bash
make seed-big
```

---

## Checklist trước khi sang Phần 03

- [ ] Chỉ ra được ba file (fork) của một bảng và vai trò từng file.
- [ ] Tính được số line pointer trong một page từ `lower`.
- [ ] Giải thích được vì sao `lp_off` giảm dần còn line pointer tăng dần.
- [ ] Chứng minh được `ctid` thay đổi sau `UPDATE ... SET x = x`.
- [ ] Tự tái hiện được chênh lệch 31% do thứ tự column.
- [ ] Nêu được **hai** điều kiện của HOT update và chứng minh từng cái bằng thí nghiệm.
- [ ] Giải thích được vì sao `length()` và `pg_column_size()` cho kết quả khác nhau.
- [ ] Nêu được chuỗi `DELETE → VACUUM → FSM → INSERT`.

---

**Tiếp theo:** [bai-tap.md](bai-tap.md), rồi Phần 03 — MVCC & Transaction.
