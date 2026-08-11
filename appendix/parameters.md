# Phụ lục — Bảng tra cứu tham số

> Cột **`context`** cho biết cách áp dụng thay đổi. Tra bằng:
>
> ```sql
> SELECT name, setting, unit, context, short_desc FROM pg_settings WHERE name = '...';
> ```

| `context` | Cách áp dụng |
|---|---|
| `user` | `SET` ngay trong session |
| `superuser` | `SET`, cần quyền superuser |
| `sighup` | `SELECT pg_reload_conf();` |
| `postmaster` | **Bắt buộc restart cluster** |

---

## 1. Bộ nhớ

| Tham số | Mặc định | Khuyến nghị | `context` | Ghi chú |
|---|---|---|---|---|
| `shared_buffers` | 128MB | **25% RAM** | `postmaster` | Đặt quá lớn làm chậm đi — Phần 01 |
| `work_mem` | 4MB | Giữ thấp, nâng theo role | `user` | **Mỗi node**, không phải mỗi query — Phần 11 |
| `maintenance_work_mem` | 64MB | 512MB–1GB | `user` | Thiếu → `index scans: > 1` — Phần 04 |
| `effective_cache_size` | 4GB | 50–75% RAM | `user` | **Không cấp phát gì**, chỉ gợi ý planner |
| `hash_mem_multiplier` | 2.0 | 2.0 | `user` | Hash node được `work_mem × hệ số` |
| `temp_buffers` | 8MB | 8MB | `user` | Cache cho temporary table |

**Công thức RAM:**

```text
shared_buffers + (connection × node × work_mem)
               + (autovacuum_max_workers × maintenance_work_mem)
               + chừa cho OS page cache
```

---

## 2. Cost model của planner

| Tham số | Mặc định | SSD | `context` | Ghi chú |
|---|---|---|---|---|
| `seq_page_cost` | 1.0 | 1.0 | `user` | Mốc quy chiếu |
| `random_page_cost` | 4.0 | **1.1** | `user` | Để 4.0 trên SSD làm planner ngại dùng index |
| `cpu_tuple_cost` | 0.01 | 0.01 | `user` | Phần 06 có công thức kiểm chứng |
| `cpu_index_tuple_cost` | 0.005 | 0.005 | `user` | |
| `cpu_operator_cost` | 0.0025 | 0.0025 | `user` | |
| `effective_io_concurrency` | 1 | 200 | `user` | Số I/O song song, cho SSD/NVMe |
| `default_statistics_target` | 100 | 100 | `user` | Nâng theo từng column, không nâng toàn cục |

---

## 3. WAL và checkpoint

| Tham số | Mặc định | Khuyến nghị | `context` | Ghi chú |
|---|---|---|---|---|
| `wal_level` | replica | replica / logical | `postmaster` | `logical` sinh nhiều WAL hơn |
| `max_wal_size` | 1GB | Đủ để checkpoint chủ yếu `timed` | `sighup` | Phần 09 |
| `min_wal_size` | 80MB | 1–2GB | `sighup` | |
| `checkpoint_timeout` | 5min | **15–30min** | `sighup` | Thưa hơn = ít WAL hơn, recovery lâu hơn |
| `checkpoint_completion_target` | 0.9 | 0.9 | `sighup` | Trải đều I/O |
| `full_page_writes` | on | **on** | `sighup` | Tắt = mất dữ liệu khi mất điện |
| `synchronous_commit` | on | on (đặt `off` theo transaction) | `user` | `off` mất vài trăm ms, **không** hỏng dữ liệu |
| `wal_compression` | off | on | `superuser` | Giảm WAL, tốn CPU |
| `archive_mode` | off | on nếu cần PITR | `postmaster` | |

---

## 4. Autovacuum

| Tham số | Mặc định | Khuyến nghị | `context` |
|---|---|---|---|
| `autovacuum` | on | **on** | `sighup` |
| `autovacuum_max_workers` | 3 | 3–6 | `postmaster` |
| `autovacuum_naptime` | 1min | 15–30s | `sighup` |
| `autovacuum_vacuum_scale_factor` | 0.2 | **0.01–0.05** cho bảng lớn | `sighup` |
| `autovacuum_vacuum_threshold` | 50 | 1000+ | `sighup` |
| `autovacuum_analyze_scale_factor` | 0.1 | 0.01–0.05 | `sighup` |
| `autovacuum_vacuum_cost_delay` | 2ms | 0–2ms trên SSD | `sighup` |
| `autovacuum_vacuum_cost_limit` | -1 (dùng 200) | 1000–3000 | `sighup` |
| `autovacuum_freeze_max_age` | 200 triệu | 200 triệu | `postmaster` |

**Đặt theo từng bảng** — quan trọng hơn đặt toàn cục:

```sql
ALTER TABLE bang_lon SET (
    autovacuum_vacuum_scale_factor = 0.02,
    autovacuum_vacuum_threshold    = 1000
);
```

