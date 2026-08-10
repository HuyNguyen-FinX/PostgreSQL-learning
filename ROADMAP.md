# ROADMAP

Lộ trình chi tiết của giáo trình. Mỗi phần là một module độc lập, nhưng thứ tự được sắp
xếp có chủ đích: các phần sau dựa trên mental model được xây ở phần trước.

Đặc biệt, thứ tự **Storage → MVCC → VACUUM → Index → Planner** là bắt buộc. Rất nhiều
người học Index và Planner trước khi hiểu tuple được lưu thế nào, dẫn tới việc học thuộc
quy tắc thay vì hiểu nguyên nhân.

---

## Phần 00 — Môi trường thực hành

**Mục tiêu:** có một PostgreSQL để phá, không phải để giữ gìn.

- Dựng PostgreSQL bằng Docker, cấu hình `postgresql.conf` cho mục đích học (bật logging chi tiết).
- `psql` ở mức thành thạo: meta-command, `\watch`, `\timing`, `\x`, output format.
- Dataset mẫu: một dataset nhỏ để đọc plan và một dataset lớn (vài chục triệu row) để thấy khác biệt hiệu năng.
- Cài và giải thích các extension dùng xuyên suốt giáo trình:
  `pg_stat_statements`, `auto_explain`, `pageinspect`, `pgstattuple`, `pg_buffercache`, `pg_prewarm`.
- Cách chạy hai session song song để quan sát hành vi concurrency.

---

## Phần 01 — Kiến trúc tổng quan PostgreSQL

**Mục tiêu:** biết trong máy có những process nào và ai chịu trách nhiệm gì.

- Process model: `postmaster`, backend process cho mỗi connection, các background process
  (`checkpointer`, `background writer`, `WAL writer`, `autovacuum launcher`, `logical replication launcher`).
- Vì sao PostgreSQL dùng process thay vì thread, và hệ quả thực tế lên chi phí connection.
- Vòng đời một câu SQL: Parser → Analyzer → Rewriter → Planner → Executor.
- Shared memory và local memory: `shared_buffers`, WAL buffer, lock table, `work_mem`.
- Client/server protocol: simple query vs extended query, prepared statement.
- Đọc `pg_stat_activity` để nhìn thấy chính các process này.

---

## Phần 02 — Storage layer

**Mục tiêu:** hiểu một row thực sự nằm ở đâu trên đĩa.

- Cấu trúc file của một table: `relfilenode`, segment 1GB, fork (main, FSM, VM).
- Cấu trúc page 8KB: `PageHeaderData`, `ItemIdData`, tuple, special space.
- Tuple header: `t_xmin`, `t_xmax`, `t_ctid`, `t_infomask` — nền tảng để hiểu MVCC ở phần sau.
- TOAST: khi nào giá trị bị đẩy ra ngoài, chiến lược `PLAIN`/`EXTENDED`/`EXTERNAL`/`MAIN`, chi phí đọc.
- Free Space Map và Visibility Map: vì sao Index Only Scan phụ thuộc vào VM.
- `fillfactor` và HOT update: cơ chế tránh phải cập nhật index khi update.
- Lab: dùng `pageinspect` để mở một page ra xem từng byte có ý nghĩa gì.

---

## Phần 03 — MVCC & Transaction

**Mục tiêu:** giải thích được vì sao hai session nhìn thấy dữ liệu khác nhau.

- Transaction ID, cách `xmin`/`xmax` quyết định tuple có visible hay không.
- Snapshot: cấu tạo, thời điểm được lấy ở từng isolation level.
- Isolation level: Read Committed, Repeatable Read, Serializable (SSI) — PostgreSQL cài đặt khác chuẩn SQL ở đâu.
- Các anomaly: dirty read, non-repeatable read, phantom read, lost update, write skew.
- Vì sao PostgreSQL không có "rollback segment" như Oracle, và cái giá phải trả là dead tuple.
- Subtransaction, `SAVEPOINT` và chi phí ẩn của nó.
- Xid wraparound: vì sao đây là sự cố có thể làm dừng toàn bộ cluster.
- Lab: tự tạo ra write skew, rồi tự chặn nó bằng Serializable và bằng constraint.

---

## Phần 04 — VACUUM & Autovacuum

**Mục tiêu:** hiểu vì sao bảng phình to dù đã xóa dữ liệu.

