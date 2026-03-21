# ─────────────────────────────────────────────────────
# InfoVoto Perú 2026 — Makefile
# ─────────────────────────────────────────────────────
# Puertos: gateway=2080 web=2300 mcp=2900 postgres=2432 redis=2379 metabase=2010

DC = docker compose
DC_SCRAPER = docker compose --profile scraper
DC_DEV = docker compose --profile dev
DC_EVAL = docker compose --profile eval

.PHONY: help build up down restart logs ps \
        test test-all \
        test-gateway test-mcp test-scraper test-web test-gradio \
        test-integration test-stress test-eval test-cov \
        eval-stress eval-adversarial eval-build \
        scrape lint migrate shell-gw shell-db shell-redis \
        cache-flush cache-flush-all \
        clean nuke \
        git-status git-commit \
        env-check env-sync

# ── Info ─────────────────────────────────────────────

help: ## Mostrar esta ayuda
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: metabase-up metabase-setup metabase-shell metabase-logs

# ── Build & Run ──────────────────────────────────────

build: ## Buildear imágenes del stack principal (gateway + web + mcp)
	$(DC) build

up: ## Levantar stack completo (gateway + web + mcp + postgres + redis)
	$(DC) up -d
	@echo "\n  Gateway:  http://localhost:2080"
	@echo "  Web:      http://localhost:2300"
	@echo "  MCPs:     http://localhost:2900"
	@echo "  Postgres: localhost:2432"
	@echo "  Redis:    localhost:2379\n"

up-dev: ## Levantar stack + gradio (debug UI en localhost:2860)
	$(DC_DEV) up -d

up-logs: ## Levantar stack con logs en foreground
	$(DC) up

down: ## Bajar todos los servicios
	$(DC) down

restart: ## Restart gateway (recarga MCP registry y config)
	$(DC) restart gateway

logs: ## Ver logs de todos los servicios
	$(DC) logs -f

logs-gw: ## Ver logs solo del gateway
	$(DC) logs -f gateway

logs-gradio: ## Ver logs solo de gradio
	$(DC) logs -f gradio

ps: ## Estado de servicios
	$(DC_SCRAPER) ps -a

# ── Tests ────────────────────────────────────────────
# test          → unit: gateway + mcp (rápido, no requiere nada externo)
# test-gateway  → solo unit tests del gateway
# test-mcp      → solo unit tests del mcp (5 tools demo + /health + /metadata)
# test-integration → flujo completo gateway↔mcp (requiere make up)
# test-all      → unit + integration (requiere make up)

IGNORE_INT = --ignore=tests/integration --ignore=tests/stress --ignore=tests/eval --ignore=tests/reality

test: ## Unit tests: gateway + mcp (rápido, requiere make up)
	@echo "\n\033[1m[1/2] Gateway unit tests\033[0m"
	$(DC) exec gateway pytest tests/ -v --tb=short $(IGNORE_INT)
	@echo "\n\033[1m[2/2] MCP unit tests\033[0m"
	$(DC) exec infovoto-mcp pytest tests/ -v --tb=short

test-gateway: ## Unit tests del gateway
	$(DC) exec gateway pytest tests/ -v --tb=short $(IGNORE_INT)

test-mcp: ## Unit tests del mcp (5 tools demo + /health + /metadata)
	$(DC) exec infovoto-mcp pytest tests/ -v --tb=short

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
		-e GATEWAY_URL=http://localhost:8080 -e MCP_URL=http://infovoto-mcp:8080 \
		gateway pytest tests/stress/ -v --tb=short -s

test-eval: ## Pipeline completo eval: 105 preguntas + LLM-judge + CSV + gráficos (requiere make up + GOOGLE_API_KEY)
	$(DC_EVAL) run --rm eval python -m tests.eval.run_eval --workers $(or $(workers),2)
	@echo "\nResultados en infovoto-gateway/tests/eval/results/"