---

## 5. Connection và timeout

| Tham số | Mặc định | Khuyến nghị | `context` |
|---|---|---|---|
| `max_connections` | 100 | `số core × 2` đến `× 4` | `postmaster` |
| `statement_timeout` | 0 (tắt) | 30s–60s cho role API | `user` |
| `lock_timeout` | 0 (tắt) | **3–5s, bắt buộc trước DDL** | `user` |
| `idle_in_transaction_session_timeout` | 0 (tắt) | **5min** | `user` |
| `idle_session_timeout` | 0 (tắt) | Tuỳ | `user` |
| `deadlock_timeout` | 1s | 1s | `superuser` |
| `tcp_keepalives_idle` | 0 | 60 | `user` |

Ba tham số in đậm là biện pháp phòng thủ rẻ nhất cho một cluster production.

---

## 6. Parallel query

| Tham số | Mặc định | Ghi chú |
|---|---|---|
| `max_parallel_workers_per_gather` | 2 | Đặt 0 để tắt khi debug |
| `max_parallel_workers` | 8 | Tổng toàn cluster |
| `max_worker_processes` | 8 | Phải ≥ `max_parallel_workers` |
| `min_parallel_table_scan_size` | 8MB | Bảng nhỏ hơn không parallel |
| `parallel_setup_cost` | 1000 | Chi phí khởi tạo worker |

Trong Docker, cần `shm_size` đủ lớn (mặc định 64MB là quá ít).

---

## 7. Replication

| Tham số | Mặc định | Ghi chú |
|---|---|---|
| `max_wal_senders` | 10 | Số replica tối đa |
| `max_replication_slots` | 10 | |
| `max_slot_wal_keep_size` | -1 (không giới hạn) | **Đặt giới hạn** — Phần 10, Case 9 |
| `hot_standby_feedback` | off | `on` chặn VACUUM trên primary |
| `max_standby_streaming_delay` | 30s | Hoãn replay bao lâu trước khi hủy query |
| `synchronous_standby_names` | '' | `ANY 1 (a, b)` — đừng dùng đúng một replica |

---

## 8. Logging

| Tham số | Production | Môi trường học | Ghi chú |
|---|---|---|---|
| `log_min_duration_statement` | 500ms–1s | 200ms | |
| `log_checkpoints` | on | on | |
| `log_lock_waits` | on | on | Ngưỡng là `deadlock_timeout` |
| `log_temp_files` | 1MB | **0** (ghi tất cả) | `0` = tất cả, `-1` = tắt |
| `log_autovacuum_min_duration` | 1s | **0** | |
| `log_line_prefix` | `'%m [%p] %q%u@%d '` | như vậy | |
| `log_connections` | off | off | Rất ồn |

---

## 9. Extension chẩn đoán

| Extension | Tham số | Ghi chú |
|---|---|---|
| `pg_stat_statements` | `pg_stat_statements.max = 10000` | Cần `shared_preload_libraries` |
| | `pg_stat_statements.track = all` | `all` gồm cả câu trong function |
| `auto_explain` | `auto_explain.log_min_duration = '1s'` | |
| | `auto_explain.log_analyze = on` | Thêm chi phí đo cho **mọi** query |
| | `auto_explain.log_timing = off` | Tắt để giảm chi phí, vẫn giữ `rows`/`Buffers` |
| | `auto_explain.log_buffers = on` | |
| | `auto_explain.log_nested_statements = on` | Bắt query trong function/trigger |

---

## 10. Cấu hình khởi điểm cho máy 32 GB RAM, 8 core, SSD

```conf
# Bộ nhớ
shared_buffers = 8GB
effective_cache_size = 24GB
work_mem = 32MB
maintenance_work_mem = 1GB

# Connection
max_connections = 100          # dùng PgBouncer phía trước

# Cost model
random_page_cost = 1.1
effective_io_concurrency = 200

# WAL / checkpoint
wal_level = replica
max_wal_size = 8GB
min_wal_size = 2GB
checkpoint_timeout = 15min
checkpoint_completion_target = 0.9

# Autovacuum
autovacuum_max_workers = 4
autovacuum_naptime = 30s
autovacuum_vacuum_cost_limit = 2000

# Parallel
max_parallel_workers_per_gather = 4
max_parallel_workers = 8

# Timeout
lock_timeout = 5s
idle_in_transaction_session_timeout = 5min

# Logging
log_min_duration_statement = 500ms
log_checkpoints = on
log_lock_waits = on
log_temp_files = 1MB
log_autovacuum_min_duration = 1s

# Chẩn đoán
shared_preload_libraries = 'pg_stat_statements,auto_explain'
track_io_timing = on
```

> **Đây là điểm khởi đầu, không phải đích đến.** Mọi giá trị đều phải điều chỉnh theo số đo
> thực tế của workload. Xem Phần 14 để biết đo cái gì.
