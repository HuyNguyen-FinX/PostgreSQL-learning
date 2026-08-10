-- =============================================================================
--  02-seed.sql — sinh dữ liệu mẫu
-- =============================================================================
--  Chạy được nhiều lần: script TRUNCATE toàn bộ trước khi nạp lại.
--
--  Kích thước dữ liệu điều khiển bằng biến của psql. Không truyền gì thì dùng
--  bộ nhỏ (dataset "lab"):
--
--      psql -f /sql/02-seed.sql
--
--  Bộ lớn (dataset "lab_big"):
--
--      psql -v n_categories=200 -v n_users=200000 \
--           -v n_products=20000 -v n_orders=1000000 \
--           -f /sql/02-seed.sql
--
--  Dữ liệu được sinh có SKEW (phân bố lệch) một cách cố ý — xem README.
-- =============================================================================

\if :{?n_categories}
\else
\set n_categories 20
\endif

\if :{?n_users}
\else
\set n_users 5000
\endif

\if :{?n_products}
\else
\set n_products 1000
\endif

\if :{?n_orders}
\else
\set n_orders 20000
\endif

\echo '>>> categories=':n_categories ' users=':n_users ' products=':n_products ' orders=':n_orders

-- setseed() cố định chuỗi số ngẫu nhiên của random() trong session này, để dữ
-- liệu sinh ra giống nhau ở mọi máy. Nhờ vậy con số trong bài giảng khớp với
-- con số bạn nhìn thấy.
SELECT setseed(0.42);

TRUNCATE payments, order_items, orders, products, users, categories
    RESTART IDENTITY CASCADE;

-- ── categories ───────────────────────────────────────────────────────────────
-- 10 category gốc, phần còn lại là category con.
INSERT INTO categories (id, name, parent_id)
SELECT g,
       'Category ' || g,
       CASE WHEN g <= 10 THEN NULL ELSE 1 + (g % 10) END
FROM generate_series(1, :n_categories) AS g;

-- ── users ────────────────────────────────────────────────────────────────────
-- country_code lệch nặng: VN 70%, US 15%, JP 8%, SG 5%, DE 2%.
-- Đây là nguyên liệu để Phần 06 nói về MCV list và selectivity.
INSERT INTO users (id, email, full_name, country_code, status, created_at)
SELECT g,
       'user' || g || '@example.com',
       'User ' || g,
       CASE
           WHEN g % 100 < 70 THEN 'VN'
           WHEN g % 100 < 85 THEN 'US'
           WHEN g % 100 < 93 THEN 'JP'
           WHEN g % 100 < 98 THEN 'SG'
           ELSE                      'DE'
       END,
       CASE
           WHEN g % 50 = 0 THEN 'banned'
           WHEN g % 7  = 0 THEN 'inactive'
           ELSE                 'active'
       END,
       now() - (random() * interval '730 days')
FROM generate_series(1, :n_users) AS g;

-- ── products ─────────────────────────────────────────────────────────────────
INSERT INTO products (id, sku, name, category_id, price, stock, created_at)
SELECT g,
       'SKU-' || lpad(g::text, 8, '0'),
       'Product ' || g,
       1 + (g % :n_categories),
       round((random() * 990 + 10)::numeric, 2),
       (random() * 500)::int,
       now() - (random() * interval '900 days')
FROM generate_series(1, :n_products) AS g;

-- ── orders ───────────────────────────────────────────────────────────────────
-- user_id dùng power(random(), 2) nên lệch về phía user id nhỏ: một số ít user
-- có rất nhiều order, phần lớn user có vài order. Phân bố này giống thực tế và
-- là nguyên nhân khiến planner ước lượng sai ở Phần 06.
INSERT INTO orders (id, user_id, status, total_amount, created_at)
SELECT g,
       1 + (floor(power(random(), 2) * :n_users))::bigint,
       CASE
           WHEN g % 100 < 80 THEN 'completed'
           WHEN g % 100 < 90 THEN 'shipped'
           WHEN g % 100 < 97 THEN 'pending'
           ELSE                   'cancelled'
       END,
       0,
       now() - (random() * interval '365 days')
FROM generate_series(1, :n_orders) AS g;

-- ── order_items ──────────────────────────────────────────────────────────────
-- Mỗi order có 1..4 item, trung bình 2.5 item.
INSERT INTO order_items (order_id, product_id, quantity, unit_price)
SELECT x.order_id, x.product_id, x.quantity, p.price
FROM (
    SELECT o.id                                            AS order_id,
           1 + (floor(random() * :n_products))::bigint     AS product_id,
           1 + (floor(random() * 3))::int                  AS quantity
    FROM orders o, generate_series(1, 1 + (o.id % 4)) AS s
) AS x
JOIN products p ON p.id = x.product_id;

