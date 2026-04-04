# Debate 05: Reescribir infovoto-gateway en Rust/Go vs mantener Python

**Fecha:** 2026-04-02
**Contexto:** infovoto-gateway es un servicio FastAPI (~3,200 LOC en `src/`) que orquesta un agente conversacional (Gemini/Claude/OpenAI), MCP registry, OAuth, Redis sessions y PostgreSQL. Corre en Cloud Run. Se evalua si reescribirlo en Rust o Go mejoraria rendimiento, costos o escalabilidad.

**Datos actuales del gateway:**
- ~3,200 lineas Python (agent/ ~2,700, gateway/ ~550)
- Latencia p50 del endpoint /api/chat: ~1.5-3s (dominada por llamada LLM)
- Latencia p50 de /auth/verify: ~50ms
- Cloud Run: 1 vCPU, 512MB RAM, min instances 0, max 10
- Costo mensual estimado: ~$15-30 USD (bajo trafico actual)
- Dependencias criticas: google-genai SDK, anthropic SDK, openai SDK, httpx (MCP calls), SQLAlchemy async, Redis

---

## Roles

| # | Rol | Perspectiva |
|---|-----|-------------|
| 1 | **Senior MLE** | Arquitectura, clean code, hexagonal |
| 2 | **Junior MLE** | Testing, preguntas, dudas |
| 3 | **AI Tech Lead** | Revision critica, arquitectura de sistemas |
| 4 | **Full Stack Lead** | Frontend-backend integration, DX |
| 5 | **Delivery Lead** | UX, tiempos, costos, stakeholders |
| 6 | **SRE / Platform Engineer** | Infra, Cloud Run, observabilidad, costos |
| 7 | **Rust Advocate** | Argumenta a favor de Rust |
| 8 | **Go Advocate** | Argumenta a favor de Go |
| 9 | **Python Advocate** | Argumenta a favor de mantener Python |
| 10 | **CTO / Decision Maker** | Veredicto final con datos |

---

## Ciclo 1: Definicion del problema y metricas

**Senior MLE:**
Antes de evaluar lenguajes, necesitamos definir que problema estamos resolviendo. El gateway tiene dos tipos de endpoints:

1. **I/O-bound (95%+ del trafico):** `/api/chat` espera 1-3s a que el LLM responda. El CPU del gateway esta idle durante ese tiempo.
2. **CPU-bound (minimo):** Preprocesamiento de texto, output filtering, routing logic. Esto toma <10ms.

La Ley de Amdahl aplica directamente aqui:

```
Speedup = 1 / ((1 - P) + P/S)

Donde:
- P = fraccion del tiempo que se puede paralelizar/optimizar (codigo CPU del gateway)
- S = speedup del componente optimizado
- (1 - P) = fraccion que NO se puede optimizar (latencia LLM externa)
```

Si el LLM toma 2000ms y nuestro codigo Python toma 15ms:
- P = 15/2015 = 0.0074 (0.74% del tiempo total)
- Incluso con S = infinito: Speedup = 1 / (1 - 0.0074) = 1.0075x

**Resultado: optimizar el lenguaje del gateway da un speedup maximo teorico de 0.75%.** Eso es ~15ms en un request de 2 segundos.

**Junior MLE:**
Espera, pero que pasa con el cold start de Cloud Run? Python con FastAPI + todas las dependencias tarda mas en arrancar que Go o Rust compilado.

**AI Tech Lead:**
Buen punto. Los cold starts son el unico argumento valido de rendimiento. Pero Cloud Run con min-instances=1 elimina cold starts para el primer request. Ademas, el cold start de Python con uvicorn + FastAPI es ~2-4s. Go seria ~200ms. Rust ~100ms. Eso importa SOLO si usamos min-instances=0.

**Veredicto Ciclo 1:** 🔄 Necesita mas datos sobre cold starts y costos reales.

---

## Ciclo 2: Benchmarks reales de rendimiento

**Go Advocate:**
Go tiene ventajas claras en:
- Goroutines: miles de conexiones concurrentes con bajo overhead (~4KB por goroutine vs ~8MB por thread OS)
- Compilacion a binario estatico: cold start rapido, imagen Docker pequena (~15MB)
- net/http es extremadamente rapido: ~100k req/s en un solo core

