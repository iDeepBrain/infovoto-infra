# Debate 03: Arquitectura de Cache Inteligente para InfoVoto

> **Pregunta central:** ¿Que estrategia de cache maximiza hit rate sin servir data stale? Cache por exact-match, por tool+args, por entity, semantico, o combinacion?

**Fecha:** 2026-04-02
**Contexto:** Chatbot electoral Peru 2026. 36 candidatos presidenciales. Data cuasi-estatica (JNE actualiza semanalmente). Actual: exact-match normalizado en Redis (TTL=24h prod, 0 dev). Hit rate estimado: bajo (~15-20%) porque variaciones semanticas generan keys distintas.

---

## Estado Actual del Cache

### Normalizacion (`_normalize_query` en `src/agent/core.py`)

```python
_CACHE_STOPWORDS = frozenset({"de", "del", "la", "el", "los", "las", "un", "una",
    "dame", "dime", "cuentame", "info", "informacion", "datos", "sobre",
    "cual", "cuales", "que", "es", "son", "quien", "quienes", ...})

def _normalize_query(query: str) -> str:
    tokens = [t for t in query.lower().split() if t not in _CACHE_STOPWORDS]
    return " ".join(sorted(tokens))
```

### Cache Key (`_cache_key`)

```python
def _cache_key(message: str, user_id: str = "") -> str:
    normalized = _normalize_query(message)
    prefix = f"cache:query:{user_id}:" if _has_pii(message) and user_id else "cache:query:"
    return prefix + hashlib.sha256(normalized.encode()).hexdigest()
```

### Warmup (`src/gateway/main.py` linea 123)

- 30 preguntas predefinidas en `COMMON_QUESTIONS`
- Secuencial: `for q in COMMON_QUESTIONS` -> `await agent.process_message()`
- Tiempo estimado: 5-10 minutos (30 queries x 10-20s cada una)
- No hay paralelismo (`asyncio.create_task` pero internamente secuencial)

### Problemas Concretos

| Query A | Query B | Misma respuesta? | Cache hit? |
|---------|---------|-------------------|------------|
| "info de keiko" | "quien es keiko" | Si | NO (keys distintas tras normalizar) |
| "propuestas de seguridad de keiko" | "que propone keiko sobre seguridad" | Si | NO |
| "keiko fujimori" | "la china" | Si (preprocessor resuelve) | NO (normaliza ANTES de resolver nickname) |
| "candidatos presidenciales" | "quienes postulan a presidente" | Si | NO |
| "cuando son las elecciones" | "fecha de las elecciones 2026" | Si | NO |

---

## Ciclo 1 — Diagnostico del Exact-Match Actual

### Codeforces Grandmaster

El problema es algoritmico. `_normalize_query` hace sort lexicografico de tokens no-stopword. Esto colapsa variaciones de orden pero NO variaciones semanticas.

Analicemos la complejidad:
- **Espacio de queries posibles**: infinito (lenguaje natural)
- **Espacio de respuestas utiles**: finito y pequeno (~200 respuestas unicas para 36 candidatos x 5 MCPs + logistica)
- **Hit rate teorico optimo**: ~80-90% (la mayoria de queries del dia de elecciones seran repetitivas)
- **Hit rate actual estimado**: ~15-20% (solo exact-match post-normalizacion)

El gap es de 60-70 puntos porcentuales. Eso es un 4x-5x de LLM calls innecesarias.

### Senior AI Engineer

El approach actual ignora que el LLM router ya clasifica la query en `tool_name + args`. Si dos queries distintas ("info de keiko" y "quien es keiko") producen el mismo tool call `buscar_candidato(nombre="Keiko Fujimori")`, la respuesta del MCP es identica. El cache deberia estar en la capa de tool+args, no en la capa de query textual.

Ademas, el warmup secuencial de 5-10 minutos durante startup es un problema de disponibilidad: el pod de Cloud Run esta respondiendo con cache frio durante ese tiempo.

### Senior MLE

Propongo tres capas de cache, de mas rapida a mas lenta:

| Capa | Key | TTL | Hit rate |
|------|-----|-----|----------|
| L1: Query exact-match | `cache:query:{sha256(normalized)}` | 24h | ~15-20% |
| L2: Tool+Args | `cache:tool:{tool_name}:{sha256(sorted_args)}` | 24h | ~50-60% |
| L3: Entity | `cache:entity:{candidato}:{campo}` | 7d | ~70-80% |

L2 es el sweet spot. Cada vez que el LLM router decide `buscar_candidato(nombre="Keiko Fujimori")`, cacheamos el resultado del MCP. La siguiente query sobre Keiko, sin importar como la formule el usuario, pega en L2.

### Junior MLE

Pregunta: si cacheamos en L2 (tool+args), ya no necesitamos L1? Y si la respuesta del LLM es distinta cada vez (porque el LLM genera texto diferente para el mismo MCP result), L2 no ayuda...

### Junior Full Stack

El warmup tarda 5-10 minutos. En Cloud Run con min_instances=0, cada cold start es un startup de 5-10 min con cache frio. Los primeros usuarios tienen latencia de 3-5s en vez de <100ms. Eso es inaceptable para un chatbot electoral el dia de las elecciones.

### AI Tech Lead

Buen punto del Junior. L1 y L2 son complementarios, no excluyentes:

- **L1 (query exact)**: cachea la respuesta FINAL (texto del LLM + sources). Hit = 0ms de LLM.
- **L2 (tool+args)**: cachea el resultado del MCP. Hit = ahorra MCP call pero el LLM aun sintetiza. Hit = ahorra ~1-2s de MCP, LLM genera en ~1.5s.
- **L3 (entity)**: pre-computa perfiles completos por candidato. Hit = dato estructurado listo.

El punto del Junior MLE es valido: el LLM genera texto ligeramente distinto cada vez para el mismo MCP result. Pero eso es un feature, no un bug: da variedad. Lo importante es que L2 evita el round-trip al MCP.

### Full Stack Lead

Desde el frontend, me interesa la latencia percibida:

| Escenario | Latencia |
|-----------|----------|
| L1 hit (query exact) | <100ms |
| L2 hit (tool+args, LLM sintetiza) | ~1.5-2s |
| L3 hit (entity, LLM sintetiza) | ~1.5-2s |
| Cache miss completo | ~3-5s |

L1 es el unico que da respuesta instantanea. L2 y L3 ahorran tiempo pero no eliminan la espera del LLM.

### Delivery Lead

Para el dia de las elecciones necesitamos:
1. Respuestas sobre candidatos: <2s
2. Respuestas sobre logistica (donde voto): <1s (PII, no cacheable globalmente)
3. Respuestas sobre proceso electoral: <500ms (completamente estaticas)

L1 con buen warmup cubre (3). L2 mejora (1). (2) es per-user y requiere MCP real.

### Staff Engineer

El problema del warmup secuencial tiene solucion simple: `asyncio.gather` con semaforo. Pero el problema de fondo es que 30 preguntas no cubren las 200+ variaciones semanticas reales. El warmup deberia ser por entidad, no por pregunta.

### Product Manager

Los usuarios van a preguntar de 3 formas: por nombre ("keiko"), por tema ("seguridad"), o por logistica ("donde voto"). El 80% de las queries del dia de elecciones seran sobre los top 5-6 candidatos. Si cacheamos los perfiles de los 36 candidatos + 10 temas x 36 candidatos = 396 combinaciones, cubrimos el 80% del trafico.

**Veredicto Ciclo 1:** 🔄 Necesita cambios. El exact-match actual es insuficiente. Consenso en agregar L2 (tool+args). Debatir implementacion.

---

## Ciclo 2 — Diseno del Cache L2 (Tool+Args)

### Codeforces Grandmaster

La clave de L2 es la canonicalizacion de los argumentos. Si el LLM router retorna `buscar_candidato(nombre="Keiko Fujimori")` y otra vez `buscar_candidato(nombre="keiko fujimori")`, deben generar la misma cache key.

```python
def _tool_cache_key(tool_name: str, args: dict) -> str:
    # Canonical: sort keys, lowercase string values, strip whitespace
    canonical = {k: v.strip().lower() if isinstance(v, str) else v
                 for k, v in sorted(args.items())}
    payload = f"{tool_name}:{json.dumps(canonical, sort_keys=True, ensure_ascii=False)}"
    return "cache:tool:" + hashlib.sha256(payload.encode()).hexdigest()
```

