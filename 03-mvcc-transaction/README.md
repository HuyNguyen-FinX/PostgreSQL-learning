# Phần 03 — MVCC & Transaction

> **Mục tiêu:** giải thích được vì sao hai session nhìn thấy dữ liệu khác nhau tại cùng một
> thời điểm, và biết chọn isolation level nào cho từng bài toán.

---

## 1. Vấn đề mà MVCC giải quyết

Hai transaction cùng chạm một row: một cái đọc, một cái ghi. Có ba cách xử lý:

| Cách | Cơ chế | Cái giá |
|---|---|---|
| Khóa đọc | Người đọc chặn người ghi và ngược lại | Đọc nhiều là hệ thống đứng |
| Đọc bẩn | Cho đọc dữ liệu chưa commit | Sai dữ liệu |
| **MVCC** | Giữ nhiều version, mỗi transaction đọc version phù hợp với mình | **Dead tuple** |

PostgreSQL chọn MVCC. Khẩu quyết cần thuộc:

> **Đọc không chặn ghi, ghi không chặn đọc.**

Cái giá là mỗi lần ghi đều sinh ra một version cũ cần được dọn. Đó là lý do Phần 04 (VACUUM)
tồn tại, và vì sao gần như mọi sự cố bloat trên PostgreSQL đều bắt nguồn từ đây.

---

## 2. Cơ chế: `xmin`, `xmax`, `ctid`

### 2.1. Ba trường quyết định tất cả

Mỗi tuple trong heap mang theo:

| Trường | Ý nghĩa |
|---|---|
| `t_xmin` | ID của transaction đã **tạo ra** version này |
| `t_xmax` | ID của transaction đã **xóa hoặc cập nhật** version này. `0` = chưa ai |
| `t_ctid` | Con trỏ tới version **mới hơn**. Trỏ về chính nó = đây là version mới nhất |

### 2.2. Quan sát trực tiếp

```sql
CREATE TABLE mv (id int PRIMARY KEY, v text);
INSERT INTO mv VALUES (1, 'ban_dau');
SELECT ctid, xmin, xmax, id, v FROM mv;
```

```text
  ctid | xmin | xmax | id |    v
-------+------+------+----+---------
 (0,1) |  879 |    0 |  1 | ban_dau
```

Transaction 879 tạo ra row này. `xmax = 0` — chưa ai xóa.

Bây giờ `UPDATE` và nhìn vào page:

```sql
UPDATE mv SET v = 'sua_lan_1' WHERE id = 1;

SELECT lp, t_ctid, t_xmin, t_xmax,
       heap_tuple_infomask_flags(t_infomask, t_infomask2)
FROM heap_page_items(get_raw_page('mv', 0));
```

```text
 lp | t_ctid | t_xmin | t_xmax |            cờ
----+--------+--------+--------+------------------------------------------
  1 | (0,2)  |    879 |    879 | HEAP_HOT_UPDATED
  2 | (0,2)  |    879 |      0 | HEAP_UPDATED, HEAP_ONLY_TUPLE, HEAP_XMAX_INVALID
```

Đây là toàn bộ MVCC gói trong một bảng hai dòng:

- **`lp = 1`** là version cũ. `t_xmax = 879` — đã bị transaction 879 cập nhật. `t_ctid = (0,2)`
  — **trỏ sang version mới**. Cờ `HEAP_HOT_UPDATED` cho biết đây là mắt xích trong một chuỗi HOT.
- **`lp = 2`** là version mới. `t_xmax = 0` — còn sống. Cờ `HEAP_ONLY_TUPLE` nghĩa là **không
  có index nào trỏ trực tiếp tới nó**; muốn tới được phải đi từ `lp = 1` theo `t_ctid`. Đây
  chính là HOT update của Phần 02, nhìn từ bên trong.

`UPDATE` **không sửa dữ liệu tại chỗ**. Nó là `INSERT` một version mới cộng với đánh dấu
version cũ đã chết.

Sau `DELETE`:

```sql
DELETE FROM mv WHERE id = 1;
```

