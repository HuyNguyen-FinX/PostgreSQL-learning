# Phần 02 — Bài tập và đáp án

> Tự làm hết phần A trước khi xem phần B.

---

## Phần A — Bài tập

### A1. Tính sức chứa của một page

Với bảng `orders`, hãy tính **bằng tay** rồi kiểm chứng bằng `pageinspect`:

1. Một tuple `orders` chiếm bao nhiêu byte (gồm cả header và line pointer)?
2. Một page 8KB chứa tối đa bao nhiêu tuple?
3. 1.000.000 row cần bao nhiêu page? So sánh với `relpages` thật.

### A2. Thiết kế lại schema cho gọn

Cho bảng sau:

```sql
CREATE TABLE su_kien (
    loai        smallint,
    id          bigint,
    da_xu_ly    boolean,
    thoi_diem   timestamptz,
    ma_nguon    smallint,
    user_id     bigint,
    muc_do      smallint,
    noi_dung    text
);
```

1. Sắp lại thứ tự column cho tối ưu.
2. Tạo cả hai bảng, nạp 500.000 row giống nhau, đo chênh lệch dung lượng.
3. Tính xem với 2 tỷ row thì tiết kiệm được bao nhiêu GB.

### A3. Săn `ctid`

1. Chọn một row bất kỳ, ghi lại `ctid`.
2. `UPDATE` row đó 5 lần liên tiếp, mỗi lần ghi lại `ctid` mới.
3. Chạy `VACUUM`, rồi `UPDATE` thêm 5 lần nữa và ghi lại `ctid`.
4. Giải thích vì sao dãy `ctid` ở bước 3 khác dãy ở bước 2.

### A4. Tự tạo một tuple có NULL và xem `t_hoff` đổi

1. Tạo bảng có 5 column nullable.
2. Insert một row đầy đủ giá trị, một row có NULL.
3. So sánh `t_hoff` của hai tuple bằng `heap_page_items`.
4. Giải thích chênh lệch.

### A5. Tìm ngưỡng TOAST

Bằng thực nghiệm, xác định độ dài chuỗi **không nén được** nhỏ nhất khiến giá trị bị đẩy ra
bảng TOAST. Vẽ bảng: độ dài → `pg_column_size` → kích thước bảng TOAST.

### A6. `EXTERNAL` có thật sự nhanh hơn khi đọc một phần không

1. Tạo hai bảng, một dùng `EXTENDED`, một dùng `EXTERNAL`, cùng chứa 1.000 row với giá trị
   `text` dài 50 KB khó nén.
2. So sánh `EXPLAIN (ANALYZE, BUFFERS)` của `SELECT left(noi_dung, 100) FROM ...` trên hai bảng.
3. So sánh dung lượng đĩa.

### A7. Tối ưu một bảng thật bằng `fillfactor`

Trong `lab_big`, giả sử `orders.status` bị cập nhật liên tục theo vòng đời đơn hàng.

1. Đo tỷ lệ HOT hiện tại sau khi chạy `UPDATE orders SET status = 'shipped' WHERE id % 10 = 0;`
2. Đặt `fillfactor = 80`, chạy `VACUUM FULL`, lặp lại phép đo.
3. Đo thêm mức tăng dung lượng bảng do `fillfactor` thấp.
4. Kết luận: đánh đổi có đáng không, và đáng trong điều kiện nào?

### A8. Chứng minh index chặn HOT

Trên bảng ở A7, tạo thêm `CREATE INDEX ON orders(status);` rồi lặp lại phép đo.

Giải thích kết quả, và rút ra nguyên tắc khi quyết định tạo index trên column hay bị update.

---

## Phần B — Đáp án

**A1.** Tuple `orders`: `lp_len` đo được là 64–72 byte (thay đổi vì `numeric`), cộng 4 byte
line pointer → khoảng 68–76 byte. Page có 8192 − 24 (header) = 8168 byte dùng được, nên
chứa khoảng `8168 / 76 ≈ 107` tuple. Đo thật: **108**. 1.000.000 row cần khoảng
`1000000 / 108 ≈ 9259` page; `relpages` thật là **9163** — sát, chênh vì độ dài tuple không đều.

**A2.** Thứ tự tối ưu: các kiểu 8 byte trước, rồi 2 byte, rồi 1 byte, rồi kiểu độ dài thay đổi:

```sql
CREATE TABLE su_kien (
    id          bigint,       -- 8
    thoi_diem   timestamptz,  -- 8
    user_id     bigint,       -- 8
    loai        smallint,     -- 2
    ma_nguon    smallint,     -- 2
    muc_do      smallint,     -- 2
    da_xu_ly    boolean,      -- 1
    noi_dung    text          -- biến đổi, để cuối
);
```

