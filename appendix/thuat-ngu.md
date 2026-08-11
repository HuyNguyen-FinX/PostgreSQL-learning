# Phụ lục — Từ điển thuật ngữ

> Thuật ngữ **giữ nguyên tiếng Anh**, giải thích bằng tiếng Việt. Cột cuối trỏ tới phần nói kỹ.

---

## Kiến trúc và process

| Thuật ngữ | Giải thích | Phần |
|---|---|---|
| **postmaster** | Process cha, lắng nghe cổng và `fork()` ra backend cho mỗi connection. Không xử lý query | 01 |
| **client backend** | Process phục vụ **một** connection, xử lý toàn bộ vòng đời câu SQL | 01 |
| **checkpointer** | Process ghi toàn bộ dirty buffer xuống đĩa tại mỗi checkpoint | 01, 09 |
| **background writer** | Process ghi rải rác dirty buffer để backend không phải tự ghi | 01, 09 |
| **WAL writer** | Process đẩy WAL buffer xuống đĩa | 01, 09 |
| **autovacuum launcher / worker** | Theo dõi bảng cần vacuum và chạy VACUUM/ANALYZE | 01, 04 |
| **parallel worker** | Process chạy một phần Execution Plan song song với backend cha | 01, 06 |
| **shared_buffers** | Cache page 8KB dùng chung cho mọi process | 01 |
| **OS page cache** | Cache tầng hai của hệ điều hành. PostgreSQL dựa vào nó | 01 |
| **double buffering** | Cùng một page nằm ở cả `shared_buffers` lẫn OS page cache | 01 |

---

## Vòng đời câu SQL

| Thuật ngữ | Giải thích | Phần |
|---|---|---|
| **Parser** | Kiểm tra **ngữ pháp** SQL. Không tra catalog → lỗi `syntax error` | 01 |
| **Analyzer** | Phân giải tên bảng, column qua catalog → lỗi `does not exist` | 01 |
| **Rewriter** | Áp dụng rule, **mở rộng view** thành định nghĩa của nó | 01 |
| **Query Planner / Optimizer** | Sinh và chọn plan rẻ nhất theo cost ước lượng | 06 |
| **Executor** | Chạy plan, kéo từng row theo mô hình iterator | 01 |
| **Execution Plan** | Cây các bước PostgreSQL sẽ làm để trả kết quả | 07 |
| **optimization fence** | Rào chắn khiến điều kiện không đẩy vào trong được (window function, `DISTINCT`, `LIMIT`, CTE `MATERIALIZED`) | 01, 06 |
| **generic plan** | Plan lập sẵn không phụ thuộc giá trị tham số. Nguồn gốc sự cố "nhanh 5 lần rồi chậm" | 01 |
| **custom plan** | Plan lập riêng cho từng bộ tham số cụ thể | 01 |

---

## Storage

| Thuật ngữ | Giải thích | Phần |
|---|---|---|
| **page / block** | Đơn vị lưu trữ 8KB. Mọi I/O đều theo đơn vị này | 02 |
| **heap** | File chứa dữ liệu thật của bảng | 02 |
| **fork** | Các file phụ của một bảng: `main`, `_fsm`, `_vm` | 02 |
| **line pointer (ItemId)** | Con trỏ 4 byte trong page, trỏ tới tuple. Phần thứ hai của `ctid` | 02 |
| **tuple** | Một version vật lý của một row | 02, 03 |
| **ctid** | Địa chỉ vật lý `(page, line pointer)`. **Thay đổi sau mỗi `UPDATE`** | 02 |
| **TOAST** | Cơ chế nén và đẩy giá trị lớn ra bảng phụ khi tuple vượt ~2KB | 02 |
| **alignment padding** | Byte đệm để mỗi giá trị bắt đầu đúng biên. Thứ tự column ảnh hưởng 31% dung lượng | 02 |
| **fillfactor** | Tỷ lệ % page được lấp đầy khi insert. Chừa chỗ cho HOT update | 02 |
| **HOT update** | Update không phải sửa index. Cần **hai** điều kiện: có chỗ trong page **và** column bị sửa không có index | 02 |
| **FSM (Free Space Map)** | Bản đồ page nào còn chỗ. **Chỉ được cập nhật bởi VACUUM** | 02, 04 |
| **VM (Visibility Map)** | 2 bit mỗi page: `all_visible`, `all_frozen`. Điều kiện sống còn của Index Only Scan | 02, 05 |
| **relfilenode** | Số hiệu file của bảng. **Đổi** sau `VACUUM FULL`, `TRUNCATE`, `REINDEX` | 02 |

