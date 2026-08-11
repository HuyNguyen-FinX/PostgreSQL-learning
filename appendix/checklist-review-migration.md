# Phụ lục — Checklist review migration trước khi deploy

> Nền tảng của toàn bộ checklist này là một sự thật của Phần 08: **mọi DDL cần
> `ACCESS EXCLUSIVE`, và một `ACCESS EXCLUSIVE` phải chờ sẽ chặn toàn bộ traffic đọc phía sau.**
>
> Migration không sập vì nó chậm. Nó sập vì nó phải **chờ**.

---

## 0. Quy tắc số một

- [ ] Migration có `SET lock_timeout` ở đầu không?

```sql
SET lock_timeout = '3s';
```

**Không có ngoại lệ.** Thà migration thất bại và thử lại, còn hơn API sập 4 phút *(Case 4)*.

---

## 1. Phân loại từng thao tác

| Thao tác | Lock | Viết lại bảng | An toàn |
|---|---|---|---|
| `ADD COLUMN` nullable, không default | `ACCESS EXCLUSIVE` ngắn | Không | ✅ |
| `ADD COLUMN ... DEFAULT <hằng>` | `ACCESS EXCLUSIVE` ngắn | Không (PG11+) | ✅ |
| `ADD COLUMN ... DEFAULT now()` | `ACCESS EXCLUSIVE` | **Có** | ❌ |
| `DROP COLUMN` | `ACCESS EXCLUSIVE` ngắn | Không | ✅ |
| `RENAME COLUMN` | `ACCESS EXCLUSIVE` ngắn | Không | ⚠️ hỏng app đang chạy |
| `ALTER COLUMN TYPE` | `ACCESS EXCLUSIVE` | **Có** | ❌ |
| `SET NOT NULL` trực tiếp | `ACCESS EXCLUSIVE` | Quét bảng | ❌ |
| `ADD CONSTRAINT ... NOT VALID` | `ACCESS EXCLUSIVE` ngắn | Không | ✅ |
| `VALIDATE CONSTRAINT` | `SHARE UPDATE EXCLUSIVE` | Quét, không chặn | ✅ |
| `CREATE INDEX` | `SHARE` | Quét, **chặn ghi** | ❌ |
| `CREATE INDEX CONCURRENTLY` | `SHARE UPDATE EXCLUSIVE` | Quét, không chặn | ✅ |
| `DROP INDEX` | `ACCESS EXCLUSIVE` | Không | ⚠️ dùng `CONCURRENTLY` |
| `TRUNCATE` | `ACCESS EXCLUSIVE` | Tạo file mới | ⚠️ |
| `VACUUM FULL` | `ACCESS EXCLUSIVE` | **Có** | ❌ dùng `pg_repack` |

- [ ] Mọi thao tác trong migration đã được phân loại theo bảng trên chưa?
- [ ] Thao tác nào ở cột ❌ đã được thay bằng mẫu an toàn chưa?

---

## 2. Các mẫu an toàn

### `SET NOT NULL`

```sql
ALTER TABLE t ADD CONSTRAINT c_nn CHECK (col IS NOT NULL) NOT VALID;
ALTER TABLE t VALIDATE CONSTRAINT c_nn;      -- không chặn đọc ghi
ALTER TABLE t ALTER COLUMN col SET NOT NULL; -- nhanh vì đã có CHECK hợp lệ (PG12+)
ALTER TABLE t DROP CONSTRAINT c_nn;
```

### Thêm foreign key

```sql
ALTER TABLE con ADD CONSTRAINT fk FOREIGN KEY (cha_id) REFERENCES cha(id) NOT VALID;
ALTER TABLE con VALIDATE CONSTRAINT fk;
CREATE INDEX CONCURRENTLY ON con(cha_id);    -- ĐỪNG QUÊN
```

### Đổi kiểu column — expand/contract

```text
1. ADD COLUMN col_moi <kiểu mới>
2. Trigger đồng bộ ghi mới
3. Backfill CHIA LÔ
4. RENAME trong transaction ngắn
5. DROP column cũ (deploy sau)
```

### Xóa column

```text
1. Ứng dụng ngừng dùng column  →  2. Deploy  →  3. DROP COLUMN
```

---

## 3. Backfill dữ liệu

- [ ] Backfill có **chia lô** không? Mỗi lô bao nhiêu row?
- [ ] Mỗi lô có commit riêng không? *(một `UPDATE` 1 triệu row giữ lock hàng phút và tạo 1
      triệu dead tuple cùng lúc — Phần 04)*
- [ ] Có nghỉ giữa các lô để autovacuum kịp làm việc không?
- [ ] Có `WHERE ... IS DISTINCT FROM` để không chạm row đã đúng không? *(Phần 03)*
- [ ] Có thể chạy lại từ giữa nếu thất bại không?