Benchmarks TechEmpower Round 22 (JSON serialization, single query):
- Go (gin): ~450k req/s
- Python (FastAPI + uvicorn): ~25k req/s
- Ratio: Go es ~18x mas rapido en throughput bruto

**Rust Advocate:**
Rust con actix-web o axum supera a Go:
- Rust (actix): ~650k req/s
- Rust (axum): ~580k req/s
- Zero-cost abstractions, no GC pauses, memoria predecible

Benchmarks TechEmpower Round 22 (JSON serialization):
- Rust (actix): ~650k req/s
- Go (gin): ~450k req/s
- Python (FastAPI): ~25k req/s

**Python Advocate:**
Esos benchmarks son de serialization pura. Irrelevantes para nuestro caso. Nuestro gateway no serializa JSON 450k veces por segundo. Hace ~10-50 req/s en pico. FastAPI con uvicorn maneja eso sin pestanear.

El throughput real del gateway esta limitado por:
1. Latencia del LLM (1-3s por request)
2. Latencia de Redis (~1ms)
3. Latencia de PostgreSQL (~5ms)
4. Latencia de MCP calls (~100-300ms)

Ninguna de esas mejora cambiando el lenguaje del gateway.

**AI Tech Lead:**
Correcto. Apliquemos Amdahl con datos reales de un request tipico a /api/chat:

```
Componente              Tiempo (ms)    Optimizable con Rust/Go?
─────────────────────────────────────────────────────────────
LLM call (Gemini)        2000           NO (I/O externo)
MCP tool calls           200            NO (I/O externo)
Redis read/write         2              NO (I/O externo)
PostgreSQL query         5              NO (I/O externo)
Preprocessing Python     8              SI
Output filtering         5              SI
Routing logic            2              SI
JSON serialization       1              SI
─────────────────────────────────────────────────────────────
TOTAL                    2223 ms
Optimizable              16 ms (0.72%)
No optimizable           2207 ms (99.28%)
```

Speedup maximo teorico (Amdahl): **1 / (0.9928 + 0.0072/50) = 1.0071x = 0.71%**

Asumiendo Rust es 50x mas rapido que Python en CPU puro, el usuario veria 2223ms vs 2207ms. **Imperceptible.**

**Veredicto Ciclo 2:** ✅ Los benchmarks confirman que el bottleneck NO es el lenguaje. No hay caso de rendimiento.

---

## Ciclo 3: Costos de Cloud Run

**SRE / Platform Engineer:**
Analicemos costos. Cloud Run cobra por:
- vCPU-segundo: $0.00002400
- GB-segundo: $0.00000250
- Requests: $0.40 por millon

Configuracion actual (Python):
- 1 vCPU, 512MB RAM
- ~50k requests/mes (estimado fase beta)
- Tiempo promedio de request: 3s (incluye LLM wait)
- min-instances: 0 (cold start ok para beta)

Costo mensual Python:
```
CPU: 50,000 * 3s * $0.00002400 = $3.60
RAM: 50,000 * 3s * 0.5GB * $0.00000250 = $0.19
Requests: 50,000 * $0.0000004 = $0.02
Total: ~$3.81/mes
```

Con Go (misma config pero podriamos bajar a 256MB RAM):
```
CPU: 50,000 * 3s * $0.00002400 = $3.60  (igual, mismo tiempo de request)
RAM: 50,000 * 3s * 0.25GB * $0.00000250 = $0.09
Requests: $0.02
Total: ~$3.71/mes
```

**Ahorro: $0.10/mes.** Diez centavos.

**Delivery Lead:**
Incluso si escalamos 100x (5M requests/mes), el ahorro seria ~$10/mes en RAM. El costo dominante siempre sera la API de Gemini/Claude ($0.15-$0.60 por 1M tokens input). Con 5M requests, el costo de LLM seria ~$500-2000/mes. El lenguaje del gateway es irrelevante en el budget.

**Go Advocate:**
Pero Go usa menos memoria. Podemos meter mas instancias concurrentes en Cloud Run con el mismo RAM.