---

## MVCC và transaction

| Thuật ngữ | Giải thích | Phần |
|---|---|---|
| **MVCC** | Multi-Version Concurrency Control. Giữ nhiều version để đọc không chặn ghi | 03 |
| **xmin / xmax** | Transaction tạo ra / xóa version này. Cơ sở của mọi quyết định hiển thị | 03 |
| **snapshot** | "Ảnh chụp" danh sách transaction đã xong tại một thời điểm | 03 |
| **dead tuple** | Version cũ không còn ai nhìn thấy, chờ VACUUM dọn | 03, 04 |
| **bloat** | Bảng/index lớn hơn dữ liệu thật do dead tuple tích tụ | 04 |
| **non-repeatable read** | Hai lần đọc trong cùng transaction cho hai kết quả khác nhau | 03 |
| **phantom read** | Lần đọc thứ hai thấy row mới xuất hiện | 03 |
| **lost update** | Hai transaction cùng đọc rồi ghi, một thay đổi bị mất | 03 |
| **write skew** | Hai transaction ghi hai row khác nhau, cùng phá một ràng buộc. **Repeatable Read không chặn được** | 03 |
| **SSI** | Serializable Snapshot Isolation — cách PostgreSQL cài Serializable, dựa trên theo dõi phụ thuộc | 03 |
| **pivot** | Transaction ở giữa một "dangerous structure" trong SSI, bị hủy | 03 |
| **freeze** | Đánh dấu tuple đủ cũ là luôn hiển thị, chống xid wraparound | 03, 04 |
| **xid wraparound** | Transaction ID 32-bit quay vòng. Có thể làm cluster ngừng nhận ghi | 03, 04 |
| **subtransaction** | Transaction con do `SAVEPOINT` tạo. Trên 64 cái gây `SubtransSLRU` contention | 03 |

---

## Index

| Thuật ngữ | Giải thích | Phần |
|---|---|---|
| **B-tree** | Loại index mặc định, phù hợp 90% trường hợp | 05 |
| **Index Scan** | Đọc index rồi nhảy vào heap từng row. Đắt khi correlation thấp | 05, 07 |
| **Index Only Scan** | Lấy toàn bộ dữ liệu từ index, không đụng heap. Cần page `all_visible` | 05 |
| **Bitmap Index/Heap Scan** | Gom địa chỉ, sắp theo số page, đọc heap mỗi page một lần | 05, 07 |
| **Heap Fetches** | Số lần Index Only Scan buộc phải về heap. Lớn = autovacuum không theo kịp | 05 |
| **lossy bitmap** | Bitmap tràn `work_mem`, chỉ nhớ số page thay vì từng row | 07 |
| **leftmost prefix** | Index `(a,b)` chỉ seek được theo `a`. Vi phạm → quét toàn index | 05 |
| **covering index** | Index chứa đủ column query cần, thường qua `INCLUDE` | 05 |
| **partial index** | Index chỉ trên các row thỏa một điều kiện | 05 |
| **expression index** | Index trên biểu thức, ví dụ `lower(email)` | 05 |
| **GIN / GiST / BRIN** | Index cho JSONB & full-text / range & hình học / bảng lớn có correlation cao | 05 |
| **correlation** | Mức tương quan giữa thứ tự logic và thứ tự vật lý, từ −1 tới 1 | 05, 06 |
| **index bloat** | Index phình do page thưa. Đo bằng `avg_leaf_density` | 04, 05 |

---

## Planner

| Thuật ngữ | Giải thích | Phần |
|---|---|---|
| **Cardinality** | Số row planner **ước lượng** trả về tại một bước | 06 |
| **Selectivity** | Tỷ lệ row thỏa một điều kiện | 06 |
| **MCV list** | Danh sách giá trị hay gặp nhất và tần suất của chúng | 06 |
| **histogram** | Phân bố phần dữ liệu còn lại sau khi bỏ MCV | 06 |
| **n_distinct** | Số giá trị khác nhau. **Âm** = tỷ lệ, **dương** = số tuyệt đối | 06 |
| **extended statistics** | `CREATE STATISTICS` — dạy planner về quan hệ giữa các column | 06 |
| **cost** | Đơn vị nội bộ so sánh phương án. **Không phải thời gian** | 06 |
| **startup cost / total cost** | Chi phí tới row đầu tiên / tới row cuối cùng | 06 |
| **Nested Loop / Hash Join / Merge Join** | Ba thuật toán join | 06 |
| **GEQO** | Thuật toán di truyền dùng khi query có hơn `geqo_threshold` bảng | 06 |
| **loops** | Số lần một node được chạy lại. **`actual rows` phải nhân với nó** | 06, 07 |

