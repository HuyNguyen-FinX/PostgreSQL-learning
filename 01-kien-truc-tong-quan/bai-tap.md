# Phần 01 — Bài tập

> Làm trên môi trường của Phần 00. Mỗi bài đều phải kết thúc bằng một **bằng chứng đo được**,
> không phải một câu trả lời từ trí nhớ.

---

## Bài 1 — Vẽ lại bản đồ process của chính bạn

Chạy cluster, mở đúng 5 connection bằng 5 terminal, rồi:

1. Liệt kê toàn bộ process bằng `pg_stat_activity`.
2. Đối chiếu với process thật trong container qua `/proc`.
3. Với mỗi process nền, viết một câu trả lời cho: *nếu process này chết, triệu chứng đầu tiên
   người dùng nhìn thấy là gì?*

**Gợi ý:** thử tự tay kết thúc một backend bằng `SELECT pg_terminate_backend(<pid>)` và quan
sát `postmaster` phản ứng thế nào. Đừng thử với process nền.

---

## Bài 2 — Tìm điểm gãy của `max_connections`

Đo TPS bằng `pgbench` với số client tăng dần: 1, 2, 4, 8, 16, 32, 64, 128.

```bash
docker compose exec -T db sh -c 'echo "SELECT 1;" > /tmp/q.sql'
docker compose exec -T db pgbench -U lab -d lab -n -f /tmp/q.sql -c <N> -T 10
```

1. Vẽ bảng: số client → TPS → latency trung bình.
2. Chỉ ra số client mà TPS **ngừng tăng**.
3. Chỉ ra số client mà TPS **bắt đầu giảm**.
4. So sánh hai con số đó với số core của máy bạn (`docker compose exec -T db nproc`).

**Câu hỏi cần trả lời:** vì sao TPS không tăng mãi theo số client? Điều gì trở thành nút thắt?

---

## Bài 3 — Chi phí connection trong bối cảnh thật

Bài 3 của lab đo `SELECT 1`. Câu query thật thì nặng hơn nhiều, nên tỷ lệ sẽ khác.

1. Tạo một file `pgbench` chứa một câu query thật trên `lab_big`, ví dụ tổng doanh thu theo
   `status`.
2. Đo TPS có và không có `-C`.
3. Tính lại tỷ lệ.

**Câu hỏi cần trả lời:** khi câu query càng nặng, tỷ lệ chênh lệch tăng lên hay giảm đi?
Giải thích vì sao. Điều đó nói gì về việc *loại ứng dụng nào* chịu thiệt nhiều nhất khi
không dùng connection pool?

---

## Bài 4 — Phân loại lỗi theo chặng

Với mỗi câu lệnh dưới đây, **dự đoán trước** nó chết ở chặng nào (Parser / Analyzer /
Planner / Executor), rồi chạy để kiểm chứng:

```sql
SELECT * FROM orders WHERE;
SELECT * FROM orders WHERE khong_co = 1;
SELECT * FROM orders ORDER BY 99;
SELECT 1/0;
SELECT * FROM orders WHERE id = 'chuoi_khong_phai_so';
INSERT INTO orders (id, user_id, status, total_amount, created_at)
VALUES (1, 999999999, 'x', 0, now());
```

Ghi lại thông báo lỗi và giải thích vì sao nó thuộc chặng đó.

**Gợi ý cho câu cuối:** lỗi này không đến từ Parser, Analyzer hay Planner. Nó liên quan tới
thứ đã xuất hiện ở Bài 8 của Phần 00.

---

## Bài 5 — Săn optimization fence

Tạo bốn view trên `lab_big`, mỗi view chứa một cấu trúc: `DISTINCT`, `GROUP BY`, `LIMIT`,
và window function. Với mỗi view, chạy một câu query có `WHERE user_id = 42` bên ngoài.

1. Lập bảng: view nào đẩy được điều kiện vào trong, view nào không.
2. Với `GROUP BY`, thử cả hai trường hợp: điều kiện trên grouping column, và điều kiện trên
   kết quả aggregate. Kết quả có khác nhau không?