**SRE / Platform Engineer:**
Con 50k req/mes y 3s por request, necesitamos manejar ~0.06 requests concurrentes en promedio. Incluso en pico (10x) son 0.6 concurrentes. Una sola instancia de Python sobra. No necesitamos "mas instancias concurrentes".

**Veredicto Ciclo 3:** ✅ No hay caso de costos. El ahorro es negligible y el LLM domina el gasto.

---

## Ciclo 4: Ecosistema de SDKs y compatibilidad

**Senior MLE:**
El gateway usa estos SDKs criticos:

| SDK | Python | Go | Rust |
|-----|--------|----|------|
| google-genai (Gemini) | ✅ Oficial, first-class | ✅ Oficial | ❌ No oficial, community crate |
| anthropic (Claude) | ✅ Oficial | ❌ Community | ❌ Community crate |
| openai | ✅ Oficial | ✅ Oficial | ❌ Community (async-openai) |
| MCP SDK (client) | ✅ mcp Python SDK | ⚠️ Experimental | ❌ No existe |
| SQLAlchemy async | ✅ Maduro | N/A (GORM/sqlx) | N/A (sqlx/diesel) |
| Redis async | ✅ redis-py async | ✅ go-redis | ✅ redis-rs |
| FastAPI/HTTP framework | ✅ FastAPI | ✅ gin/chi/echo | ✅ axum/actix |

**Rust Advocate:**
Admito que el ecosistema de SDKs de LLM en Rust es inmaduro. Los crates community no tienen paridad de features con los SDKs oficiales de Python. Especialmente para streaming, function calling, y tool use -- features que el gateway usa intensamente.

**Go Advocate:**
Go tiene SDKs oficiales de Google y OpenAI. Pero el SDK de Anthropic en Go es community-maintained. Y el MCP SDK en Go esta en estado experimental. Tendriamos que mantener wrappers custom.

**Python Advocate:**
Python es el lenguaje de primera clase para TODOS los proveedores de LLM. Cuando Gemini 2.5 o Claude 4 lanzan una feature nueva (ej: structured output, tool use mejorado, computer use), el SDK de Python se actualiza el dia del launch. Los SDKs de Go/Rust pueden tardar semanas o meses. En un proyecto de AI, estar atras en features de LLM es un riesgo real.

**AI Tech Lead:**
El MCP protocol es especialmente critico. El gateway usa `mcp_pool.py` (508 LOC) para mantener conexiones SSE persistentes con los 5 MCPs. El SDK oficial de MCP esta en Python y TypeScript. Reescribir el pool de conexiones MCP en Go/Rust requeriria implementar el protocolo desde cero o depender de SDKs inmaduros.

**Veredicto Ciclo 4:** ✅ Python tiene ventaja clara en ecosistema LLM/MCP. Migrar introduce riesgo de compatibilidad.

---

## Ciclo 5: Costo de reescritura (tiempo y esfuerzo)

**Delivery Lead:**
Estimemos el costo de reescritura:

Gateway actual: ~3,200 LOC Python con:
- Arquitectura hexagonal (ports/adapters)
- Multi-provider LLM (Gemini/Claude/OpenAI)
- MCP pool con reconexion automatica
- Preprocessor + output filter + router + response validator
- OAuth + Redis sessions
- PostgreSQL async

Estimacion de reescritura:

| Tarea | Go (semanas) | Rust (semanas) |
|-------|-------------|----------------|
| Setup proyecto + CI/CD | 0.5 | 1 |
| HTTP server + middleware + auth | 1 | 1.5 |
| Multi-provider LLM adapters | 2 | 3 |
| MCP client pool | 2 | 3 |
| Agent core (1,316 LOC) | 2 | 3 |
| Preprocessor + filter + router | 1 | 1.5 |
| Redis + PostgreSQL integration | 1 | 1.5 |
| Tests + debugging | 2 | 3 |
| Migration + deployment | 1 | 1 |
| **Total** | **12.5 semanas** | **18.5 semanas** |

Eso es **3-4.5 meses** de desarrollo full-time para un solo desarrollador.

