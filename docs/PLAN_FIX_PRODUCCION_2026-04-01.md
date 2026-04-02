# Plan: Fix producción InfoVoto — 1 abril 2026

## Resumen ejecutivo

Se hicieron ~878 líneas de cambios en MCP y gateway para integrar data de competidores (posiciones políticas de Decide.pe, antecedentes detallados de VotaBienPerú, fotos de candidatos + logos de partidos). En **local todo funciona perfecto** (2-6s por respuesta). En **producción (GCP Cloud Run + Supabase) falla** el synthesizer de Gemini con timeout.

**Root cause**: NO es el código/features — es configuración de infra (timeouts, cold starts, connection pooling). Cero features a revertir.

---

## Estado actual (1 abril 2026 ~19:00 PET)

### Lo que funciona en LOCAL (Docker + Postgres local):
- ✅ Antecedentes detallados de VotaBienPerú (71 con título, descripción, fuente)
- ✅ 500 hechos relevantes (biografía detallada)
- ✅ 575 posiciones políticas (Decide.pe, 20 temas)
- ✅ 112K posiciones inferidas de partido (para senadores/diputados)
- ✅ CandidateCard con foto + logo de partido en el chat
- ✅ Tool `explorar_tema` para "quiénes apoyan X"
- ✅ Tool `foto_candidato` para "foto/logo de X"
- ✅ Separación de fuentes (DJHV vs VotaBienPerú) en antecedentes
- ✅ Scores numéricos reemplazados por labels ("A favor"/"En contra")
- ✅ Diff de posiciones en comparaciones
- ✅ Senadores por región corregido (cargos nacionales)
- ✅ Scores de evaluación: 8.31/10 (200 preguntas), 8.83/10 (100 posiciones), 8.82/10 (100 antecedentes)

### Tiempos locales verificados:
| Query | Tiempo | Card |
|---|---|---|
| hola | 0.1s | - |
| Antecedentes Keiko | 4.6s | ✅ foto+logo |
| Quiénes apoyan pena de muerte | 4.1s | - |
| foto de Acuña | 1.8s | ✅ foto+logo |
| Perfil López Aliaga | 6.0s | ✅ foto+logo |

### Lo que funciona en PRODUCCIÓN:
- ✅ MCP health: OK (después de subir test timeout a 30s)
- ✅ MCP tools directos: retorna datos correctos (6 antecedentes Keiko, 19 posiciones, 5 hechos)
- ✅ Gateway queries simples: "hola", "explorar_tema" funcionan en 4s
- ❌ Gateway queries con perfil completo: Gemini synthesizer timeout exacto en 8s

### Data en Supabase prod:
| Data | Cantidad | Estado |
|---|---|---|
| Candidatos | 7,145 | ✅ |
| Temas políticos | 20 | ✅ |
| Posiciones presidenciales | 575 | ✅ |
| Posiciones de partido | 0 | ❌ (no se cargaron, Supabase timeout con 112K inserts) |
| Antecedentes VotaBien | 71 | ✅ |
| Hechos relevantes | 500 | ✅ |
| Fotos Supabase Storage | 35 | ✅ |
| Logos partidos | 38 | ✅ |
| Bio curada | 33 | ✅ |

---

## Diagnóstico del problema en producción

### Problema 1: MCP no arrancaba (RESUELTO)
- `scripts/startup.sh` corría tests de integración antes de marcar healthy
- `test_keiko_datos_personales` hacía httpx.ReadTimeout contra Supabase cold DB
- Fix aplicado: `TIMEOUT = 30.0` en tests (commit `a44df3a`, ya deployado)
- MCP ahora arranca OK en Cloud Run

### Problema 2: Gemini synthesizer timeout (PENDIENTE)
- `llm_call_max_timeout = 8.0` en `infovoto-gateway/src/gateway/config.py`
- Perfiles enriquecidos (posiciones + hechos + antecedentes) generan contexto ~3x más grande
- Gemini necesita ~8-10s para sintetizar en Cloud Run (en local: 3-5s)
- El timeout corta exacto a 8.001s → respuesta fallback "problema técnico"
- Queries simples (explorar_tema, hola) SÍ funcionan porque el contexto es más pequeño

