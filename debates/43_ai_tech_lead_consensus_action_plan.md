# Debate 43: Consenso Final — Plan de Acción Priorizado

**Rol:** AI Tech Lead
**Input:** Debates 34-42 (todos) + eval v4 (4.71/5, 23 queries < 4.0)
**Fecha:** 2026-04-03

---

## Resumen de consenso de los 9 debates

### Unanimidad en estos puntos

1. **RAG paralelo de perfiles candidatos es viable y deseable** — aprobado por todos los roles
2. **36 documentos presidenciales** — colección trivial en tamaño, latencia despreciable
3. **Impacto estimado**: 13-15 de 23 queries fallidas mejorarían directamente
4. **Latencia**: +0ms en hot path (paralelo con router), +100ms en synthesizer (tokens extra)
5. **Modelo**: all-MiniLM-L6-v2 es suficiente para v1 con keywords + expansion
6. **Infraestructura**: ChromaDB embebido read-only en gateway (PersistentClient)
7. **Fail-open**: Si el RAG falla o no existe, el pipeline funciona igual que antes

### Debates por prioridad

| Debate | Rol | Veredicto | Takeaway clave |
|--------|-----|-----------|---------------|
| D34 | RAG Architect | 🔄→✅ | 13/23 queries se benefician del RAG |
| D35 | Latency Engineer | ✅ | +0ms en hot path, +100ms en synthesizer |
| D36 | Data Quality Lead | ✅ | 15/23 tienen datos suficientes en PostgreSQL |
| D37 | Search/IR Specialist | ✅ | Keywords + expansion compensan modelo básico |
| D38 | UX Researcher | ✅ | Elimina "No encontré esa info" en ~15 queries |
| D39 | Señora de 55 | ✅ | "Que NUNCA me diga 'no encontré' cuando el dato existe" |
| D40 | Joven de 20 | ✅ | Tablas comparativas + datos concretos + velocidad |
| D41 | Backend Architect | ✅ | ChromaDB embebido, módulo rag.py, fail-open |
| D42 | ML Engineer | ✅ | No reranker, no chunking por sección, threshold L2<1.2 |

## Las 23 queries: impacto proyectado con RAG

### Mejoran con certeza (13 queries)

| Query | Score actual | Score proyectado | Cómo mejora |
|-------|-------------|-----------------|-------------|
| "alguno está investigado?" | 1.0 | ~3.5-4.0 | RAG inyecta antecedentes (fallback del error 500) |
| "fujimori puede postular con juicios?" | 1.0 | ~3.5-4.0 | RAG inyecta inhabilitaciones + antecedentes |
| "antecedentes penales hay?" | 2.8 | ~4.0-4.5 | RAG inyecta candidatos con antecedentes |
| "educación de keiko" | 3.0 | ~4.5-5.0 | RAG inyecta sección educación |
| "aborto keiko" | 3.1 | ~4.5-5.0 | RAG inyecta posición directa |
| "keiko vs acuña propuestas" | 3.4 | ~4.0-4.5 | RAG inyecta ambos perfiles |
| "pena de muerte lopez aliaga" | 3.5 | ~4.5-5.0 | RAG inyecta posición |
| "pena de muerte acuña" | 3.5 | ~4.0-4.5 | RAG inyecta o marca "SIN DATOS" |
| "y la keiko cuánto tiene?" | 3.5 | ~4.5-5.0 | RAG inyecta patrimonio |
| "cuánto gana porky" | 3.5 | ~4.5-5.0 | RAG inyecta patrimonio |
| "quién es keiko" | 3.5 | ~4.5-5.0 | RAG inyecta perfil completo |
| "háblame de lopez aliaga" | 3.8 | ~4.5-5.0 | RAG inyecta perfil completo |
| "china tiene sentencias?" | 3.9 | ~4.5-5.0 | RAG inyecta antecedentes |

### Mejoran parcialmente (5 queries)

