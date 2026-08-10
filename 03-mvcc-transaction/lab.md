# Phần 03 — Lab: tự tạo ra từng anomaly

> Cần **hai terminal**. Ký hiệu **A** và **B** là hai session `psql` riêng biệt.
> Mở bằng `make psql` ở hai cửa sổ.

---

## Bài 1 — Vòng đời một row qua `xmin` / `xmax`

Toàn bộ bài này chạy trong **một** session.

```sql
DROP TABLE IF EXISTS mv;
CREATE TABLE mv (id int PRIMARY KEY, v text);

INSERT INTO mv VALUES (1, 'ban_dau');
SELECT ctid, xmin, xmax, id, v FROM mv;
```

```text
  ctid | xmin | xmax | id |    v
-------+------+------+----+---------
 (0,1) |  879 |    0 |  1 | ban_dau
```

`xmin` là id transaction vừa tạo row. Xem id transaction hiện tại:

```sql
SELECT pg_current_xact_id_if_assigned();   -- NULL nếu chưa ghi gì
```

Bây giờ `UPDATE` và nhìn thẳng vào page:

```sql
UPDATE mv SET v = 'sua_lan_1' WHERE id = 1;

SELECT lp, t_ctid, t_xmin, t_xmax,
       heap_tuple_infomask_flags(t_infomask, t_infomask2) AS co
FROM heap_page_items(get_raw_page('mv', 0));
```

```text
 lp | t_ctid | t_xmin | t_xmax |                     co
----+--------+--------+--------+---------------------------------------------
  1 | (0,2)  |    879 |    879 | HEAP_HOT_UPDATED
  2 | (0,2)  |    879 |      0 | HEAP_UPDATED, HEAP_ONLY_TUPLE, HEAP_XMAX_INVALID
```

**Đọc kỹ hai dòng này — đây là toàn bộ MVCC:**

- `lp = 1`: version cũ. `t_xmax = 879` (đã bị sửa), `t_ctid = (0,2)` trỏ sang version mới.
- `lp = 2`: version mới. `t_xmax = 0` (còn sống). Cờ `HEAP_ONLY_TUPLE` nghĩa là không index
  nào trỏ tới nó — phải đi từ `lp = 1` mới tới được. Đây chính là chuỗi HOT của Phần 02.

Bảng vẫn chỉ có 1 row logic, nhưng có **2 tuple vật lý**.

```sql
DELETE FROM mv WHERE id = 1;

SELECT lp, t_xmin, t_xmax FROM heap_page_items(get_raw_page('mv', 0));
SELECT tuple_count AS song, dead_tuple_count AS chet, dead_tuple_len AS byte_chet
FROM pgstattuple('mv');
```

```text
 lp | t_xmin | t_xmax
----+--------+--------
  1 |    879 |    879
  2 |    879 |    879

 song | chet | byte_chet
------+------+-----------
    0 |    2 |        74
```

Bảng "rỗng" nhưng vẫn giữ 74 byte. `DELETE` chỉ ghi `xmax`. Dọn dẹp là việc của VACUUM:

```sql
VACUUM mv;
SELECT tuple_count, dead_tuple_count FROM pgstattuple('mv');
```

---

## Bài 2 — Non-repeatable read

**A:**

```sql
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT tien FROM sodu WHERE id = 1;
```

Chuẩn bị bảng trước nếu chưa có:

```sql
DROP TABLE IF EXISTS sodu;
CREATE TABLE sodu (id int PRIMARY KEY, tien int);
INSERT INTO sodu VALUES (1, 100);
```

**B:**

```sql
UPDATE sodu SET tien = 999 WHERE id = 1;
```

**A** (vẫn trong transaction cũ):

```sql
SELECT tien FROM sodu WHERE id = 1;
```

```text
 tien
------
  999      ← khác lần đọc đầu
```

Lặp lại y hệt với `BEGIN ISOLATION LEVEL REPEATABLE READ`:

