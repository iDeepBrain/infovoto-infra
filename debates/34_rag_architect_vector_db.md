# Debate 34: ¿RAG Vectorial Paralelo para Todo?

**Rol:** RAG Architect
**Input:** Eval v4 (23 queries < 4.0) + arquitectura actual (5 MCPs, ChromaDB, PostgreSQL)
**Fecha:** 2026-04-03

---

## El problema que quiero resolver

El sistema actual tiene un **cuello de botella en el routing**: un LLM (gemini-2.5-flash-lite) decide qué MCP llamar. Si decide mal → "No encontré esa info" → score 1.0-3.5. De las 23 queries con score < 4.0:

- **8 devuelven "No encontré esa info"**: El router eligió tools=[] o la herramienta equivocada
- **3 son timeouts/errores 500**: Problemas de infraestructura
- **5 devuelven data incorrecta**: El router eligió bien pero el MCP no encontró lo que buscaba
- **7 son respuestas genéricas**: El synthesizer no extrajo lo específico de los datos

**Hipótesis**: Si en CADA query inyectamos contexto relevante vía RAG (búsqueda semántica en ChromaDB), el synthesizer SIEMPRE tendrá datos buenos — aunque el router falle o no exista.

## Estado actual de los datos

### Lo que YA está en ChromaDB (búsqueda semántica)
1. **planes_gobierno_local** — 33 partidos, chunks de 100-800 palabras
2. **debates** — Transcripciones de 3 debates presidenciales
3. **proceso_electoral** — 13 temas (voto preferencial, bicameral, segunda vuelta)
4. **logistica_electoral** — Procedimientos del día de votación
5. **resoluciones** — Resoluciones JNE (tachas, exclusiones)
6. **perfiles_candidatos** — Análisis de inhabilitaciones
7. **financiamiento_electoral** — Datos ONPE CLARIDAD

### Lo que está SOLO en PostgreSQL (búsqueda exacta)
1. **Perfiles de candidatos**: nombre, cargo, partido, foto
2. **Educación**: nivel, institución, carrera, grado, año
3. **Experiencia laboral**: puesto, empresa, años
4. **Antecedentes penales**: tipo, descripción, fallo, estado, fuente (JNE_DJHV / VOTABIEN)
5. **Sentencias/obligaciones**: materia, monto
6. **Posiciones políticas**: 20 temas × score (0-1) de Decide.pe
7. **Hechos relevantes**: noticias recientes (VotaBienPerú)
8. **Patrimonio**: ingreso total, bienes inmuebles, vehículos

**Observación clave**: Los datos más ricos del candidato (educación, antecedentes, posiciones, patrimonio) están en PostgreSQL y son accesibles SOLO si el router llama a `buscar_candidato_por_dni(nombre=X)` correctamente. Si no → "No encontré".

## Propuesta: Colección vectorial de perfiles de candidatos

### Qué vectorizar

Crear una nueva colección ChromaDB: `perfiles_candidatos_rag` con un documento por candidato presidencial (36 candidatos). Cada documento es un resumen textual completo:

```
Candidato: KEIKO SOFIA FUJIMORI HIGUCHI
Partido: Fuerza Popular
Cargo: Presidente

EDUCACIÓN:
- Bachiller en Administración de Empresas, Boston University (2001)
- Estudios de maestría en Columbia University

EXPERIENCIA:
- Congresista de la República (2006-2011)
- Candidata presidencial 2011, 2016, 2021

PATRIMONIO:
- Ingreso total declarado: S/ 271,853
- Bienes inmuebles: 2 propiedades

ANTECEDENTES:
- Investigación por lavado de activos (EN_INVESTIGACIÓN, JNE_DJHV)
- Caso Cócteles: presunto financiamiento ilícito (EN_INVESTIGACIÓN, VOTABIEN/Infobae)
- ...

POSICIONES POLÍTICAS:
- Pena de muerte: A FAVOR
- Aborto: EN CONTRA
- Matrimonio igualitario: EN CONTRA
- Minería: A FAVOR
- Pensiones públicas: NEUTRAL
- ...

HECHOS RELEVANTES:
- (2024-03) Keiko Fujimori fue absuelta del cargo de...
- (2025-11) Declaró apoyo a la reforma del sistema de pensiones...
```