```text
 lp | t_ctid | t_xmin | t_xmax
----+--------+--------+--------
  1 | (0,2)  |    879 |    879
  2 | (0,2)  |    879 |    879
```

```sql
SELECT tuple_count AS song, dead_tuple_count AS chet, dead_tuple_len AS byte_chet
FROM pgstattuple('mv');
```

```text
 song | chet | byte_chet
------+------+-----------
    0 |    2 |        74
```

Bảng "rỗng" nhưng vẫn chiếm 74 byte dead tuple. **`DELETE` không xóa gì cả** — nó chỉ ghi
`xmax`. Việc thu hồi thật là của VACUUM.

> **Chi tiết đáng chú ý:** trong ví dụ trên `xmin` và `xmax` đều là 879. Vì cả ba câu lệnh
> được gửi trong **một** message tới server nên chúng nằm trong cùng một transaction. Cờ
> `HEAP_COMBOCID` xuất hiện chính vì lý do này: cùng một transaction vừa tạo vừa xóa tuple,
> PostgreSQL phải mã hóa cả command id tạo lẫn command id xóa vào một trường.

---

## 3. Snapshot — cách PostgreSQL quyết định ai thấy gì

### 3.1. Trực giác

**Level 1.** Snapshot giống như chụp một tấm ảnh danh sách "những transaction nào đã xong tại
thời điểm này". Từ đó về sau, transaction của bạn chỉ nhìn thấy kết quả của những transaction
có trong ảnh, bất kể thế giới bên ngoài đã đổi thế nào.

**Level 2 — Backend Engineer.** Snapshot là lý do một report chạy 10 phút vẫn cho ra số liệu
nhất quán, dù dữ liệu bị sửa liên tục trong lúc nó chạy. Cũng là lý do transaction dài chặn
VACUUM: snapshot cũ vẫn "cần" các version cũ, nên chúng chưa được phép dọn.

**Level 3 — Internals.** Một snapshot gồm:

| Thành phần | Ý nghĩa |
|---|---|
| `xmin` | Mọi transaction có id nhỏ hơn giá trị này đều đã kết thúc |
| `xmax` | Mọi transaction có id lớn hơn hoặc bằng giá trị này đều chưa bắt đầu |
| `xip_list` | Danh sách transaction đang chạy dở trong khoảng giữa |

```sql
SELECT pg_current_snapshot();
```

Quy tắc kiểm tra một tuple có hiển thị hay không:

```text
tuple hiển thị  ⟺  t_xmin đã commit VÀ nằm trong snapshot
                   VÀ ( t_xmax = 0
                        HOẶC t_xmax chưa commit
                        HOẶC t_xmax không nằm trong snapshot )
```

### 3.2. Thời điểm lấy snapshot — khác biệt cốt lõi giữa các isolation level

| Isolation level | Lấy snapshot khi nào |
|---|---|
| Read Committed | **Mỗi câu lệnh** lấy một snapshot mới |
| Repeatable Read | **Một snapshot** cho cả transaction, lấy ở câu lệnh đầu tiên |
| Serializable | Như Repeatable Read, cộng thêm theo dõi phụ thuộc đọc/ghi |

Toàn bộ khác biệt hành vi giữa ba mức đều suy ra được từ bảng này.

---

## 4. Isolation level trong thực tế

### 4.1. PostgreSQL chỉ có ba mức, không phải bốn

Chuẩn SQL định nghĩa bốn mức. PostgreSQL chấp nhận cả bốn tên nhưng chỉ cài đặt ba hành vi:
`READ UNCOMMITTED` được xử lý **y hệt** `READ COMMITTED`. PostgreSQL không bao giờ cho đọc
dữ liệu chưa commit — MVCC không có cách nào để làm điều đó.

| Anomaly | Read Committed | Repeatable Read | Serializable |
|---|---|---|---|
| Dirty read | Không bao giờ | Không bao giờ | Không bao giờ |
| Non-repeatable read | **Có thể** | Không | Không |
| Phantom read | **Có thể** | Không | Không |
| Lost update | **Có thể** | Chặn bằng lỗi | Chặn bằng lỗi |
| **Write skew** | **Có thể** | **Có thể** | Không |

