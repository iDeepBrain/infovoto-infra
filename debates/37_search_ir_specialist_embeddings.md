# Debate 37: Embeddings y Búsqueda Semántica para Español Peruano

**Rol:** Search/IR Specialist
**Input:** Debates 34-36 + modelo de embeddings actual + queries fallidas
**Fecha:** 2026-04-03

---

## Contexto

El proyecto ya usa ONNX DefaultEmbeddingFunction (all-MiniLM-L6-v2, 384 dims) para las 7 colecciones de ChromaDB existentes. La propuesta es crear una nueva colección `perfiles_candidatos_rag` con 36 documentos de perfiles presidenciales.

Mi trabajo: evaluar si los embeddings actuales capturan correctamente las queries en español peruano coloquial, y proponer mejoras de IR si no.

## Modelo actual: all-MiniLM-L6-v2

### Características
- **Dimensiones**: 384
- **Entrenamiento**: Inglés primario, multilingüe limitado
- **Español**: Funciona pero no es su fuerte — entrenado mayormente en inglés
- **Tamaño**: ~80MB ONNX
- **Velocidad**: ~10-20ms por embedding

### El problema con español coloquial peruano

Las queries del eval usan lenguaje informal:
- "cuánto gana porky" (porky = apodo de un candidato)
- "y la keiko cuánto tiene?" (patrimonio implícito)
- "china tiene sentencias?" (china = apodo)
- "q propne keiko pa la educasion" (typos, abreviaciones)
- "alguno está investigado?" (investigado → antecedentes penales)

Los documentos vectorizados usan lenguaje formal:
- "Ingreso total declarado: S/ 271,853"
- "Investigación por lavado de activos (EN_INVESTIGACIÓN)"
- "Sentencia por plagio de tesis doctoral (SENTENCIADO)"

### Test mental de similitud semántica

| Query del usuario | Fragmento del documento | ¿Match? |
|-------------------|------------------------|---------|
| "cuánto gana" | "Ingreso total declarado: S/ 271,853" | ⚠️ Débil — "gana" ≠ "ingreso declarado" |
| "está investigado" | "Investigación por lavado de activos" | 🔄 Parcial — "investigado" ↔ "investigación" |
| "pena de muerte" | "Pena de muerte: A FAVOR" | ✅ Fuerte — match directo |
| "aborto" | "Aborto: EN CONTRA" | ✅ Fuerte — match directo |
| "qué estudió" | "Bachiller en Administración, Boston University" | ⚠️ Débil — "estudió" ≠ "bachiller en" |
| "tiene sentencias" | "Sentencia por plagio (SENTENCIADO)" | ✅ Fuerte — "sentencias" ↔ "sentencia" |
| "cuánto tiene" (patrimonio) | "Bienes inmuebles: 2 propiedades" | ❌ Muy débil |
| "háblame de" | Todo el perfil | ✅ Match genérico al perfil completo |

**Resultado**: De 8 tipos de query, 3 tienen match fuerte, 2 parcial, 2 débil, 1 muy débil.

## Estrategias para mejorar el retrieval

### Estrategia 1: Document structuring con keywords explícitos

En lugar de solo datos formales, agregar **keywords semánticos** al inicio de cada sección:

```
PATRIMONIO Y DINERO (cuánto gana, cuánto tiene, patrimonio, riqueza, ingresos):
- Ingreso total declarado: S/ 271,853
- Bienes inmuebles: 2 propiedades
- Vehículos: 1

ANTECEDENTES E INVESTIGACIONES (está investigado, tiene sentencias, prontuario, juicios, procesado):
- Investigación por lavado de activos (EN_INVESTIGACIÓN, JNE_DJHV)
- Caso Cócteles (EN_INVESTIGACIÓN, VotaBienPerú/Infobae)

EDUCACIÓN Y ESTUDIOS (qué estudió, dónde estudió, formación, universidad, carrera):
- Bachiller en Administración de Empresas, Boston University (2001)
```

**Ventaja**: Los keywords entre paréntesis sirven como "anclas semánticas" — cuando el usuario dice "cuánto gana", el embedding del query se acerca al embedding de la sección que contiene "cuánto gana" en sus keywords.

**Costo**: Agrega ~50-100 tokens por documento (36 docs → ~2000-3600 tokens totales). Trivial.

### Estrategia 2: Chunking por sección (en vez de documento completo)

En lugar de 1 documento gigante por candidato, crear chunks por sección:

```
Chunk 1: "Keiko Fujimori — EDUCACIÓN: Bachiller en Administración..."
Chunk 2: "Keiko Fujimori — PATRIMONIO: Ingreso total S/ 271,853..."
Chunk 3: "Keiko Fujimori — ANTECEDENTES: Investigación lavado..."
Chunk 4: "Keiko Fujimori — POSICIONES: Aborto EN CONTRA, Pena..."
```

**36 candidatos × 5-7 secciones = ~200-250 chunks**

**Ventaja**: Match más preciso — "cuánto gana keiko" matchea directamente el chunk de patrimonio de Keiko.

**Desventaja**:
- "háblame de keiko" necesita múltiples chunks → top_k=3 podría no cubrir todo el perfil
- "quién tiene más antecedentes" necesita comparar chunks de antecedentes de TODOS los candidatos

**Compromiso**: Usar **ambos** — un documento completo por candidato + chunks por sección. ChromaDB puede tener overlapping documents sin problema.

### Estrategia 3: Modelo de embeddings multilingüe

Alternativas a all-MiniLM-L6-v2:

| Modelo | Dims | Español | Tamaño | Velocidad |
|--------|------|---------|--------|-----------|
| all-MiniLM-L6-v2 (actual) | 384 | Básico | 80MB | ~10ms |
| paraphrase-multilingual-MiniLM-L12-v2 | 384 | Bueno | 420MB | ~20ms |
| multilingual-e5-small | 384 | Bueno | 470MB | ~20ms |
| multilingual-e5-base | 768 | Muy bueno | 1.1GB | ~40ms |

**Recomendación**: Para 36-250 docs, la diferencia de velocidad es irrelevante (<5ms). El modelo `paraphrase-multilingual-MiniLM-L12-v2` es el mejor trade-off:
- Mismas dimensiones (384) → compatible con ChromaDB existente
- Significativamente mejor en español
- ~20ms de embedding (vs 10ms actual) — irrelevante para 36 docs

**PERO**: Cambiar el modelo de embeddings requiere re-indexar TODAS las colecciones ChromaDB existentes (7 colecciones). Para la colección nueva de perfiles, no hay costo de migración.

**Decisión práctica**: Usar el modelo actual (all-MiniLM-L6-v2) para la nueva colección de perfiles, con la Estrategia 1 (keywords explícitos) para compensar. Si no es suficiente, migrar a multilingual en una fase posterior.

### Estrategia 4: Hybrid search (keyword + vector)

ChromaDB soporta filtrado por metadata + búsqueda semántica:

```python
collection.query(
    query_texts=["cuánto gana keiko"],
    n_results=3,
    where={"candidato_nombre": {"$contains": "KEIKO"}},  # Filtro exacto
)
```

Si el preprocessor ya resolvió `entities.candidate = "Keiko Fujimori"`, podemos filtrar por candidato ANTES de la búsqueda semántica.

**Ventaja**: Elimina el riesgo de que el RAG devuelva datos de "Kenji Fujimori" cuando preguntan por "Keiko".

**Flujo**:
```
1. Preprocessor → entities = {candidate: "KEIKO SOFIA FUJIMORI HIGUCHI"}
2. RAG search:
   - Si hay entity.candidate → filtrar por candidato + query semántica
   - Si NO hay entity → query semántica pura (top_k=3 de todos)
```

### Estrategia 5: Query expansion

Antes de buscar en ChromaDB, expandir la query con sinónimos:

```
"cuánto gana" → "cuánto gana patrimonio ingreso dinero sueldo"
"está investigado" → "está investigado antecedentes penales sentencias"
"qué estudió" → "qué estudió educación universidad carrera"
```

**Implementación**: Un dict simple de expansiones (no necesita LLM):

```python
QUERY_EXPANSIONS = {
    r"\b(cuánto\s+(?:gana|tiene)|patrimonio|dinero|riqueza)\b": "patrimonio ingreso bienes dinero",
    r"\b(estudi[oó]|educaci[oó]n|universidad|carrera)\b": "educación estudios universidad carrera formación",
    r"\b(investigad|antecedentes?|sentencias?|juicios?|prontuario)\b": "antecedentes investigación sentencia penal judicial",
    r"\b(pena\s+de\s+muerte|aborto|matrimonio|marihuana)\b": "posiciones políticas",
}
```

**Ventaja**: Muy barato (~1ms, regex). Mejora el recall sin cambiar modelo.
**Desventaja**: Mantenimiento manual del dict. Pero con 36 docs y temas acotados, es manejable.

## Propuesta integrada

### Para la colección `perfiles_candidatos_rag`:

