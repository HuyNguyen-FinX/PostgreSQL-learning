# =============================================================================
#  Các lệnh hay dùng khi thực hành. Chạy `make` để xem danh sách.
# =============================================================================

COMPOSE := docker compose -f 00-moi-truong/docker/docker-compose.yml
PSQL    := $(COMPOSE) exec -T db psql -U lab -v ON_ERROR_STOP=1

.DEFAULT_GOAL := help
.PHONY: help up down restart reset ps logs psql psql-big seed-small seed-big sizes

help: ## Hiện danh sách lệnh
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

up: ## Dựng PostgreSQL (lần đầu sẽ tự tạo schema + nạp dataset nhỏ)
	$(COMPOSE) up -d

down: ## Dừng container, GIỮ NGUYÊN dữ liệu
	$(COMPOSE) down

restart: ## Restart PostgreSQL (cần sau khi sửa postgresql.conf)
	$(COMPOSE) restart db

reset: ## XÓA SẠCH dữ liệu và dựng lại từ đầu
	$(COMPOSE) down -v
	$(COMPOSE) up -d

ps: ## Trạng thái container
	$(COMPOSE) ps

logs: ## Theo dõi log PostgreSQL (Ctrl-C để thoát)
	$(COMPOSE) logs -f --no-log-prefix db

psql: ## Mở psql vào database `lab` (dataset nhỏ)
	$(COMPOSE) exec db psql -U lab -d lab

psql-big: ## Mở psql vào database `lab_big` (dataset lớn)
	$(COMPOSE) exec db psql -U lab -d lab_big

seed-small: ## Nạp lại dataset nhỏ vào `lab`
	$(PSQL) -d lab -f /sql/02-seed.sql

seed-big: ## Nạp dataset lớn vào `lab_big` (~35 giây)
	$(PSQL) -d lab_big \
		-v n_categories=200 -v n_users=200000 \
		-v n_products=20000 -v n_orders=1000000 \
		-f /sql/02-seed.sql

sizes: ## Xem kích thước bảng ở cả hai database
	@echo '── lab ──'
	@$(PSQL) -d lab -c "SELECT relname AS bang, to_char(n_live_tup,'FM999,999,999') AS so_row, pg_size_pretty(pg_total_relation_size(relid)) AS kich_thuoc FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC;"
	@echo '── lab_big ──'
	@$(PSQL) -d lab_big -c "SELECT relname AS bang, to_char(n_live_tup,'FM999,999,999') AS so_row, pg_size_pretty(pg_total_relation_size(relid)) AS kich_thuoc FROM pg_stat_user_tables ORDER BY pg_total_relation_size(relid) DESC;"