Hai ô quan trọng nhất là hai ô cuối cùng bên trái — chúng là nguồn gốc của hầu hết bug dữ
liệu trong hệ thống thật.

### 4.2. Thí nghiệm: Read Committed và Repeatable Read

Kịch bản: A đọc số dư, ngủ 2 giây, đọc lại, rồi trừ 10. Trong lúc A ngủ, B đặt số dư thành 999.

**READ COMMITTED:**

```text
  A: doc_lan_1 = 100
  B: đã UPDATE thành 999 và COMMIT
  A: doc_lan_2 = 999          ← đọc lại ra giá trị KHÁC
  ===> Giá trị cuối: 989
```

Hai lần đọc trong cùng transaction cho hai kết quả khác nhau — **non-repeatable read**. Và
`UPDATE sodu SET tien = tien - 10` cho ra 989, nghĩa là nó lấy giá trị **mới nhất** (999) chứ
không phải giá trị A đã đọc (100).

Hành vi này của Read Committed rất hay bị hiểu sai. Khi một `UPDATE` gặp row vừa bị
transaction khác sửa, PostgreSQL **chờ** transaction kia xong, rồi **đọc lại row** và áp dụng
điều kiện `WHERE` lên giá trị mới. Nó không hủy, không báo lỗi, cứ thế chạy tiếp.

**REPEATABLE READ:**

```text
  A: doc_lan_1 = 100
  B: đã UPDATE thành 999 và COMMIT
  A: doc_lan_2 = 100          ← vẫn thấy giá trị CŨ, snapshot không đổi
  A: ERROR: could not serialize access due to concurrent update
  ===> Giá trị cuối: 999
```

A đọc nhất quán từ đầu tới cuối. Nhưng khi định ghi đè lên row đã bị người khác sửa,
PostgreSQL **từ chối** thay vì âm thầm ghi đè.

Đây là đánh đổi trung tâm:

- **Read Committed:** không bao giờ lỗi, nhưng có thể ghi lên dữ liệu bạn chưa từng nhìn thấy.
- **Repeatable Read:** dữ liệu nhất quán, nhưng **application phải biết retry**.

### 4.3. Lost update

Bài toán kinh điển: hai người cùng rút tiền.

```sql
-- Cả hai session
SELECT tien FROM sodu WHERE id = 1;      -- cả hai đọc 100
-- application tính: 100 - 30 = 70
UPDATE sodu SET tien = 70 WHERE id = 1;  -- cả hai ghi 70
```

Kết quả: rút 60 nhưng số dư chỉ giảm 30. Mất một lần cập nhật.

Ba cách xử lý, theo thứ tự nên ưu tiên:

**Cách 1 — Để database tự tính (tốt nhất khi dùng được):**

```sql
UPDATE sodu SET tien = tien - 30 WHERE id = 1 AND tien >= 30;
```

An toàn ở **mọi** isolation level, kể cả Read Committed, vì phép trừ được thực hiện trên giá
trị mới nhất ngay tại thời điểm ghi. Không cần retry.

**Cách 2 — Khóa tường minh:**

```sql
BEGIN;
SELECT tien FROM sodu WHERE id = 1 FOR UPDATE;   -- session kia phải chờ
-- tính toán trong application
UPDATE sodu SET tien = 70 WHERE id = 1;
COMMIT;
```

Dùng khi logic tính toán phức tạp, không diễn đạt được bằng một câu SQL. Cái giá là
serialization thật sự — Phần 08.

**Cách 3 — Optimistic locking:**

```sql
UPDATE sodu SET tien = 70, version = version + 1
WHERE id = 1 AND version = 5;
-- Nếu số row bị ảnh hưởng = 0 → có người đã sửa → đọc lại và thử lại
```

Phù hợp với ứng dụng web có form chỉnh sửa, nơi khoảng cách giữa đọc và ghi tính bằng phút.

### 4.4. Write skew — anomaly mà Repeatable Read không chặn được

Đây là điểm mà nhiều người ngạc nhiên: **Repeatable Read không đủ an toàn.**