- Dead tuple sinh ra từ đâu, vì sao `DELETE` không trả lại disk.
- VACUUM làm gì thật sự, khác gì `VACUUM FULL`, khác gì `pg_repack`.
- Freeze và aggressive vacuum, quan hệ với xid wraparound.
- Autovacuum: các parameter `autovacuum_vacuum_scale_factor`, `autovacuum_vacuum_cost_delay`,
  `autovacuum_max_workers` — tune theo kích thước bảng chứ không theo mặc định.
- Table bloat và index bloat: cách đo bằng `pgstattuple`, cách ước lượng nhanh không khóa bảng.
- Vấn đề production: long-running transaction và replication slot giữ `xmin` khiến vacuum vô hiệu.
- Lab: tạo bloat có chủ đích, đo, rồi xử lý.

---

## Phần 05 — Index

**Mục tiêu:** biết khi nào index giúp, khi nào index là gánh nặng.

- B-tree internals: cấu trúc node, page split, deduplication (PostgreSQL 13+).
- Index Scan, Index Only Scan, Bitmap Index Scan + Bitmap Heap Scan — khác biệt và điều kiện chọn.
- Composite index: thứ tự column quyết định điều gì, quy tắc leftmost prefix.
- Covering index với `INCLUDE`.
- Partial index và expression index — hai công cụ bị dùng ít hơn giá trị thật của chúng.
- Các loại index khác: GIN (full-text, JSONB, array), GiST (range, geometry), BRIN (bảng lớn theo thời gian), Hash, SP-GiST.
- Chi phí ghi của index: mỗi index làm chậm `INSERT`/`UPDATE` bao nhiêu và vì sao.
- Vì sao PostgreSQL bỏ qua index: kiểu dữ liệu không khớp, function trên column, selectivity thấp, statistics sai.
- Index không dùng tới: phát hiện bằng `pg_stat_user_indexes`, rủi ro khi xóa.
- `REINDEX CONCURRENTLY`, `CREATE INDEX CONCURRENTLY` và các cạm bẫy.

---

## Phần 06 — Query Planner & Optimizer

**Mục tiêu:** dự đoán được PostgreSQL sẽ chọn plan nào trước khi chạy `EXPLAIN`.

- Statistics: `pg_statistic`, `pg_stats`, `n_distinct`, MCV list, histogram, correlation.
- `ANALYZE` lấy mẫu như thế nào, `default_statistics_target` ảnh hưởng ra sao.
- Selectivity và cardinality: planner ước lượng số row ra sao và sai ở đâu.
- Cost model: `seq_page_cost`, `random_page_cost`, `cpu_tuple_cost`, `cpu_index_tuple_cost`,
  `effective_cache_size` — ý nghĩa vật lý của từng tham số trên SSD.
- Join algorithm: Nested Loop, Hash Join, Merge Join — chi phí, điều kiện chọn, khi nào mỗi loại thành thảm họa.
- Join order và genetic query optimizer khi số bảng lớn.
- Extended statistics (`CREATE STATISTICS`) cho các column tương quan.
- Parallel query: điều kiện kích hoạt, `parallel_workers`, khi nào parallel làm chậm đi.
- CTE: materialization trước và sau PostgreSQL 12, subquery pullup, view flattening.

---

## Phần 07 — Đọc EXPLAIN chuyên sâu

**Mục tiêu:** nhìn một plan và chỉ ra được chỗ bệnh trong vòng một phút.

- `EXPLAIN (ANALYZE, BUFFERS, VERBOSE, SETTINGS, WAL)` — mỗi option cho biết điều gì.
- Đọc đúng: `rows` ước lượng vs actual, `loops`, thời gian tích lũy vs thời gian riêng của node.
- `Rows Removed by Filter` — chỉ số bị bỏ qua nhiều nhất.
- `Buffers`: `shared hit` / `read` / `dirtied` / `written` và cách quy ra khối lượng I/O thật.
- Các dấu hiệu bệnh điển hình:
  - ước lượng lệch hàng chục lần
  - `Sort Method: external merge Disk` (thiếu `work_mem`)
  - `Heap Blocks: lossy` (bitmap tràn `work_mem`)
  - Nested Loop nổ vì ước lượng sai một row
