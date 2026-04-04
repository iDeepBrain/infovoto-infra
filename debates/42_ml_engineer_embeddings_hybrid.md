# Debate 42: Embeddings, Reranking y Hybrid Search

**Rol:** ML Engineer
**Input:** Debates 34-41 + modelo actual + arquitectura propuesta
**Fecha:** 2026-04-03

---

## Contexto

El Backend Architect (D41) decidió ChromaDB embebido en gateway con all-MiniLM-L6-v2. Mi trabajo: evaluar si este setup es óptimo para nuestro caso o si necesitamos ajustes ML.

## Análisis del modelo: all-MiniLM-L6-v2

### Fortalezas para nuestro caso
- **Velocidad**: ~10ms por embedding. Para 36 docs, irrelevante.
- **Tamaño**: 80MB ONNX. Aceptable.
- **Ya integrado**: Las 7 colecciones ChromaDB existentes lo usan. Sin migración.

### Debilidades
- **Español limitado**: Entrenado primariamente en inglés. El español viene del fine-tuning multilingüe pero no es su fuerte.
- **384 dims**: Menos capacidad expresiva que modelos de 768+ dims.
- **Sin instrucciones**: No es un modelo instruction-tuned (como E5 que usa prefijos "query:" / "passage:").

### Test empírico necesario

Antes de cambiar modelo, debemos probar con el actual. La Estrategia 1 del D37 (keywords semánticos en documentos) puede compensar las debilidades del modelo.

**Hipótesis**: Para 36 documentos con keywords explícitos, all-MiniLM-L6-v2 es suficiente porque:
1. El espacio de búsqueda es tiny (36 docs)
2. Los keywords crean "anclas" artificiales que compensan el gap semántico
3. El filtro por entity reduce el problema a ~1-3 documentos

## ¿Necesitamos un reranker?

### Qué es un reranker

Un cross-encoder que re-ordena los resultados del bi-encoder (ChromaDB). Más preciso pero más lento (~50-100ms por par query-doc).

### Para 36 documentos: NO

| Modelo | Latencia | Precision improvement |
|--------|----------|----------------------|
| Bi-encoder solo (actual) | ~15ms | Baseline |
| Bi-encoder + cross-encoder reranker | ~15ms + 50ms × 3 = ~165ms | +5-15% precision |

**Costo-beneficio**: +150ms para +10% precision en 36 docs no justifica la complejidad. El filtro por entity + threshold de distancia ya da precision aceptable.

**Cuándo SÍ necesitaríamos reranker**: Si expandimos a congresistas (130+) o a todos los candidatos (7146). Ahí sí el bi-encoder puede rankear mal.

### Veredicto: NO reranker para v1. Revisitar si expandimos.

## Hybrid search: ¿keyword + vector?

### El problema

ChromaDB hace búsqueda semántica pura (vector similarity). No tiene full-text search nativo.

Queries donde vector search falla:
- "cuánto gana" → El embedding no captura bien que "gana" = "ingreso declarado"
- "tiene sentencias" → "sentencias" como token está en el documento pero el embedding podría matchear con cualquier texto legal
- "dni 10729252" → Búsqueda exacta de un número — vector search no sirve

### Solución: Query expansion + keywords en documentos

En vez de implementar hybrid search compleja (que requiere Elasticsearch o pgvector con tsvector), usamos la Estrategia 1+5 del D37:

1. **Keywords en documentos**: Cada sección tiene sinónimos explícitos
   ```
   PATRIMONIO Y DINERO (cuánto gana, cuánto tiene, propiedades, ingresos, riqueza):
   ```
2. **Query expansion**: El query se expande con sinónimos antes de la búsqueda
   ```
   "cuánto gana" → "cuánto gana patrimonio ingreso bienes dinero sueldo"
   ```

**Esto simula hybrid search** sin infraestructura adicional:
- Los keywords en el documento mejoran el recall (vector search matchea tokens compartidos)
- La expansion del query refuerza la señal semántica

### Evaluación esperada

| Query | Sin keywords/expansion | Con keywords/expansion |
|-------|----------------------|----------------------|
| "cuánto gana keiko" | Distancia ~1.0 (débil) | Distancia ~0.5 (fuerte) |
| "está investigado" | Distancia ~0.8 (parcial) | Distancia ~0.4 (fuerte) |
| "qué estudió" | Distancia ~0.7 (parcial) | Distancia ~0.4 (fuerte) |
| "aborto" | Distancia ~0.3 (fuerte) | Distancia ~0.2 (muy fuerte) |

## Modelo alternativo: ¿cuándo migrar?