| Query | Score actual | Score proyectado | Nota |
|-------|-------------|-----------------|------|
| "sueldo mínimo" | 2.5 | ~3.0-3.5 | RAG podría tener propuestas laborales |
| "q propne keiko pa la educasion" | 3.2 | ~3.5-4.0 | Necesita planes + perfil |
| "propone lopez aliaga seguridad" | 3.5 | ~3.5-4.0 | Necesita planes + perfil |
| "quién financia a keiko" | 3.6 | ~4.0-4.5 | RAG tiene Caso Cócteles |
| "mejor plan de seguridad" | 3.8 | ~4.0 | Necesita comparación de planes |

### NO mejoran con RAG (5 queries)

| Query | Score actual | Problema | Solución separada |
|-------|-------------|----------|-------------------|
| "keiko vs porky" | 1.0 | ERROR 500 — infraestructura | Fix MCP stability |
| "rankings de candidatos" | 1.5 | Devuelve 7146 candidatos | Fix router/MCP para filtrar cargo=presidente |
| "qué necesito para votar" | 2.5 | Es proceso electoral, no candidatos | Fix router para info_dia_elecciones |
| "partidos principales" | 3.4 | Es listado, no búsqueda semántica | Fix router/MCP listado |
| "menos antecedentes" | 3.8 | Requiere lógica de ranking | Fix synthesizer prompt |

## Score proyectado global

### Cálculo conservador

- 13 queries mejoran de promedio 2.8 → 4.3 (+1.5 promedio)
- 5 queries mejoran de promedio 3.3 → 3.7 (+0.4 promedio)
- 5 queries sin cambio (promedio 2.0)
- 238 queries sin cambio (promedio 4.95)

**Score proyectado**: (13×4.3 + 5×3.7 + 5×2.0 + 238×4.95) / 261 = **~4.82/5**

**Delta**: 4.71 → 4.82 (+0.11). Significativo dado que 0.08 es ruido de eval (D35).

### Cálculo optimista

Si además arreglamos los 5 que NO mejoran con RAG (fixes de routing/infra separados):

**Score proyectado**: (18×4.5 + 5×3.7 + 238×4.95) / 261 = **~4.87/5**

## Plan de acción priorizado

### Fase 1: RAG de perfiles (impacto ALTO, esfuerzo MEDIO)

**Archivos a crear:**
1. `infovoto-scraper/scripts/db/build_perfiles_chromadb.py` — Script que lee PostgreSQL y genera colección ChromaDB
2. `infovoto-gateway/src/agent/rag.py` — Módulo RAG con CandidateRAG class

**Archivos a modificar:**
3. `infovoto-gateway/src/agent/core.py` — Integrar RAG paralelo en pipeline (~20 líneas)
4. `infovoto-gateway/src/agent/prompts/system.py` — Instrucción para CONTEXTO COMPLEMENTARIO (~5 líneas)
5. `docker-compose.yml` — Volumen para chromadb_perfiles

**Esfuerzo estimado**: ~3-4 horas de implementación + 1 hora de eval

**Impacto estimado**: +0.11 en score global, 13 queries con mejora directa

### Fase 2: Fixes de routing/infra (impacto MEDIO, esfuerzo BAJO)

Estas 5 queries no mejoran con RAG pero tienen fixes directos:

| Query | Fix | Archivo | Esfuerzo |
|-------|-----|---------|----------|
| "keiko vs porky" | Investigar ERROR 500 en MCP | infovoto-mcp | 1h |
| "rankings de candidatos" | Router debe filtrar cargo=presidente | router.py | 30min |
| "qué necesito para votar" | Router ejemplo para info_dia_elecciones | router.py | 15min |
| "partidos principales" | Router ejemplo para listado | router.py | 15min |
| "menos antecedentes" | Synthesizer prompt para comparaciones | system.py | 15min |

**Esfuerzo estimado**: ~2 horas

**Impacto estimado**: +0.05 adicional en score global