Bài toán: ca trực bệnh viện luôn phải có ít nhất một người. Alice và Bob đều đang trực. Cả
hai cùng lúc xin nghỉ; mỗi người kiểm tra "còn ai khác trực không?" trước khi nghỉ.

```sql
CREATE TABLE truc_ca (ten text PRIMARY KEY, dang_truc boolean);
INSERT INTO truc_ca VALUES ('alice', true), ('bob', true);
```

Mỗi session chạy:

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT count(*) FROM truc_ca WHERE dang_truc;      -- kiểm tra ràng buộc
-- nếu count >= 2 thì được phép nghỉ
UPDATE truc_ca SET dang_truc = false WHERE ten = '<tên mình>';
COMMIT;
```

Kết quả đo được:

```text
=== REPEATABLE READ ===
  A: thay_dang_truc = 2
  B: thay_dang_truc = 2
  ===> Số người còn trực: 0        ← RÀNG BUỘC BỊ PHÁ
```

Cả hai đều thấy 2 người đang trực, cả hai đều kết luận "mình nghỉ được", cả hai đều commit
thành công. Không có lỗi nào. Kết quả: **không còn ai trực**.

Repeatable Read không phát hiện được, vì hai transaction **ghi vào hai row khác nhau**. Không
có xung đột ghi–ghi trực tiếp. Xung đột nằm ở chỗ mỗi transaction **đọc** cái mà transaction
kia **ghi** — và Repeatable Read không theo dõi quan hệ đó.

Đổi sang Serializable:

```text
=== SERIALIZABLE ===
  A: thay_dang_truc = 2
  B: thay_dang_truc = 2
  B: ERROR:  could not serialize access due to read/write dependencies among transactions
  B: DETAIL:  Reason code: Canceled on identification as a pivot, during write.
  B: HINT:  The transaction might succeed if retried.
  ===> Số người còn trực: 1        ← RÀNG BUỘC ĐƯỢC GIỮ
```

### 4.5. Serializable Snapshot Isolation hoạt động thế nào

PostgreSQL cài đặt Serializable bằng **SSI (Serializable Snapshot Isolation)** — không dùng
khóa, mà **theo dõi phụ thuộc**.

Nó ghi lại mỗi transaction đã đọc những gì và ghi những gì, rồi tìm trong đồ thị phụ thuộc
một cấu trúc gọi là **dangerous structure**: một transaction vừa có cạnh đọc–ghi vào, vừa có
cạnh đọc–ghi ra. Transaction ở giữa gọi là **pivot**. Đúng chữ trong thông báo lỗi:
*"Canceled on identification as a pivot"*.

Khi phát hiện, PostgreSQL hủy một transaction trong nhóm.

**Ưu điểm:** đọc vẫn không chặn ghi. Serializable của PostgreSQL không phải khóa toàn cục.

**Cái giá:**

1. **Bắt buộc phải retry.** Không có ngoại lệ. Ứng dụng dùng Serializable mà không xử lý
   `40001` là ứng dụng sẽ lỗi ngẫu nhiên trên production.
2. Có **false positive** — đôi khi hủy cả transaction thật ra không xung đột.
3. Tốn bộ nhớ theo dõi (`max_pred_locks_per_transaction`).

### 4.6. Chọn isolation level nào

| Tình huống | Nên dùng |
|---|---|
| CRUD thông thường, mỗi transaction chạm một entity | Read Committed (mặc định) |
| Cập nhật counter, số dư, tồn kho | Read Committed + `SET x = x - n` hoặc `FOR UPDATE` |
| Báo cáo đọc nhiều bảng, cần số liệu nhất quán | Repeatable Read |
| Có ràng buộc nghiệp vụ **trải trên nhiều row** | **Serializable** + retry |
| Chuyển tiền, đặt chỗ, chống overbooking | **Serializable** + retry, hoặc constraint ở tầng database |

Nguyên tắc thực dụng: **nếu ràng buộc của bạn có thể diễn đạt bằng `UNIQUE`, `CHECK` hoặc
`EXCLUDE` constraint, hãy làm vậy thay vì dựa vào isolation level.** Constraint được kiểm tra
ở tầng thấp hơn, rẻ hơn, và không cần retry.

Ví dụ, ràng buộc "luôn có ít nhất một người trực" khó diễn đạt bằng constraint. Nhưng "không
đặt trùng phòng trong cùng khoảng thời gian" thì diễn đạt được:

```sql
CREATE EXTENSION btree_gist;
ALTER TABLE dat_phong ADD CONSTRAINT khong_trung
  EXCLUDE USING gist (phong_id WITH =, khoang_thoi_gian WITH &&);
