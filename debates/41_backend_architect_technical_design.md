# Debate 41: Diseño Técnico del RAG Paralelo

**Rol:** Backend Architect
**Input:** Debates 34-40 + arquitectura gateway actual + config.py + core.py
**Fecha:** 2026-04-03

---

## Decisiones de arquitectura

Después de 7 debates con consenso de que el RAG paralelo es viable y deseable, necesito resolver las decisiones técnicas concretas.

## Decisión 1: ¿Dónde vive ChromaDB del RAG?

### Opciones evaluadas

| Opción | Latencia | Complejidad | Memory | Docker Image |
|--------|----------|-------------|--------|-------------|
| A: HTTP al MCP existente | 200-500ms | Baja | 0 extra | Sin cambio |
| B: ChromaDB client directo | 50-100ms | Media | ~100MB | +chromadb dep |
| C: ChromaDB embebido en gateway | 15-25ms | Alta | ~300MB | +chromadb +onnx |

### Recomendación: Opción B — ChromaDB HTTP client directo

**Razón**:
- El servicio `infovoto-mcp` ya corre ChromaDB. El gateway puede conectarse directamente al ChromaDB server via HTTP sin pasar por las capas FastAPI/FastMCP del MCP.
- Latencia ~50-100ms es suficiente (Debate 35: termina antes que el router LLM).
- NO duplica datos ni infraestructura.
- NO agrega ONNX al gateway (ahorra 200MB de Docker image + cold start).

**PERO**: Requiere que ChromaDB en infovoto-mcp exponga el puerto HTTP. Actualmente ChromaDB es un PersistentClient embebido en el MCP — no tiene server HTTP propio.

### Decisión revisada: Opción C — ChromaDB embebido (persistente, read-only)

Dado que ChromaDB en el MCP es embebido (PersistentClient), no hay server HTTP al que conectarse. Las opciones reales son:

1. **Agregar ChromaDB server al MCP** → Complejidad, nuevo puerto, nuevo servicio
2. **Agregar MCP tool para RAG** → Ya existe (buscar_propuesta_tema), pero pasa por routing que es lo que queremos bypassear
3. **ChromaDB embebido en gateway** → Independiente del MCP, read-only

**Opción elegida: ChromaDB embebido en gateway, colección read-only.**

La colección `perfiles_candidatos_rag` se genera offline (script en infovoto-scraper) y se monta como volumen en el gateway container. El gateway la abre como PersistentClient read-only.

```
infovoto-scraper/
└── scripts/db/build_perfiles_chromadb.py  ← genera la colección

infovoto-gateway/
└── src/data/chromadb_perfiles/            ← directorio montado
    ├── chroma.sqlite3
    └── ...embeddings...
```

**Docker compose**:
```yaml
gateway:
  volumes:
    - ../infovoto-scraper/data/chromadb_perfiles:/app/src/data/chromadb_perfiles:ro
```

**Cloud Run**: Los datos se incluyen en el Docker image del gateway (COPY durante build) o se montan desde GCS via Cloud Storage FUSE.

### Trade-off de la opción elegida

| Pro | Contra |
|-----|--------|
| Latencia mínima (~15-25ms) | Agrega chromadb + onnxruntime al gateway (~200MB) |
| Sin dependencia de red | Necesita re-build del gateway si datos cambian |
| Read-only = seguro | Cold start de Cloud Run +3-5s (ONNX model load) |
| 36 docs = trivial en memoria | Duplicación de datos (PostgreSQL + ChromaDB) |

**Mitigación del cold start**: Pre-cargar modelo ONNX y colección en el lifespan del gateway. Cloud Run mantiene min-instances=1 en producción.

## Decisión 2: Estructura del módulo RAG en gateway

### Ubicación en el código

```
src/agent/
├── core.py           ← pipeline principal (llama al RAG)
├── rag.py            ← NUEVO: módulo RAG (búsqueda + formateo)
├── router.py         ← router LLM (sin cambios)
├── preprocessor.py   ← preprocessor (sin cambios)
└── prompts/
    └── system.py     ← system prompt (ajustar para RAG context)
```