Complejidad: O(k log k) donde k = numero de args (siempre < 10). Despreciable.

### Senior AI Engineer

El cache L2 se inserta entre el LLM router y la llamada MCP. Flujo actual:

```
Query -> Normalize -> L1 check -> Preprocessor -> LLM Router -> MCP call -> LLM Synth -> Response
```

Flujo propuesto:

```
Query -> Normalize -> L1 check -> Preprocessor -> LLM Router -> L2 check -> [MCP call si miss] -> LLM Synth -> Response
```

El punto de insercion es en `core.py` despues del router decision y antes de `_call_mcp_tool`. El resultado del MCP se cachea con la tool+args key.

### Senior MLE

Hay un matiz: el LLM router a veces pide multiples tools en secuencia (2 rounds max segun `llm_max_rounds: int = 2`). Ejemplo: "compara a keiko con lopez aliaga" genera dos calls: `buscar_candidato(nombre="Keiko Fujimori")` + `buscar_candidato(nombre="Rafael Lopez Aliaga")`. Cada call individual se cachea en L2, asi que la segunda vez que alguien pida comparar, ambas pegan en L2.

TTL propuesto para L2:

```python
# Tool TTL por tipo de dato
TOOL_TTL_MAP = {
    "buscar_candidato": 86400 * 7,      # 7 dias — perfil cambia poco
    "buscar_plan_gobierno": 86400 * 7,   # 7 dias — planes no cambian post-inscripcion
    "listar_candidatos_region": 86400 * 7,  # 7 dias — lista fija post-inscripcion
    "consultar_local_votacion": 86400,   # 24h — logistica puede cambiar
    "info_dia_elecciones": 86400 * 30,   # 30 dias — fecha fija
    "buscar_financiamiento": 86400 * 3,  # 3 dias — ONPE actualiza semanal
    "buscar_antecedentes": 86400 * 3,    # 3 dias — exclusiones pueden ocurrir
}
DEFAULT_TOOL_TTL = 86400  # 24h fallback
```

### Junior MLE

Pregunta: si cacheamos el resultado raw del MCP (JSON estructurado), el LLM aun necesita sintetizarlo en lenguaje natural. Eso cuesta ~1.5s de LLM. No seria mejor cachear tambien la respuesta sintetizada vinculada al tool+args?

### Junior Full Stack

Si cacheamos la respuesta sintetizada en L2, perdemos la variedad del LLM (cada respuesta suena ligeramente distinta). Pero honestamente, a un usuario electoral no le importa la variedad. Le importa la velocidad y la precision.

### AI Tech Lead

El Junior Full Stack tiene razon. Propongo un L2 hibrido:

- **L2-raw**: cachea el resultado del MCP (JSON). TTL largo (7d para perfiles). Se usa cuando el LLM necesita combinar con otros datos.
- **L2-synth**: cachea el resultado sintetizado del LLM para queries single-tool. TTL = min(L2-raw TTL, 24h). Es como un L1 pero indexado por tool+args en vez de query text.

```python
# L2-raw: resultado del MCP
"cache:tool:raw:{sha256(buscar_candidato:{'nombre':'keiko fujimori'})}"
# -> {"nombre": "Keiko Fujimori", "partido": "Fuerza Popular", "edad": 51, ...}

# L2-synth: respuesta sintetizada para single-tool queries
"cache:tool:synth:{sha256(buscar_candidato:{'nombre':'keiko fujimori'})}"
# -> {"reply": "Keiko Fujimori (51) es candidata por Fuerza Popular...", "sources": [...]}
```

### Full Stack Lead

Esto agrega complejidad. Tenemos que decidir cuando usar L2-synth vs L2-raw:
- Query single-tool -> usar L2-synth si existe (respuesta instantanea)
- Query multi-tool -> usar L2-raw de cada tool, sintetizar con LLM

La logica de decision es simple y determinista. No veo problemas.

### Delivery Lead

Numeros de latencia con L2-synth:

| Escenario | Latencia | % trafico estimado |
|-----------|----------|--------------------|
| L1 hit | <100ms | ~15% |
| L2-synth hit | <100ms | ~40% (nuevo!) |
| L2-raw hit + LLM synth | ~1.5s | ~15% |
| Cache miss completo | ~3-5s | ~30% |

Pasamos de 15% instantaneo a 55% instantaneo. Eso es un cambio enorme para el dia de elecciones.

### Staff Engineer

Un concern de operaciones: con L2 estamos almacenando 3 tipos de keys en Redis:
- `cache:query:*` (L1)
- `cache:tool:raw:*` (L2-raw)
- `cache:tool:synth:*` (L2-synth)
- `entity:*` (entity context)
- `session:*` (history)

Para 36 candidatos x 5 tools x ~10 variaciones de args = ~1800 keys de L2. Cada key ~2-5KB. Total: ~9MB. Irrelevante para Redis (Upstash free tier soporta 256MB).

### Product Manager

Me gusta que el hit rate suba de 15% a 55%+. Pero quiero entender la invalidacion: si el JNE excluye a un candidato durante la campana, cuanto tarda en reflejarse?

Con TTL de 7 dias para perfiles, podriamos servir data stale por hasta 7 dias. Eso es inaceptable para una exclusion. Necesitamos invalidacion manual o TTL mas agresivo.

**Veredicto Ciclo 2:** 🔄 Necesita cambios. L2 hibrido (raw + synth) aprobado en concepto. Falta definir estrategia de invalidacion y TTL adaptativo.

---

## Ciclo 3 — Invalidacion y TTL Adaptativo

### Codeforces Grandmaster

La invalidacion de cache es uno de los dos problemas dificiles de CS (el otro es nombrar cosas). Pero en este dominio es mas simple que en el caso general porque:

1. La fuente de verdad es UNA (JNE/ONPE)
2. Las actualizaciones son infrecuentes (semanal, no en tiempo real)
3. El espacio de entidades es pequeno (36 candidatos + ~20 partidos)

Propongo tres mecanismos:

```python
# 1. TTL escalonado por volatilidad
TTL_TIERS = {
    "static":  86400 * 30,  # 30d — fecha elecciones, proceso, reglas
    "stable":  86400 * 7,   # 7d  — perfiles, planes de gobierno
    "dynamic": 86400 * 1,   # 1d  — financiamiento, antecedentes
    "volatile": 3600 * 6,   # 6h  — resultados (solo post-eleccion)
}

# 2. Invalidacion por patron (flush selectivo)
async def invalidate_candidate(redis, candidate_name: str):
    """Invalida TODO el cache relacionado a un candidato."""
    normalized = candidate_name.strip().lower()
    # Scan + delete keys que contengan el nombre
    # En produccion: usar Redis SCAN con patron
    pattern = f"cache:tool:*{hashlib.sha256(normalized.encode()).hexdigest()[:8]}*"
    async for key in redis.scan_iter(match=pattern):
        await redis.delete(key)

# 3. Version tag (invalidacion global sin flush)
CACHE_VERSION = "v2"  # Incrementar al detectar actualizacion masiva del JNE

def _tool_cache_key(tool_name: str, args: dict) -> str:
    canonical = {k: v.strip().lower() if isinstance(v, str) else v
                 for k, v in sorted(args.items())}
    payload = f"{CACHE_VERSION}:{tool_name}:{json.dumps(canonical, sort_keys=True)}"
    return "cache:tool:" + hashlib.sha256(payload.encode()).hexdigest()
```

### Senior AI Engineer

El approach del version tag es elegante pero tiene un problema: incrementar `CACHE_VERSION` invalida TODO el cache (cold start). Para data electoral con 36 candidatos, prefiero invalidacion granular.

Propongo un `last_updated` por entidad en Redis:

```python
# Al detectar actualizacion del JNE (via scraper o manual)
await redis.hset("meta:last_update", "keiko_fujimori", "2026-03-28T10:00:00Z")
await redis.hset("meta:last_update", "global", "2026-03-28T10:00:00Z")

# Al leer cache, verificar frescura
async def _is_cache_fresh(redis, tool_name: str, args: dict) -> bool:
    cache_key = _tool_cache_key(tool_name, args)
    cached_at = await redis.hget(f"meta:cached_at:{cache_key}", "timestamp")
    # Determinar entidad afectada
    entity = args.get("nombre", args.get("partido", "global")).strip().lower()
    last_update = await redis.hget("meta:last_update", entity)
    if cached_at and last_update:
        return cached_at > last_update
    return True  # Si no hay metadata, confiar en TTL
```