- `auto_explain` để bắt plan của query chậm trên production mà không phải chạy lại.

---

## Phần 08 — Lock & Concurrency

**Mục tiêu:** giải thích được vì sao một lệnh `ALTER TABLE` làm treo cả hệ thống.

- Bảng lock mode và ma trận xung đột — cách đọc thay vì học thuộc.
- Row-level lock: `FOR UPDATE`, `FOR NO KEY UPDATE`, `FOR SHARE`, `FOR KEY SHARE`.
- Lock queue: vì sao một transaction chờ lại chặn cả những transaction chỉ đọc phía sau.
- Deadlock: cơ chế phát hiện, `deadlock_timeout`, cách thiết kế để tránh.
- Advisory lock: khi nào nên dùng thay cho row lock.
- `SKIP LOCKED` và mô hình job queue trên PostgreSQL.
- Chẩn đoán: `pg_locks`, `pg_blocking_pids()`, `lock_timeout`, `statement_timeout`.
- Lab: dựng một lock queue thật rồi gỡ.

---

## Phần 09 — WAL, Checkpoint và Durability

**Mục tiêu:** hiểu chuyện gì xảy ra giữa lúc `COMMIT` trả về và lúc dữ liệu nằm trên đĩa.

- WAL record, LSN, quan hệ giữa WAL và buffer dirty.
- `full_page_writes` và vì sao WAL phình sau mỗi checkpoint.
- Checkpoint: timed vs requested, `checkpoint_timeout`, `max_wal_size`, `checkpoint_completion_target`.
- Hiện tượng checkpoint spike và cách nhận ra trong biểu đồ I/O.
- `synchronous_commit`: các mức và đánh đổi giữa latency và độ bền dữ liệu.
- Crash recovery: redo từ đâu tới đâu.
- Backup: `pg_basebackup`, WAL archiving, PITR — và cách kiểm chứng backup thật sự khôi phục được.

---

## Phần 10 — Replication & High Availability

**Mục tiêu:** biết replica đang tụt lại vì lý do gì.

- Streaming replication: `walsender`, `walreceiver`, replication slot.
- Synchronous vs asynchronous, `synchronous_standby_names`, ảnh hưởng lên latency của write.
- Replication lag: đo bằng byte và bằng thời gian, phân biệt lag do network / apply / disk.
- Hot standby conflict: vì sao query trên replica bị hủy, `hot_standby_feedback` và tác dụng phụ lên vacuum ở primary.
- Logical replication: publication/subscription, giới hạn (DDL, sequence), dùng cho migration.
- Failover: khái niệm, split-brain, vai trò của công cụ như Patroni.
- Đọc-ghi tách biệt ở tầng application và bẫy read-after-write.

---

## Phần 11 — Connection & Resource Management

**Mục tiêu:** trả lời được "vì sao tăng `max_connections` lại làm hệ thống chậm hơn".

- Chi phí thật của một connection: memory, process, context switch.
- `max_connections` và quan hệ với số core.
- PgBouncer: session / transaction / statement pooling — mỗi mode phá vỡ tính năng nào.
- Bẫy phổ biến: prepared statement, advisory lock, `SET` session-level khi dùng transaction pooling.
- `work_mem` là per-node chứ không phải per-query — cách tính lượng RAM tối đa thật sự.
- `maintenance_work_mem`, `temp_buffers`, `hash_mem_multiplier`.
- Temp file: phát hiện qua log và `pg_stat_database`.

---

## Phần 12 — Partitioning & Scale

**Mục tiêu:** biết khi nào partitioning giúp và khi nào nó chỉ thêm phức tạp.

- Declarative partitioning: range, list, hash — chọn theo pattern truy vấn.
- Partition pruning ở thời điểm plan và thời điểm execution.
- Partition-wise join và partition-wise aggregate.
- Chi phí: số partition quá nhiều làm planner chậm, ảnh hưởng tới lock.
- Bảo trì: tạo partition trước, detach, drop — và cách làm không khóa bảng.
- Khi nào partitioning **không** giải quyết vấn đề (thường là khi vấn đề thật là index hoặc query).
- Khái niệm sharding và giới hạn của một node đơn.

---

## Phần 13 — Schema & Data Modeling

**Mục tiêu:** thiết kế schema không phải sửa lại sau 6 tháng.

