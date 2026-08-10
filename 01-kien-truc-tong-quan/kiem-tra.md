# Phần 01 — Câu hỏi kiểm tra và đáp án

---

## Phần A — Câu hỏi kiểm tra

Tự trả lời trước khi xem đáp án ở dưới.

**A1.** Cluster của bạn có `max_connections = 300`. Ứng dụng mở đúng 300 connection và giữ
chúng trong pool. Database chạy trên máy 8 core. Điều gì sẽ xảy ra khi cả 300 connection
cùng chạy query, và vì sao?

**A2.** Câu lệnh `SELECT * FROM bang_khong_ton_tai;` báo lỗi gì, và lỗi đó đến từ chặng nào
trong năm chặng xử lý query?

**A3.** Một đồng nghiệp nói: "Đừng dùng view, nó làm query chậm vì phải chạy view trước rồi
mới lọc." Câu này đúng hay sai? Trả lời kèm điều kiện.

**A4.** Trong `EXPLAIN (ANALYZE, BUFFERS)`, bạn thấy `Buffers: shared read=50000`. Có thể
kết luận query này đã đọc 50.000 page từ đĩa vật lý không?

**A5.** Vì sao `effective_cache_size = 16GB` không làm PostgreSQL chiếm thêm RAM?

**A6.** Một câu query chạy qua prepared statement. Năm lần đầu mất 3ms, từ lần thứ sáu mất
900ms. Nêu giả thuyết và cách kiểm chứng.

**A7.** Vì sao `postmaster` không tự xử lý query mà phải fork ra backend?

**A8.** `state = 'idle in transaction'` nguy hiểm hơn `state = 'idle'` ở điểm nào?

**A9.** Trong plan có `Subquery Scan on v / Filter: (v.user_id = 42)`. Điều này nói lên gì
về view `v`?

**A10.** Bạn đặt `shared_buffers = 24GB` trên máy 32GB RAM. Vì sao đây thường là quyết định
sai?

---

## Phần B — Đáp án phần A

**A1.** 300 process cùng tranh 8 core. TPS sẽ **thấp hơn** so với khi chỉ có 16–32
connection. Nguyên nhân: context switch, tranh chấp lock trong shared memory (đặc biệt là
lock buffer mapping), và cache CPU liên tục bị đẩy ra. Ngoài ra mỗi backend có thể dùng tới
nhiều lần `work_mem`, nên rủi ro hết RAM tăng theo. Số connection tối ưu thường nằm trong
khoảng `số core × 2` đến `số core × 4`, và phần dư nên xếp hàng ở connection pool phía
application thay vì mở thêm process trong database.

**A2.** `ERROR: relation "bang_khong_ton_tai" does not exist`. Lỗi đến từ **Analyzer**, không
phải Parser. Parser chỉ kiểm tra ngữ pháp SQL và không hề tra catalog — câu này ngữ pháp
hoàn toàn hợp lệ. Chỉ tới chặng phân giải tên mới phát hiện bảng không tồn tại.

**A3. Sai trong đa số trường hợp.** Rewriter thay view bằng định nghĩa của nó **trước khi**
Planner làm việc, nên planner tối ưu trên câu query đã ghép và điều kiện bên ngoài được đẩy
vào trong. Bằng chứng: plan của `SELECT count(*) FROM v_don_hang_lon WHERE user_id = 42` ra
`Seq Scan on orders / Filter: ((total_amount > 5000) AND (user_id = 42))` — cả hai điều kiện
gộp làm một, không còn dấu vết view.

Câu đó **chỉ đúng** khi view chứa optimization fence: window function, `DISTINCT`, `LIMIT`,
điều kiện trên kết quả aggregate, hoặc CTE `MATERIALIZED`. Và luôn đúng với `MATERIALIZED VIEW`,
vì đó là bảng thật.