---

## Lock

| Thuật ngữ | Giải thích | Phần |
|---|---|---|
| **ACCESS SHARE** | Lock của `SELECT`. Chỉ xung đột với `ACCESS EXCLUSIVE` | 08 |
| **ACCESS EXCLUSIVE** | Lock của `ALTER TABLE`, `DROP`, `VACUUM FULL`. Xung đột với **tất cả** | 08 |
| **lock queue** | Hàng đợi FIFO. Một transaction đang chờ **chặn tất cả phía sau** | 08 |
| **deadlock** | Hai transaction chờ nhau thành vòng. Phát hiện sau `deadlock_timeout` | 08 |
| **advisory lock** | Lock do ứng dụng tự định nghĩa ý nghĩa | 08 |
| **SKIP LOCKED** | Bỏ qua row đang bị khóa thay vì chờ. Nền tảng của job queue | 08 |
| **idle in transaction** | Có transaction mở nhưng không chạy gì. Giữ lock **và** chặn VACUUM | 01, 03, 04 |

---

## WAL và replication

| Thuật ngữ | Giải thích | Phần |
|---|---|---|
| **WAL** | Write-Ahead Logging. Ghi nhật ký tuần tự trước khi ghi dữ liệu | 09 |
| **LSN** | Log Sequence Number — vị trí byte trong dòng WAL | 09 |
| **checkpoint** | Điểm mà mọi dirty buffer đã xuống đĩa; mốc bắt đầu recovery | 09 |
| **full page write** | Ghi nguyên page 8KB vào WAL ở lần chạm đầu sau checkpoint | 09 |
| **crash recovery** | Replay WAL từ checkpoint gần nhất sau sự cố | 09 |
| **PITR** | Point-In-Time Recovery — khôi phục về một thời điểm bất kỳ | 09 |
| **streaming replication** | Replica replay WAL vật lý của primary | 10 |
| **replication slot** | Đảm bảo primary giữ WAL cho replica. **Bỏ quên = đầy đĩa + bloat** | 10 |
| **replication lag** | Độ trễ của replica. Chia bốn chặng: sent/write/flush/replay | 10 |
| **hot standby conflict** | Xung đột giữa replay WAL và query trên replica | 10 |
| **logical replication** | Sao chép thay đổi mức row. Không sao chép DDL và sequence | 10 |
| **split-brain** | Hai node cùng nhận ghi sau failover hỏng | 10 |

---

## Vận hành

| Thuật ngữ | Giải thích | Phần |
|---|---|---|
| **connection pool** | Gom connection để tránh chi phí mở mới (đo được 74 lần) | 01, 11 |
| **transaction pooling** | Chế độ PgBouncer trả connection về pool sau mỗi transaction | 11 |
| **work_mem** | Giới hạn bộ nhớ cho **mỗi node**, không phải mỗi query | 11 |
| **spill to disk** | Sort/hash tràn ra đĩa vì thiếu `work_mem` | 07, 11 |
| **temp file** | File tạm sinh ra khi spill to disk | 07, 11 |
| **wait event** | Thứ một backend đang chờ. Câu hỏi chẩn đoán **đầu tiên** | 14 |
| **partition pruning** | Loại bỏ partition không liên quan khỏi plan | 12 |
| **partition-wise join** | Join từng cặp partition tương ứng thay vì gộp rồi join | 12 |
| **N+1 query** | Vòng lặp gọi database. Biểu hiện: `calls` khổng lồ, `mean_exec_time` cực nhỏ | 15 |
| **outbox pattern** | Ghi việc cần làm cùng transaction nghiệp vụ, worker gửi sau | 15 |
| **keyset pagination** | Phân trang theo giá trị khóa thay vì `OFFSET`. Thời gian không đổi | 15 |
| **idempotency** | Chạy lại nhiều lần cho cùng kết quả. Bắt buộc khi có retry | 15 |
| **throughput** | Số giao dịch xử lý được mỗi đơn vị thời gian (TPS) | 11 |
| **query latency** | Thời gian một query hoàn thành | 07 |