eval-stress: ## Solo stress (sin juez LLM) — mide latencia y errores sin gastar tokens
	$(DC_EVAL) run --rm eval python -m tests.eval.run_eval --no-judge --workers $(or $(workers),3)

eval-adversarial: ## Solo categoría adversarial, 1 worker — detecta vulnerabilidades de seguridad
	$(DC_EVAL) run --rm eval python -m tests.eval.run_eval --category adversarial --workers 1

eval-build: ## Buildear imagen del pipeline de evaluación
	$(DC_EVAL) build eval

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

cache-flush: ## Borrar solo cache de queries LLM (mantiene sesiones de usuario)
	$(DC) exec redis redis-cli --scan --pattern "cache:query:*" | xargs -r $(DC) exec -T redis redis-cli DEL
	@echo "Cache de queries limpiado"

cache-flush-all: ## Borrar TODO el cache Redis (queries + sesiones)
	$(DC) exec redis redis-cli FLUSHDB
	@echo "Redis vaciado completamente"

# ── Dev Utilities ────────────────────────────────────

shell-gw: ## Shell dentro del container gateway
	$(DC) exec gateway bash

shell-scraper: ## Shell dentro del container scraper
	$(DC_SCRAPER) run --rm scraper bash

lint: ## Linter (ruff) en gateway y mcp
	$(DC) exec gateway ruff check src/ tests/
	$(DC) exec infovoto-mcp ruff check src/ tests/ 2>/dev/null || echo "  [mcp] ruff no disponible en imagen"

fmt: ## Formatear código (ruff format)
	$(DC) exec gateway ruff format src/ tests/

health: ## Check health de todos los servicios (Docker healthcheck + HTTP)
	@_hc() { docker inspect --format='{{.State.Health.Status}}' "infovoto-$$1-1" 2>/dev/null || echo "no-healthcheck"; }; \
	_http() { curl -s -o /dev/null -w '%{http_code}' "$$1" 2>/dev/null || echo "DOWN"; }; \
	echo "Gateway:  $$(_http http://localhost:2080/health) [docker: $$(_hc gateway)]"; \
	echo "MCPs:     $$(_http http://localhost:2900/health) [docker: $$(_hc infovoto-mcp)]"; \
	echo "Web:      $$(_http http://localhost:2300/) [docker: $$(_hc web)]"; \
	echo "Postgres: $$(docker compose exec postgres pg_isready -U infovoto > /dev/null 2>&1 && echo 'OK' || echo 'DOWN') [docker: $$(_hc postgres)]"; \
	echo "Redis:    $$(docker compose exec redis redis-cli ping 2>/dev/null || echo 'DOWN') [docker: $$(_hc redis)]"; \
	echo "Metabase: $$(_http http://localhost:2010/api/health) [docker: $$(_hc metabase)]"

logs-web: ## Ver logs del web frontend
	$(DC) logs -f web

logs-mcp: ## Ver logs de infovoto-mcp
	$(DC) logs -f infovoto-mcp

restart-gateway: ## Restart solo gateway (carga nueva config MCP)
	$(DC) restart gateway

# ── Metabase ──────────────────────────────────────────

metabase-up: ## Iniciar Metabase (dashboard de analytics)
	$(DC) up -d metabase
	@echo "\n  Metabase: http://localhost:2010\n"

metabase-setup: ## Configurar Metabase automáticamente (requiere que esté corriendo)
	@bash scripts/metabase/setup.sh

metabase-shell: ## Abrir shell interactivo en Metabase
	$(DC) exec metabase bash

metabase-logs: ## Ver logs de Metabase
	$(DC) logs -f metabase

# ── Env ──────────────────────────────────────────────

env-check: ## Verificar keys en .env.config y .env.secrets
	@bash scripts/env/check-env.sh

env-sync: ## Agregar keys faltantes a .env.config automáticamente
	@bash scripts/env/sync-env.sh

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