**Junior MLE:**
Y durante esos 3-4 meses no podemos avanzar features nuevas en el gateway. Estamos en fase beta con elecciones en 2026. El costo de oportunidad es enorme.

**Full Stack Lead:**
Ademas, el equipo actual domina Python. La curva de aprendizaje de Rust (borrow checker, lifetimes, async con Pin/Future) o Go (goroutines, channels, error handling idiomatico) agrega semanas de ramp-up.

**CTO / Decision Maker:**
El costo de oportunidad es el argumento mas fuerte. 3-4 meses de reescritura vs 3-4 meses de features que impactan usuarios reales antes de las elecciones.

**Veredicto Ciclo 5:** ✅ El costo de reescritura es prohibitivo dado el timeline del proyecto.

---

## Ciclo 6: Analisis de Amdahl ampliado -- escenarios futuros

**AI Tech Lead:**
Evaluemos escenarios donde el balance I/O vs CPU podria cambiar:

**Escenario A: RAG pesado con embeddings locales**
Si el gateway generara embeddings localmente en vez de llamar a un API externo:
```
Embedding generation (local): 50ms CPU-intensive
LLM call: 2000ms
Total: 2050ms
P = 50/2050 = 0.024
Speedup con Rust (50x en CPU): 1 / (0.976 + 0.024/50) = 1.024x = 2.4%
```
Sigue siendo negligible. Y ademas, generamos embeddings en infovoto-mcp, no en el gateway.

**Escenario B: Procesamiento de PDFs/documentos grandes**
Si parsearamos PDFs de planes de gobierno en el gateway:
```
PDF parsing: 500ms CPU
LLM call: 2000ms
Total: 2500ms
P = 500/2500 = 0.20
Speedup con Rust (50x): 1 / (0.80 + 0.20/50) = 1.24x = 24%
```
Esto SI seria significativo. Pero el scraper hace este trabajo, no el gateway.

**Escenario C: 10,000 requests concurrentes (viral moment)**
Python con uvicorn (4 workers) maneja ~1000 conexiones concurrentes sin problema porque son I/O-bound (asyncio). Go manejaria mas con menos RAM. Pero Cloud Run auto-escala instancias -- a 10k concurrentes tendriamos 10-20 instancias de Python vs 5-10 de Go. Diferencia de ~$5/hora extra durante el spike.

**Rust Advocate:**
El escenario C es real. Si InfoVoto se viraliza el dia de las elecciones...

**SRE / Platform Engineer:**
Cloud Run escala a 1000 instancias automaticamente. El cuello de botella a 10k concurrentes seria el rate limit de Gemini API (60 QPM en tier gratuito, 360 QPM en tier pago), no el lenguaje del gateway. Tendriamos que implementar queuing/rate limiting sin importar el lenguaje.

**Veredicto Ciclo 6:** ✅ Incluso en escenarios futuros, Amdahl muestra que el lenguaje no es el bottleneck.

---

## Ciclo 7: Type safety, mantenibilidad y bugs

**Rust Advocate:**
Rust ofrece:
- Sistema de tipos que previene null pointer exceptions, data races, y memory leaks en compilacion
- Pattern matching exhaustivo con `match`
- Error handling explicito con `Result<T, E>`
- Lifetime analysis previene use-after-free

En un servicio de produccion, esto reduce bugs en runtime.

**Go Advocate:**
Go ofrece:
- Tipado estatico mas simple que Rust
- `error` como valor (no exceptions)
- Race detector built-in (`go test -race`)
- Simplicidad: cualquier developer lo lee en una semana

**Python Advocate:**
Python con type hints + mypy/pyright da:
- Type checking estatico opcional (sin overhead de compilacion)
- Pydantic para validacion en runtime (FastAPI lo usa nativamente)
- Los bugs que Rust previene (null, data races) son irrelevantes en nuestro contexto:
  - No tenemos shared mutable state (cada request es independiente)
  - No tenemos concurrencia con memoria compartida (usamos asyncio, no threads)
  - No tenemos memory management manual
  - Pydantic valida todo input/output con tipos strictos

