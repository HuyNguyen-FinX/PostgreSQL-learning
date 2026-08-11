# Phần 03 — Bài tập và đáp án

> Tự làm hết phần A trước khi xem phần B. Mỗi bài phải kết thúc bằng một **bằng chứng đo được**.

---

## Phần A — Bài tập

### A1. Đọc tiểu sử một row

Tạo một row, `UPDATE` ba lần, `DELETE`, rồi dùng `heap_page_items()` để:

1. Đếm số tuple vật lý tồn tại.
2. Vẽ chuỗi `t_ctid` nối các version với nhau.
3. Chỉ ra version nào là `HEAP_ONLY_TUPLE`, version nào không, và giải thích vì sao.
4. Chạy `VACUUM` rồi đếm lại.

### A2. Snapshot được lấy lúc nào

Với mỗi isolation level (`READ COMMITTED`, `REPEATABLE READ`), xác định **bằng thực nghiệm**
thời điểm snapshot được lấy: lúc `BEGIN`, hay lúc câu lệnh đầu tiên chạy?

**Gợi ý:** `BEGIN;` rồi chờ 5 giây (trong lúc đó session khác `INSERT`), rồi mới `SELECT`.

### A3. Ba cách chống lost update

Dựng bảng `kho(id, ton)` với `ton = 100`. Hai session cùng trừ 30. Cài đủ ba cách ở mục 4.3
của [README.md](README.md), và với mỗi cách:

1. Ghi lại kết quả cuối.
2. Ghi lại session nào phải chờ, session nào bị lỗi.
3. Đo số lần cần retry (nếu có).

### A4. Write skew trong tình huống thật

Thiết kế một ràng buộc nghiệp vụ khác ràng buộc "ca trực" trong lab, ví dụ: *"tổng số tiền
rút từ hai tài khoản của cùng một người không được vượt hạn mức chung"*.

1. Tái hiện write skew dưới `REPEATABLE READ`.
2. Chặn nó bằng `SERIALIZABLE`.
3. Chặn nó bằng một cách **không dùng** `SERIALIZABLE`.

### A5. Đo chi phí của `UPDATE` không đổi gì

Trên `lab_big`:

1. Đo `n_dead_tup` và kích thước bảng.
2. Chạy `UPDATE orders SET status = status WHERE id <= 100000;`
3. Đo lại cả hai.
4. Viết lại câu `UPDATE` để không tạo dead tuple thừa, và chứng minh nó hiệu quả hơn.

### A6. Transaction dài chặn VACUUM ở đâu

1. Mở transaction ở database `lab`, chạm vào bảng `users`.
2. Ở database **`lab_big`**, tạo dead tuple trên `orders` và chạy `VACUUM VERBOSE`.
3. Dead tuple có bị chặn không? Giải thích.
4. Lặp lại nhưng cả hai cùng database.

**Câu hỏi:** phạm vi chặn của một transaction dài là **database** hay **cluster**?

### A7. Đếm subtransaction

Viết một khối `DO` tạo 100 `SAVEPOINT` trong một transaction. Trong lúc chạy, quan sát
`pg_stat_activity` và tìm dấu hiệu của subtransaction.

**Câu hỏi:** vì sao ngưỡng 64 lại quan trọng?

### A8. Kiểm tra nguy cơ wraparound

Viết một câu query duy nhất trả về: database, bảng có `age(relfrozenxid)` cao nhất, phần trăm
so với giới hạn, và **ước lượng còn bao nhiêu ngày** trước khi chạm ngưỡng — dựa trên tốc độ
tiêu thụ xid hiện tại.

**Gợi ý:** đo `txid_current()` hai lần cách nhau một khoảng để tính tốc độ.

---

## Phần B — Đáp án

**A1.** Sau 3 lần `UPDATE` có **4** tuple vật lý (1 gốc + 3 version mới). Chuỗi `t_ctid` nối
`(0,1) → (0,2) → (0,3) → (0,4)`; version cuối trỏ về chính nó.

Tuple đầu tiên **không** có `HEAP_ONLY_TUPLE` vì index trỏ trực tiếp tới nó. Các version sau
có cờ này — chúng chỉ tới được bằng cách đi theo chuỗi `t_ctid` từ tuple đầu (đây là HOT chain
của Phần 02).

Sau `DELETE`, cả 4 đều có `t_xmax` khác 0. Sau `VACUUM`, `pgstattuple` cho `dead_tuple_count = 0`
và các line pointer được giải phóng để tái sử dụng.

Nếu bảng có `fillfactor = 100` và page đầy, chuỗi sẽ **không** phải HOT — version mới nằm ở
page khác và cờ `HEAP_ONLY_TUPLE` không xuất hiện.

**A2.** Cả hai đều lấy snapshot ở **câu lệnh đầu tiên**, không phải lúc `BEGIN`. `BEGIN` chỉ mở
transaction về mặt logic; PostgreSQL trì hoãn việc lấy snapshot cho tới khi thật sự cần.

Kiểm chứng: `BEGIN;` → chờ → session khác `INSERT` và commit → `SELECT` trong transaction cũ
**vẫn thấy** row mới, ở cả hai isolation level.

Muốn lấy snapshot ngay tại `BEGIN`, dùng:

```sql
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT pg_export_snapshot();   -- ép lấy snapshot ngay
```

**A3.** Kết quả:

| Cách | Kết quả cuối | Ai chờ / lỗi | Retry |
|---|---|---|---|
| Đọc rồi ghi (sai) | 70 | Không ai | 0 — **và kết quả sai** |
| `SET ton = ton - 30` | 40 | Session 2 chờ rất ngắn | 0 |
| `FOR UPDATE` | 40 | Session 2 chờ tới khi session 1 commit | 0 |
| Optimistic (`WHERE version = ?`) | 40 | Session 2 nhận 0 row | 1 |

Cách 1 (`SET ton = ton - 30`) là tốt nhất khi diễn đạt được: an toàn ở **mọi** isolation level,
không cần retry, và session thứ hai chỉ chờ đúng khoảng thời gian ghi.

**A4.** Ràng buộc hạn mức chung là ví dụ điển hình của write skew: mỗi transaction đọc tổng của
**cả hai** tài khoản rồi chỉ ghi vào **một** tài khoản. Không có xung đột ghi–ghi.

Ba cách chặn:

1. `SERIALIZABLE` + retry `40001`.
2. Khóa tường minh row "hạn mức chung" bằng `SELECT ... FOR UPDATE` — biến xung đột đọc/ghi
   thành xung đột ghi/ghi mà Repeatable Read phát hiện được.
3. Đưa ràng buộc xuống tầng database: lưu tổng đã rút vào một row riêng và dùng
   `UPDATE ... SET da_rut = da_rut + n WHERE da_rut + n <= han_muc` — khi đó `CHECK` hoặc số
   row bị ảnh hưởng đảm bảo tính đúng.

Cách 3 thường tốt nhất: rẻ nhất, không cần retry, và đúng ở mọi isolation level.

**A5.** `UPDATE orders SET status = status WHERE id <= 100000` tạo đúng **100.000** dead tuple
dù không giá trị nào thay đổi. Kích thước bảng tăng tương ứng.

Cách viết đúng:

```sql
UPDATE orders SET status = 'shipped'
WHERE id <= 100000 AND status IS DISTINCT FROM 'shipped';
```

Dùng `IS DISTINCT FROM` thay vì `<>` để xử lý đúng cả `NULL`. Trên dữ liệu mà 80% row đã đúng
giá trị, cách này giảm dead tuple đi 5 lần.

Đây là một trong những thay đổi rẻ nhất khi tối ưu job chạy định kỳ.

**A6.** Phạm vi chặn là **database**, không phải cluster. Một transaction mở ở `lab` **không**
chặn VACUUM ở `lab_big`.

Lý do: `xmin` được tính theo từng database cho các bảng thường. Nhưng có ngoại lệ quan trọng —
với **shared catalog** (`pg_database`, `pg_authid`…) và với việc tính `datfrozenxid`, ảnh hưởng
lan ra toàn cluster. Đó là lý do một transaction dài ở database bất kỳ vẫn có thể góp phần vào
nguy cơ xid wraparound của cả cluster.

Trong cùng một database, transaction dài chặn VACUUM ở **mọi** bảng — kể cả bảng nó không chạm.

**A7.** Trong `pg_stat_activity`, dấu hiệu là `backend_xid` và `backend_xmin` khác nhau nhiều,
và khi vượt 64 subtransaction thì `wait_event` xuất hiện `SubtransSLRU` hoặc `SubtransBuffer`.

Ngưỡng 64 là kích thước cache subtransaction trong shared memory của mỗi backend. Vượt qua nó,
việc kiểm tra "subtransaction này đã commit chưa" phải đọc từ `pg_subtrans` trên đĩa. Trên hệ
thống nhiều connection, đây là một trong những nguyên nhân sập hiệu năng khó chẩn đoán nhất, vì
nó ảnh hưởng **toàn cluster** chứ không riêng transaction gây ra.

Nguy hiểm hơn: nhiều ORM tự tạo savepoint cho mỗi câu lệnh trong transaction để mô phỏng "tiếp
tục sau lỗi". Một vòng lặp 10.000 `INSERT` có thể âm thầm tạo 10.000 subtransaction.

**A8.**

```sql
WITH toc_do AS (
  SELECT 100000.0 AS xid_moi_giay   -- thay bằng số đo thật của bạn
)
SELECT d.datname,
       c.relname                                   AS bang_gia_nhat,
       age(c.relfrozenxid)                         AS tuoi_xid,
       round(100.0 * age(c.relfrozenxid) / 2000000000, 2) AS pct_gioi_han,
       round((2000000000 - age(c.relfrozenxid))
             / (SELECT xid_moi_giay FROM toc_do) / 86400, 1) AS con_bao_nhieu_ngay
FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
CROSS JOIN (SELECT current_database() AS datname) d
WHERE c.relkind IN ('r','m') AND n.nspname NOT IN ('pg_catalog','information_schema')
ORDER BY age(c.relfrozenxid) DESC
LIMIT 1;
```

Đo tốc độ tiêu thụ xid thật:

```sql
SELECT pg_current_xact_id() AS x1 \gset
SELECT pg_sleep(60);
SELECT (pg_current_xact_id() - :x1) / 60.0 AS xid_moi_giay;
```

Lưu ý: con số này chỉ có ý nghĩa nếu autovacuum **không** freeze kịp. Trên hệ thống khỏe mạnh,
`age(relfrozenxid)` dao động quanh `autovacuum_freeze_max_age` chứ không tăng đơn điệu — nên
"còn bao nhiêu ngày" chỉ là kịch bản xấu nhất khi freeze bị chặn hoàn toàn.