### Senior MLE

Ojo: eso agrega 2 Redis reads extras por cache hit. Upstash cross-region es ~200-500ms per op. Dos reads extras = +400-1000ms. Destruye el beneficio del cache.

Alternativa: usar Redis `GETEX` con TTL dinamico. Cuando el scraper detecta actualizacion, reduce el TTL de las keys afectadas a 0 (las invalida):

```python
# En el scraper (o un endpoint admin):
async def on_jne_update(redis, candidate_name: str):
    """Llamado cuando el scraper detecta datos nuevos del JNE."""
    pattern = f"cache:tool:*"
    count = 0
    async for key in redis.scan_iter(match=pattern, count=100):
        # Verificar si la key contiene data del candidato
        raw = await redis.get(key)
        if raw and candidate_name.lower() in raw.decode().lower():
            await redis.delete(key)
            count += 1
    logger.info("Invalidated %d cache keys for %s", count, candidate_name)
```

### Junior MLE

Pero el scraper corre como job local, no tiene acceso al Redis de produccion (Upstash). Como invalidamos en prod?

### Junior Full Stack

Podriamos tener un endpoint admin protegido:

```python
@router.post("/admin/cache/invalidate")
async def invalidate_cache(
    entity: str = Query(...),
    api_key: str = Depends(verify_admin_key),
):
    """Invalida cache de un candidato o patron."""
    count = await invalidate_by_entity(app.state.redis, entity)
    return {"invalidated": count, "entity": entity}
```

Ya tenemos `api_key_admin` en `Settings`. Solo falta el endpoint.

### AI Tech Lead

Me gusta el endpoint admin. Pero seamos pragmaticos: en la realidad, cuantas veces vamos a invalidar cache manualmente?

- Pre-elecciones: tal vez 1-2 veces por semana (cuando el scraper corre)
- Dia de elecciones: 0 veces (no hay actualizaciones del JNE ese dia)
- Post-elecciones: resultados parciales cada hora

Para pre-elecciones, un TTL de 24h para todo es suficiente. El JNE no actualiza mas de 1 vez al dia.

Para el dia de elecciones, la data es 100% estatica. Podriamos poner TTL infinito (o 30 dias).

**Propuesta simplificada:**

```python
def _get_tool_ttl(tool_name: str) -> int:
    """TTL inteligente por tipo de tool."""
    if settings.is_election_day:  # Feature flag o calculo por fecha
        return 86400 * 7  # 7 dias — data congelada
    return {
        "buscar_candidato": 86400,          # 24h
        "buscar_plan_gobierno": 86400 * 3,  # 3 dias
        "listar_candidatos_region": 86400,  # 24h
        "consultar_local_votacion": 86400,  # 24h
        "info_dia_elecciones": 86400 * 30,  # 30 dias
        "buscar_financiamiento": 86400,     # 24h
        "buscar_antecedentes": 86400,       # 24h
    }.get(tool_name, 86400)
```

### Full Stack Lead

El flag `is_election_day` es sencillo:

```python
@property
def is_election_day(self) -> bool:
    from datetime import date
    return date.today() == date(2026, 4, 12)  # Primera vuelta
```

Hardcodeado y explicito. No necesita config externa.

### Delivery Lead

Me preocupa la invalidacion masiva. Si el JNE excluye a un candidato a 3 dias de la eleccion (ha pasado antes en Peru), necesitamos invalidar en menos de 1 hora. Con TTL de 24h, el usuario podria ver al candidato excluido durante 23 horas.

Solucion minima: endpoint admin + alerta de Slack/Telegram al equipo. Invalidamos manualmente en 5 minutos.

### Staff Engineer

Estoy de acuerdo con el approach pragmatico. La invalidacion manual via endpoint admin es suficiente para la escala de InfoVoto. No necesitamos CDC (Change Data Capture) ni pub/sub para 36 candidatos.

Resumen de invalidacion:
1. **TTL por tipo de tool** (automatico, cubre 99% de los casos)
2. **Endpoint admin** (manual, para emergencias como exclusiones)
3. **Version tag** (nuclear, solo si hay corrupcion masiva)

### Product Manager

Aprobado. TTL adaptativo + endpoint admin. No over-engineer con CDC o pub/sub. La probabilidad de necesitar invalidacion de emergencia es baja (1-2 veces en toda la campana), y el endpoint admin la cubre.

**Veredicto Ciclo 3:** ✅ Aprobado. TTL por tipo de tool + endpoint admin + version tag como nuclear option.

---

## Ciclo 4 — Cache L3: Entity-Based

### Codeforces Grandmaster

L3 es un cache estructurado por entidad. En vez de cachear respuestas a queries, pre-computamos y almacenamos datos por candidato/partido como objetos JSON en Redis.

```python
# Estructura L3
"entity:profile:keiko_fujimori" -> {
    "nombre": "Keiko Fujimori",
    "partido": "Fuerza Popular",
    "edad": 51,
    "educacion": "...",
    "experiencia": "...",
    "propuestas_top5": [...],
    "sentencias": [...],
    "financiamiento_total": "S/ 2.3M",
    "updated_at": "2026-03-28T10:00:00Z"
}
```

El LLM consulta este JSON directamente en vez de llamar al MCP. Latencia: ~200ms (Redis GET) vs ~2-4s (MCP call + ChromaDB search).

### Senior AI Engineer

Esto basicamente convierte a Redis en una base de datos de candidatos. Es tentador pero tiene problemas:

1. **Duplicacion de datos**: la fuente de verdad es PostgreSQL/ChromaDB en infovoto-mcp. Ahora tenemos una copia en Redis.
2. **Sincronizacion**: cada vez que el scraper actualiza PostgreSQL, hay que actualizar Redis tambien.
3. **Esquema**: el JSON de L3 necesita un esquema definido. Si el MCP agrega un campo, L3 queda desactualizado.

L2 (tool+args) evita estos problemas porque cachea el RESULTADO del MCP, no una vista materializada.

### Senior MLE

Contra-argumento: L3 es exactamente lo que hacen los CDN. Materializar una vista optimizada para lectura rapida. La duplicacion es aceptable si:
- El costo de sincronizacion es bajo (36 candidatos x 1 update semanal)
- El beneficio es alto (elimina MCP calls para el 70% de queries)

Pero estoy de acuerdo en que agrega complejidad operacional. No lo necesitamos si L2 funciona bien.

### Junior MLE

Pregunta: L3 requiere que el LLM sepa leer JSONs de Redis directamente, sin pasar por las tools del MCP. Eso significa cambiar el system prompt y la logica del agent. Es un cambio grande.

### Junior Full Stack

Si implementamos L3, necesitamos un dashboard admin para ver y editar los perfiles cacheados. Eso es otra feature que no existe.

### AI Tech Lead

L3 es over-engineering para la escala actual. Con L1 + L2 cubrimos:
- L1: ~15% hit rate (queries exactas repetidas)
- L2-synth: ~40% hit rate (misma tool+args, respuesta pre-sintetizada)
- L2-raw: ~15% adicional (multi-tool queries con MCP results cacheados)
- Total: ~70% hit rate

El 30% restante son queries nuevas o combinaciones inusuales. L3 solo mejoraria ese 30% marginalmente, y a un costo alto de complejidad.

### Full Stack Lead

Coincido. L3 viola el principio de "no over-engineer" del CLAUDE.md. Si en el futuro el hit rate de L2 no es suficiente, podemos agregar L3 incrementalmente.

### Delivery Lead

El dia de elecciones el trafico se multiplica x10-x50. L1+L2 con 70% hit rate significa que solo el 30% de queries pega en los MCPs. Eso reduce la carga en infovoto-mcp dramaticamente. Suficiente para la escala esperada.

### Staff Engineer

Un punto operacional: L2 es auto-populante (se llena con queries reales). L3 requiere un pipeline de materializacion. L2 es zero-ops despues de implementar. L3 requiere ops continuas.

### Product Manager

Descartamos L3 por ahora. Si despues de las elecciones analizamos logs y vemos que necesitamos mas, lo reconsideramos. YAGNI.