El gateway tiene 0 bugs reportados relacionados con tipos o null references. Los bugs reales son logicos (el LLM no entiende la pregunta, el MCP retorna datos incompletos). Ningun lenguaje soluciona eso.

**AI Tech Lead:**
Exacto. La clase de bugs que Rust/Go previenen (memory safety, null derefs, data races) no son los bugs que tenemos. Nuestros bugs son:
1. El LLM alucina datos de candidatos
2. El MCP no encuentra el plan de gobierno correcto
3. El prompt system no maneja edge cases
4. Redis session expira antes de lo esperado

Todos estos son bugs de logica de negocio y de AI, no de seguridad de tipos.

**Veredicto Ciclo 7:** ✅ Type safety de Rust/Go no resuelve los bugs reales del proyecto.

---

## Ciclo 8: Imagen Docker y cold starts

**SRE / Platform Engineer:**
Comparemos imagenes Docker y cold starts:

| Metrica | Python (actual) | Go | Rust |
|---------|----------------|-----|------|
| Imagen Docker | ~250MB (slim) | ~15MB (scratch) | ~10MB (scratch) |
| Cold start (Cloud Run) | ~2-4s | ~200ms | ~100ms |
| Warm request overhead | ~1ms | ~0.1ms | ~0.05ms |
| RAM idle | ~80MB | ~15MB | ~10MB |

**Go Advocate:**
Los cold starts de 2-4s en Python son malos para UX. Si el usuario abre la app despues de inactividad, espera 2-4s extra.

**Python Advocate:**
Tres respuestas:
1. `min-instances=1` en Cloud Run elimina cold starts por ~$5/mes extra
2. El frontend (Next.js) tambien tiene cold start en Cloud Run
3. Podemos optimizar el cold start de Python: lazy imports, eliminar dependencias innecesarias, usar multi-stage build

Ademas, ya estamos en min-instances=0 para beta. Cuando vayamos a produccion, pondremos min-instances=1. Problema resuelto por $5/mes.

**Delivery Lead:**
$5/mes vs 3-4 meses de reescritura. La relacion costo-beneficio es absurda.

**SRE / Platform Engineer:**
Hay optimizaciones Python que aun no hemos hecho:
- Multi-stage build (ya lo hacemos? verificar)
- `--no-cache-dir` en pip install
- Lazy imports de SDKs pesados (anthropic, openai se importan pero quiza no se usan)
- UV en vez de pip (instalacion 10-100x mas rapida, reduce build time)

Esas optimizaciones pueden bajar el cold start de 3s a ~1.5s sin cambiar de lenguaje.

**Veredicto Ciclo 8:** ✅ Cold starts se resuelven con min-instances o lazy imports. No justifica reescritura.

---

## Ciclo 9: Cuando SI tendria sentido migrar

**CTO / Decision Maker:**
Definamos los criterios claros para reconsiderar:

**Migrar a Go/Rust TIENE sentido si:**
1. El gateway deja de ser I/O-bound (ej: procesamiento local de ML, embeddings on-device, inferencia local)
2. El costo de Cloud Run supera $500/mes y el bottleneck es CPU/RAM del gateway (no del LLM)
3. El equipo crece a 5+ developers y necesitamos type safety del compilador para evitar regresiones
4. Los SDKs de LLM en Go/Rust alcanzan paridad de features con Python
5. El proyecto migra de Cloud Run a Kubernetes donde cold starts importan mas

**Migrar NO tiene sentido si:**
1. El 99%+ del tiempo de request es I/O externo (caso actual)
2. El equipo es 1-2 personas con expertise en Python
3. Los SDKs de AI son Python-first
4. El timeline es ajustado (elecciones 2026)
5. El costo de Cloud Run es <$50/mes

**Senior MLE:**
Un patron intermedio que podria ser util: escribir un **sidecar en Go** solo para health checks, rate limiting y reverse proxy. Asi el Python no recibe requests invalidos y el cold start del sidecar es rapido. Pero Cloud Run ya tiene load balancer... seria over-engineering.