**A4. Không.** `shared read` chỉ có nghĩa "không tìm thấy trong `shared_buffers`". Page đó
rất có thể được lấy từ **OS page cache**, tức vẫn nằm trong RAM. PostgreSQL không dùng
direct I/O nên không phân biệt được hai trường hợp này ở mức đó. Muốn biết có chạm đĩa thật
không, phải nhìn `I/O Timings` (cần `track_io_timing = on`), hoặc quan sát ở tầng hệ điều hành.

**A5.** `effective_cache_size` **không cấp phát bộ nhớ**. Nó chỉ là thông tin bạn khai báo
cho planner: "tổng cache khả dụng của hệ thống, gồm cả `shared_buffers` lẫn OS page cache,
ước chừng bằng ngần này". Planner dùng nó để ước lượng xác suất một Index Scan đọc trúng
cache, từ đó tính cost. Đặt sai không gây lỗi và không đổi lượng RAM sử dụng, nhưng làm
planner chọn sai plan — đặt quá thấp khiến nó ngại dùng index.

**A6.** Giả thuyết: PostgreSQL đã chuyển từ **custom plan** sang **generic plan** sau 5 lần
chạy. Generic plan lập mà không biết giá trị tham số nên phải giả định phân bố đều; với dữ
liệu lệch, ước lượng sai dẫn tới chọn sai plan.

Kiểm chứng:

```sql
SET plan_cache_mode = force_custom_plan;
-- chạy lại, nếu nhanh trở lại thì giả thuyết đúng
SET plan_cache_mode = force_generic_plan;
EXPLAIN (ANALYZE) EXECUTE ...;   -- so sánh estimated rows với actual rows
```

Dấu hiệu nhận biết trong plan: `Index Cond: (col = $1)` là generic plan;
`Index Cond: (col = 'DE'::bpchar)` là custom plan.

**A7.** Ba lý do. **Cô lập lỗi:** một backend crash (segfault trong extension chẳng hạn)
không kéo theo `postmaster`; `postmaster` phát hiện, đưa shared memory về trạng thái an toàn
và cho các backend khác khởi động lại. **Đồng thời:** một process chỉ phục vụ một connection
tại một thời điểm, nên muốn phục vụ nhiều client cùng lúc thì phải có nhiều process.
**Giám sát:** `postmaster` cần luôn rảnh để chấp nhận connection mới và theo dõi process con;
nếu nó bận chạy query, cả cluster mất khả năng nhận kết nối.

**A8.** `idle` là connection rảnh, **không giữ gì cả** — chỉ tốn một process và một ít bộ nhớ.

`idle in transaction` có transaction đang mở, nên nó:

1. Giữ mọi lock transaction đã lấy — có thể chặn `ALTER TABLE`, `VACUUM FULL`, hoặc chính
   các transaction khác.
2. Giữ một snapshot cũ, khiến VACUUM **không dọn được dead tuple trên toàn bộ database**,
   không chỉ bảng nó chạm. Đây là nguyên nhân bloat lan rộng.
3. Giữ `backend_xmin`, cản trở việc freeze và làm tăng nguy cơ xid wraparound.

Biện pháp: đặt `idle_in_transaction_session_timeout`, và cảnh báo khi có session vượt ngưỡng.

**A9.** View `v` chứa một **optimization fence**. Điều kiện `user_id = 42` bị áp dụng **bên
ngoài** subquery, tức là phần bên trong view đã chạy trên toàn bộ dữ liệu trước khi lọc.
Nguyên nhân thường là window function, `DISTINCT`, `LIMIT`, hoặc `GROUP BY` với điều kiện đặt
trên aggregate. Khi thấy `Subquery Scan` kèm `Filter` trong plan, hãy đọc lại định nghĩa view.

**A10.** PostgreSQL dùng **hai tầng cache**: `shared_buffers` và OS page cache. Đặt
`shared_buffers` chiếm 75% RAM sẽ:

1. Cướp RAM của OS page cache, làm mọi lần `shared read` đều phải xuống đĩa thật.
2. Gây double buffering nặng: cùng một page tồn tại ở cả hai nơi, lãng phí RAM.
3. Kéo dài thời gian checkpoint, vì có nhiều dirty buffer hơn phải ghi cùng lúc.
4. Không còn chỗ cho `work_mem` của các backend, dễ dẫn tới OOM.

