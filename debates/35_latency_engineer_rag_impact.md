# Debate 35: Impacto en Latencia del RAG Paralelo

**Rol:** Latency Engineer
**Input:** Debate 34 (RAG Architect) + arquitectura actual (TimeBudget, pipeline 2-pass)
**Fecha:** 2026-04-03

---

## Lo que propone el Debate 34

RAG paralelo: en cada query, buscar en ChromaDB `perfiles_candidatos_rag` (36 docs) AL MISMO TIEMPO que el router LLM decide qué MCP llamar. El resultado se inyecta como contexto adicional al synthesizer.

**Mi trabajo**: Verificar que esto no rompe el TimeBudget ni agrega latencia perceptible.

## Arquitectura de tiempos actual

```
Total budget: 20s (settings.request_timeout)
│
├─ Redis cache check       ~50-150ms
├─ Preprocessor            ~5-10ms (regex, local)
├─ Router LLM              ~500-2000ms (gemini-2.5-flash-lite)
│   reserve=8.0s, cap=5.0s
├─ MCP calls (parallel)    ~200-800ms (PostgreSQL/ChromaDB via MCP)
│   reserve=2.0s, cap=5.0s
├─ Synthesizer LLM         ~1500-8000ms (gemini-2.0-flash / gemini-2.5-flash)
│   reserve=0.3s, cap=15.0s
└─ Redis save (background) ~50-200ms
```

### Timing real del eval (261 queries)

| Percentil | Latencia total |
|-----------|---------------|
| p50 | ~2.0s |
| p75 | ~3.5s |
| p90 | ~5.5s |
| p99 | ~8.0s |
| Timeouts | 3 queries (>20s) |

### Dónde se gasta el tiempo

- **Router LLM (pass 1)**: 500-2000ms. Es el cuello de botella en latencia percibida porque bloquea TODO lo demás.
- **MCP calls**: 200-800ms. En paralelo entre sí, pero secuenciales respecto al router.
- **Synthesizer LLM (pass 2)**: 1500-8000ms. El más lento por mucho, pero es el que genera la respuesta.

## Análisis: ChromaDB local con ONNX embeddings

### Benchmarks esperados

ChromaDB con ONNX DefaultEmbeddingFunction (all-MiniLM-L6-v2, 384 dims):

| Operación | 36 docs | 1000 docs | 10000 docs |
|-----------|---------|-----------|------------|
| Embedding del query | ~10-20ms | ~10-20ms | ~10-20ms |
| Similarity search | ~1-3ms | ~5-10ms | ~20-50ms |
| **Total** | **~15-25ms** | **~20-30ms** | **~30-70ms** |

Para 36 documentos, la búsqueda es **trivial** — cabe en memoria, la multiplicación de matrices es instantánea.

### PERO: ChromaDB no está en el gateway

**Observación crítica**: ChromaDB NO corre dentro del gateway container. Está en el servicio `infovoto-mcp` (puerto 2900). El gateway accede a los datos de ChromaDB **a través de HTTP calls al MCP**, no directamente.

Esto significa que un "RAG paralelo" tiene dos opciones:

**Opción 1: RAG vía MCP existente (HTTP)**
```
Gateway → HTTP POST infovoto-mcp:8080/planes/tools → ChromaDB query → response
Latencia: ~200-500ms (network + serialization + ChromaDB)
```
Esto ya existe — es lo que hace `buscar_propuesta_tema`. No agrega nueva infraestructura pero depende del routing.

**Opción 2: ChromaDB directo en gateway (nuevo client)**
```
Gateway → ChromaDB client (HTTP) → ChromaDB server en MCP container → response
Latencia: ~50-100ms (skip FastAPI/MCP serialization)
```
Requiere que el gateway tenga acceso directo al ChromaDB del MCP, o que corra su propio ChromaDB.

**Opción 3: ChromaDB embebido en gateway**
```
Gateway → chromadb.PersistentClient(path=local_dir) → in-process query
Latencia: ~15-25ms (todo local, sin red)
```
Requiere copiar/montar los datos de ChromaDB en el gateway container. Es la más rápida pero agrega complejidad de sincronización.

## Análisis de latencia por opción

### Opción A: RAG paralelo vía MCP (HTTP)

```
t=0ms    ┌─ Router LLM (gemini-2.5-flash-lite) ─────────────── 500-2000ms
         │
         ├─ RAG HTTP call (infovoto-mcp) ── 200-500ms
         │
t=2000ms └─ Ambos terminan
         │
         ├─ MCP calls (resultado del router) ── 200-800ms
         │
t=2800ms └─ Synthesizer LLM ── 1500-8000ms
         │
t=6000ms └─ Respuesta
```

**Impacto en latencia total: ~0ms** (el RAG termina antes que el router LLM, que es más lento).

**Riesgo**: Si hay contención en infovoto-mcp (muchas queries simultáneas), el RAG HTTP podría competir con los MCP calls posteriores por conexiones/CPU.

### Opción B: ChromaDB client directo