```

### 4.7. Retry đúng cách

```sql
-- Mã lỗi cần bắt:
-- 40001  serialization_failure
-- 40P01  deadlock_detected
```

Khuôn mẫu:

```python
for lan_thu in range(5):
    try:
        with conn.transaction():
            chay_nghiep_vu()
        break
    except SerializationFailure:
        if lan_thu == 4:
            raise
        time.sleep(0.05 * (2 ** lan_thu))   # exponential backoff
```

Ba điều bắt buộc:

1. **Retry toàn bộ transaction**, không phải chỉ câu lệnh lỗi. Snapshot cũ đã hỏng.
2. **Có backoff.** Retry ngay lập tức thường xung đột lại đúng như cũ.
3. **Có giới hạn số lần.** Retry vô hạn biến một xung đột thành một sự cố.

Và quan trọng nhất: **nghiệp vụ phải idempotent hoặc nằm trọn trong transaction.** Nếu giữa
chừng có gọi API bên ngoài (trừ tiền, gửi email), retry sẽ thực hiện nó hai lần. Phần 15 nói
về outbox pattern để xử lý chuyện này.

---

## 5. Cái giá của MVCC: dead tuple

Mỗi `UPDATE` và `DELETE` để lại một version chết. Nhìn thấy trực tiếp:

```sql
UPDATE orders SET status = status WHERE id <= 10000;   -- "không đổi gì"

SELECT n_live_tup, n_dead_tup FROM pg_stat_user_tables WHERE relname = 'orders';
```

Câu `UPDATE` gán giá trị cũ vào chính nó, về mặt dữ liệu không đổi gì, nhưng vẫn tạo ra
10.000 dead tuple thật. Đây là lý do:

- `UPDATE ... SET x = x` **không** vô hại.
- Job chạy định kỳ "cập nhật trạng thái" trên bảng lớn là nguồn bloat phổ biến nhất.
- Nên thêm điều kiện `WHERE x IS DISTINCT FROM <giá trị mới>` vào các câu update hàng loạt.

Phần 04 dành trọn cho việc dọn số dead tuple này.

---

## 6. Transaction ID và nguy cơ wraparound

### 6.1. Vấn đề

Transaction ID là số **32 bit** — chỉ khoảng 4,2 tỷ giá trị. PostgreSQL so sánh xid theo kiểu
vòng tròn: với một xid bất kỳ, 2 tỷ giá trị "phía trước" là tương lai, 2 tỷ giá trị "phía sau"
là quá khứ.

Nếu một xid trở nên cũ hơn 2 tỷ transaction, nó sẽ bị hiểu nhầm thành **tương lai**, và mọi
row do nó tạo ra sẽ **biến mất** khỏi tầm nhìn. Mất dữ liệu.

### 6.2. Giải pháp: freeze

VACUUM đánh dấu các tuple đủ cũ và chắc chắn ai cũng thấy được là **frozen** — bật cờ
`HEAP_XMIN_FROZEN` mà bạn đã gặp ở Phần 02. Tuple frozen luôn hiển thị, không cần so sánh xid
nữa.

### 6.3. Theo dõi

```sql
SELECT datname,
       age(datfrozenxid) AS tuoi_xid,
       round(100.0 * age(datfrozenxid) / 2000000000, 2) AS pct_toi_gioi_han
FROM pg_database ORDER BY 2 DESC;
```

Tìm bảng cụ thể:

```sql
SELECT relname, age(relfrozenxid) AS tuoi_xid,
       pg_size_pretty(pg_total_relation_size(oid)) AS kich_thuoc
