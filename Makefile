# ─────────────────────────────────────────────────────
# InfoVoto Perú 2026 — Makefile
# ─────────────────────────────────────────────────────
# Puertos: gateway=2080 gradio=2860 postgres=2432 redis=2379

DC = docker compose
DC_SCRAPER = docker compose --profile scraper

.PHONY: help build up down restart logs ps \
        test test-gateway test-scraper test-all \
        scrape lint migrate shell-gw shell-db \
        clean nuke

# ── Info ─────────────────────────────────────────────

help: ## Mostrar esta ayuda
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ── Build & Run ──────────────────────────────────────

build: ## Buildear todas las imágenes
	$(DC_SCRAPER) build

up: ## Levantar gateway + gradio + postgres + redis
	$(DC) up -d
	@echo "\n  Gateway: http://localhost:2080"
	@echo "  Gradio:  http://localhost:2860"
	@echo "  Postgres: localhost:2432"
	@echo "  Redis:   localhost:2379\n"

up-all: ## Levantar todo incluyendo scraper
	$(DC_SCRAPER) up -d

up-logs: ## Levantar todo con logs en foreground
	$(DC) up

down: ## Bajar todos los servicios
	$(DC_SCRAPER) down

restart: ## Restart gateway + gradio (sin tocar DB)
	$(DC) restart gateway gradio

logs: ## Ver logs de todos los servicios
	$(DC) logs -f

logs-gw: ## Ver logs solo del gateway
	$(DC) logs -f gateway

logs-gradio: ## Ver logs solo de gradio
	$(DC) logs -f gradio

ps: ## Estado de servicios
	$(DC_SCRAPER) ps -a

# ── Tests ────────────────────────────────────────────

test: test-gateway ## Alias: testear gateway

test-gateway: ## Tests unitarios del gateway
	$(DC) exec gateway pytest tests/ -v --tb=short

test-scraper: ## Tests unitarios del scraper
	$(DC_SCRAPER) run --rm scraper pytest tests/ -v --tb=short

test-all: test-gateway test-scraper ## Testear gateway + scraper

test-cov: ## Tests con cobertura
	$(DC) exec gateway pytest tests/ -v --cov=src --cov-report=term-missing

# ── Scraper ──────────────────────────────────────────

scrape: ## Ejecutar scraper manualmente
	$(DC_SCRAPER) run --rm scraper python -m src.scraper.main

scrape-pdf: ## Procesar PDFs de planes de gobierno
	$(DC_SCRAPER) run --rm scraper python -m src.scraper.pdf.processor

scrape-news: ## Scrape noticias
	$(DC_SCRAPER) run --rm scraper python -m src.scraper.news.aggregator

# ── Database ─────────────────────────────────────────

migrate: ## Correr migraciones Alembic
	$(DC) exec gateway alembic upgrade head

migrate-new: ## Crear nueva migración (usar: make migrate-new MSG="add users table")
	$(DC) exec gateway alembic revision --autogenerate -m "$(MSG)"

shell-db: ## Abrir psql en postgres
	$(DC) exec postgres psql -U infovoto -d infovoto

shell-redis: ## Abrir redis-cli
	$(DC) exec redis redis-cli

# ── Dev Utilities ────────────────────────────────────

shell-gw: ## Shell dentro del container gateway
	$(DC) exec gateway bash

shell-scraper: ## Shell dentro del container scraper
	$(DC_SCRAPER) run --rm scraper bash

lint: ## Linter (ruff) en gateway y scraper
	$(DC) exec gateway ruff check src/ tests/
	$(DC_SCRAPER) run --rm scraper ruff check src/ tests/

fmt: ## Formatear código (ruff format)
	$(DC) exec gateway ruff format src/ tests/

health: ## Check health de todos los servicios
	@echo "Gateway:  $$(curl -s -o /dev/null -w '%{http_code}' http://localhost:2080/health)"
	@echo "Gradio:   $$(curl -s -o /dev/null -w '%{http_code}' http://localhost:2860/)"
	@echo "Postgres: $$(docker compose exec postgres pg_isready -U infovoto > /dev/null 2>&1 && echo 'OK' || echo 'DOWN')"
	@echo "Redis:    $$(docker compose exec redis redis-cli ping 2>/dev/null || echo 'DOWN')"

# ── Cleanup ──────────────────────────────────────────

clean: ## Bajar servicios y borrar volúmenes
	$(DC_SCRAPER) down -v

nuke: ## Borrar TODO: containers, imágenes, volúmenes, cache
	$(DC_SCRAPER) down -v --rmi local
	docker builder prune -f