```text
 tien
------
  100      ← vẫn như cũ
```

Đây là toàn bộ khác biệt giữa hai mức: Read Committed lấy snapshot mới **mỗi câu lệnh**,
Repeatable Read giữ **một** snapshot cho cả transaction.

---

## Bài 3 — Read Committed ghi đè lên dữ liệu chưa từng đọc

Bài này quan trọng hơn Bài 2, vì nó tạo ra bug thật.

Đặt lại: `UPDATE sodu SET tien = 100 WHERE id = 1;`

**A:**

```sql
BEGIN ISOLATION LEVEL READ COMMITTED;
SELECT tien FROM sodu WHERE id = 1;    -- 100
```

**B:**

```sql
UPDATE sodu SET tien = 999 WHERE id = 1;
```

**A:**

```sql
UPDATE sodu SET tien = tien - 10 WHERE id = 1;
COMMIT;
SELECT tien FROM sodu WHERE id = 1;
```

```text
 tien
------
  989
```

**989, không phải 90.** A đọc 100, nhưng câu `UPDATE` áp dụng lên giá trị mới nhất 999.

Khi `UPDATE` của Read Committed gặp row đang bị transaction khác sửa, PostgreSQL **chờ**
transaction kia commit, rồi **đọc lại row** và tính lại `WHERE` trên giá trị mới. Không lỗi,
không cảnh báo.

Đây vừa là tính năng vừa là cạm bẫy:

- **Tính năng:** `UPDATE ... SET tien = tien - 10` luôn đúng ngay cả khi có tranh chấp.
- **Cạm bẫy:** nếu application đọc 100, tính 90 rồi ghi `SET tien = 90`, thì thay đổi của B
  bị mất trắng — lost update.

Chạy lại toàn bộ với `REPEATABLE READ`:

```text
ERROR:  could not serialize access due to concurrent update
```

Repeatable Read từ chối thay vì âm thầm ghi đè. Đổi lại, application **phải retry**.

---

## Bài 4 — Write skew: khi Repeatable Read cũng không đủ

Đây là bài quan trọng nhất của Phần 03.

```sql
DROP TABLE IF EXISTS truc_ca;
CREATE TABLE truc_ca (ten text PRIMARY KEY, dang_truc boolean);
INSERT INTO truc_ca VALUES ('alice', true), ('bob', true);
```

Ràng buộc nghiệp vụ: **luôn phải có ít nhất một người trực.**

**A:**

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM truc_ca WHERE dang_truc;    -- 2, "còn người khác, mình nghỉ được"
```

**B:**

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM truc_ca WHERE dang_truc;    -- 2, cũng nghĩ vậy
```

**A:**

```sql
UPDATE truc_ca SET dang_truc = false WHERE ten = 'alice';
COMMIT;
```

**B:**

```sql
UPDATE truc_ca SET dang_truc = false WHERE ten = 'bob';
COMMIT;
```

Kiểm tra:

```sql
SELECT count(*) FROM truc_ca WHERE dang_truc;
```

```text
 count
-------
     0      ← RÀNG BUỘC BỊ PHÁ, không có lỗi nào cả
```

Cả hai transaction đều commit thành công. Không có xung đột ghi–ghi vì chúng ghi vào **hai
row khác nhau**. Repeatable Read không theo dõi việc mỗi transaction *đọc* cái mà transaction
kia *ghi*.

Bây giờ lặp lại y hệt với `SERIALIZABLE`:

```sql
UPDATE truc_ca SET dang_truc = true;   -- đặt lại
```

**A** và **B** cùng chạy với `BEGIN ISOLATION LEVEL SERIALIZABLE`. Kết quả ở B:

```text
ERROR:  could not serialize access due to read/write dependencies among transactions
DETAIL:  Reason code: Canceled on identification as a pivot, during write.
HINT:  The transaction might succeed if retried.
```

```sql
SELECT count(*) FROM truc_ca WHERE dang_truc;
```

```text
 count
-------
     1      ← ràng buộc được giữ
```