### Cómo usarlo

**Opción A: RAG paralelo siempre (la idea del usuario)**

```
User: "keiko está a favor del aborto?"
    ↓
┌─ ROUTER (LLM, ~500ms) → decide tools
│  ↓
│  MCP call: buscar_candidato_por_dni(nombre="keiko") → ~300ms
│
├─ RAG PARALELO (~100ms, local ChromaDB)
│  query: "keiko aborto" → top 3 chunks de perfiles_candidatos_rag
│  → "Keiko Fujimori - Aborto: EN CONTRA (Decide.pe)"
│
└─ SYNTHESIS (LLM, ~2s)
   Input: [MCP data] + [RAG context] + user query
   → Responde con datos de AMBAS fuentes
```

**Ventaja**: Aunque el router falle o el MCP no devuelva posiciones políticas, el RAG inyecta el dato relevante. El synthesizer tiene redundancia.

**Opción B: RAG como fallback (solo si MCP falla)**

```
Si MCP devuelve datos → usar datos del MCP (como ahora)
Si MCP devuelve vacío/error → usar RAG como respaldo
```

**Ventaja**: No agrega latencia en el happy path. Solo actúa cuando hay fallo.

**Opción C: RAG como contexto del router (pre-routing)**

```
RAG search → top 3 chunks relevantes
Inyectar como contexto en el ROUTER prompt
Router tiene mejor info para decidir qué tool usar
```

**Ventaja**: Mejora la decisión del router sin cambiar el pipeline de síntesis.

## Análisis de las 23 queries fallidas con RAG

### ¿Cuántas se arreglarían con RAG de perfiles?

| Query | Score | ¿RAG ayudaría? | Por qué |
|-------|-------|----------------|---------|
| "keiko vs porky" | 1.0 | ❌ | ERROR 500 — es infraestructura |
| "alguno está investigado?" | 1.0 | ✅ SÍ | RAG devolvería antecedentes de todos |
| "fujimori puede postular con juicios?" | 1.0 | ✅ SÍ | RAG devolvería inhabilitaciones + antecedentes |
| "rankings de candidatos" | 1.5 | ❌ | Problema de routing (7146 candidatos) |
| "qué necesito para votar" | 2.5 | ❌ | Es proceso electoral, no candidatos |
| "sueldo mínimo" | 2.5 | 🔄 | RAG podría encontrar propuestas laborales |
| "antecedentes penales hay?" | 2.8 | ✅ SÍ | RAG devolvería candidatos con antecedentes |
| "educación de keiko" | 3.0 | ✅ SÍ | RAG tiene educación de Keiko |
| "aborto keiko" | 3.1 | ✅ SÍ | RAG tiene posición sobre aborto |
| "q propne keiko pa la educasion" | 3.2 | 🔄 | RAG de planes + perfiles combinado |
| "keiko vs acuña propuestas" | 3.4 | ✅ SÍ | RAG de ambos perfiles + planes |
| "partidos principales" | 3.4 | ❌ | Es listado, no búsqueda semántica |
| "pena de muerte lopez aliaga" | 3.5 | ✅ SÍ | RAG tiene posición |
| "propone lopez aliaga seguridad" | 3.5 | 🔄 | RAG de planes + perfil |
| "pena de muerte acuña" | 3.5 | ✅ SÍ | RAG tiene posición |
| "y la keiko cuánto tiene?" | 3.5 | ✅ SÍ | RAG tiene patrimonio |
| "cuánto gana porky" | 3.5 | ✅ SÍ | RAG tiene patrimonio |
| "quién es keiko" | 3.5 | ✅ SÍ | RAG tiene perfil completo |
| "quién financia a keiko" | 3.6 | 🔄 | RAG tiene antecedentes de financiamiento |
| "menos antecedentes" | 3.8 | ✅ SÍ | RAG permite comparar antecedentes |
| "háblame de lopez aliaga" | 3.8 | ✅ SÍ | RAG tiene perfil completo |
| "mejor plan de seguridad" | 3.8-3.9 | 🔄 | RAG de planes combinado |
| "china tiene sentencias?" | 3.9 | ✅ SÍ | RAG tiene antecedentes |

**Resultado: 13 de 23 se beneficiarían directamente (✅), 5 parcialmente (🔄), 5 no (❌)**