1. **Documentos**: 36 documentos completos (1 por candidato), con keywords semánticos por sección (Estrategia 1)
2. **Chunks adicionales**: 36 × 6 secciones = ~216 chunks por sección (Estrategia 2), metadata: `{candidato_nombre, seccion, partido}`
3. **Modelo**: all-MiniLM-L6-v2 (actual) — suficiente con keywords + hybrid search
4. **Hybrid search**: Filtrar por candidato si entity resuelta (Estrategia 4)
5. **Query expansion**: Dict de 10-15 expansiones para términos comunes (Estrategia 5)

### Flujo de búsqueda propuesto

```python
async def rag_search(query: str, entities: dict | None) -> str:
    expanded_query = expand_query(query)  # ~1ms

    if entities and entities.get("candidate"):
        # Búsqueda filtrada: perfil completo del candidato + secciones relevantes
        results = collection.query(
            query_texts=[expanded_query],
            n_results=3,
            where={"candidato_nombre": {"$contains": entities["candidate"]}},
        )
    else:
        # Búsqueda abierta: top 3 chunks más relevantes de cualquier candidato
        results = collection.query(
            query_texts=[expanded_query],
            n_results=3,
        )

    return format_rag_context(results, max_tokens=800)
```

### Similarity threshold

No inyectar contexto si la distancia es demasiado alta:

```python
MIN_SIMILARITY = 0.3  # Cosine similarity threshold

results = collection.query(...)
filtered = [
    doc for doc, dist in zip(results["documents"][0], results["distances"][0])
    if dist < (1 - MIN_SIMILARITY)  # ChromaDB usa distancia, no similitud
]
```

**Razón**: Si el usuario pregunta "cuándo son las elecciones", el RAG de perfiles no debería inyectar nada (baja similitud). Solo inyectar cuando es relevante.

## Riesgos de IR

### 1. False positives
- "Fujimori" matchea con Keiko, Kenji, y Alberto Fujimori
- **Mitigación**: Filtro por entity + metadata. Si no hay entity, el top_k=3 podría devolver los 3 Fujimoris, lo cual es aceptable para una query como "los Fujimori"

### 2. Query demasiado genérica
- "candidatos" matchea con TODOS los documentos igualmente
- **Mitigación**: Threshold de similitud. Si todos los scores son ~iguales, no inyectar nada.

### 3. Español informal no capturado
- "q propne keiko pa la educasion" — typos extremos
- **Mitigación**: El preprocessor YA normaliza typos (paso de NLP). Si llega con typos al RAG, el match será más débil pero los keywords explícitos ("educación estudios universidad") pueden compensar.

## Métricas esperadas

| Query tipo | Sin RAG (actual) | Con RAG + keywords + hybrid |
|-----------|------------------|----------------------------|
| "aborto keiko" | Score 3.1 (routing falla) | Score ~4.5-5.0 (RAG inyecta posición directa) |
| "cuánto gana porky" | Score 3.5 (genérica) | Score ~4.0-4.5 (RAG inyecta patrimonio, match débil→mejorado con keywords) |
| "educación de keiko" | Score 3.0 (routing falla) | Score ~4.5-5.0 (RAG inyecta sección educación) |
| "está investigado?" | Score 2.8 (no sabe qué tool) | Score ~4.0 (RAG inyecta antecedentes de varios candidatos) |
| "háblame de lopez aliaga" | Score 3.8 (perfil superficial) | Score ~4.5-5.0 (RAG inyecta perfil completo) |

## Veredicto

✅ **Aprobado — el modelo actual es suficiente con optimizaciones de IR.**

No necesitamos cambiar el modelo de embeddings. La combinación de:
1. Keywords semánticos en documentos (+recall)
2. Hybrid search con filtro de entity (+precision)
3. Query expansion con dict de sinónimos (+recall en español coloquial)
4. Threshold de similitud (−ruido)

...compensan las limitaciones de all-MiniLM-L6-v2 para español peruano.

**Si después del eval no mejora suficiente**: Migrar a paraphrase-multilingual-MiniLM-L12-v2 solo para la colección de perfiles (no requiere re-indexar las existentes).

## Preguntas para debates siguientes

- **UX Researcher (D38)**: ¿El usuario nota la diferencia entre "No encontré esa info" y una respuesta basada en RAG parcial?
- **Backend Architect (D41)**: ¿Dónde vive el dict de query expansions? ¿En preprocessor o en el módulo RAG?
- **ML Engineer (D42)**: ¿Vale la pena un reranker (cross-encoder) para 36 docs? Probablemente no.