Khuyến nghị phổ biến là khoảng 25% RAM, và điều chỉnh dựa trên đo đạc tỷ lệ cache hit thực tế.

---

## Phần C — Đáp án cho [bai-tap.md](bai-tap.md)

**Bài 1.** Triệu chứng khi từng process nền chết: xem bảng ở mục 2.2 của
[README.md](README.md). `pg_terminate_backend` trên một client backend chỉ làm connection đó
đứt; `postmaster` vẫn hoạt động bình thường. Nếu một process nền bị kill bằng `SIGKILL`,
`postmaster` thường khởi động lại toàn bộ cluster ở chế độ recovery — đó là cơ chế bảo vệ
tính nhất quán của shared memory.

**Bài 2.** TPS thường tăng gần tuyến tính tới khoảng `số core`, đi ngang trong khoảng
`số core × 2` đến `số core × 4`, rồi giảm. Nút thắt lần lượt là: CPU, sau đó là tranh chấp
lock trong shared memory và context switch. Đây chính là lý do PgBouncer ở chế độ transaction
pooling lại làm hệ thống **nhanh hơn** dù số connection tới database ít đi — nó giữ số
process ở vùng tối ưu.

**Bài 3.** Tỷ lệ **giảm** khi query nặng hơn. Chi phí mở connection gần như cố định (~5ms),
còn thời gian chạy query thì tăng. Với `SELECT 1` (0,067ms), chi phí connection lớn gấp 75
lần. Với một query 200ms, nó chỉ thêm 2,5%.

Hệ quả: ứng dụng chịu thiệt nhiều nhất là loại có **nhiều query nhỏ** — API CRUD, trang web
render nhiều widget, microservice gọi database liên tục. Hệ thống chạy báo cáo nặng thì gần
như không bị ảnh hưởng.

**Bài 4.** Phân loại:

| Câu lệnh | Chặng | Thông báo |
|---|---|---|
| `SELECT * FROM orders WHERE;` | **Parser** | `syntax error at or near ";"` |
| `SELECT * FROM orders WHERE khong_co = 1;` | **Analyzer** | `column "khong_co" does not exist` |
| `SELECT * FROM orders ORDER BY 99;` | **Analyzer** | `ORDER BY position 99 is not in select list` |
| `SELECT 1/0;` | **Planner** | `division by zero` |
| `SELECT * FROM orders WHERE id = 'chuoi_khong_phai_so';` | **Analyzer** | `invalid input syntax for type bigint` |
| `INSERT ... user_id = 999999999` | **Executor** (qua trigger FK) | `violates foreign key constraint` |

Hai câu đáng chú ý:

- **`SELECT 1/0` chết ở Planner, không phải Executor.** Kiểm chứng: `EXPLAIN SELECT 1/0;`
  cũng báo lỗi — mà `EXPLAIN` không chạy Executor. Nguyên nhân là **constant folding**:
  planner tính sẵn các biểu thức hằng số để đơn giản hóa plan, và phép chia nổ ngay lúc đó.
- **Câu `INSERT` chết ở Executor**, thông qua trigger kiểm tra foreign key — chính câu
  `SELECT ... FOR KEY SHARE` mà bạn đã nhìn thấy trong `pg_stat_statements` ở Bài 8 của Phần 00.

**Bài 5.** `DISTINCT`, `LIMIT` và window function đều là fence. `GROUP BY` thì tùy: điều
kiện trên **grouping column** vẫn được đẩy vào trong (planner biết việc lọc trước hay sau
không đổi kết quả); điều kiện trên **kết quả aggregate** (dạng `HAVING`) thì không.

PostgreSQL không được phép đẩy điều kiện qua window function vì `row_number()` được định
nghĩa trên toàn bộ tập row của window. Lọc trước rồi mới đánh số cho ra kết quả **khác về
mặt ngữ nghĩa**, không phải chỉ khác về tốc độ. Trình tối ưu chỉ được phép biến đổi khi kết
quả không đổi.