### Diseño de `rag.py`

```python
"""RAG module — semantic search over candidate profiles.

Provides parallel context injection for the synthesizer.
ChromaDB collection: perfiles_candidatos_rag (36 presidential candidates).
Read-only, loaded at startup from src/data/chromadb_perfiles/.
"""

import logging
import re
from pathlib import Path

import chromadb

logger = logging.getLogger(__name__)

# ── Query expansion for Spanish electoral queries ──
_EXPANSIONS: dict[re.Pattern, str] = {
    re.compile(r"\b(cuánto\s+(?:gana|tiene)|patrimonio|dinero|riqueza)\b", re.I):
        "patrimonio ingreso bienes dinero sueldo",
    re.compile(r"\b(estudi[oó]|educaci[oó]n|universidad|carrera|formaci[oó]n)\b", re.I):
        "educación estudios universidad carrera formación",
    re.compile(r"\b(investigad|antecedentes?|sentencias?|juicios?|procesado|penal)\b", re.I):
        "antecedentes investigación sentencia penal judicial",
    re.compile(r"\b(pena\s+de\s+muerte|aborto|matrimonio|marihuana|posici[oó]n)\b", re.I):
        "posiciones políticas",
    re.compile(r"\b(propone|propuesta|plan|proyecto)\b", re.I):
        "propuestas plan gobierno",
}

_BROAD_QUERY_RE = re.compile(
    r"\b(alguno|algún|cuántos|quiénes|todos|ninguno|menos|más|mejor|peor)\b", re.I
)

# Similarity threshold — don't inject if distance is too high
_MAX_DISTANCE = 1.2  # ChromaDB L2 distance; lower = more similar


class CandidateRAG:
    """Read-only RAG over presidential candidate profiles."""

    def __init__(self, persist_dir: str | Path):
        self._client = chromadb.PersistentClient(path=str(persist_dir))
        self._collection = self._client.get_collection("perfiles_candidatos_rag")
        logger.info("[RAG] Loaded collection: %d documents", self._collection.count())

    async def search(
        self,
        query: str,
        candidate_name: str | None = None,
        max_tokens: int = 800,
    ) -> str:
        """Search candidate profiles. Returns formatted context or empty string."""
        expanded = _expand_query(query)
        top_k = 5 if _BROAD_QUERY_RE.search(query) else 3

        where_filter = None
        if candidate_name:
            where_filter = {
                "candidato_nombre": {"$contains": candidate_name.upper()}
            }

        results = self._collection.query(
            query_texts=[expanded],
            n_results=top_k,
            where=where_filter,
        )

        if not results["documents"] or not results["documents"][0]:
            return ""

        # Filter by distance threshold
        docs = []
        for doc, dist in zip(results["documents"][0], results["distances"][0]):
            if dist < _MAX_DISTANCE:
                docs.append(doc)

        if not docs:
            return ""

        # Truncate to max_tokens (~4 chars per token)
        context = "\n---\n".join(docs)
        max_chars = max_tokens * 4
        if len(context) > max_chars:
            context = context[:max_chars] + "\n[...truncado]"

        return context


def _expand_query(query: str) -> str:
    """Expand query with synonyms for better recall."""
    expanded = query
    for pattern, expansion in _EXPANSIONS.items():
        if pattern.search(query):
            expanded = f"{expanded} {expansion}"
    return expanded
```

### Integración en `core.py`

En `_process_with_budget()`, después del preprocessor y antes del synthesizer:

```python
# Después de línea ~940 (después de preprocessor, antes de router)

# ── RAG paralelo (si está disponible) ──
rag_context = ""
if self.candidate_rag:
    rag_task = asyncio.create_task(
        self.candidate_rag.search(
            query=intent.enriched_message,
            candidate_name=intent.resolved_entities.get("candidate") if intent.resolved_entities else None,
        )
    )

# ... router LLM call (existente, ~500-2000ms) ...
# ... MCP calls (existente, ~200-800ms) ...

# Recoger RAG result (ya terminó, await inmediato)
if self.candidate_rag and rag_task:
    try:
        rag_context = await asyncio.wait_for(rag_task, timeout=0.5)
    except asyncio.TimeoutError:
        rag_context = ""
```