```sql
-- Mẫu backfill an toàn
DO $$
DECLARE tu bigint := 0; buoc int := 10000; toi bigint;
BEGIN
  SELECT max(id) INTO toi FROM t;
  WHILE tu <= toi LOOP
    UPDATE t SET col_moi = col_cu
    WHERE id > tu AND id <= tu + buoc
      AND col_moi IS DISTINCT FROM col_cu;
    COMMIT;
    tu := tu + buoc;
    PERFORM pg_sleep(0.05);
  END LOOP;
END $$;
```

---

## 4. Tương thích ngược

Ứng dụng và schema **không bao giờ** deploy cùng một khoảnh khắc.

- [ ] Phiên bản ứng dụng **hiện đang chạy** có hoạt động được với schema mới không?
- [ ] Phiên bản ứng dụng **mới** có hoạt động được với schema cũ không? *(cần cho rollback)*
- [ ] Có `RENAME COLUMN` hoặc `DROP COLUMN` mà ứng dụng còn dùng không?

> **Không bao giờ `RENAME COLUMN` trực tiếp trên hệ thống đang chạy.** Luôn qua bốn bước:
> thêm mới → đồng bộ → chuyển ứng dụng → xóa cũ.

---

## 5. Trước khi bấm deploy

- [ ] Đã ước lượng thời gian chạy trên dữ liệu **cỡ production** chưa?
- [ ] Đã kiểm tra không có transaction dài đang chạy chưa?

```sql
SELECT pid, now() - xact_start AS tuoi, state, left(query, 60)
FROM pg_stat_activity
WHERE state <> 'idle' AND now() - xact_start > interval '30 seconds'
ORDER BY xact_start;
```

- [ ] Có replication lag đáng kể không? *(migration nặng làm lag tăng thêm — Phần 10)*
- [ ] Đủ dung lượng đĩa chưa? *(thao tác viết lại bảng cần chỗ trống bằng cỡ bảng — Phần 02)*
- [ ] Có kế hoạch rollback không? Rollback có mất dữ liệu không?
- [ ] Ai theo dõi trong lúc chạy? Theo dõi bằng chỉ số nào?

---

## 6. Trong lúc chạy

Chạy song song ở một session khác:

```sql
SELECT a.pid, a.state, l.mode, l.granted,
       pg_blocking_pids(a.pid) AS bi_chan_boi,
       now() - a.xact_start AS tuoi, left(a.query, 50)
FROM pg_stat_activity a
LEFT JOIN pg_locks l ON l.pid = a.pid AND l.relation = '<bảng>'::regclass
WHERE a.backend_type = 'client backend'
ORDER BY a.xact_start;
```

- [ ] Nếu thấy hàng đợi hình thành (nhiều dòng `granted = f`), **hủy migration ngay**:

```sql
SELECT pg_cancel_backend(<pid_migration>);
```

Hàng đợi thông ngay lập tức. Thử lại vào lúc khác.

---

## 7. Sau khi chạy

- [ ] `CREATE INDEX CONCURRENTLY` có thành công không?

```sql
SELECT indexrelid::regclass AS index_khong_hop_le FROM pg_index WHERE NOT indisvalid;
```

Index không hợp lệ vẫn tốn chi phí ghi nhưng planner không dùng — **tệ nhất của cả hai thế
giới**. Phải `DROP` và làm lại.

- [ ] Có `ANALYZE` sau khi thay đổi dữ liệu lớn không? *(Case 1 — statistics lỗi thời làm plan
      flip)*
- [ ] Nếu có chạy `VACUUM FULL` hoặc `pg_repack`: đã chạy `VACUUM (ANALYZE)` ngay sau chưa?
      *(Phần 00 mục 6.6 — Visibility Map bị xóa sạch, mất Index Only Scan)*
- [ ] Constraint `NOT VALID` đã được `VALIDATE` chưa?

```sql
SELECT conname, conrelid::regclass FROM pg_constraint WHERE NOT convalidated;
```

- [ ] Đã kiểm tra `pg_stat_statements` xem có query nào chậm đi không?

---

## Cờ đỏ — không merge

| Thấy gì | Vì sao |
|---|---|
| Không có `SET lock_timeout` | Một transaction cũ đủ để làm sập API |
| `CREATE INDEX` không `CONCURRENTLY` trên bảng lớn | Chặn mọi thao tác ghi |
| `ALTER COLUMN TYPE` trên bảng lớn | Viết lại toàn bộ bảng khi giữ `ACCESS EXCLUSIVE` |
| `UPDATE` toàn bảng không chia lô | Lock dài + hàng triệu dead tuple |
| `RENAME COLUMN` trên hệ thống đang chạy | Hỏng ứng dụng phiên bản cũ |
| Thêm FK mà không tạo index | `DELETE` ở bảng cha quét toàn bộ bảng con *(Phần 08)* |
| Migration chưa từng chạy thử trên dữ liệu cỡ thật | Không biết nó mất bao lâu |