**Bài 6.** Kết quả đo được:

```text
-- CTE thường (PostgreSQL 12+): được inline
 Gather
   Workers Planned: 2
   ->  Parallel Seq Scan on orders
         Filter: (user_id = 42)

-- CTE MATERIALIZED: là fence
 CTE Scan on d
   Filter: (user_id = 42)
   CTE d
     ->  Seq Scan on orders
```

Bản inline đẩy được điều kiện xuống tận Seq Scan và còn dùng được parallel query. Bản
`MATERIALIZED` phải vật chất hóa toàn bộ 1 triệu row rồi mới lọc.

Lời khuyên cũ "dùng CTE để ép thứ tự thực thi" **không còn đúng** từ PostgreSQL 12. Rủi ro
khi nâng cấp là ngược lại với trực giác: query từng nhanh nhờ CTE chặn planner **có thể chậm
đi**, vì giờ planner được tự do gộp và có thể chọn nhầm. Khi nâng cấp, hãy tìm các CTE quan
trọng và cân nhắc thêm `MATERIALIZED` một cách tường minh nếu hành vi cũ mới là hành vi đúng.

**Bài 7.** Cách phát hiện từ phía application: bật `auto_explain` với
`auto_explain.log_nested_statements = on` để bắt plan thật của lần chạy chậm. Chạy `EXPLAIN`
tay trong `psql` sẽ **luôn** cho custom plan, nên không bao giờ tái hiện được — đây chính là
lý do loại sự cố này nổi tiếng khó chẩn đoán.

Ngoài ra có thể so sánh `mean_exec_time` với `stddev_exec_time` trong `pg_stat_statements`:
độ lệch chuẩn lớn bất thường trên một query id duy nhất là dấu hiệu hai plan khác nhau đang
được dùng cho cùng câu query.

**Bài 8.** Công thức trần lý thuyết:

```text
shared_buffers + (max_connections × số_node_cần_bộ_nhớ × (1 + parallel_workers) × work_mem)
= 256MB + (100 × 3 × 3 × 4MB)
= 256MB + 3600MB
≈ 3,8 GB
```

Con số này gần như không xảy ra vì đòi hỏi cả 100 connection **đồng thời** chạy query có 3
node cần bộ nhớ và đều đạt parallel tối đa. Thực tế nên tính theo tải quan sát được: lấy
`work_mem` nhân với số query nặng chạy song song ở giờ cao điểm.

Trả lời sếp: cần biết (1) kích thước working set — phần dữ liệu thực sự được truy cập thường
xuyên, không phải tổng dung lượng database; (2) số query đồng thời ở giờ cao điểm; (3) tỷ
trọng query cần sort/hash lớn. Nguyên tắc chung: đủ RAM để working set nằm trong cache, cộng
biên an toàn cho `work_mem`.

**Bài 9.** Một cách viết:

```sql
SELECT
    count(*) FILTER (WHERE state = 'active')                     AS dang_chay,
    count(*) FILTER (WHERE state = 'idle')                       AS ranh,
    count(*) FILTER (WHERE state = 'idle in transaction')        AS idle_in_tx,
    count(*) FILTER (WHERE wait_event_type = 'Lock')             AS dang_cho_lock,
    COALESCE(max(EXTRACT(epoch FROM now() - xact_start))
             FILTER (WHERE state = 'idle in transaction'), 0)::int AS idle_tx_lau_nhat_giay,
    COALESCE(max(EXTRACT(epoch FROM now() - query_start))
             FILTER (WHERE state = 'active'), 0)::int              AS query_lau_nhat_giay
FROM pg_stat_activity
WHERE backend_type = 'client backend'
  AND pid <> pg_backend_pid();
```

Chạy bằng `\watch 2`. Bốn con số đầu cho biết hệ thống đang ở trạng thái nào, hai con số sau
chỉ thẳng tới thủ phạm nếu có.