```
t=0ms    ┌─ Router LLM ────────────────────────── 500-2000ms
         │
         ├─ ChromaDB query (HTTP directo) ── 50-100ms
         │
t=2000ms └─ Router termina, RAG ya terminó
         │
         ├─ MCP calls ── 200-800ms
         │
t=2800ms └─ Synthesizer LLM ── 1500-8000ms
```

**Impacto en latencia total: ~0ms**. Aún más rápido que opción A.

### Opción C: ChromaDB embebido

```
t=0ms    ┌─ Router LLM ────────────────────────── 500-2000ms
         │
         ├─ ChromaDB in-process query ── 15-25ms
         │
t=2000ms └─ Router termina, RAG terminó hace rato
         │
         ├─ MCP calls ── 200-800ms
         │
t=2800ms └─ Synthesizer LLM ── 1500-8000ms
```

**Impacto en latencia total: ~0ms**. Virtualmente gratis.

## El verdadero costo: tokens del synthesizer

El costo NO está en la latencia de ChromaDB. Está en lo que le inyectamos al synthesizer:

### Sin RAG (actual)
```
Synthesizer input:
- System prompt: ~800 tokens
- History: ~500-2000 tokens
- MCP data: ~200-1000 tokens
- User query: ~20-50 tokens
TOTAL: ~1500-4000 tokens input
```

### Con RAG paralelo
```
Synthesizer input:
- System prompt: ~800 tokens
- History: ~500-2000 tokens
- MCP data: ~200-1000 tokens
- RAG context: ~200-800 tokens (perfil completo de 1-3 candidatos)
- User query: ~20-50 tokens
TOTAL: ~1700-4800 tokens input
```

**Diferencia**: +200-800 tokens de input. En gemini-2.0-flash, esto agrega:
- ~50-200ms extra en time-to-first-token (TTFT)
- ~0ms extra en generation (output tokens no cambian)

**En el peor caso**: +200ms en el synthesizer. Dentro del ruido normal de variabilidad LLM.

### Pero el RAG puede REDUCIR tokens en otro escenario

Si el RAG inyecta datos buenos y el MCP falla (tools=[]), el synthesizer tiene datos para responder **sin necesitar un MCP call fallido + retry**. Esto AHORRA:
- MCP call timeout: 200-800ms
- Posible retry del router: 500-2000ms
- Fallback message generation: evitada

**Net effect**: En happy path, +50-200ms. En failure path, -500-3000ms.

## Impacto en TimeBudget

### Dónde insertar el RAG en el pipeline

```python
# core.py _process_with_budget(), después del preprocessor (~line 940)

# Opción: RAG paralelo con el router
async def _rag_search(self, query: str, entities: dict | None) -> str:
    """Búsqueda semántica en perfiles_candidatos_rag. ~50-100ms."""
    # ChromaDB query con filtro de metadata si hay entidad resuelta
    ...

# En el pipeline:
rag_task = asyncio.create_task(self._rag_search(enriched, entities))
# ... router LLM call (existente) ...
rag_context = await rag_task  # Ya terminó, await inmediato
```

### Budget allocation

| Operación | Budget actual | Con RAG |
|-----------|--------------|---------|
| Router reserve | 8.0s | 8.0s (sin cambio) |
| MCP reserve | 2.0s | 2.0s (sin cambio) |
| RAG | N/A | 0.0s adicional (paralelo con router) |
| Synthesizer | 15.0s cap | 15.0s cap (sin cambio) |

**El RAG NO necesita su propio budget slot** porque corre en paralelo con el router y SIEMPRE termina antes (~100ms vs ~500-2000ms del router).

Solo necesita un safety timeout:
```python
rag_task = asyncio.create_task(self._rag_search(enriched, entities))
# Si el RAG tarda más de 500ms, lo ignoramos (no bloquea el pipeline)
try:
    rag_context = await asyncio.wait_for(rag_task, timeout=0.5)
except asyncio.TimeoutError:
    rag_context = ""  # Graceful degradation
```

## Casos edge de latencia

### 1. Cold start de ChromaDB
- **Primera query**: ChromaDB carga la colección a memoria (~500ms-1s para 36 docs)
- **Queries siguientes**: ~15-25ms (todo en caché)
- **Mitigación**: Warm-up en startup del gateway (cargar colección al inicializar)

### 2. ONNX model loading
- **Primera vez**: El embedding model (all-MiniLM-L6-v2) se descarga y carga (~2-5s)
- **Queries siguientes**: Ya está en memoria
- **Mitigación**: Pre-cargar en lifespan del gateway

### 3. Queries que matchean muchos candidatos
- "quién tiene antecedentes?" → Top 5-10 candidatos relevantes
- Cada perfil ~300-500 tokens → 1500-5000 tokens de RAG context
- **Mitigación**: Limitar a top_k=3 y truncar cada chunk a 300 tokens máx