3. Đo `actual rows` của node dưới cùng trong mỗi trường hợp.

**Câu hỏi cần trả lời:** vì sao PostgreSQL *không được phép* đẩy điều kiện qua window
function, dù làm vậy sẽ nhanh hơn nhiều?

---

## Bài 6 — CTE trước và sau PostgreSQL 12

```sql
EXPLAIN (COSTS OFF)
WITH don_hang AS (
    SELECT id, user_id, total_amount FROM orders
)
SELECT * FROM don_hang WHERE user_id = 42;

EXPLAIN (COSTS OFF)
WITH don_hang AS MATERIALIZED (
    SELECT id, user_id, total_amount FROM orders
)
SELECT * FROM don_hang WHERE user_id = 42;
```

1. So sánh hai plan.
2. Chạy cả hai với `EXPLAIN (ANALYZE, BUFFERS)` và so sánh số buffer.

**Câu hỏi cần trả lời:** trước PostgreSQL 12, mọi CTE đều hoạt động như bản `MATERIALIZED`.
Rất nhiều tài liệu cũ khuyên "dùng CTE để ép PostgreSQL chạy theo thứ tự bạn muốn". Lời
khuyên đó giờ còn đúng không? Nếu code cũ của bạn dựa vào hành vi đó, việc nâng cấp lên
PostgreSQL 12 có thể gây chuyện gì?

---

## Bài 7 — Tái hiện sự cố "nhanh 5 lần rồi chậm"

Dựng một tình huống mà generic plan thực sự **thay đổi hình dạng plan**, chứ không chỉ sai
ước lượng như trong lab.

**Gợi ý:** cần một column có phân bố cực lệch và một index. Chạy prepared statement với tham
số ứng với giá trị hiếm, lặp nhiều lần, so sánh `plan_cache_mode` ở ba chế độ `auto`,
`force_generic_plan`, `force_custom_plan`.

1. Ghi lại plan và thời gian ở cả ba chế độ.
2. Tính xem generic plan chậm hơn bao nhiêu lần.

**Câu hỏi cần trả lời:** nếu ứng dụng của bạn dùng driver có prepared statement (JDBC,
psycopg với `prepare_threshold`), làm sao phát hiện được vấn đề này từ phía application, khi
mà chạy `EXPLAIN` bằng tay trong `psql` luôn cho ra plan đẹp?

---

## Bài 8 — Ngân sách bộ nhớ

Cluster của bạn có `shared_buffers = 256MB`, `work_mem = 4MB`, `max_connections = 100`.

1. Tính lượng RAM tối đa **về lý thuyết** mà cluster có thể dùng, giả sử mỗi query có 3 node
   cần bộ nhớ và tối đa 2 parallel worker.
2. Chạy `SELECT sum(size) FROM pg_shmem_allocations;` và so sánh với `shared_buffers`.
3. Giải thích vì sao con số ở bước 1 gần như không bao giờ xảy ra thật.

**Câu hỏi cần trả lời:** nếu sếp bạn hỏi "cấp bao nhiêu RAM cho database này là đủ?", bạn sẽ
trả lời bằng công thức nào, và cần biết thêm thông tin gì về workload?

---

## Bài 9 — Xây một dashboard tối thiểu

Viết một câu query duy nhất, chạy được bằng `\watch 2`, hiển thị cùng lúc:

- Số connection theo `state`
- Session `idle in transaction` lâu nhất (tính bằng giây)
- Query đang chạy lâu nhất (tính bằng giây)
- Số session đang chờ lock

Đây là câu query bạn sẽ dùng thật khi có sự cố, nên hãy làm cho nó đọc được trên một màn hình.

**Kiểm chứng:** tạo tình huống có `idle in transaction` và một query dài, xác nhận dashboard
hiển thị đúng.

---

## Đáp án

Đáp án và giải thích chi tiết nằm ở [kiem-tra.md](kiem-tra.md). Hãy tự làm trước — giá trị
của các bài này nằm ở việc bạn tự chạy và tự nhìn thấy số liệu, không nằm ở đáp án.