**Veredicto Ciclo 4:** ❌ Rechazado. L3 es over-engineering. L1+L2 es suficiente. Puede reconsiderarse post-elecciones con data real.

---

## Ciclo 5 — Cache Semantico (Embeddings)

### Codeforces Grandmaster

Cache semantico: en vez de exact-match, usamos embeddings para encontrar queries "similares" cuya respuesta ya esta cacheada.

```python
# Flujo semantico
query = "que piensa keiko sobre inseguridad"
embedding = await embed(query)  # gemini-embedding-001, ~200ms
# Buscar en cache vectorial (Redis Search o ChromaDB)
similar = await vector_search(embedding, threshold=0.92)
if similar:
    return similar.cached_response  # Hit semantico
```

El threshold (0.92) es critico:
- Muy alto (0.98): solo matchea parafraseos triviales. Hit rate bajo.
- Muy bajo (0.85): matchea queries semanticamente distintas. Respuestas incorrectas.

### Senior AI Engineer

Ya tenemos `gemini-embedding-001` configurado en `config_agent.py`. Y usamos ChromaDB en infovoto-mcp para busqueda semantica de planes de gobierno. La infra existe.

Pero el cache semantico tiene un costo por query: ~200ms para generar el embedding + ~50ms para la busqueda vectorial. Eso es 250ms extras en CADA request, incluso cuando hay cache miss. Comparar con L2 (tool+args) que es un simple Redis GET de ~5ms.

### Senior MLE

Hay otro problema: falsos positivos. Ejemplo:

```
Q1: "que propone keiko sobre seguridad"     -> propuestas de seguridad de Keiko
Q2: "que propone acuna sobre seguridad"     -> propuestas de seguridad de Acuna
Similitud coseno: 0.94 (alto! — las queries son estructuralmente identicas)
```

Si el threshold es 0.92, Q2 matchea con Q1 y devuelve las propuestas de Keiko para una pregunta sobre Acuna. **Respuesta incorrecta.**

El cache semantico requiere que la similitud capture la IDENTIDAD de la entidad, no solo la estructura de la pregunta. Esto es inherentemente fragil con embeddings de proposito general.

### Junior MLE

Podriamos combinar: semantico + filtro por entidad. Primero extraer la entidad (candidato/partido), luego buscar solo en el cache de esa entidad.

```python
entity = extract_entity(query)  # "Keiko Fujimori"
embedding = await embed(query)
similar = await vector_search(embedding, filter={"entity": entity}, threshold=0.90)
```

### Junior Full Stack

Eso agrega complejidad significativa. Ahora tenemos que:
1. Extraer entidad ANTES del cache check
2. Mantener un indice vectorial particionado por entidad
3. Gestionar el lifecycle de los embeddings en el indice

Para 36 candidatos, es manejable. Pero es mucha complejidad para un beneficio marginal sobre L2.

### AI Tech Lead

Hagamos los numeros. El cache semantico mejora sobre L2 en un caso especifico: queries que van al mismo tool+args pero con formulaciones tan distintas que L2-synth no las matchea.

Pero espera... L2-synth SE indexa por tool+args, no por query text. Si "que piensa keiko sobre inseguridad" y "propuestas de keiko en seguridad" ambas producen `buscar_plan_gobierno(candidato="Keiko Fujimori", tema="seguridad")`, L2 YA las matchea.

El cache semantico solo agregaria valor si el LLM router genera tool+args DISTINTOS para queries semanticamente equivalentes. Ejemplo:
- "seguridad ciudadana keiko" -> `buscar_plan_gobierno(candidato="Keiko Fujimori", tema="seguridad ciudadana")`
- "inseguridad keiko" -> `buscar_plan_gobierno(candidato="Keiko Fujimori", tema="inseguridad")`

L2 no matchea porque los args son distintos ("seguridad ciudadana" vs "inseguridad"). Aqui el cache semantico si ayudaria.

**Pero**: la solucion correcta es normalizar los args del tool, no agregar una capa semantica.

```python
TOPIC_SYNONYMS = {
    "inseguridad": "seguridad ciudadana",
    "seguridad": "seguridad ciudadana",
    "crimen": "seguridad ciudadana",
    "delincuencia": "seguridad ciudadana",
    "robos": "seguridad ciudadana",
    "educacion publica": "educacion",
    "colegios": "educacion",
    # ... 20-30 sinonimos mas
}
```

Esto es determinista, rapido (dict lookup), y no tiene falsos positivos.

### Full Stack Lead

El approach de sinonimos de temas es mas limpio. Un diccionario de 30 entradas vs un pipeline de embeddings completo. No contest.

### Delivery Lead

El cache semantico agrega 250ms de latencia al hot path, requiere un indice vectorial adicional, y tiene riesgo de falsos positivos. No vale la pena para el dominio electoral donde las entidades son finitas y los temas se pueden enumerar.

### Staff Engineer

Si quisieramos cache semantico en el futuro, podemos hacerlo OFFLINE: cada noche, generar embeddings de todas las queries del dia, clusterizar, e identificar queries que deberian compartir cache. Luego agregar esas variaciones al diccionario de sinonimos. Semantico como herramienta de analisis, no como hot-path.

### Product Manager

Descartado para hot-path. El diccionario de sinonimos de temas es la solucion correcta. Podemos usar cache semantico offline para descubrir nuevos sinonimos.

**Veredicto Ciclo 5:** ❌ Rechazado para hot-path. Aprobado como herramienta offline de analisis. Normalizar args con diccionario de sinonimos.

---

## Ciclo 6 — Warmup Optimizado

### Codeforces Grandmaster

El warmup actual es O(n) secuencial donde n=30. Con latencia promedio de 10-20s por query (MCP + LLM), son 5-10 minutos.

Solucion: paralelizar con semaforo para no saturar el LLM/MCP:

```python
async def _warm_cache(agent, concurrency: int = 5):
    """Parallel cache warmup with bounded concurrency."""
    from src.agent.prompts.common_questions import COMMON_QUESTIONS
    semaphore = asyncio.Semaphore(concurrency)
    cached = 0

    async def warm_one(q: str) -> bool:
        async with semaphore:
            existing = await agent._get_cached_reply(q)
            if existing:
                return True
            try:
                await agent.process_message(
                    ProcessRequest(user_id="__cache_warmup__", message=q, channel="cache")
                )
                return True
            except Exception as e:
                logger.warning("Warmup failed for '%s': %s", q[:40], e)
                return False

    results = await asyncio.gather(*[warm_one(q) for q in COMMON_QUESTIONS])
    cached = sum(1 for r in results if r)
    logger.info("Cache warmup: %d/%d in parallel (concurrency=%d)",
                cached, len(COMMON_QUESTIONS), concurrency)
```

Con concurrency=5: 30 queries / 5 paralelas = 6 batches x ~15s = ~90 segundos. **6x mas rapido.**

### Senior AI Engineer

Ademas del paralelismo, con L2 el warmup se vuelve mas inteligente. En vez de warmup por query textual, hacemos warmup por tool+args:

```python
# Warmup por entidad (cubre TODAS las variaciones de query)
WARMUP_TOOLS = [
    ("buscar_candidato", {"nombre": name})
    for name in TOP_CANDIDATES  # Top 10 candidatos por encuestas
] + [
    ("buscar_plan_gobierno", {"candidato": name, "tema": tema})
    for name in TOP_CANDIDATES[:5]
    for tema in ["seguridad ciudadana", "educacion", "salud", "economia", "empleo"]
] + [
    ("info_dia_elecciones", {}),
    ("listar_candidatos_region", {"cargo": "presidente", "limite": 36}),
]
# Total: 10 + 25 + 2 = 37 tool calls. Pero cachean TODAS las variaciones de query.
```

### Senior MLE

Con L2 warmup por tool+args, un warmup de 37 calls con concurrency=5 toma ~2 minutos. Y cubre el 80% del trafico esperado (top 10 candidatos + 5 temas principales).

Podemos ir mas lejos: si el pod ya tenia cache en Redis (Upstash persiste entre deploys), el warmup solo ejecuta las queries cuyo TTL expiro. Con TTL de 7 dias para perfiles, la mayoria ya estaran cacheados.

```python
async def _should_warm(redis, tool_name: str, args: dict) -> bool:
    """Check if L2 cache exists and is fresh."""
    key = _tool_cache_key(tool_name, args)
    return not await redis.exists(key)
```

### Junior MLE