### Inyección en el synthesizer

```python
# Antes de la llamada al synthesizer (línea ~1126)
if rag_context:
    synthesis_data = f"""[CONTEXTO COMPLEMENTARIO — perfiles de candidatos]
{rag_context}
[FIN CONTEXTO COMPLEMENTARIO]

[DATOS CONSULTADOS POR EL SISTEMA]
{mcp_results}
[FIN DATOS]"""
else:
    synthesis_data = f"""[DATOS CONSULTADOS POR EL SISTEMA]
{mcp_results}
[FIN DATOS]"""
```

**Nota**: El RAG context se inyecta ANTES de los datos MCP. Si hay overlap (MCP y RAG tienen el mismo dato), el MCP tiene prioridad por estar después (recency bias en LLMs).

## Decisión 3: Inicialización y warm-up

### En `core.py` `__init__`

```python
class InfoVotoAgent:
    def __init__(self, ...):
        ...
        # RAG de perfiles de candidatos (opcional)
        rag_path = Path(__file__).parent.parent / "data" / "chromadb_perfiles"
        if rag_path.exists():
            self.candidate_rag = CandidateRAG(rag_path)
        else:
            self.candidate_rag = None
            logger.warning("[RAG] No candidate profiles found at %s", rag_path)
```

**Fail-open**: Si no hay datos de RAG, el pipeline funciona exactamente igual que antes. El RAG es un enhancement, no una dependencia.

### Warm-up en lifespan

```python
# En gateway/main.py lifespan
async def lifespan(app):
    ...
    # Warm-up RAG (trigger ONNX model load)
    if agent.candidate_rag:
        agent.candidate_rag.search("warm up", max_tokens=10)
    ...
```

## Decisión 4: Script de generación de datos

### Ubicación

`infovoto-scraper/scripts/db/build_perfiles_chromadb.py`

### Lógica

```python
"""Generate ChromaDB collection for presidential candidate profiles.

Reads from PostgreSQL, generates one document per candidate,
indexes in ChromaDB with ONNX embeddings.

Usage:
    python -m scripts.db.build_perfiles_chromadb
"""

# 1. Query PostgreSQL: 36 candidatos presidenciales
# 2. Para cada candidato:
#    a. Query educación, experiencia, patrimonio, antecedentes, posiciones, hechos
#    b. Generar documento textual con keywords semánticos (D37)
#    c. Marcar explícitamente secciones sin datos (D36)
# 3. Indexar en ChromaDB PersistentClient
# 4. Guardar en data/chromadb_perfiles/
```

### Estructura del documento (consenso de D36 + D37)

```
Candidato: KEIKO SOFIA FUJIMORI HIGUCHI
Partido: Fuerza Popular
Cargo: Presidente

EDUCACIÓN Y ESTUDIOS (qué estudió, dónde estudió, formación, universidad, carrera):
- Bachiller en Administración de Empresas, Boston University (2001)
- Estudios de maestría en Columbia University

EXPERIENCIA LABORAL (en qué ha trabajado, trayectoria, cargos):
- Congresista de la República (2006-2011)
- Candidata presidencial 2011, 2016, 2021

PATRIMONIO Y DINERO (cuánto gana, cuánto tiene, propiedades, ingresos, riqueza):
- Ingreso total declarado: S/ 271,853 (Declaración Jurada JNE)
- Bienes inmuebles: 2 propiedades
- Vehículos: 1

ANTECEDENTES E INVESTIGACIONES (está investigado, sentencias, juicios, procesado, penal):
- Investigación por lavado de activos (EN_INVESTIGACIÓN, JNE_DJHV)
- Caso Cócteles: presunto financiamiento ilícito (EN_INVESTIGACIÓN, VotaBienPerú/Infobae)

POSICIONES POLÍTICAS (a favor, en contra, opinión sobre):
- Pena de muerte: EN CONTRA (Decide.pe 2025)
- Aborto: EN CONTRA (Decide.pe 2025)
- Matrimonio igualitario: EN CONTRA (Decide.pe 2025)
- Legalización marihuana: SIN POSICIÓN REGISTRADA
- Minería: A FAVOR (Decide.pe 2025)

HECHOS RELEVANTES:
- (2024-03) Keiko Fujimori fue absuelta del cargo de... (VotaBienPerú)
- (2025-11) Declaró apoyo a la reforma del sistema de pensiones (VotaBienPerú)

Última actualización: 2026-04-01
Fuentes: JNE Declaración Jurada, Decide.pe, VotaBienPerú
```