**AI Tech Lead:**
Otro patron: si en el futuro necesitamos procesamiento CPU-intensivo (ej: NLP local, parsing masivo), lo ponemos como un **microservicio separado en Go/Rust** que el gateway Python invoca. No reescribimos el gateway, agregamos un servicio especializado.

**Full Stack Lead:**
Ese patron es exactamente lo que ya hacemos con infovoto-mcp. Los MCPs hacen el trabajo pesado (queries a DB, ChromaDB, parsing). El gateway solo orquesta. La arquitectura actual ya separa las responsabilidades.

**Veredicto Ciclo 9:** ✅ La arquitectura actual (gateway orquestador + MCPs especializados) ya es la solucion correcta.

---

## Ciclo 10: Veredicto final

**CTO / Decision Maker:**

### Resumen de evidencia

| Criterio | Rust | Go | Python (actual) |
|----------|------|----|-----------------|
| Rendimiento real (end-to-end) | +0.7% | +0.7% | Baseline |
| Amdahl speedup maximo | 1.007x | 1.007x | 1.0x |
| Costo Cloud Run mensual | -$0.10 | -$0.10 | $3.81 |
| SDKs LLM (Gemini/Claude/OpenAI) | ❌ Inmaduros | ⚠️ Parciales | ✅ Todos oficiales |
| SDK MCP | ❌ No existe | ⚠️ Experimental | ✅ Oficial |
| Cold start | 100ms | 200ms | 2-4s (fix: $5/mes) |
| Tiempo de reescritura | 18.5 semanas | 12.5 semanas | 0 semanas |
| Costo de oportunidad | 4.5 meses sin features | 3 meses sin features | 0 |
| Curva de aprendizaje equipo | Alta (lifetimes, async) | Media (goroutines) | Nula |
| Type safety real beneficio | Bajo (no hay memory bugs) | Bajo | Suficiente (Pydantic + mypy) |

### Ley de Amdahl aplicada

```
Tiempo total de un request /api/chat:  2,223 ms
Tiempo optimizable (codigo gateway):      16 ms (0.72%)
Tiempo NO optimizable (I/O externo):   2,207 ms (99.28%)

Speedup maximo teorico (S=infinito):   1.0073x
Speedup con Rust (S=50):               1.0071x
Speedup con Go (S=18):                 1.0068x

Conclusion: el lenguaje del gateway no puede mejorar
la latencia end-to-end mas de un 0.73%, independientemente
de que tan rapido sea el lenguaje.
```

### Decision

**❌ RECHAZADO: No reescribir el gateway en Rust ni Go.**

**Razones:**
1. **Amdahl's Law mata el caso de rendimiento.** 99.3% del tiempo es I/O externo. Optimizar 0.7% no justifica nada.
2. **Los SDKs de AI son Python-first.** Migrar introduce riesgo de compatibilidad y retraso en adoptar features nuevas de LLM.
3. **El costo de oportunidad es brutal.** 3-4.5 meses de reescritura vs features para las elecciones 2026.
4. **El ahorro en Cloud Run es $0.10/mes.** Literal.
5. **La arquitectura ya es correcta.** Gateway orquestador (I/O-bound) + MCPs especializados es el patron adecuado.

### Acciones recomendadas (en vez de reescribir)

1. **Optimizar cold start Python:** Lazy imports, UV para builds, multi-stage Docker slim
2. **min-instances=1 para produccion:** Elimina cold starts por $5/mes
3. **Monitorear costos de LLM API:** Ahi esta el gasto real, no en el gateway
4. **Si necesitamos CPU-intensivo en el futuro:** Nuevo microservicio en Go/Rust, no reescribir el gateway
5. **Mantener type hints + Pydantic estrictos:** Mejor costo-beneficio que cambiar de lenguaje

### Regla de reevaluacion

Revisitar esta decision si:
- El costo de Cloud Run del gateway supera $200/mes por CPU/RAM (no por LLM)
- El gateway necesita procesamiento CPU-intensivo local (embeddings, parsing)
- Los SDKs de Go para LLM/MCP alcanzan paridad con Python
- El equipo crece a 5+ personas

**Veredicto Ciclo 10:** ❌ Rechazado unanimemente. Mantener Python. Optimizar lo que importa.
