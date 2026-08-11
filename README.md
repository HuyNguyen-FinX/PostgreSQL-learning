# Database Engineering & PostgreSQL chuyên sâu cho Backend Engineer

Repository này là một giáo trình tiếng Việt về Database Engineering, lấy PostgreSQL làm
hệ quy chiếu chính.

PostgreSQL là một relational database mã nguồn mở, nhưng để hiểu PostgreSQL sâu thì không
nên chỉ xem nó như nơi lưu dữ liệu. PostgreSQL thực chất gồm nhiều subsystem như Query
Planner, Executor, Buffer Manager, WAL, MVCC và Storage Engine phối hợp với nhau để xử lý
một câu SQL. Khi một query chậm đi 50 lần lúc 2 giờ sáng, thứ giúp bạn xử lý được không
phải là danh sách cú pháp SQL, mà là khả năng suy luận xem subsystem nào đang gặp vấn đề.

Đó chính là thứ repository này muốn xây dựng.

---

## Repository này dành cho ai

Dành cho Backend Engineer đã biết viết SQL, đã dùng PostgreSQL trong công việc, nhưng
đang ở trạng thái:

- Biết `CREATE INDEX` nhưng không giải thích được vì sao PostgreSQL **không** dùng index vừa tạo.
- Đọc được `EXPLAIN` nhưng không biết con số nào là dấu hiệu bệnh.
- Nghe nói VACUUM quan trọng nhưng không biết vì sao bảng vẫn phình ra dù autovacuum đang bật.
- Gặp deadlock trên production và chỉ biết retry.
- Không chắc nên đặt transaction boundary ở đâu trong code application.

Nếu bạn chưa từng viết SQL, nên học SQL cơ bản trước rồi quay lại.

---

## Repository này KHÔNG phải là gì

- Không phải bản dịch của PostgreSQL Documentation.
- Không phải danh sách "10 mẹo tối ưu PostgreSQL".
- Không phải tài liệu chỉ dạy cú pháp.

Mỗi chủ đề đều đi theo mạch: khái niệm → tại sao cần → PostgreSQL làm thế nào → bên trong
DB đang xảy ra chuyện gì → ví dụ → thử nghiệm → vấn đề production → cách debug → cách tối ưu.

---

## Bắt đầu nhanh

Yêu cầu duy nhất: Docker đang chạy. Không cần cài PostgreSQL hay `psql` trên máy.

```bash
make up
```

Lệnh này dựng PostgreSQL 17, tạo schema và nạp sẵn dataset nhỏ. Sau đó:

```bash
make psql
```

Xem toàn bộ lệnh có sẵn bằng `make`. Hướng dẫn chi tiết nằm ở
[Phần 00 — Môi trường thực hành](00-moi-truong/README.md).

---

## Cách học

Mỗi module có cấu trúc giống nhau:

| File | Nội dung |
|---|---|
| `README.md` | Lý thuyết, giải thích theo 3 tầng |
| `lab.md` | Thực hành trên PostgreSQL thật, có thể copy chạy được |
| `bai-tap.md` | Bài tập tự làm, kèm đáp án |
| `kiem-tra.md` | Câu hỏi kiểm tra riêng (chỉ với module đủ lớn) |

Từ **Phần 09** trở đi, phần thực hành được lồng ngay vào `README.md` thay vì tách file riêng.

Phần lý thuyết luôn được trình bày theo 3 tầng:

- **Level 1 — Trực giác:** hình dung vấn đề bằng ngôn ngữ đời thường.
- **Level 2 — Góc nhìn Backend Engineer:** ảnh hưởng tới query, transaction, latency, throughput.
- **Level 3 — PostgreSQL Internals:** PostgreSQL thực sự cài đặt nó ra sao.

Nguyên tắc quan trọng: **đừng đọc mà không chạy**. Gần như mọi kết luận trong repository
này đều có thể kiểm chứng lại bằng một vài câu SQL trên máy của bạn. Việc tự tay tạo ra
một table bloat, tự gây ra một deadlock, tự làm planner ước lượng sai — có giá trị hơn
nhiều so với việc đọc mô tả về chúng.

---

## Lộ trình

Chi tiết đầy đủ nằm ở [ROADMAP.md](ROADMAP.md). Tóm tắt:

| Phần | Chủ đề | Trọng tâm |
|---|---|---|
| [00](00-moi-truong/README.md) | Môi trường thực hành | Docker, psql, dataset mẫu, extension chẩn đoán |
| [01](01-kien-truc-tong-quan/README.md) | Kiến trúc tổng quan | Process model, vòng đời một câu SQL |
| [02](02-storage-layer/README.md) | Storage layer | Page 8KB, tuple header, TOAST, HOT update |
| [03](03-mvcc-transaction/README.md) | MVCC & Transaction | Snapshot, isolation level, các anomaly |
| [04](04-vacuum-autovacuum/README.md) | VACUUM & Autovacuum | Dead tuple, bloat, freeze, xid wraparound |
| [05](05-index/README.md) | Index | B-tree internals, GIN, GiST, BRIN, khi nào index vô dụng |
| [06](06-query-planner/README.md) | Query Planner & Optimizer | Statistics, cost model, cardinality, join algorithm |
| [07](07-doc-explain/README.md) | Đọc EXPLAIN chuyên sâu | BUFFERS, ước lượng sai, spill to disk |
| [08](08-lock-concurrency/README.md) | Lock & Concurrency | Lock mode, deadlock, lock queue, SKIP LOCKED |
| [09](09-wal-checkpoint/README.md) | WAL, Checkpoint, Durability | LSN, crash recovery, PITR |
| [10](10-replication/README.md) | Replication & HA | Streaming, logical, replication lag, failover |
| [11](11-connection-resource/README.md) | Connection & Resource | PgBouncer, work_mem, temp file |
| [12](12-partitioning/README.md) | Partitioning & Scale | Range/list/hash, partition pruning, sharding |
| [13](13-schema-modeling/README.md) | Schema & Data Modeling | Data type, JSONB, migration zero-downtime |
| [14](14-monitoring-debug/README.md) | Monitoring & Debug | pg_stat_statements, wait event, playbook sự cố |
| [15](15-phia-application/README.md) | Phía application | N+1, batch, outbox, retry, ORM pitfall |
| [16](16-case-study/README.md) | Case study production | Các tình huống thật, phân tích từ đầu tới cuối |

**Phụ lục:** [tham số](appendix/parameters.md) · [checklist review query](appendix/checklist-review-query.md) ·
[checklist review migration](appendix/checklist-review-migration.md) ·
[checklist lên production](appendix/checklist-truoc-khi-len-production.md) ·
[từ điển thuật ngữ](appendix/thuat-ngu.md) · [tài liệu tham khảo](appendix/tai-lieu-tham-khao.md)

---

## Tiến độ

Xem [PROGRESS.md](PROGRESS.md).

---

## Quy ước viết nội dung

Toàn bộ nội dung viết bằng tiếng Việt. Thuật ngữ kỹ thuật, SQL, tên parameter và source
code giữ nguyên tiếng Anh. Chi tiết quy ước nằm ở [CLAUDE.md](CLAUDE.md).

---

## Phiên bản PostgreSQL tham chiếu

Nội dung mặc định viết cho **PostgreSQL 16** trở lên. Khi một hành vi khác nhau giữa các
version (ví dụ `pg_stat_io` chỉ có từ PostgreSQL 16, B-tree deduplication từ PostgreSQL 13),
bài viết sẽ nói rõ.
# PostgreSQL-learning
