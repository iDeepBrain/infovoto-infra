# ─────────────────────────────────────────────────────
# InfoVoto Perú 2026 — Makefile
# ─────────────────────────────────────────────────────
# Puertos: gateway=2080 web=2300 mcp=2900 postgres=2432 redis=2379

DC = docker compose
DC_SCRAPER = docker compose --profile scraper
DC_DEV = docker compose --profile dev

.PHONY: help build up down restart logs ps \
        test test-all \
        test-gateway test-mcp test-scraper test-web test-gradio \
        test-integration test-stress test-eval test-cov \
        scrape lint migrate shell-gw shell-db \
        clean nuke \
        git-status git-commit

# ── Info ─────────────────────────────────────────────

help: ## Mostrar esta ayuda
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ── Build & Run ──────────────────────────────────────

build: ## Buildear todas las imágenes
	$(DC_SCRAPER) build

up: ## Levantar gateway + web + infovoto-mcp + postgres + redis
	$(DC) up -d
	@echo "\n  Gateway:  http://localhost:2080"
	@echo "  Web:      http://localhost:2300"
	@echo "  MCPs:     http://localhost:2900"
	@echo "  Postgres: localhost:2432"
	@echo "  Redis:    localhost:2379\n"

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
# Niveles:
#   test-gateway    → unit tests del gateway (sin Docker externo)
#   test-mcp        → unit tests del MCP demo + tools
#   test-scraper    → unit tests del scraper
#   test-web        → build check del frontend Next.js
#   test-gradio     → smoke test del Gradio (health del endpoint)
#   test-integration → flujo completo gateway↔mcp (requiere make up)
#   test-stress     → carga concurrente (requiere make up)
#   test-eval       → LLM-as-judge: tono, seguridad, comprensión, empatía
#   test-cov        → cobertura de código del gateway
#   test            → unit: gateway + mcp (rápido, sin DB real)
#   test-all        → todo: unit + integration + stress

IGNORE_INT = --ignore=tests/integration --ignore=tests/stress --ignore=tests/eval

test: ## Tests unitarios rápidos: gateway + mcp (no requieren datos reales)
	@echo "\n\033[1m[1/2] Gateway unit tests\033[0m"
	$(DC) exec gateway pytest tests/ -v --tb=short $(IGNORE_INT)
	@echo "\n\033[1m[2/2] MCP unit tests\033[0m"
	$(DC) exec infovoto-mcp pytest tests/ -v --tb=short

test-gateway: ## Unit tests del gateway (models, middleware, agent lógica)
	$(DC) exec gateway pytest tests/ -v --tb=short $(IGNORE_INT)

test-mcp: ## Unit tests del MCP: 5 tools demo, endpoints /health y /metadata
	$(DC) exec infovoto-mcp pytest tests/ -v --tb=short

test-scraper: ## Unit tests del scraper (requiere perfil scraper)
	$(DC_SCRAPER) run --rm scraper pytest tests/ -v --tb=short

test-web: ## Build check del frontend Next.js (detecta errores TypeScript)
	$(DC) exec web sh -c "npm run build 2>&1 | tail -20" || \
		docker run --rm -v $$(pwd)/../infovoto-web:/app -w /app node:20-alpine sh -c "npm run build 2>&1 | tail -20"

test-gradio: ## Smoke test Gradio: verifica que responde (requiere make up-dev)
	@echo "Gradio UI:    $$(curl -s -o /dev/null -w '%{http_code}' http://localhost:2860/)"
	@echo "Gateway→MCP:  $$(curl -s http://localhost:2900/demo/health | python3 -c \"import sys,json; d=json.load(sys.stdin); print(d['status'])\")"

test-integration: ## Flujo completo: auth → chat → MCP demo → respuesta (requiere make up)
	$(DC) exec gateway pytest tests/integration/ -v --tb=short -s

test-stress: ## Carga concurrente N usuarios (requiere make up, STRESS_USERS=10 STRESS_REQUESTS=30)
	$(DC) exec -e STRESS_USERS=$(or $(USERS),10) -e STRESS_REQUESTS=$(or $(REQ),30) \
		gateway pytest tests/stress/ -v --tb=short -s

test-eval: ## LLM-as-judge: tono/seguridad/comprensión/empatía sobre 10 queries (requiere GOOGLE_API_KEY)
	$(DC) exec gateway python -m tests.eval.pipeline --output /tmp/eval_results.json
	@echo "\nResultados guardados en /tmp/eval_results.json (dentro del container)"
	@echo "Para copiar al host: docker compose cp gateway:/tmp/eval_results.json ."

test-cov: ## Gateway con cobertura de código (HTML + terminal)
	$(DC) exec gateway pytest tests/ -v --cov=src --cov-report=term-missing --cov-report=html:/tmp/htmlcov \
		$(IGNORE_INT)
	@echo "\nCobertura HTML en /tmp/htmlcov (dentro del container)"

test-all: test test-integration test-stress ## Todo: unit + integration + stress (requiere make up)

# ── Scraper ──────────────────────────────────────────

scrape-critical: ## Descargar fuentes críticas (JNE, ONPE)
	$(DC_SCRAPER) run --rm scraper python -m src.scraper.main --task=download-critical

scrape-all: ## Descargar TODAS las fuentes
	$(DC_SCRAPER) run --rm scraper python -m src.scraper.main --task=download-all

scrape-jne-planes: ## Descargar planes de gobierno del JNE
	$(DC_SCRAPER) run --rm scraper python -m src.scraper.main --task=download-jne-planes

scrape-jne-candidatos: ## Descargar candidatos del JNE
	$(DC_SCRAPER) run --rm scraper python -m src.scraper.main --task=download-jne-candidatos

scrape-pdfs: ## Extraer texto de PDFs descargados
	$(DC_SCRAPER) run --rm scraper python -m src.scraper.main --task=process-pdfs

scrape-news: ## Scrape noticias electorales
	$(DC_SCRAPER) run --rm scraper python -m src.scraper.main --task=news

scrape-shell: ## Shell interactivo en container scraper
	$(DC_SCRAPER) run --rm scraper bash

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
	@echo "Web:      $$(curl -s -o /dev/null -w '%{http_code}' http://localhost:2300/)"
	@echo "MCPs:     $$(curl -s -o /dev/null -w '%{http_code}' http://localhost:2900/health)"
	@echo "Postgres:     $$(docker compose exec postgres pg_isready -U infovoto > /dev/null 2>&1 && echo 'OK' || echo 'DOWN')"
	@echo "Redis:        $$(docker compose exec redis redis-cli ping 2>/dev/null || echo 'DOWN')"

logs-web: ## Ver logs del web frontend
	$(DC) logs -f web

logs-mcp: ## Ver logs de infovoto-mcp
	$(DC) logs -f infovoto-mcp

restart-gateway: ## Restart solo gateway (carga nueva config MCP)
	$(DC) restart gateway

# ── Git Global ───────────────────────────────────────

git-status: ## Ver estado de todos los repos
	@bash scripts/git/status-all.sh

git-commit: ## Commitear y pushear todos los repos (usar: make git-commit m="mensaje")
	@bash scripts/git/commit-all.sh "$(m)"

# ── Cleanup ──────────────────────────────────────────

clean: ## Bajar servicios y borrar volúmenes
	$(DC_SCRAPER) down -v

nuke: ## Borrar TODO: containers, imágenes, volúmenes, cache
	$(DC_SCRAPER) down -v --rmi local
	docker builder prune -f