### Problema 3: Sin connection pooling (PENDIENTE)
- MCP usa `create_async_engine(url)` sin `pool_pre_ping`, sin pool size config
- Supabase via port 5432 (direct), no 6543 (PgBouncer)
- En cold start, primera conexión tarda 2-5s adicionales

### Problema 4: Lazy-load en primer request (PENDIENTE)
- Cache de posiciones (`_POSICIONES_BY_DNI`, 575 entries) se carga en el primer request
- En Cloud Run, esto suma 1-3s al primer tool call después de cold start

---

## Cambios realizados (13 archivos, 878 líneas)

### infovoto-mcp (7 archivos, 562 inserts)
| Commit | Archivo | Cambio |
|---|---|---|
| `0970212` | `src/utils/fuentes.py` | +FUENTE_POSICIONES, +FUENTE_ALERTAS |
| `0970212` | `src/mcp/perfiles/server.py` | Cache posiciones, explorar_tema tool, bio_curada, alertas (luego removidas), senadores nacionales, campo partidos/alertas |
| `0970212` | `src/mcp/logistica/server.py` | Datos votante en info_dia_elecciones |
| `0970212` | `src/mcp/proceso_electoral/server.py` | Aspecto 'votante' |
| `0970212` | `src/mcp/planes_gobierno/server.py` | Mejores descriptions |
| `a07cd44` | `src/db/models.py` | +HechoRelevante model, +7 columnas AntecedentePenal, +4 columnas redes sociales |
| `df931ab` | `src/mcp/perfiles/server.py` | _candidate metadata (foto, logo) |
| `a28002d` | `src/mcp/perfiles/server.py` | foto_candidato tool |
| `a44df3a` | `tests/test_tools_integration.py` | TIMEOUT 10→30s |

### infovoto-gateway (6 archivos, 316 inserts)
| Commit | Archivo | Cambio |
|---|---|---|
| `b0ea02c` | `src/agent/core.py` | _extract_source multi-fuente, _extract_candidates, CandidateCard model, SYNTHESIZER_INSTRUCTION (posiciones, antecedentes, hechos) |
| `b0ea02c` | `src/agent/output_filter.py` | Disclaimer decide.pe + votabienperu.com |
| `c2a1ebc` | `src/agent/router.py` | Ejemplos foto/logo, foto_candidato routing |
| `4241223` | `src/gateway/routers/api.py` | CandidateCardResponse en ChatResponse |
| `e6ff064` | `src/agent/core.py` | No mostrar scores numéricos |
| - | `tests/eval/questions_posiciones.json` | 100 preguntas de test posiciones |
| - | `tests/eval/questions_detalle.json` | 100 preguntas de test antecedentes |

### infovoto-web (3 archivos)
| Commit | Archivo | Cambio |
|---|---|---|
| `afe1ebe` | `app/components/CandidateCard.tsx` | Nuevo componente con foto + logo |
| `afe1ebe` | `app/chat/page.tsx` | Importar CandidateCard, renderizar en chat |
| `afe1ebe` | `lib/api.ts` | CandidateCard type, candidates en ChatResponse |

---

## Plan de fixes para producción

### Fase 1: Debug local apuntando a Supabase

**Objetivo:** Reproducir el entorno de producción localmente.

1. Crear `docker-compose.supabase.yml` override que cambie DATABASE_URL a Supabase
2. Levantar MCP + gateway con ese override
3. Correr 5 queries de verificación y comparar tiempos
4. Si tiempos son similares a local → problema es Cloud Run específico
5. Si son más lentos → problema es Supabase connection

### Fase 2: Aplicar fixes de infra