Bản gốc xen kẽ `smallint` giữa các `bigint` nên mỗi lần đều mất 6 byte padding. Chênh lệch
thực đo thường vào khoảng 15–25% tùy độ dài `noi_dung`. Với 2 tỷ row và tiết kiệm 16 byte
mỗi row, đó là khoảng **30 GB**.

**A3.** Ở bước 2, mỗi `UPDATE` đặt version mới vào page hiện tại nếu còn chỗ, nên `ctid` tăng
dần trong cùng page: `(0,5)`, `(0,6)`, `(0,7)`… Khi page hết chỗ, version mới nhảy sang page
khác.

Sau `VACUUM` ở bước 3, các line pointer của version cũ được giải phóng và **tái sử dụng**,
nên `ctid` mới có thể quay lại các số nhỏ đã dùng trước đó. Đây là bằng chứng trực tiếp rằng
`ctid` không chỉ thay đổi mà còn có thể **lặp lại giá trị cũ** — lý do tuyệt đối không dùng
nó làm khóa.

**A4.** Tuple không có NULL: `t_hoff = 24`. Tuple có NULL: `t_hoff = 32`.

Khi tuple có ít nhất một NULL, PostgreSQL bật cờ `HEAP_HASNULL` và thêm một **null bitmap**
ngay sau header cố định — mỗi column một bit. Bitmap đó rồi được MAXALIGN lên bội số của 8,
nên header nhảy từ 24 lên 32 byte.

Hệ quả thực tế: với bảng có nhiều column nullable và nhiều row chứa NULL, mỗi row tốn thêm
8 byte. Nhưng đừng vì thế mà đặt `NOT NULL DEFAULT ''` bừa bãi — giá trị rỗng vẫn tốn chỗ, và
đánh mất khả năng phân biệt "không có giá trị" với "giá trị rỗng".

**A5.** Ngưỡng `TOAST_TUPLE_THRESHOLD` khoảng **2.000 byte** (chính xác là 2.032 trong cấu
hình mặc định). PostgreSQL bắt đầu TOAST khi **toàn bộ tuple** vượt ngưỡng đó, không phải khi
một column vượt.

Với dữ liệu không nén được, chuỗi khoảng 2.000 ký tự trở lên bắt đầu bị đẩy ra ngoài. Với
dữ liệu nén tốt, có thể lưu 100.000 ký tự mà vẫn nằm inline — như row 1 trong lab.

**A6.** `EXTERNAL` thắng rõ ở phép đọc một phần. Với `EXTENDED`, `left(noi_dung, 100)` buộc
PostgreSQL đọc **toàn bộ** các chunk và giải nén hết mới cắt được 100 ký tự đầu. Với
`EXTERNAL` (không nén), nó chỉ đọc đúng chunk đầu tiên.

Số buffer trong `EXPLAIN (ANALYZE, BUFFERS)` chênh nhau nhiều lần. Cái giá là dung lượng đĩa
lớn hơn — thường 1,5–3 lần với dữ liệu văn bản.

Dùng `EXTERNAL` khi: có column văn bản lớn, và truy vấn thường chỉ lấy phần đầu (preview,
snippet, tiêu đề trích).

**A7.** Với `fillfactor = 100` mặc định, tỷ lệ HOT thấp vì các page của `orders` đã đặc sau
`VACUUM FULL` (đo được ở Bài 2: chỉ còn 48 byte trống trên page 0).

Hạ xuống 80 và `VACUUM FULL` để áp dụng cho dữ liệu cũ, tỷ lệ HOT tăng đáng kể, bù lại bảng
lớn hơn khoảng 25%.

Đáng làm khi: bảng bị update thường xuyên, và các column bị update **không có index**. Không
đáng khi: bảng chủ yếu insert (log, event), hoặc mỗi row chỉ được update một lần trong đời.

**A8.** Sau khi tạo index trên `status`, tỷ lệ HOT tụt về **0%**, vì `status` chính là column
bị update. Điều kiện thứ nhất của HOT bị vi phạm, `fillfactor` bao nhiêu cũng không cứu được.

Nguyên tắc: **trước khi tạo index trên một column bị update thường xuyên, hãy tính cả cái giá
mất HOT update trên toàn bộ bảng.** Cái giá đó gồm index phình nhanh hơn, nhiều WAL hơn,
nhiều dead tuple hơn, và autovacuum phải làm việc nhiều hơn — thường lớn hơn lợi ích mà index
đó mang lại, trừ khi nó phục vụ một query thật sự quan trọng.

Cách kiểm tra index có đáng giữ không, sẽ dùng nhiều ở Phần 05:

```sql
SELECT indexrelname, idx_scan, pg_size_pretty(pg_relation_size(indexrelid)) AS kich_thuoc
FROM pg_stat_user_indexes
WHERE relname = 'orders'
ORDER BY idx_scan;
```

`idx_scan = 0` sau một chu kỳ vận hành đủ dài nghĩa là index đó chỉ tốn chi phí mà chưa từng
được dùng.