Pregunta: el warmup actual usa `ProcessRequest(channel="cache")`. Esto pasa por todo el pipeline (preprocessor, LLM router, MCP, LLM synth). Para L2 warmup, podriamos llamar directamente al MCP sin pasar por el LLM, y solo cachear el raw result.

### Junior Full Stack

Buen punto. Un warmup "directo" al MCP seria mucho mas rapido:

```python
async def _warm_tool_cache(mcp_pool, redis, tool_name: str, args: dict):
    """Warm L2-raw cache by calling MCP directly."""
    key = _tool_cache_key(tool_name, args)
    if await redis.exists(key):
        return  # Already cached
    result = await mcp_pool.call_tool(tool_name, args)
    ttl = _get_tool_ttl(tool_name)
    await redis.set(f"cache:tool:raw:{key}", json.dumps(result), ex=ttl)
```

Sin LLM, cada call toma ~1-2s (solo MCP + DB). 37 calls con concurrency=10 = ~8 segundos total.

### AI Tech Lead

Excelente. El warmup directo al MCP tiene dos beneficios:
1. **Velocidad**: ~8s vs ~90s vs ~600s (actual)
2. **Costo**: 0 LLM calls vs 30 LLM calls (ahorra tokens de Gemini)

La primera query real de un usuario sobre Keiko si hara el LLM synth (~1.5s), pero el MCP call se ahorra porque L2-raw ya tiene el dato. Total: ~1.5s vs ~3-5s.

La segunda query identica pega en L1 o L2-synth y es <100ms.

### Full Stack Lead

El warmup directo requiere que el gateway conozca el schema de args de cada MCP tool. Actualmente el MCP registry ya descubre los tools y sus schemas via `/metadata`. Podemos usar eso:

```python
# Usar MCP registry para construir warmup calls
registry = app.state.mcp_registry
for tool in registry.tools:
    if tool.name in WARMUP_PRIORITIES:
        for args in generate_warmup_args(tool.name):
            await _warm_tool_cache(mcp_pool, redis, tool.name, args)
```

### Delivery Lead

Resumen de mejoras de warmup:

| Aspecto | Actual | Propuesto |
|---------|--------|-----------|
| Duracion | 5-10 min | ~8-15 seg |
| Concurrency | 1 | 10 |
| LLM calls | 30 | 0 |
| Costo Gemini | ~30 calls x $0.001 | $0 |
| Cobertura | 30 queries exactas | 37 tool combos (cubre miles de queries) |

### Staff Engineer

Un detalle: el warmup directo al MCP necesita que el MCP pool ya este inicializado. En el startup actual, el orden es: Redis -> MCP registry -> MCP pool -> Agent -> Warmup. Esto ya es correcto. Solo necesitamos cambiar `_warm_cache` para usar `mcp_pool.call_tool` en vez de `agent.process_message`.

### Product Manager

Aprobado. El warmup directo al MCP es objetivamente superior en todos los ejes. Implementar.

**Veredicto Ciclo 6:** ✅ Aprobado. Warmup directo al MCP con concurrency=10. Elimina LLM calls del warmup.

---

## Ciclo 7 — Normalizacion de Args del Tool

### Codeforces Grandmaster

Para que L2 funcione con hit rate alto, los args del tool deben ser canonicos. El LLM router puede generar variaciones:

```python
# Variaciones reales del LLM router
{"nombre": "Keiko Fujimori"}
{"nombre": "keiko fujimori"}
{"nombre": "Keiko Sofia Fujimori Higuchi"}
{"nombre": "Fujimori"}
```

Todos deberian resolver al mismo cache key. Propongo un `ArgNormalizer` por tool:

```python
from difflib import SequenceMatcher

# Canonical candidate names (loaded from MCP registry or hardcoded)
CANONICAL_CANDIDATES = [
    "Keiko Fujimori", "Rafael Lopez Aliaga", "Cesar Acuna",
    "Yonhy Lescano", "Ricardo Belmont", ...  # 36 total
]

def normalize_candidate_name(name: str) -> str:
    """Fuzzy match to canonical name."""
    name_lower = name.strip().lower()
    best_match = max(
        CANONICAL_CANDIDATES,
        key=lambda c: SequenceMatcher(None, name_lower, c.lower()).ratio()
    )
    if SequenceMatcher(None, name_lower, best_match.lower()).ratio() > 0.6:
        return best_match.lower()
    return name_lower

def normalize_tool_args(tool_name: str, args: dict) -> dict:
    """Canonicalize tool args for consistent cache keys."""
    normalized = {}
    for key, value in sorted(args.items()):
        if isinstance(value, str):
            value = value.strip().lower()
            if key in ("nombre", "candidato"):
                value = normalize_candidate_name(value)
            elif key == "tema":
                value = TOPIC_SYNONYMS.get(value, value)
        normalized[key] = value
    return normalized
```

### Senior AI Engineer

El fuzzy matching con `SequenceMatcher` es O(n*m) por candidato donde n y m son las longitudes de los strings. Con 36 candidatos y strings cortos (<50 chars), es ~1800 comparaciones x ~100 ops = ~180K ops. Despreciable (microsegundos).

Pero hay un edge case: "Fujimori" matchea con "Keiko Fujimori" (ratio ~0.7) pero tambien podria matchear con un candidato apellidado "Fujimori Otro". Dado que solo hay UNA Fujimori candidata, esta bien. Pero el code debe ser robusto a edge cases futuros.

### Senior MLE

Mejor usar el preprocessor existente que ya resuelve nicknames a nombres canonicos. `_resolve_nickname("keiko")` ya retorna `"Keiko Fujimori"`. Si el preprocessor enriquece el mensaje ANTES del LLM router, el router recibe el nombre canonico y genera args consistentes.

Verificando el flujo actual en `core.py`:

```python
# Linea 876
intent = preprocess(message, history, entity_context=entity_context)
# Luego el enriched_message se pasa al LLM router
```

Si el enriched_message ya tiene "Keiko Fujimori" (resuelto por el preprocessor), el LLM router generara `buscar_candidato(nombre="Keiko Fujimori")` consistentemente. El problema de variacion de args se reduce significativamente.

### Junior MLE

Pero no todos los nicknames estan en `_NICKNAMES`. Alguien podria escribir "la hija de Fujimori" o "candidata de Fuerza Popular". El preprocessor no resuelve esas variaciones.

### Junior Full Stack

Esas variaciones son responsabilidad del LLM router, no del preprocessor. El router interpreta lenguaje natural y extrae el candidato correcto. Lo que necesitamos es que post-router, los args se normalicen antes de generar la cache key.

### AI Tech Lead

Correcto. La normalizacion de args tiene dos puntos de aplicacion:

1. **Pre-router** (preprocessor): resuelve nicknames a nombres canonicos. Ya existe.
2. **Post-router** (antes de cache key): normaliza los args que el LLM genero.

Ambos son necesarios. Pre-router mejora la calidad del routing. Post-router garantiza cache consistency.

```python
# En el flujo de tool execution (core.py)
async def _execute_tool_with_cache(self, tool_name: str, args: dict) -> dict:
    normalized_args = normalize_tool_args(tool_name, args)
    cache_key = _tool_cache_key(tool_name, normalized_args)

    # Check L2-raw
    cached = await self.redis.get(f"cache:tool:raw:{cache_key}")
    if cached:
        logger.info("[L2-RAW] hit tool=%s", tool_name)
        return json.loads(cached)

    # Cache miss: call MCP
    result = await self._call_mcp_tool(tool_name, args)  # Usar args originales para el MCP

    # Cache result with normalized key
    ttl = _get_tool_ttl(tool_name)
    await self.redis.set(
        f"cache:tool:raw:{cache_key}",
        json.dumps(result, ensure_ascii=False),
        ex=ttl,
    )
    return result
```

### Full Stack Lead

Nota importante: usamos `normalized_args` para la cache key pero `args` (originales) para la llamada al MCP. El MCP puede ser sensible a la capitalizacion o formato de los args.

### Delivery Lead

La normalizacion de args con diccionario de sinonimos de temas cubre los 5-6 temas principales del debate electoral. Es una lista finita:

```python
TOPIC_SYNONYMS = {
    # Seguridad
    "inseguridad": "seguridad ciudadana",
    "seguridad": "seguridad ciudadana",
    "crimen": "seguridad ciudadana",
    "delincuencia": "seguridad ciudadana",
    "robos": "seguridad ciudadana",
    "narcotrafico": "seguridad ciudadana",
    # Educacion
    "educacion publica": "educacion",
    "colegios": "educacion",
    "universidades": "educacion",
    "escuelas": "educacion",
    # Salud
    "hospitales": "salud",
    "sis": "salud",
    "essalud": "salud",
    # Economia
    "empleo": "economia",
    "trabajo": "economia",
    "desempleo": "economia",
    "inflacion": "economia",
    "sueldo minimo": "economia",
    # Pensiones
    "afp": "pensiones",
    "jubilacion": "pensiones",
    "onp": "pensiones",
    # Corrupcion
    "anticorrupcion": "corrupcion",
    "lavado de activos": "corrupcion",
}
```

Unas 25-30 entradas. Mantenible a mano.

### Staff Engineer

Un concern: este diccionario vive en el gateway. Si infovoto-mcp agrega un nuevo tema o cambia la taxonomia, hay que actualizar el gateway. Acopla los dos servicios.

Solucion: que el MCP exponga sus temas canonicos via `/metadata`. El gateway los descarga al startup y construye el diccionario automaticamente.

Pero eso es over-engineering para 25 entradas. Dejemos el diccionario hardcodeado y lo movemos a config si crece.

### Product Manager

Aprobado con el diccionario hardcodeado. Si llega a 50+ entradas lo refactorizamos.

**Veredicto Ciclo 7:** ✅ Aprobado. Normalizacion post-router de args + diccionario de sinonimos de temas. Hardcodeado por ahora.

---

## Ciclo 8 — Integracion en el Pipeline Actual

### Codeforces Grandmaster

Definamos el flujo completo con todas las capas aprobadas:

```
Request
  |
  v
[1] Input validation (injection, guardrails)     ~0ms
  |
  v
[2] L1 check: cache:query:{sha256(normalized)}   ~5ms (Redis GET)
  |-- HIT -> return cached response               <100ms total
  |
  v
[3] Preprocessor (nicknames, DNI, fast-routes)    ~0ms
  |
  v
[4] LLM Router (tool selection)                   ~750ms
  |
  v
[5] normalize_tool_args(tool, args)               ~0ms
  |
  v
[6] L2-synth check: cache:tool:synth:{key}        ~5ms (Redis GET)
  |-- HIT -> return cached synthesized response    ~760ms total
  |
  v
[7] L2-raw check: cache:tool:raw:{key}            ~5ms (Redis GET)
  |-- HIT -> skip MCP, go to [9]                   ahorra ~2s
  |
  v
[8] MCP call (real)                                ~1-4s
  |
  v
[9] LLM Synthesis                                  ~1.5-3s
  |
  v
[10] Cache write (async, non-blocking):
     - L1: cache:query:{sha256(normalized)}
     - L2-synth: cache:tool:synth:{key} (solo single-tool)
     - L2-raw: cache:tool:raw:{key}
  |
  v
Response
```

### Senior AI Engineer

El paso [4] (LLM Router) sigue ejecutandose incluso cuando hay L2 hit. Eso es ~750ms de LLM call "desperdiciada" cuando hay L2-synth hit.

Alternativa: mover el L2-synth check ANTES del router. Pero para eso necesitariamos saber el tool+args sin pasar por el router...

Podemos hacerlo para fast-routes. El preprocessor ya tiene `_try_fast_route` que genera tool+args sin LLM:

```python
# Si hay fast-route, checkear L2-synth ANTES del router
if intent.fast_route:
    for tool in intent.fast_route.tools:
        normalized_args = normalize_tool_args(tool["name"], tool["args"])
        synth_key = _tool_cache_key(tool["name"], normalized_args)
        cached = await redis.get(f"cache:tool:synth:{synth_key}")
        if cached:
            return cached  # Skip router AND MCP AND synth
```

Esto ahorra ~750ms para fast-routes con L2-synth hit. Las fast-routes cubren: candidatos presidenciales, fecha elecciones, local de votacion.

### Senior MLE

Buen punto. Pero los fast-routes son solo 3-4 patrones. Para queries no-fast-route, el router es necesario.

Hay otra optimizacion: el `is_short_msg` check actual (`len(message.split()) <= 5`) desactiva el cache L1 para mensajes cortos. Eso es incorrecto con L2, porque "keiko" (1 palabra) deberia matchear en L2-synth via `buscar_candidato(nombre="Keiko Fujimori")`.

```python
# Actual (core.py linea 835-836):
is_short_msg = len(message.split()) <= 5
check_cache = not is_short_msg and settings.cache_exact_ttl_seconds > 0

# Propuesto: siempre checkear cache
check_cache = settings.cache_exact_ttl_seconds > 0 or settings.feature_l2_cache_enabled
```

### Junior MLE

Espera, por que se desactiva el cache para mensajes cortos? Leyendo el codigo, parece que es porque mensajes cortos son ambiguos y dependen del contexto (entity_context). "sus propuestas" necesita saber QUIEN del contexto previo.

### Junior Full Stack

Buen punto. L1 no deberia activarse para mensajes ambiguos sin entidad. Pero L2 si puede, porque el router resuelve la ambiguedad usando el history. Si el router decide `buscar_plan_gobierno(candidato="Keiko Fujimori", tema="propuestas")`, L2 puede cachear eso.

### AI Tech Lead

Correcto. L1 y L2 tienen reglas de activacion distintas:

- **L1**: solo si `len(tokens) > 5` (mensaje autocontenido). Mantener regla actual.
- **L2**: siempre, post-router. El router ya desambiguo.

El flujo queda:

```python
# L1 check (pre-router, solo mensajes largos)
if len(message.split()) > 5:
    l1_hit = await _get_cached_reply(message, user_id)
    if l1_hit:
        return l1_hit

# Router + Preprocessor
intent = preprocess(message, ...)
route = await llm_router(intent.enriched_message, history)

# L2 check (post-router, siempre)
for tool_call in route.tools:
    norm_args = normalize_tool_args(tool_call.name, tool_call.args)
    l2_key = _tool_cache_key(tool_call.name, norm_args)
    # Single-tool: check L2-synth first
    if len(route.tools) == 1:
        synth = await redis.get(f"cache:tool:synth:{l2_key}")
        if synth:
            return json.loads(synth)
    # Check L2-raw
    raw = await redis.get(f"cache:tool:raw:{l2_key}")
    if raw:
        tool_call.cached_result = json.loads(raw)
```

### Full Stack Lead

Esto agrega hasta 3 Redis reads secuenciales post-router: L2-synth + L2-raw para cada tool. Con Upstash (~200-500ms per op), eso es +400-1500ms.

Solucion: `asyncio.gather` para leer L2-synth y L2-raw en paralelo. Y si hay 2 tools, leer los 4 keys en un solo `MGET`:

```python
# Redis MGET: 1 round-trip para N keys
keys = []
for tc in route.tools:
    norm = normalize_tool_args(tc.name, tc.args)
    k = _tool_cache_key(tc.name, norm)
    keys.extend([f"cache:tool:synth:{k}", f"cache:tool:raw:{k}"])

values = await redis.mget(*keys)  # 1 round-trip, ~200ms
```

### Delivery Lead

Con `MGET`, el overhead de L2 es 1 Redis round-trip (~200-500ms). Aceptable dado que ahorra 1-4s de MCP call cuando hay hit.

### Staff Engineer

Resumen de cambios en `core.py`:

1. Agregar `normalize_tool_args()` y `TOPIC_SYNONYMS`
2. Agregar `_tool_cache_key()` con canonicalizacion
3. Modificar el flujo post-router para check L2 via `MGET`
4. Agregar cache write de L2-raw y L2-synth post-execution
5. Modificar warmup para usar MCP directo con concurrency

Estimacion: ~200 lineas de cambio en `core.py` + ~50 lineas de nuevo modulo `cache.py`.

### Product Manager

Eso es un cambio mediano. Quiero que se implemente incrementalmente:
1. **Fase 1**: L2-raw (cache MCP results) + warmup paralelo. Menor riesgo.
2. **Fase 2**: L2-synth (cache respuestas sintetizadas). Requiere mas testing.
3. **Fase 3**: Normalizacion de args + sinonimos de temas.