### Trigger para migrar a modelo multilingüe

Si después del eval con all-MiniLM-L6-v2 + keywords + expansion:
- **>5 queries** donde el RAG debería haber inyectado pero no lo hizo (distancia alta)
- **>3 false positives** donde el RAG inyectó datos del candidato incorrecto
- **Precision@3 < 0.7** en queries de candidato específico

Entonces migrar a `paraphrase-multilingual-MiniLM-L12-v2`:
- Mismas 384 dims → compatible con ChromaDB
- Pero re-indexar toda la colección (trivial: 36 docs, <10s)
- Modelo más grande: 420MB vs 80MB
- Misma velocidad efectiva para 36 docs

### Modelo ideal a futuro (si expandimos)

`multilingual-e5-base` (768 dims):
- Excelente en español
- Instruction-tuned (usa prefijos "query:" / "passage:")
- Pero requiere re-crear colección con nuevas dimensiones
- Solo justificado si vamos a 1000+ documentos

## Chunking: documento completo vs secciones

### El debate del D37

El D37 propuso usar AMBOS: documentos completos + chunks por sección. Yo lo simplifico:

**Para v1: solo documentos completos (36 docs).**

**Razón**:
1. 36 documentos es tan pequeño que top_k=3 con filtro de entity siempre devuelve el candidato correcto
2. Los chunks por sección solo serían útiles si el documento completo es demasiado largo para inyectar. Pero cada documento es ~300-600 tokens — cabe fácilmente en el cap de 800 tokens del D35.
3. Menos complejidad = menos bugs

**Cuándo agregar chunks**: Si expandimos a congresistas (130+) o si los documentos crecen a >1000 tokens.

## Threshold de distancia: calibración

### ChromaDB usa distancia L2 (Euclidean) por defecto

```
Distancia 0.0 = idéntico
Distancia 0.5 = muy similar
Distancia 1.0 = parcialmente similar
Distancia 1.5 = débilmente similar
Distancia 2.0+ = no relacionado
```

### Threshold recomendado

Para inyectar al synthesizer: `distancia < 1.2`

**Razonamiento**:
- Queries sobre candidatos: distancia ~0.3-0.8 → INYECTAR ✅
- Queries sobre proceso electoral: distancia ~1.0-1.5 → BORDER LINE
- Queries no electorales: distancia ~1.5-2.0 → NO INYECTAR ❌

Con threshold 1.2:
- "educación de keiko" → ~0.4, inyecta ✅
- "cuándo son las elecciones" → ~1.4, no inyecta ✅
- "hola" → ~1.8, no inyecta ✅
- "sueldo mínimo propuestas" → ~1.0, inyecta ✅ (podría tener propuestas relevantes en el perfil)

### Ajuste fino post-eval

Después del eval, medir:
- **False positives**: Queries donde el RAG inyectó datos irrelevantes → subir threshold
- **False negatives**: Queries donde el RAG no inyectó pero debería → bajar threshold
- Ajustar en incrementos de 0.1

## Resumen de decisiones ML

| Decisión | V1 (36 docs) | V2 (futuro, 1000+ docs) |
|----------|-------------|------------------------|
| Modelo | all-MiniLM-L6-v2 | paraphrase-multilingual o E5 |
| Dimensiones | 384 | 384 o 768 |
| Reranker | NO | Evaluar cross-encoder |
| Chunking | Doc completo | Doc + secciones |
| Hybrid search | Keywords + expansion | Considerar pgvector + tsvector |
| Threshold | 1.2 (L2 distance) | Calibrar con eval |
| Top_k | 3 (puntual), 5 (amplia) | 5-10 con reranker |

## Veredicto

✅ **Aprobado — modelo actual es suficiente para v1.**

La combinación de:
1. all-MiniLM-L6-v2 (modelo actual, sin migración)
2. Keywords semánticos en documentos (mejora recall)
3. Query expansion con dict de sinónimos (mejora recall en español)
4. Filtro por entity (mejora precision)
5. Threshold de distancia L2 < 1.2 (reduce ruido)
6. Top_k dinámico (3 puntual, 5 amplia)

...es la solución más simple que funciona para 36 documentos presidenciales.

**No hay que over-engineerear**: 36 docs caben en memoria. Cualquier modelo con 384 dims encuentra lo que buscas en microsegundos. El cuello de botella nunca va a ser el RAG sino el synthesizer LLM.

## Pregunta para el debate final

- **AI Tech Lead (D43)**: ¿Plan de acción priorizado? ¿Qué implementar primero y qué dejar para v2?