Chú ý chữ **pivot** trong thông báo lỗi — đó là thuật ngữ của thuật toán SSI. PostgreSQL
không khóa gì cả; nó dựng đồ thị phụ thuộc đọc/ghi và phát hiện transaction nằm giữa một
"dangerous structure".

**Bài học mang sang production:** Serializable là mức duy nhất bảo vệ được các ràng buộc trải
trên nhiều row (tồn kho, chỗ ngồi, hạn mức, ca trực). Và dùng nó thì **bắt buộc** phải xử lý
mã lỗi `40001`.

---

## Bài 5 — Transaction dài chặn VACUUM trên toàn bộ database

Bài này giải thích một trong những sự cố production phổ biến nhất.

**A** — mở một transaction rồi bỏ đó:

```sql
BEGIN;
SELECT 1 FROM orders LIMIT 1;   -- chỉ cần chạm vào bất cứ thứ gì để lấy snapshot
-- KHÔNG commit
```

**B** — tạo dead tuple ở một bảng **hoàn toàn khác**:

```sql
UPDATE users SET status = status WHERE id <= 5000;
VACUUM (VERBOSE) users;
```

```text
INFO:  vacuuming "lab.public.users"
INFO:  finished vacuuming: ... 
       5000 dead row versions cannot be removed yet, oldest xmin: 1234
```

**`cannot be removed yet`** — VACUUM chạy nhưng không dọn được gì. Nguyên nhân nằm ở session A,
dù A không hề chạm tới bảng `users`.

Tìm thủ phạm:

```sql
SELECT pid,
       now() - xact_start   AS transaction_mo_bao_lau,
       state,
       backend_xmin,
       left(query, 50)      AS query_cuoi
FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL
ORDER BY xact_start;
```

`backend_xmin` là snapshot cũ nhất mà session đó đang giữ. VACUUM không được phép dọn bất kỳ
tuple nào còn hiển thị với snapshot đó — **ở mọi bảng trong database**.

**A:** `COMMIT;`

**B:** `VACUUM (VERBOSE) users;` — lần này dọn sạch.

Ba nguồn gây tắc nghẽn cần theo dõi trên production:

```sql
-- 1. Transaction đang chạy hoặc idle in transaction
SELECT pid, now() - xact_start AS tuoi, state FROM pg_stat_activity
WHERE backend_xmin IS NOT NULL ORDER BY xact_start LIMIT 5;

-- 2. Replication slot bị bỏ quên
SELECT slot_name, active, age(xmin) AS tuoi_xmin,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS wal_giu_lai
FROM pg_replication_slots;

-- 3. Prepared transaction bị treo
SELECT gid, prepared, age(transaction) AS tuoi FROM pg_prepared_xacts;
```

Cả ba đều giữ `xmin` và đều gây hậu quả giống hệt nhau. Phần 04 và Phần 14 sẽ quay lại.

---

## Bài 6 — Ba cách chống lost update

```sql
DROP TABLE IF EXISTS kho;
CREATE TABLE kho (id int PRIMARY KEY, ton int, version int DEFAULT 1);
INSERT INTO kho VALUES (1, 100, 1);
```

### Cách sai — đọc rồi ghi

**A:** `SELECT ton FROM kho WHERE id = 1;` → 100, tính 100−30 = 70
**B:** `SELECT ton FROM kho WHERE id = 1;` → 100, tính 100−30 = 70
**A:** `UPDATE kho SET ton = 70 WHERE id = 1;`
**B:** `UPDATE kho SET ton = 70 WHERE id = 1;`

Kết quả: 70. Bán 60 nhưng tồn chỉ giảm 30.

### Cách 1 — để database tự tính

```sql
UPDATE kho SET ton = ton - 30 WHERE id = 1 AND ton >= 30;
```

Chạy đồng thời ở hai session: kết quả đúng 40. An toàn ở **mọi** isolation level, không cần
retry. Đây là cách nên dùng bất cứ khi nào diễn đạt được.

