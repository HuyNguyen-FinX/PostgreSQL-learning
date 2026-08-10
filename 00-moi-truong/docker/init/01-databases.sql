-- =============================================================================
--  Tạo database thứ hai cho dataset lớn.
-- =============================================================================
--  Hai database, cùng một schema, khác nhau ở kích thước dữ liệu:
--
--    lab      — dataset nhỏ (~20k order). Dùng để đọc Execution Plan, thử MVCC,
--               thử lock. Chạy nhanh, reset nhanh.
--    lab_big  — dataset lớn (~1 triệu order). Dùng khi cần thấy sự khác biệt
--               thật về hiệu năng: Sequential Scan vs Index Scan, Hash Join vs
--               Nested Loop, spill to disk, parallel query.
--
--  Lý do tách ra: trên dataset nhỏ, PostgreSQL thường chọn Sequential Scan cho
--  mọi thứ vì bảng vừa đủ nhỏ để đọc hết còn rẻ hơn đi qua index. Nếu chỉ học
--  trên dataset nhỏ, bạn sẽ kết luận sai rằng "index không có tác dụng".
-- =============================================================================

CREATE DATABASE lab_big;