| # | Fix | Archivo | Cambio | Por qué |
|---|-----|---------|--------|---------|
| A | pool_pre_ping | `mcp/perfiles/server.py`, `mcp/logistica/server.py`, `main.py` | `create_async_engine(url, pool_pre_ping=True, pool_size=3, max_overflow=5)` | Conexiones stale causan errores silenciosos |
| B | Pre-load posiciones | `main.py` | Nuevo `@app.on_event("startup")` que cargue cache de posiciones | Primer request 2-5s más rápido |
| C | LLM timeout | `gateway/config.py` | `llm_call_max_timeout: 12.0` (era 8.0), `request_timeout: 25.0` (era 20.0) | Perfiles enriquecidos necesitan más tiempo de síntesis |
| D | PgBouncer | GCP Secret Manager | `:5432` → `:6543` + `statement_cache_size=0` | Reduce latencia de conexión 10x |
| E | Tests opcionales | `startup.sh` | Tests en background post-healthy, no-blocking | Tests no deben ser gate del deployment |

### Fase 3: Verificar en Docker local con Supabase

1. Aplicar fixes A-C en código
2. Rebuild containers
3. Correr 5 queries de verificación → tiempos < 8s
4. Correr 30 queries automatizadas → score > 8.0

### Fase 4: Deploy a producción

1. Commit cada fix como commit independiente (rollback granular)
2. Cloud Build MCP → verificar health
3. Cloud Build Gateway → verificar health
4. 10 queries E2E contra producción
5. Revisar logs Cloud Run → confirmar zona verde

### Fase 5: Validación final

1. Test visual con puppeteer en web de producción
2. 30 queries automatizadas con LLM judge
3. Verificar cards con foto + logo
4. Verificar separación de fuentes
5. Comparar scores con evaluación local

---

## Archivos críticos de referencia

| Archivo | Qué contiene | Para qué |
|---|---|---|
| `infovoto-mcp/scripts/startup.sh` | Boot sequence: ONNX warmup → uvicorn → tests → healthy | Controla si el container arranca |
| `infovoto-mcp/src/gateway/config.py` | `llm_call_max_timeout=8.0`, `request_timeout=20.0` | Timeouts que causan el fallo |
| `infovoto-mcp/src/mcp/perfiles/server.py:183` | `create_async_engine(url)` sin pool config | Pool sin pre_ping |
| `infovoto-mcp/src/mcp/perfiles/server.py:_ensure_posiciones()` | Lazy-load 575 posiciones en primer request | Causa cold-start lento |
| `infovoto-mcp/src/main.py:_load_fuzzy_catalogs()` | Carga 7146 candidatos en RAM al startup | Funciona OK |
| GCP Secret Manager: `DATABASE_URL` | `postgresql+asyncpg://...@db.xxx.supabase.co:5432/postgres` | Direct port, debería ser 6543 |

---

## Scraper data disponible (no cargada a prod aún)

| Data | Local | Prod | Pendiente |
|---|---|---|---|
| Posiciones de partido (112K) | ✅ | ❌ | Cargar en batches con commits intermedios |
| Fotos candidatos (35 JPGs) | ✅ disco | ✅ Supabase Storage | OK |
| Logos partidos (35 PNGs) | ✅ disco | ✅ Supabase Storage | OK |
| JSONs VotaBienPerú (35 candidatos) | ✅ en `data/raw/competidores/votabienperu/candidatos/` | N/A (procesados a DB) | Solo presidenciales. Faltan senadores/diputados |

---

## Evaluaciones realizadas

| Dataset | Score | Queries | Fecha |
|---|---|---|---|
| 200 preguntas original | 8.31/10 | 200 | 31 mar |
| 100 posiciones políticas | 8.83/10 | 95 | 31 mar |
| 100 antecedentes detallados | 8.82/10 | 90 | 1 abr |
| 21 conversaciones (5 msgs c/u) | 7.4/10 | 105 | 30 mar |

---

## Próximos pasos (después de fix producción)

1. Scraping de senadores/diputados/parlamento andino de VotaBienPerú
2. Cargar 112K posiciones de partido en Supabase (batches de 1000)
3. Scraping de logos de todos los partidos (no solo presidenciales)
4. Descargar fotos de senadores/diputados
5. Evaluar si se necesita un MCP de financiamiento (tabla `finanzas_claridad` vacía)
6. Evaluar si se necesita un MCP de fiscalización (tabla `expedientes` vacía)