Kiểm tra số row bị ảnh hưởng để biết có đủ hàng không:

```sql
-- Nếu UPDATE trả về 0 row → không đủ tồn kho
```

### Cách 2 — `SELECT FOR UPDATE`

```sql
BEGIN;
SELECT ton FROM kho WHERE id = 1 FOR UPDATE;   -- session kia chờ ở đây
UPDATE kho SET ton = 70 WHERE id = 1;
COMMIT;
```

Thử ở hai session để thấy B thực sự bị chặn. Dùng khi logic phức tạp, không viết được bằng
một câu SQL. Cái giá là serialization thật — Phần 08.

### Cách 3 — optimistic locking

```sql
UPDATE kho SET ton = 70, version = version + 1
WHERE id = 1 AND version = 1;
```

Session thứ hai chạy cùng câu đó sẽ ảnh hưởng **0 row** — dấu hiệu để application đọc lại và
thử lại. Phù hợp khi khoảng cách giữa đọc và ghi dài (form web, API stateless).

---

## Bài 7 — Đo dead tuple sinh ra từ update "không đổi gì"

```sql
SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables WHERE relname = 'orders';

UPDATE orders SET status = status WHERE id <= 10000;

-- chờ vài giây cho thống kê được ghi
SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables WHERE relname = 'orders';
```

`n_dead_tup` tăng đúng 10.000 dù không giá trị nào thay đổi.

Cách phòng:

```sql
UPDATE orders SET status = 'shipped'
WHERE id <= 10000
  AND status IS DISTINCT FROM 'shipped';    -- ← chỉ chạm row thật sự cần đổi
```

`IS DISTINCT FROM` thay vì `<>` để xử lý đúng cả trường hợp `NULL`.

Đây là một trong những thay đổi rẻ nhất và hiệu quả nhất khi tối ưu job chạy định kỳ trên
bảng lớn.

---

## Bài 8 — Kiểm tra nguy cơ xid wraparound

```sql
SELECT datname,
       age(datfrozenxid) AS tuoi_xid,
       round(100.0 * age(datfrozenxid) / 2000000000, 4) AS pct_toi_gioi_han
FROM pg_database
ORDER BY 2 DESC;
```

Trên cluster lab, con số này rất nhỏ. Trên production bận rộn, đây là chỉ số phải có cảnh báo.

Tìm bảng có xid cũ nhất:

```sql
SELECT c.relname,
       age(c.relfrozenxid) AS tuoi_xid,
       pg_size_pretty(pg_total_relation_size(c.oid)) AS kich_thuoc
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE c.relkind IN ('r', 'm') AND n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY 2 DESC LIMIT 10;
```

Ngưỡng cần nhớ:

| `age()` | Ý nghĩa |
|---|---|
| 150.000.000 | Autovacuum **bắt buộc** chạy freeze, kể cả bảng đã tắt autovacuum |
| 2.000.000.000 | Cảnh báo nghiêm trọng trong log |
| ~2.100.000.000 | **Cluster ngừng nhận transaction ghi** |

---

## Checklist trước khi sang Phần 04

- [ ] Chỉ ra được version cũ và version mới của một row trong cùng một page.
- [ ] Giải thích được cờ `HEAP_ONLY_TUPLE` nghĩa là gì.
- [ ] Tự tái hiện được non-repeatable read, rồi tự chặn nó.
- [ ] Giải thích được vì sao Bài 3 ra 989 chứ không phải 90.
- [ ] Tự tái hiện được write skew và chứng minh Serializable chặn được.
- [ ] Chứng minh được một transaction ở bảng A chặn VACUUM ở bảng B.
- [ ] Viết được câu `UPDATE` chống lost update mà không cần retry.
- [ ] Biết ba nguồn giữ `xmin` cần theo dõi.

---

**Tiếp theo:** [bai-tap.md](bai-tap.md), rồi Phần 04 — VACUUM & Autovacuum.