## Trade-offs

### A favor del RAG vectorial de perfiles

1. **Redundancia**: Si el router falla, el RAG aún inyecta datos relevantes
2. **Búsqueda semántica**: "está a favor del aborto?" matchea con "Aborto: EN CONTRA" sin necesidad de routing exacto
3. **Latencia mínima**: ChromaDB local con ONNX embeddings = ~50-100ms. En paralelo con el router, no agrega al total
4. **36 documentos**: Solo 36 candidatos presidenciales. La colección es tiny — búsqueda instantánea
5. **Cross-candidate queries**: "quién está a favor de la pena de muerte?" matchea TODOS los candidatos relevantes en una sola búsqueda

### En contra

1. **Duplicación de datos**: Los mismos datos están en PostgreSQL Y en ChromaDB. Sincronización necesaria
2. **Stale data**: Si PostgreSQL se actualiza, ChromaDB debe re-indexarse. Un script manual o un trigger
3. **Ruido**: Si el RAG inyecta datos irrelevantes, el synthesizer puede confundirse
4. **Complejidad**: Agrega una ruta de datos más al pipeline ya complejo
5. **Embeddings no capturan todo**: "cuánto gana" no matchea bien con "ingreso total: S/ 271,853" en embedding space. Necesita tuning

### Riesgo principal

El mayor riesgo es que el RAG inyecte **contexto incorrecto** — por ejemplo, el usuario pregunta por "Keiko" y el RAG devuelve datos de "Kenji Fujimori" (por similitud de apellido). Esto empeoraría la respuesta.

**Mitigación**: Usar filtros de metadata. Si el preprocessor resolvió `entities.candidate = "Keiko Fujimori"`, filtrar el RAG por ese candidato.

## Propuesta concreta

### Fase 1: Crear colección `perfiles_candidatos_rag`

**Dónde**: `infovoto-scraper/scripts/db/` — nuevo script `build_perfiles_chromadb.py`
**Qué**: Leer los 36 candidatos presidenciales de PostgreSQL, generar un documento textual por candidato, indexar en ChromaDB
**Embedding**: ONNX DefaultEmbeddingFunction (ya usada en el proyecto, 384 dims, local)
**Metadata**: `{candidato_nombre, partido, cargo, dni}` para filtrado

### Fase 2: RAG paralelo en gateway

**Dónde**: `infovoto-gateway/src/agent/core.py` — en `_process_with_budget()`
**Qué**: Antes del router, lanzar búsqueda ChromaDB en paralelo:

```python
# En paralelo con el router LLM:
rag_task = asyncio.create_task(self._rag_search(intent.enriched_message, intent.resolved_entities))
router_task = asyncio.create_task(self._route_with_llm(...))

rag_context, llm_route = await asyncio.gather(rag_task, router_task)
```

**Inyección**: Agregar `rag_context` al bloque de datos del synthesizer:
```
[CONTEXTO RAG - información relevante encontrada]
{rag_context}
[FIN CONTEXTO RAG]

[DATOS CONSULTADOS POR EL SISTEMA]
{mcp_results}
[FIN DATOS]
```

### Fase 3: Evaluar impacto

Correr eval de 261 queries y comparar con baseline.

## Preguntas para los siguientes debates

1. **Latency Engineer (D35)**: ¿El RAG paralelo realmente no agrega latencia? ¿Qué pasa si ChromaDB es lento?
2. **Data Quality Lead (D36)**: ¿Los datos en PostgreSQL son completos? ¿Hay candidatos sin posiciones, sin antecedentes?
3. **Search/IR Specialist (D37)**: ¿ONNX embeddings capturan bien queries en español peruano coloquial?
4. **UX Researcher (D38)**: ¿El RAG mejora la experiencia o agrega ruido?

## Veredicto

🔄 **Necesita más investigación.** La idea es prometedora — 13 de 23 queries fallidas se beneficiarían. Pero necesito:
- Análisis de latencia (D35)
- Verificar completitud de datos (D36)
- Evaluar calidad de embeddings para español peruano (D37)
- Diseño técnico detallado (D41)

**Recomendación inicial**: Empezar con Opción A (RAG paralelo siempre) para los 36 candidatos presidenciales. Es la más simple y la colección es tiny (36 docs). Si funciona, expandir a congresistas.