**Veredicto Ciclo 8:** ✅ Aprobado. Implementacion en 3 fases. MGET para minimizar round-trips.

---

## Ciclo 9 — Metricas y Observabilidad

### Codeforces Grandmaster

Sin metricas, no podemos validar que el cache funciona. Necesitamos:

```python
# Counters por capa
CACHE_METRICS = {
    "l1_hit": 0, "l1_miss": 0,
    "l2_synth_hit": 0, "l2_synth_miss": 0,
    "l2_raw_hit": 0, "l2_raw_miss": 0,
    "total_requests": 0,
}
```

Pero counters in-memory se pierden con cada deploy. Mejor usar Redis:

```python
async def record_cache_metric(redis, layer: str, hit: bool):
    key = f"metrics:cache:{layer}:{'hit' if hit else 'miss'}"
    await redis.incr(key)
    # TTL de 7 dias para las metricas
    await redis.expire(key, 86400 * 7)
```

### Senior AI Engineer

Ya tenemos `message_traces` en PostgreSQL (migration 003). Agregar un campo `cache_layer` al trace:

```python
# En el trace actual
trace = {
    "user_id": user_id,
    "message": message,
    "reply": reply,
    "tools_called": [...],
    "cache_hit": True,
    "cache_layer": "l2_synth",  # NUEVO: "l1", "l2_synth", "l2_raw", "miss"
    "latency_ms": elapsed * 1000,
}
```

Esto permite queries SQL para analizar hit rates por capa:

```sql
SELECT cache_layer, COUNT(*) as count,
       AVG(latency_ms) as avg_latency
FROM message_traces
WHERE created_at > NOW() - INTERVAL '24 hours'
GROUP BY cache_layer;
```

### Senior MLE

Tambien necesitamos un endpoint para ver el estado del cache en tiempo real:

```python
@router.get("/admin/cache/stats")
async def cache_stats(api_key: str = Depends(verify_admin_key)):
    redis = request.app.state.redis
    info = await redis.info("memory")
    l1_keys = 0
    l2_raw_keys = 0
    l2_synth_keys = 0
    async for _ in redis.scan_iter(match="cache:query:*", count=100):
        l1_keys += 1
    async for _ in redis.scan_iter(match="cache:tool:raw:*", count=100):
        l2_raw_keys += 1
    async for _ in redis.scan_iter(match="cache:tool:synth:*", count=100):
        l2_synth_keys += 1
    return {
        "memory_used_mb": info["used_memory"] / 1024 / 1024,
        "l1_keys": l1_keys,
        "l2_raw_keys": l2_raw_keys,
        "l2_synth_keys": l2_synth_keys,
        "ttl_config": {
            "l1": settings.cache_exact_ttl_seconds,
            "l2_default": 86400,
        },
    }
```

### Junior MLE

El `SCAN` iterativo puede ser lento con muchas keys. Alternativa: mantener un SET de keys por tipo:

```python
# Al escribir cache
await redis.sadd("cache:index:l1", cache_key)
await redis.sadd("cache:index:l2_raw", cache_key)

# Para contar
l1_count = await redis.scard("cache:index:l1")
```

Pero esto agrega complejidad al write path. Para ~2000 keys totales, `SCAN` es instantaneo.

### Junior Full Stack

Propongo un dashboard simple en el frontend admin (si existe) o un script CLI:

```bash
# Script de diagnostico
curl -s https://gateway/admin/cache/stats -H "X-API-Key: $ADMIN_KEY" | jq .
```

No necesitamos un dashboard web. Un endpoint JSON + `jq` es suficiente.

### AI Tech Lead

Minimo viable de metricas:
1. Campo `cache_layer` en `message_traces` (PostgreSQL)
2. Endpoint `/admin/cache/stats` (keys count + memory)
3. Log line existente `[CACHE] hit` ya logea en Cloud Logging

No necesitamos Prometheus, Grafana, ni DataDog para la escala actual.

### Full Stack Lead

El log actual `[CACHE] hit user=%s elapsed=%.0fms` se puede extender:

```python
logger.info("[CACHE] %s layer=%s tool=%s user=%s elapsed=%.0fms",
            "hit" if cached else "miss", layer, tool_name, user_id[:12], elapsed * 1000)
```

Con Cloud Logging, podemos filtrar por `layer=l2_synth` y graficar hit rates.

### Delivery Lead

Para el dia de elecciones, necesito un dashboard que muestre en tiempo real:
- Hit rate por capa (debe ser >60%)
- Latencia P50 y P99
- Top 10 queries mas frecuentes

Cloud Logging + un query guardado en la consola de GCP es suficiente.

### Staff Engineer

Propongo tambien un "cache effectiveness" log cada 100 requests:

```python
if self._request_count % 100 == 0:
    logger.info("[CACHE-REPORT] total=%d l1_hits=%d l2_synth=%d l2_raw=%d miss=%d hit_rate=%.1f%%",
                self._request_count, self._l1_hits, self._l2_synth_hits,
                self._l2_raw_hits, self._misses,
                (self._l1_hits + self._l2_synth_hits + self._l2_raw_hits) / self._request_count * 100)
```

In-memory counters, se pierden con deploy, pero dan visibilidad en real-time durante un dia de alta carga.

### Product Manager

Aprobado. Metricas minimas: campo en traces + endpoint admin + log line extendido. Nada mas.

**Veredicto Ciclo 9:** ✅ Aprobado. Metricas minimas sin infraestructura adicional.

---

## Ciclo 10 — Riesgos, Edge Cases y Plan Final

### Codeforces Grandmaster

Enumeremos los riesgos:

| Riesgo | Probabilidad | Impacto | Mitigacion |
|--------|-------------|---------|------------|
| Cache sirve data stale (candidato excluido) | Baja (1-2x en campana) | Alto | Endpoint admin + TTL 24h |
| L2 key collision (args distintos, mismo hash) | Despreciable (SHA256) | Alto | SHA256 = 2^128 collision resistance |
| LLM router genera args inconsistentes | Media | Medio | normalize_tool_args() post-router |
| Redis Upstash caida | Baja | Medio | Circuit breaker ya existe |
| Warmup falla parcialmente | Media | Bajo | Retry + log + continuar |
| MGET timeout en Upstash | Baja | Bajo | Timeout cap + fallback a no-cache |

### Senior AI Engineer

Edge case critico: **queries multi-candidato con cache parcial**.

"Compara a Keiko con Lopez Aliaga": genera 2 tool calls. Si Keiko esta en L2-raw pero Lopez Aliaga no, hacemos 1 MCP call (solo Lopez Aliaga) y sintetizamos con ambos resultados. El L2-synth NO aplica para multi-tool queries (la respuesta depende de AMBOS resultados combinados).

```python
# Multi-tool: solo L2-raw, nunca L2-synth
if len(route.tools) > 1:
    # Check L2-raw para cada tool individualmente
    for tc in route.tools:
        raw = l2_raw_results.get(tc.cache_key)
        if raw:
            tc.cached_result = raw  # Skip MCP para este tool
        else:
            tc.cached_result = await self._call_mcp_tool(tc.name, tc.args)
            await self._cache_l2_raw(tc)  # Cache para futuro
    # Sintetizar con LLM (siempre, para multi-tool)
    reply = await self._synthesize(route.tools)
```

### Senior MLE

Otro edge case: **PII en tool args**. Si alguien pregunta "donde voto yo, mi DNI es 12345678", el tool call es `consultar_local_votacion(dni="12345678")`. Eso NO debe cachearse en L2 compartido.

```python
def _has_pii_in_args(args: dict) -> bool:
    return any(k in ("dni", "documento", "telefono") for k in args)

# En cache write
if not _has_pii_in_args(normalized_args):
    await self._cache_l2(tool_name, normalized_args, result)
```

Esto ya es consistente con la logica `_has_pii` existente en L1.

### Junior MLE

Test plan para validar el cache:

```python
# test_cache_layers.py
async def test_l1_exact_match():
    """Same normalized query -> L1 hit."""
    r1 = await agent.process("Quien es Keiko Fujimori?")
    r2 = await agent.process("Quien es Keiko Fujimori?")
    assert r2.cached is True

async def test_l2_synth_different_queries_same_tool():
    """Different queries, same tool+args -> L2-synth hit."""
    r1 = await agent.process("info de keiko")
    r2 = await agent.process("cuentame sobre keiko fujimori")
    # r2 should hit L2-synth (same tool: buscar_candidato, nombre=keiko fujimori)
    assert r2.cached is True
    assert r2.cache_layer == "l2_synth"

async def test_l2_raw_multi_tool():
    """Multi-tool query uses L2-raw for individual tools."""
    await agent.process("quien es keiko")  # Populates L2-raw for keiko
    r = await agent.process("compara a keiko con acuna")
    # Keiko data from L2-raw, Acuna from MCP (miss)
    assert "Keiko" in r.reply
    assert "Acuna" in r.reply

async def test_pii_not_cached_globally():
    """PII queries should not be in shared cache."""
    r1 = await agent.process("donde voto, mi DNI 12345678", user_id="user_a")
    r2 = await agent.process("donde voto, mi DNI 12345678", user_id="user_b")
    assert r2.cached is False  # Different user, PII query

async def test_topic_synonyms():
    """Synonym topics should hit same L2 cache."""
    r1 = await agent.process("propuestas de keiko sobre inseguridad")
    r2 = await agent.process("propuestas de keiko sobre delincuencia")
    # Both normalize to tema="seguridad ciudadana"
    assert r2.cached is True
```

### Junior Full Stack

Para la fase de implementacion, los archivos a modificar son:

| Archivo | Cambio |
|---------|--------|
| `src/agent/cache.py` (NUEVO) | `normalize_tool_args`, `_tool_cache_key`, `TOPIC_SYNONYMS`, `TOOL_TTL_MAP` |
| `src/agent/core.py` | Integrar L2 checks post-router, L2 writes post-execution |
| `src/gateway/main.py` | Warmup directo al MCP con concurrency |
| `src/gateway/config.py` | `feature_l2_cache_enabled`, TTL configs |
| `src/gateway/routers/api.py` | Pasar `cache_layer` al trace |
| `tests/integration/test_cache_layers.py` (NUEVO) | Tests del Junior MLE |

### AI Tech Lead

Plan de implementacion por fases:

**Fase 1 (1-2 dias): L2-raw + Warmup paralelo**
- Crear `src/agent/cache.py` con funciones de normalizacion
- Modificar `core.py` para cache L2-raw en MCP calls
- Warmup directo al MCP con `asyncio.Semaphore(10)`
- Tests basicos

**Fase 2 (1 dia): L2-synth**
- Agregar L2-synth write para single-tool queries
- MGET para check paralelo de L2-synth + L2-raw
- Tests de hit entre queries distintas

**Fase 3 (medio dia): Normalizacion + Metricas**
- `TOPIC_SYNONYMS` dict
- `normalize_tool_args` con fuzzy candidate matching
- Campo `cache_layer` en traces
- Endpoint `/admin/cache/stats`

**Fase 4 (medio dia): Admin + Invalidacion**
- Endpoint `/admin/cache/invalidate`
- `_get_tool_ttl` por tipo de tool
- Version tag como nuclear option

Total: 3-4 dias de implementacion.

### Full Stack Lead

El diseno respeta la arquitectura hexagonal del proyecto. `cache.py` es un modulo de infraestructura que no depende de FastAPI ni de Gemini. `core.py` orquesta las capas. Los tests validan comportamiento, no implementacion.

### Delivery Lead

Timeline:
- Fase 1-2: antes del 8 de abril (1 semana antes de elecciones)
- Fase 3-4: antes del 10 de abril
- Dia de elecciones (12 abril): cache estable, warmup rapido, metricas en Cloud Logging

Critico: hacer load testing con las 30 common questions + 50 variaciones semanticas. El hit rate debe ser >60% para considerar exitoso.

### Staff Engineer

Checklist de produccion:
- [ ] Feature flag `feature_l2_cache_enabled` (default False en dev, True en prod)
- [ ] `cache_exact_ttl_seconds` en prod = 86400 (ya configurado)
- [ ] L2 TTL map configurado en env vars o hardcodeado
- [ ] Warmup log confirma 37/37 tools cacheados
- [ ] `MGET` batch size limitado a 20 keys (Upstash limit)
- [ ] Circuit breaker de Redis ya protege contra Upstash downtime
- [ ] Rollback plan: desactivar `feature_l2_cache_enabled` via env var, redeploy en 2 min

### Product Manager

Aprobacion final. El plan es solido, incremental, y tiene rollback. Los numeros proyectados:

| Metrica | Actual | Proyectado |
|---------|--------|------------|
| Cache hit rate | ~15% | ~65-75% |
| P50 latencia | ~3s | ~1s |
| P99 latencia | ~8s | ~4s |
| Warmup time | 5-10 min | ~15 seg |
| LLM calls por 1000 req | ~850 | ~300-400 |
| Costo Gemini mensual | ~$25 | ~$10 |

La reduccion de 60% en LLM calls justifica por si sola los 3-4 dias de implementacion.

**Veredicto Ciclo 10:** ✅ Aprobado. Plan de implementacion en 4 fases. Deadline: 10 de abril 2026.

---

## VEREDICTO FINAL

### Arquitectura Aprobada: L1 + L2 (raw + synth) con normalizacion de args

```
                    ┌─────────────────────────────────────────────┐
                    │              Cache Architecture             │
                    │                                             │
Request ──────────► │  [L1] Query exact-match                    │
                    │   Key: cache:query:{sha256(normalized)}     │
                    │   TTL: 24h │ HIT = <100ms                  │
                    │       │                                     │
                    │       ▼ MISS                                │
                    │  [Preprocessor + LLM Router] ~750ms         │
                    │       │                                     │
                    │       ▼                                     │
                    │  [L2-synth] Synthesized response cache      │
                    │   Key: cache:tool:synth:{sha256(tool+args)} │
                    │   TTL: min(tool_ttl, 24h) │ HIT = <800ms   │
                    │       │                                     │
                    │       ▼ MISS                                │
                    │  [L2-raw] MCP result cache                  │
                    │   Key: cache:tool:raw:{sha256(tool+args)}   │
                    │   TTL: tool_ttl (1d-30d) │ HIT = ahorra MCP│
                    │       │                                     │
                    │       ▼ MISS                                │
                    │  [MCP call] ~1-4s                           │
                    │  [LLM Synth] ~1.5-3s                        │
                    │       │                                     │
                    │       ▼                                     │
                    │  [Cache write] L1 + L2-raw + L2-synth       │
                    └─────────────────────────────────────────────┘
```

### Decisiones Clave

| Decision | Elegido | Descartado | Razon |
|----------|---------|------------|-------|
| Cache L2 (tool+args) | Si | - | Colapsa variaciones semanticas en tool+args canonicos |
| Cache L3 (entity-based) | No | Si | Over-engineering para 36 candidatos |
| Cache semantico (embeddings) | No (hot-path) | Si | +250ms latencia, falsos positivos, L2 ya cubre |
| Invalidacion | TTL + admin endpoint | CDC, pub/sub | Data cuasi-estatica, invalidacion infrecuente |
| Warmup | MCP directo, concurrency=10 | Secuencial via agent | 6x mas rapido, 0 LLM calls |
| Normalizacion args | Diccionario sinonimos | Embeddings, ML | Determinista, rapido, sin falsos positivos |
| Metricas | trace.cache_layer + logs | Prometheus, Grafana | Escala actual no justifica infra de metricas |

### Archivos Nuevos/Modificados

```
src/agent/cache.py          (NUEVO)  ~120 lineas
src/agent/core.py           (MOD)    ~200 lineas cambio
src/gateway/main.py         (MOD)    ~30 lineas cambio (warmup)
src/gateway/config.py       (MOD)    ~10 lineas (feature flags, TTLs)
tests/integration/test_cache_layers.py (NUEVO) ~100 lineas
```

### Fases de Implementacion

| Fase | Contenido | Dias | Deadline |
|------|-----------|------|----------|
| 1 | L2-raw + warmup paralelo | 1-2 | 6 abril |
| 2 | L2-synth + MGET | 1 | 8 abril |
| 3 | Normalizacion args + metricas | 0.5 | 9 abril |
| 4 | Admin endpoint + TTL por tool | 0.5 | 10 abril |

### Criterio de Exito

- Cache hit rate > 60% en produccion (medido via `cache_layer` en traces)
- P50 latencia < 1.5s (actualmente ~3s)
- Warmup completo en < 30 segundos
- Zero incidentes de data stale reportados por usuarios