FROM pg_class WHERE relkind = 'r' ORDER BY age(relfrozenxid) DESC LIMIT 10;
```

Các mốc mặc định:

| `age(relfrozenxid)` | Điều gì xảy ra |
|---|---|
| 50.000.000 | `vacuum_freeze_min_age` — bắt đầu freeze tuple trong lúc vacuum thường |
| 150.000.000 | `autovacuum_freeze_max_age` — autovacuum **bắt buộc** chạy, kể cả khi bảng bị `autovacuum = off` |
| 2.000.000.000 | Cảnh báo nghiêm trọng trong log |
| ~2.100.000.000 | **Cluster từ chối nhận transaction ghi mới** |

Trạng thái cuối cùng là một trong số ít sự cố PostgreSQL có thể làm hệ thống dừng hẳn, và
cách khắc phục là chạy VACUUM — thứ mất hàng giờ trên bảng lớn.

Nguyên nhân gần như luôn là một trong ba:

1. Transaction chạy quá lâu (hoặc `idle in transaction` bị bỏ quên).
2. Replication slot bị bỏ rơi, giữ `xmin` cũ mãi.
3. Prepared transaction bị treo (`pg_prepared_xacts`).

Cả ba đều là chủ đề của Phần 04 và Phần 14.

---

## 7. Subtransaction và `SAVEPOINT`

Mỗi `SAVEPOINT` tạo ra một **subtransaction** với xid riêng.

```sql
BEGIN;
  INSERT INTO t VALUES (1);
  SAVEPOINT sp1;
  INSERT INTO t VALUES (2);
  ROLLBACK TO sp1;          -- chỉ hủy phần sau savepoint
COMMIT;
```

Hữu ích, nhưng có hai chi phí ẩn:

1. **Mỗi subtransaction tiêu một xid**, làm xid tăng nhanh hơn nhiều so với số transaction thật.
2. Khi một transaction có **hơn 64 subtransaction**, phần dư bị đẩy khỏi cache trong shared
   memory và phải đọc từ đĩa (`pg_subtrans`). Hiện tượng này gọi là **SubtransSLRU
   contention**, và nó có thể làm sập hiệu năng toàn cluster.

Điều quan trọng với người viết application: **nhiều ORM và driver tự động tạo savepoint cho
mỗi câu lệnh trong transaction** để mô phỏng khả năng "tiếp tục sau lỗi". Một vòng lặp 10.000
lần `INSERT` trong một transaction có thể âm thầm tạo 10.000 subtransaction.

Kiểm tra:

```sql
SELECT pid, backend_xid, backend_xmin, state, left(query, 50)
FROM pg_stat_activity WHERE backend_xid IS NOT NULL;
```

Nếu thấy `wait_event = SubtransSLRU` hoặc `SubtransBuffer` trong `pg_stat_activity`, đó là
dấu hiệu rõ ràng.

---

## 8. Những gì bạn nên rút ra từ phần này

1. `UPDATE` = `INSERT` version mới + đánh dấu version cũ chết. `DELETE` chỉ ghi `xmax`.
2. Read Committed lấy snapshot mới **mỗi câu lệnh**; Repeatable Read lấy **một lần** cho cả
   transaction. Mọi khác biệt hành vi suy ra từ đây.
3. Read Committed có thể ghi đè lên dữ liệu bạn chưa từng đọc thấy — và không báo lỗi.
4. Repeatable Read **không** chặn được write skew. Chỉ Serializable mới chặn được.
5. Dùng Serializable thì **bắt buộc** phải retry mã lỗi `40001`.
6. Nếu ràng buộc diễn đạt được bằng constraint, hãy dùng constraint thay vì isolation level.
7. `UPDATE ... SET x = x` vẫn sinh dead tuple thật.
8. Transaction dài chặn VACUUM trên **toàn bộ** database, không chỉ bảng nó chạm.
9. `SAVEPOINT` không miễn phí; hơn 64 subtransaction trong một transaction là ngưỡng nguy hiểm.

---

**Tiếp theo:** [lab.md](lab.md) — tự tay tạo ra từng anomaly rồi tự chặn chúng.