- Chọn data type: `int` vs `bigint`, `numeric` vs `float`, `text` vs `varchar(n)`, `timestamptz` vs `timestamp`.
- Ảnh hưởng của thứ tự column lên kích thước row (alignment padding).
- Normalization và khi nào cố tình denormalize.
- JSONB: khi nào hợp lý, khi nào là dấu hiệu thiết kế sai; index GIN, `jsonb_path_ops`.
- Constraint, foreign key và chi phí của chúng lên write path.
- UUID vs bigint làm primary key: ảnh hưởng lên B-tree và WAL.
- Migration zero-downtime: thêm column, đổi type, thêm `NOT NULL`, thêm index, thêm FK — từng thao tác cần lock gì.
- Checklist review migration trước khi lên production.

---

## Phần 14 — Monitoring & Debug production

**Mục tiêu:** có quy trình chẩn đoán thay vì đoán.

- `pg_stat_statements`: đọc đúng `total_exec_time`, `mean_exec_time`, `stddev`, `rows`.
- `pg_stat_activity`: `state`, `wait_event_type`, `wait_event`, `backend_xmin`.
- `pg_stat_user_tables` / `pg_stat_user_indexes`: seq scan, dead tuple, index chưa từng dùng.
- `pg_stat_io` (PostgreSQL 16+) và `pg_stat_bgwriter`.
- Wait event: phân loại và ý nghĩa của các nhóm hay gặp.
- Các metric nên đưa lên dashboard và ngưỡng cảnh báo hợp lý.
- Playbook sự cố:
  - CPU tăng đột biến
  - I/O tăng đột biến
  - connection đầy
  - query đột nhiên chậm (plan flip)
  - disk đầy vì WAL
  - transaction ID wraparound đang tới gần

---

## Phần 15 — Phía application

**Mục tiêu:** viết code không tạo ra vấn đề database.

- N+1 query: nhận diện, và vì sao ORM sinh ra nó.
- Batch và bulk: `COPY`, multi-row `INSERT`, `INSERT ... ON CONFLICT`.
- Transaction boundary: giữ transaction ngắn, không gọi HTTP bên trong transaction.
- Idempotency và outbox pattern.
- Retry đúng cách với `serialization_failure` và `deadlock_detected`.
- Pagination: `OFFSET` lớn và keyset pagination.
- Bẫy ORM: lazy loading, auto-flush, connection giữ quá lâu, migration tự sinh.
- Khi nào nên cache và khi nào cache che giấu một query cần sửa.

---

## Phần 16 — Case study production

Mỗi case study đi theo cùng một khuôn: bối cảnh → triệu chứng → dữ liệu quan sát được →
giả thuyết → cách kiểm chứng → nguyên nhân gốc → cách xử lý → cách phòng ngừa.

Danh sách dự kiến:

1. Query chạy 20ms suốt 6 tháng rồi đột nhiên thành 8 giây sau một đợt import dữ liệu.
2. Bảng 200GB nhưng dữ liệu thật chỉ 30GB.
3. Autovacuum chạy liên tục mà bloat vẫn tăng.
4. `ALTER TABLE ADD COLUMN` làm treo toàn bộ API trong 4 phút.
5. Connection pool đầy trong khi CPU database chỉ 15%.
6. Replica lag tăng dần vào mỗi 3 giờ sáng.
7. Deadlock chỉ xảy ra khi có khuyến mãi.
8. Index vừa tạo nhưng planner không dùng.
9. Disk đầy vì replication slot bị bỏ quên.
10. Job queue xử lý trùng message.
11. `COUNT(*)` trên bảng lớn làm nghẽn dashboard.
12. Batch job đêm làm chậm traffic ban ngày hôm sau.

---

## Phụ lục

- `appendix/parameters.md` — bảng tra cứu parameter quan trọng, ý nghĩa và cách tune.
- `appendix/checklist-review-query.md` — checklist review một query trước khi merge.
- `appendix/checklist-review-migration.md` — checklist review migration trước khi deploy.
- `appendix/checklist-truoc-khi-len-production.md` — checklist cấu hình cluster mới.
- `appendix/thuat-ngu.md` — từ điển thuật ngữ Anh–Việt dùng trong giáo trình.
- `appendix/tai-lieu-tham-khao.md` — nguồn tham khảo (source code, sách, bài viết).
