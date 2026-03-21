# MCP Pool Demo — Experimentación Aislada

Scripts standalone para entender y validar cada aspecto del MCP connection pooling.
Cero dependencias del proyecto — solo `httpx`, `fastapi`, `uvicorn`.

## Setup

```bash
cd infovoto-infra/demo/mcp-pool
pip install httpx fastapi uvicorn
```

## Scripts

| # | Script | Qué mide | Requiere server |
|---|--------|----------|-----------------|
| 00 | `fake_mcp_server.py` | Fake MCP con latencia configurable | — |
| 01 | `01_queue_basics.py` | acquire/release ~0μs | No |
| 02 | `02_parallel_calls.py` | 50 concurrent, pool_size=5/10/20 | Sí |
| 03 | `03_reconnection.py` | Kill/restart server, auto-recovery | Sí (o --auto) |
| 04 | `04_background_refresh.py` | Health check loop detecta muertes | Sí |
| 05 | `05_multi_server.py` | 3 servers, routing O(1) | Sí (o --auto) |
| 06 | `06_semaphore_bench.py` | Semaphore 5/10/20/unlimited | Sí |
| 07 | `07_latency_breakdown.py` | acquire/HTTP/parse por percentil | Sí |

## Quick Start

```bash
# Terminal 1: Fake server
uvicorn fake_mcp_server:app --port 9001

# Terminal 2: Correr demos
python 01_queue_basics.py                          # No necesita server
python 02_parallel_calls.py --compare              # Compara pool sizes
python 03_reconnection.py --auto                   # Auto kill/restart
python 05_multi_server.py --auto --calls 100       # 3 servers auto
python 07_latency_breakdown.py --calls 200         # Breakdown detallado
```

## Epic

Ver `infovoto-planning/epics/mcp-pool-mastery.md` para el plan completo (POOL-01 a POOL-08).
