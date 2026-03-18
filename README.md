# infovoto-infra

Orquestador local del stack InfoVoto Perú 2026.
Todos los comandos Docker se corren desde este directorio.

---

## Stack

```
postgres:2432  ←  base de todos
redis:2379     ←  cache + sesiones
infovoto-mcp:2900  ←  5 MCPs (demo + planes + perfiles + ...)
gateway:2080   ←  FastAPI + Gemini agent
web:2300       ←  Next.js frontend
gradio:2860    ←  debug UI (solo con make up-dev)
```

---

## Inicio rápido

```bash
# 1. Configurar variables de entorno (solo la primera vez)
cp ../.env.secrets.example ../.env.secrets   # completar con API keys reales
cp ../.env.config.example  ../.env.config    # ajustar URLs y flags

# 2. Buildear imágenes
make build

# 3. Levantar stack
make up

# 4. Verificar que todo esté healthy
make health
```

---

## Comandos principales

### Build y stack

```bash
make build          # buildear imágenes: gateway + web + mcp
make up             # levantar stack completo (gateway + web + mcp + postgres + redis)
make up-dev         # levantar stack + gradio (debug UI en localhost:2860)
make down           # bajar todos los servicios
make restart        # restart gateway (recarga MCP registry y config)
make health         # verificar estado HTTP + Docker healthcheck de cada servicio
make logs           # ver logs en vivo de todos los servicios
make ps             # estado de todos los containers
```

### Tests

```bash
make test               # unit tests: gateway + mcp (rápido, requiere make up)
make test-gateway       # solo unit tests del gateway
make test-mcp           # solo unit tests del mcp (5 tools demo + /health + /metadata)
make test-integration   # flujo completo gateway↔mcp (requiere make up)
make test-all           # unit + integration
make test-cov           # unit tests con cobertura de código
```

### Base de datos

```bash
make migrate            # correr migraciones Alembic
make migrate-new MSG="descripcion"  # crear nueva migración
make shell-db           # psql interactivo en postgres
make shell-redis        # redis-cli interactivo
```

### Utilidades

```bash
make shell-gw           # bash dentro del container gateway
make lint               # ruff en gateway
make fmt                # ruff format en gateway
make logs-gw            # logs solo del gateway
make logs-mcp           # logs solo del mcp
make logs-web           # logs solo del web
```

### Git global

```bash
make git-status         # estado de todos los repos
make git-commit m="mensaje"   # commitear y pushear todos los repos con cambios
```

### Limpieza

```bash
make clean              # bajar servicios y borrar volúmenes (datos locales)
make nuke               # borrar todo: containers + imágenes + volúmenes + cache
```

---

## Puertos

| Servicio      | Local                  | Container |
|---------------|------------------------|-----------|
| Gateway       | http://localhost:2080  | 8080      |
| Web           | http://localhost:2300  | 3000      |
| MCPs          | http://localhost:2900  | 8080      |
| Postgres      | localhost:2432         | 5432      |
| Redis         | localhost:2379         | 6379      |
| Gradio (dev)  | http://localhost:2860  | 7860      |

---

## Tests por repositorio

Cada repo tiene su propio Makefile para desarrollo local directo (sin Docker).

### infovoto-gateway

```bash
cd ../infovoto-gateway
make install        # pip install -e ".[dev]"
make test           # unit tests (sin integration)
make test-cov       # unit tests + cobertura
make lint           # ruff check
make dev            # uvicorn --reload puerto 8080
```

Archivos de test:
- `tests/test_auth_middleware.py` — middleware de autenticación
- `tests/integration/test_chat_flow.py` — flujo completo chat↔mcp
- `tests/stress/test_load.py` — carga concurrente
- `tests/eval/pipeline.py` — LLM-as-judge (tono, seguridad, empatía)

### infovoto-mcp

```bash
cd ../infovoto-mcp
make install        # pip install -e ".[dev]"
make test           # 14 tests: 5 tools demo + /health + /metadata
make test-cov       # tests + cobertura
make lint           # ruff check
make dev            # uvicorn --reload puerto 8080
make dev-demo       # solo MCP demo puerto 8001
```

Archivos de test:
- `tests/test_demo_tools.py` — 14 tests: buscar_candidato, listar_partidos, obtener_propuesta, consultar_local_votacion, verificar_antecedentes, /health, /metadata

### infovoto-web

```bash
cd ../infovoto-web
make install        # npm install
make dev            # next dev puerto 3000
make build          # next build (detecta errores TypeScript)
make lint           # next lint (ESLint)
```

### infovoto-gradio

```bash
cd ../infovoto-gradio
make install        # pip install -r requirements.txt
make dev            # python app.py puerto 7860
```

---

## Docker Compose Profiles

| Profile   | Activa              | Comando         |
|-----------|---------------------|-----------------|
| (default) | gateway, web, mcp, postgres, redis | `make up` |
| `dev`     | + gradio            | `make up-dev`   |
| `scraper` | + scraper job       | uso manual      |

> El scraper es un job local — se corre manualmente con los notebooks o downloaders. No forma parte del stack.

---

## Variables de entorno

| Archivo            | Propósito                          |
|--------------------|------------------------------------|
| `.env.secrets`     | API keys: Gemini, Azure, OAuth     |
| `.env.config`      | URLs, puertos, flags, MCP_URLS     |
| `.env.secrets.example` | Plantilla (commitear sin valores) |
| `.env.config.example`  | Plantilla (commitear sin valores) |

**Regla:** Si un servicio externo cobra dinero → `.env.secrets`. Si es config local → `.env.config`.