### Metadata por documento

```python
{
    "candidato_nombre": "KEIKO SOFIA FUJIMORI HIGUCHI",
    "partido": "Fuerza Popular",
    "cargo": "presidente",
    "dni": "10729252",
}
```

## Decisión 5: Ajustes al system prompt del synthesizer

### Agregar instrucción para datos RAG

En `src/agent/prompts/system.py`, sección de datos:

```
## CONTEXTO COMPLEMENTARIO
Si recibes un bloque [CONTEXTO COMPLEMENTARIO], contiene información de perfiles de candidatos
obtenida por búsqueda semántica. Úsala como referencia pero PRIORIZA los datos del bloque
[DATOS CONSULTADOS POR EL SISTEMA] si hay conflicto (están más actualizados).
Si ambos bloques tienen el mismo dato, usa el de DATOS CONSULTADOS.
Si DATOS CONSULTADOS está vacío pero CONTEXTO COMPLEMENTARIO tiene datos relevantes, usa esos.
```

## Diagrama final del pipeline

```
User message
    │
    ▼
Preprocessor (~5ms)
    │ → enriched_message + entities + intent
    │
    ├──────────────────────┐
    │                      │
    ▼                      ▼
Router LLM (500-2000ms)    RAG ChromaDB (15-25ms)
    │                      │ → rag_context
    │                      │   (ya terminó)
    ▼                      │
MCP calls (200-800ms)      │
    │                      │
    ▼                      ▼
Synthesizer LLM (1500-8000ms)
    Input: system + history + MCP data + RAG context + query
    │
    ▼
Response
```

## Riesgos y mitigaciones

| Riesgo | Mitigación |
|--------|-----------|
| ChromaDB corrompe datos en read-only | PersistentClient es estable; volumen montado :ro |
| ONNX model no carga | Fail-open: self.candidate_rag = None, pipeline sin RAG |
| RAG devuelve candidato incorrecto | Filtro por entity + threshold de distancia |
| Docker image +200MB | Aceptable; Cloud Run paga por request, no por size |
| Cold start ONNX +3-5s | min-instances=1 en producción; warm-up en lifespan |
| Datos desactualizados | Re-run script + rebuild gateway; ~5 minutos total |

## Veredicto

✅ **Aprobado — diseño técnico viable y bajo riesgo.**

**Resumen de decisiones**:
1. ChromaDB embebido (PersistentClient) en gateway, read-only
2. Nuevo módulo `src/agent/rag.py` con clase `CandidateRAG`
3. RAG paralelo con router, timeout 500ms, fail-open
4. Inyección en synthesizer como [CONTEXTO COMPLEMENTARIO]
5. Script de generación en infovoto-scraper
6. Warm-up en lifespan del gateway

**Archivos a crear/modificar**:
- CREAR: `src/agent/rag.py`
- CREAR: `infovoto-scraper/scripts/db/build_perfiles_chromadb.py`
- MODIFICAR: `src/agent/core.py` (~20 líneas: init + pipeline integration)
- MODIFICAR: `src/agent/prompts/system.py` (~5 líneas: instrucción RAG)
- MODIFICAR: `docker-compose.yml` (volumen para chromadb_perfiles)

## Preguntas para debates siguientes

- **ML Engineer (D42)**: ¿Necesitamos reranker? ¿El modelo ONNX es suficiente?
- **AI Tech Lead (D43)**: ¿Priorización final? ¿Qué implementar primero?