### 4. Contención de red (Opción A/B)
- Si el gateway y el MCP están en el mismo Docker network → ~1-5ms RTT
- Si están en Cloud Run separados → ~20-50ms RTT
- **Mitigación**: Opción C (embebido) elimina red completamente

## Comparación con enfoques alternativos

### RAG como fallback (Debate 34, Opción B)

```
Si MCP devuelve datos → usar datos (latencia igual que hoy)
Si MCP devuelve vacío → RAG como respaldo
```

**Latencia**: +100-300ms SOLO cuando MCP falla. Pero el problema es que el MCP ya consumió 200-800ms antes de fallar. El RAG agrega latencia ENCIMA del timeout del MCP.

**Veredicto**: PEOR que RAG paralelo. Agrega latencia en el peor momento (cuando ya estamos retrasados por un MCP fallido).

### RAG como pre-routing (Debate 34, Opción C)

```
RAG search (100ms) → inyectar en router prompt → router decide mejor
```

**Latencia**: +100ms SECUENCIAL antes del router. No se puede paralelizar porque el router necesita el resultado del RAG.

**Veredicto**: Agrega 100ms reales al pipeline. Marginal, pero innecesario si el RAG paralelo ya inyecta al synthesizer.

## Recomendación de latencia

### Arquitectura recomendada

```
t=0ms    ┌─ Router LLM (pass 1) ────────────────── 500-2000ms
         │
         ├─ RAG ChromaDB (paralelo) ── 50-100ms ✓ termina rápido
         │
t=2000ms └─ Router termina
         │  RAG context ya disponible
         │
         ├─ MCP calls (paralelo) ── 200-800ms
         │
t=2800ms └─ Synthesizer LLM (pass 2)
         │  Input: system + history + MCP data + RAG context + query
         │  ~1500-8000ms
         │
t=6000ms └─ Respuesta final
```

### Parámetros sugeridos

| Parámetro | Valor | Razón |
|-----------|-------|-------|
| RAG timeout | 500ms | Safety net, normalmente termina en <100ms |
| RAG top_k | 3 | Balance entre cobertura y tokens |
| RAG max_tokens per chunk | 300 | Evita que un perfil largo domine el contexto |
| RAG total max_tokens | 800 | Cap total para no inflar el synthesizer |
| Warm-up en startup | Sí | Evitar cold start en primera query |

### Impacto neto esperado

| Métrica | Sin RAG | Con RAG paralelo | Delta |
|---------|---------|-------------------|-------|
| p50 latencia | ~2.0s | ~2.1s | +100ms (+5%) |
| p90 latencia | ~5.5s | ~5.6s | +100ms (+2%) |
| Queries con "No encontré" | ~8/261 | ~2/261 (estimado) | -75% |
| Tokens input/query (avg) | ~2500 | ~3000 | +20% |

**El trade-off es claro**: +100ms (imperceptible) por -75% de respuestas vacías.

## Trade-offs

### A favor
1. **Latencia cero adicional** en el hot path (paralelo con router)
2. **Reduce latencia total** en failure paths (evita retries)
3. **TimeBudget no cambia** — no necesita nuevo slot
4. **36 docs es trivial** — la colección cabe en L1 cache

### En contra
1. **+200-800 tokens en synthesizer** — marginal pero real
2. **Cold start** si no hay warm-up (solucionable)
3. **Complejidad de infraestructura** — ¿ChromaDB embebido o vía HTTP?
4. **Costo de Gemini** — +20% tokens input por query

### Riesgos
1. **ONNX en gateway container**: Agrega ~200MB al Docker image (modelo + dependencias). Build más lento.
2. **Memory footprint**: ChromaDB + ONNX model en memoria = ~300-500MB extra en el gateway.
3. **Cloud Run cold start**: Si el gateway se escala a 0 y vuelve, el warm-up de ONNX + ChromaDB agrega 3-5s al primer request.

## Veredicto

✅ **Aprobado con condiciones.**

El RAG paralelo es **latency-neutral** para 36 docs con ChromaDB local. El costo real no es latencia sino tokens (+20%) y memoria (+300MB).

**Condiciones**:
1. Warm-up obligatorio en startup (pre-cargar colección + modelo ONNX)
2. Timeout de 500ms en la task de RAG (fail-open, no bloquea pipeline)
3. Cap de 800 tokens totales en RAG context inyectado al synthesizer
4. Top_k = 3 máximo
5. Decidir infraestructura: ¿embebido en gateway o HTTP al MCP? → Para el Debate 41 (Backend Architect)

## Preguntas para debates siguientes

- **Data Quality Lead (D36)**: ¿Los perfiles en PostgreSQL están completos? Si faltan datos, el RAG inyecta info parcial.
- **Search/IR Specialist (D37)**: ¿Los embeddings ONNX capturan bien "cuánto gana" → patrimonio? ¿Necesitamos reranking?
- **Backend Architect (D41)**: ¿ChromaDB embebido o HTTP? Implicaciones para Cloud Run.
- **ML Engineer (D42)**: ¿ONNX all-MiniLM-L6-v2 es suficiente para español peruano?