### Fase 3: Mejoras de synthesizer (impacto MEDIO, esfuerzo BAJO)

Consenso de stakeholders (D39, D40):

1. **Fuentes visibles**: Agregar instrucción al synthesizer para incluir fuente con cada dato
2. **Formato tabla**: Reforzar instrucción de tablas para comparaciones
3. **"SIN DATOS"**: Instrucción para decir "No encontramos registro en [fuente]" en vez de "No encontré"
4. **Respuestas puntuales**: Reforzar brevedad — 1-3 oraciones para datos puntuales

**Archivo**: `src/agent/prompts/system.py`
**Esfuerzo estimado**: 30min

### Fase 4: Evaluación y calibración

1. Correr eval completo (261 queries)
2. Medir precision del RAG (false positives / false negatives)
3. Ajustar threshold de distancia (L2 < 1.2 → calibrar)
4. Ajustar top_k si queries amplias no cubren suficientes candidatos
5. Comparar con baseline

**Esfuerzo estimado**: 1 hora

## Orden de implementación

```
1. build_perfiles_chromadb.py  → Generar datos (Fase 1, paso 1)
2. rag.py                      → Módulo RAG (Fase 1, paso 2)
3. core.py                     → Integrar en pipeline (Fase 1, paso 3)
4. system.py                   → Instrucciones synthesizer (Fase 1+3)
5. docker-compose.yml          → Volumen (Fase 1, paso 5)
6. Eval                        → Medir impacto (Fase 4)
7. router.py + MCP fixes       → Fixes de routing (Fase 2)
8. Eval final                  → Confirmar mejora (Fase 4)
```

## Lo que NO hacemos (decisión explícita)

| Descartado | Razón | Referencia |
|-----------|-------|-----------|
| Cambiar modelo de embeddings | all-MiniLM-L6-v2 suficiente para 36 docs | D42 |
| Reranker (cross-encoder) | Overkill para 36 docs | D42 |
| Chunking por sección | Doc completo cabe en 800 tokens | D42 |
| ChromaDB server separado | PersistentClient embebido es más simple | D41 |
| RAG como pre-routing (Opción C del D34) | RAG paralelo es mejor — no agrega latencia secuencial | D35 |
| RAG como fallback (Opción B del D34) | Agrega latencia en el peor momento | D35 |
| Modelo multilingual E5 | Solo si expandimos a 1000+ docs | D42 |

## Criterios de éxito

| Métrica | Actual | Target | Cómo medir |
|---------|--------|--------|-----------|
| Score global (eval 261q) | 4.71/5 | ≥4.80/5 | LLM-as-judge eval |
| Queries < 4.0 | 23 | ≤12 | Eval CSV |
| Queries < 2.0 | 4 | ≤2 | Eval CSV |
| "No encontré esa info" | ~8 queries | ≤2 | Grep en respuestas |
| p50 latencia | ~2.0s | ≤2.2s | Eval timing |
| p90 latencia | ~5.5s | ≤6.0s | Eval timing |

## Veredicto final

✅ **APROBADO UNÁNIMEMENTE — implementar Fase 1 primero.**

El RAG paralelo de perfiles de candidatos es la mejora más impactante con menor riesgo:
- **Impacto**: +0.11 score, 13 queries mejoradas, elimina "No encontré" en ~8 queries
- **Riesgo**: Bajo — fail-open, no rompe pipeline existente
- **Latencia**: Cero adicional (paralelo con router)
- **Esfuerzo**: ~4 horas para v1 funcional
- **Reversible**: Si no funciona, se deshabilita removiendo el volumen

Los 10 debates coinciden: esto es lo correcto. Implementar.

---

*Debates 34-43 completados. Los 10 roles han evaluado la propuesta de RAG vectorial paralelo desde arquitectura, latencia, datos, IR, UX, stakeholders, backend, ML, y liderazgo técnico. El consenso es unánime: implementar.*