-- total_amount được tính lại cho khớp với order_items.
--
-- Lưu ý: câu UPDATE này chạm vào TOÀN BỘ row của orders. Trong PostgreSQL, UPDATE
-- không sửa tại chỗ mà ghi ra một version mới của tuple rồi đánh dấu version cũ là
-- dead tuple. Kết quả: bảng orders phình lên gần gấp đôi. Đây chính là hiện tượng
-- Phần 03 và Phần 04 sẽ mổ xẻ.
--
-- Ở đây ta dọn sạch nó ngay bằng VACUUM FULL ở cuối script, để dataset khởi điểm
-- không mang sẵn bloat. Bloat phải là thứ bạn tự tạo ra khi học Phần 04, không
-- phải thứ có sẵn mà không biết từ đâu ra.
UPDATE orders o
SET total_amount = t.amount
FROM (
    SELECT order_id, sum(quantity * unit_price) AS amount
    FROM order_items
    GROUP BY order_id
) AS t
WHERE t.order_id = o.id;

-- ── payments ─────────────────────────────────────────────────────────────────
-- 90% order có payment; 10% còn lại cố tình bỏ trống để có dữ liệu cho các
-- bài về LEFT JOIN, anti-join và NOT EXISTS.
INSERT INTO payments (order_id, method, amount, status, created_at)
SELECT o.id,
       (ARRAY['card', 'bank_transfer', 'wallet', 'cod'])[1 + (o.id % 4)],
       o.total_amount,
       CASE WHEN o.status = 'cancelled' THEN 'refunded' ELSE 'succeeded' END,
       o.created_at + interval '5 minutes'
FROM orders o
WHERE o.id % 10 <> 0;

-- ── Đồng bộ lại sequence ─────────────────────────────────────────────────────
-- categories/users/products/orders được insert bằng id tường minh, nên sequence
-- phía sau identity column vẫn đang ở giá trị cũ. Nếu quên bước này, lần INSERT
-- tiếp theo không truyền id sẽ lỗi duplicate key. Đây là lỗi kinh điển khi nạp
-- dữ liệu từ dump hoặc từ script seed.
SELECT setval(pg_get_serial_sequence('categories', 'id'), max(id)) FROM categories;
SELECT setval(pg_get_serial_sequence('users',      'id'), max(id)) FROM users;
SELECT setval(pg_get_serial_sequence('products',   'id'), max(id)) FROM products;
SELECT setval(pg_get_serial_sequence('orders',     'id'), max(id)) FROM orders;

-- ── Dọn dẹp và cập nhật statistics ───────────────────────────────────────────
-- VACUUM FULL viết lại toàn bộ bảng orders sang file mới, loại bỏ hẳn dead tuple
-- và trả disk lại cho hệ điều hành. VACUUM thường KHÔNG làm được điều này — nó chỉ
-- đánh dấu không gian là dùng lại được. Khác biệt đó là nội dung chính của Phần 04.
--
-- VACUUM FULL giữ ACCESS EXCLUSIVE LOCK trên bảng, tức là chặn cả đọc lẫn ghi.
-- Ở đây chấp nhận được vì đang seed. TUYỆT ĐỐI không chạy nó trên production
-- mà không có kế hoạch downtime.
VACUUM (FULL) orders;

-- Bắt buộc phải có bước này SAU `VACUUM FULL`.
--
-- `VACUUM FULL` viết lại bảng sang file mới nhưng KHÔNG dựng lại Visibility Map:
-- sau khi nó chạy xong, không page nào được đánh dấu all-visible. Mà Index Only Scan
-- chỉ hoạt động khi page đã all-visible — nếu không, PostgreSQL vẫn phải quay về heap
-- để kiểm tra tính hiển thị của từng tuple.
--
-- Đo được trên dataset lớn:
--   Ngay sau VACUUM FULL   : all_visible = 0/9163 page  → Bitmap Heap Scan, 195 buffer
--   Sau VACUUM thường      : all_visible = 9163/9163    → Index Only Scan,   20 buffer
--
-- Đây không phải chuyện của riêng script seed. Trên production, sau mỗi lần
-- `VACUUM FULL` hoặc `pg_repack`, các query đang dựa vào Index Only Scan sẽ chậm đi
-- cho tới lần VACUUM kế tiếp. Chi tiết ở Phần 02 (Visibility Map) và Phần 05.
VACUUM (ANALYZE) categories, users, products, orders, order_items, payments;

\echo '>>> Seed xong.'
