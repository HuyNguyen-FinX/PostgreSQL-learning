# Phụ lục — Checklist review một query trước khi merge

> Dùng khi review pull request có thêm hoặc sửa query. Mỗi mục có tham chiếu tới phần giải thích.

---

## 1. Đọc plan, không đọc query

- [ ] Đã chạy `EXPLAIN (ANALYZE, BUFFERS)` trên dữ liệu **cỡ production** chưa?
- [ ] `Buffers` có lớn bất thường so với `relpages` của bảng không? *(Phần 07 — đo được 314.799
      buffer trên bảng 9.163 page)*

```sql
SELECT relname, relpages FROM pg_class WHERE relname IN (...);
```

- [ ] Node nào có `rows` ước lượng lệch quá 10 lần so với `actual rows × loops`? *(Phần 06)*
- [ ] Có `loops` rất lớn ở node bên trong Nested Loop không? *(Phần 06)*
- [ ] Có `Rows Removed by Filter` lớn không? *(Phần 07)*

---

## 2. Dấu hiệu ghi tạm ra đĩa

- [ ] `Sort Method: external merge  Disk: ...` *(Phần 07)*
- [ ] `Heap Blocks: ... lossy=...` *(Phần 07)*
- [ ] `Batches: > 1` ở node Hash
- [ ] `temp read/written` khác 0

Nếu có, cân nhắc `SET LOCAL work_mem` cho riêng query đó — **không** tăng toàn cục *(Phần 11)*.
Nhớ: đặt `work_mem` bằng đúng con số `Disk:` là **chưa đủ**.

---

## 3. Index

- [ ] Query có dùng index không? Nếu không, có đúng là nó lấy trên 10% số row không? *(Phần 05)*
- [ ] Với composite index, điều kiện có chứa **column đầu tiên** không? *(quy tắc leftmost prefix)*
- [ ] Có function hoặc ép kiểu bọc quanh **column** không?

```sql
WHERE date_trunc('day', created_at) = '...'   -- ❌ mất index
WHERE created_at >= '...' AND created_at < '...'  -- ✅

WHERE user_id::text = '42'   -- ❌ ép kiểu column
WHERE user_id = '42'         -- ✅ ép kiểu giá trị
```

- [ ] Nếu thêm index mới: đã kiểm tra nó không trùng với index có sẵn chưa?

```sql
SELECT indrelid::regclass, array_agg(indexrelid::regclass)
FROM pg_index GROUP BY indrelid, indkey HAVING count(*) > 1;
```

- [ ] Index mới có nằm trên column bị `UPDATE` thường xuyên không? Nếu có, đã cân nhắc việc
      **mất HOT update** chưa? *(Phần 02 — tỷ lệ HOT tụt từ 42,1% xuống 0%)*
- [ ] `CREATE INDEX` có `CONCURRENTLY` không?

---

## 4. Ngữ nghĩa và tính đúng

- [ ] `LEFT JOIN` có bị điều kiện trong `WHERE` biến thành `INNER JOIN` không?

```sql
-- ❌ điều kiện trong WHERE loại bỏ row NULL
LEFT JOIN payments p ON p.order_id = o.id WHERE p.status = 'succeeded'

-- ✅ đưa vào ON
LEFT JOIN payments p ON p.order_id = o.id AND p.status = 'succeeded'
```

- [ ] So sánh với `NULL` có dùng `IS DISTINCT FROM` khi cần không?
- [ ] `ORDER BY` có xác định duy nhất thứ tự không? *(thiếu tie-breaker làm pagination sai)*
- [ ] Có `LIMIT` cho query trả về danh sách không?

---

## 5. Đồng thời

- [ ] Có đọc-rồi-ghi mà không khóa không? *(lost update, Phần 03)*

```sql
-- ❌ SELECT ... rồi UPDATE SET x = <giá trị tính ở app>
-- ✅ UPDATE ... SET x = x - n WHERE ... AND x >= n
```

- [ ] Thao tác nhiều row có `ORDER BY` khóa chính để tránh deadlock không? *(Phần 08)*
- [ ] Nếu dùng `SERIALIZABLE` hoặc `REPEATABLE READ`: đã có retry cho `40001` chưa? *(Phần 03)*
- [ ] `UPDATE` hàng loạt có `WHERE ... IS DISTINCT FROM <giá trị mới>` để tránh dead tuple thừa
      không? *(Phần 03)*

---

## 6. Khối lượng

- [ ] Query này chạy bao nhiêu lần mỗi giây? *(query 10ms chạy 1 triệu lần tệ hơn query 5 giây
      chạy 10 lần)*
- [ ] Có nằm trong vòng lặp ở tầng ứng dụng không? *(N+1, Phần 15)*
- [ ] Pagination dùng keyset hay `OFFSET`? *(Phần 15)*
- [ ] Có `SELECT *` trên bảng có column `text`/`jsonb` lớn không? *(TOAST, Phần 02)*
- [ ] Có `count(*)` trên bảng lớn không? Có thật sự cần chính xác không? *(Case 11)*

---

## 7. Sau khi merge

- [ ] Đã ghi lại số liệu **trước** để so sánh chưa?
- [ ] Có theo dõi query này trong `pg_stat_statements` sau khi deploy không?
- [ ] `stddev_exec_time` có lớn bất thường không? *(dấu hiệu hai plan — generic plan, Phần 01)*

```sql
SELECT calls, round(mean_exec_time::numeric,2) AS tb,
       round(stddev_exec_time::numeric,2) AS do_lech,
       left(query, 60)
FROM pg_stat_statements
WHERE query ILIKE '%<đoạn nhận dạng>%';
```

---

## Cờ đỏ — dừng lại và hỏi

| Thấy gì | Vì sao đáng lo |
|---|---|
| `SET enable_*` trong code ứng dụng | Đóng băng quyết định mà planner phải tự điều chỉnh *(Phần 06)* |
| `OFFSET` lớn hơn 1.000 | Trang càng sâu càng chậm tuyến tính |
| Query có hơn 12 bảng | GEQO có thể cho plan khác nhau mỗi lần chạy *(Phần 06)* |
| `DISTINCT` để chữa join nhân bản | Thường là join sai, không phải cần `DISTINCT` |
| CTE `MATERIALIZED` không có lý do rõ | Chặn planner tối ưu *(Phần 06)* |
| `NOT IN (SELECT ...)` | Sai ngữ nghĩa khi có `NULL`; dùng `NOT EXISTS` |
| Transaction bao quanh lệnh gọi HTTP | Nguyên nhân số một của `idle in transaction` *(Phần 15)* |
