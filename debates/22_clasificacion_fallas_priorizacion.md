# Debate 22: Clasificación de Fallas y Priorización por Impacto

**Rol:** QA Lead
**Input:** Debates 20-21 (NLP Engineer, UX Researcher) + datos eval completos
**Fecha:** 2026-04-03

---

## Contexto

El NLP Engineer (debate 20) y el UX Researcher (debate 21) identificaron problemas desde sus perspectivas. Mi rol es clasificar las 12 fallas de forma rigurosa, identificar la causa raíz exacta de cada una, y priorizar por impacto real al usuario.

## Clasificación rigurosa de las 12 fallas

### Categoría A: TOOL ROUTING INCORRECTO (4 queries)

El LLM router envía al tool equivocado.

| # | Score | Query | Tool llamado | Tool correcto | Causa |
|---|-------|-------|-------------|---------------|-------|
| 1 | 1.0 | "qué estudió lopez aliaga" | `verificar_antecedentes` | `buscar_candidato_por_nombre` + synthesis edu | Router confunde "estudió" con investigaciones |
| 2 | 1.2 | "qué propone lopez aliaga para la seguridad" | `buscar_propuesta_tema` (sin tema específico) | `buscar_propuesta_tema(tema="seguridad")` | Router no extrae "seguridad" como tema |
| 3 | 3.2 | "alianza para el progreso de quién es" | `buscar_propuesta_tema(partido="APP")` | `buscar_candidato_por_nombre` (líder del partido) | Router confunde "de quién es" (líder) con propuestas |
| 6 | 3.4 | "cuáles son los partidos principales" | `listar_candidatos_region` (36 candidatos) | No hay tool para listar partidos | Router defaultea a lista de candidatos |

**Severidad: CRÍTICA.** El usuario recibe información completamente diferente a lo que pidió. Score de comprensión = 1.

### Categoría B: ENTITY RESOLUTION FALLA (3 queries)

El preprocessor no resuelve la entidad y el pipeline colapsa.

| # | Score | Query | Lo que pasa | Causa |
|---|-------|-------|------------|-------|
| 5 | 3.4 | "ese lescano de qué partido es pe" | "No encontré esa info" | "lescano" no está en _NICKNAMES |
| 9 | 3.5 | "kien es keiko" | "Ya te di la información" | **NO es entity resolution** — "keiko" SÍ matchea. Es cache/contexto |
| 10 | 3.5 | "acuña es empresario cierto? cuánto tiene?" | "No encontré esa info" | Sesión multi-turno: entity context conflicto |

**Corrección al debate 20:** "kien es keiko" NO falla por entity resolution. "keiko" sí matchea en `_NICKNAMES`. El reply "Ya te di la información" sugiere que:
1. En la eval, esta query se corrió después de otra query sobre Keiko en la misma sesión
2. El LLM (no el cache) decidió que "ya respondió" basándose en conversation history
3. **El problema es el LLM, no el preprocessor**

**Severidad: ALTA.** El usuario no obtiene respuesta, pero al menos el sistema no da info incorrecta.

### Categoría C: GREETING/SALUDO NO DETECTADO (1 query)

| # | Score | Query | Lo que pasa | Causa |
|---|-------|-------|------------|-------|
| 8 | 3.5 | "recién me entero de esta app a ver qué tal" | Perfil de Acuña | Regex `^...$` no matchea saludo embebido |

**Severidad: ALTA para retención.** El UX Researcher (debate 21) lo diagnosticó bien. Es un problema de primera impresión.

### Categoría D: NO EXISTE TOOL/DATA (3 queries)

El usuario pregunta algo para lo que no tenemos herramienta ni datos.

| # | Score | Query | Lo que hace | Lo que debería hacer |
|---|-------|-------|------------|---------------------|
| 7 | 3.4 | "cuánto ha gastado cada candidato en su campaña" | Perfil de Acuña | "No tengo info de gasto de campaña. Puedo mostrarte patrimonio declarado." |
| 11 | 3.6 | "quién financia a keiko" | Perfil completo de Keiko | "No tengo datos de financiamiento. Consulta ONPE CLARIDAD." |
| 12 | 3.9 | "quién defiende más a los trabajadores" | Honestamente dice que no tiene info | **Este ya funciona bien** (score 3.9, casi 4.0) |

**Nota:** Query 12 es casi correcta — el bot honestamente dice "no encontré información" y ofrece alternativas. El problema es que falta formato visual (fmt=1). La respuesta es buena en contenido.

**Severidad: MEDIA.** El sistema no tiene los datos, no es un bug de pipeline. El fix correcto es mejorar el fallback message, no crear MCPs nuevos (eso es scope de Data Engineer).

### Categoría E: LISTA DEMASIADO LARGA (1 query)

| # | Score | Query | Lo que hace | Lo que debería hacer |
|---|-------|-------|------------|---------------------|
| 4 | 3.2 | "candidatos a presidente 2026" (sesión) | Lista de 36 candidatos | Misma lista pero con paginación, o top 10 con encuestas |

**Severidad: BAJA.** La información ES correcta (score comprensión=5). El problema es que es abrumadora (concisión=2, legibilidad=3). Es un tema de UX, no de pipeline.

## Matriz de priorización

| Prioridad | Categoría | Queries | Fix | Esfuerzo | Impacto |
|-----------|-----------|---------|-----|----------|---------|
| P0 | A: Tool routing | 4 queries (score 1.0-3.4) | Router prompt + system prompt | Medio | **Máximo** (info incorrecta) |
| P1 | B: Entity resolution | 2 queries (score 3.4-3.5) | _NICKNAMES + apellidos | Bajo | Alto |
| P1 | C: Greeting detection | 1 query (score 3.5) | Detector de intent | Bajo | Alto (retención) |
| P2 | D: No existe tool/data | 2 queries (score 3.4-3.6) | Fallback messages | Bajo | Medio |
| P3 | E: Lista larga | 1 query (score 3.2) | Paginación inteligente | Medio | Bajo |

**Query 9 ("kien es keiko") reclasificada:** No es entity resolution, es **LLM context management**. El LLM decide "ya te lo dije" erróneamente. Fix: agregar instrucción en system prompt: "NUNCA digas 'ya te di esa información'. Siempre responde con la información solicitada."

**Query 12 ("quién defiende más a los trabajadores") reclasificada:** Score 3.9, casi correcto. El bot hace lo correcto (admite no tener data, ofrece alternativas). Solo falta formato visual. No es prioridad.

## Resumen ejecutivo

| Fix | Queries resueltas | Archivos | Líneas nuevas |
|-----|------------------|----------|---------------|
| Mejorar router prompt (tool selection) | 4 → score 1.0, 1.2, 3.2, 3.4 | `system.py` | ~30 |
| Ampliar _NICKNAMES con apellidos | 2 → score 3.4, 3.5 | `preprocessor.py` | ~20 |
| Detector de greeting/discovery | 1 → score 3.5 | `preprocessor.py` | ~20 |
| Fallback messages para "no data" | 2 → score 3.4, 3.6 | `system.py` o `core.py` | ~10 |
| "NUNCA digas ya te lo dije" | 1 → score 3.5 | `system.py` | ~2 |
| **Total** | **10 de 12** | **3 archivos** | **~82 líneas** |

Las 2 queries restantes (lista larga, score 3.9 casi OK) son mejoras de UX opcionales, no bugs.

## Veredicto

✅ **Aprobado.** Prioridad clara: P0=Router prompt, P1=Entity+Greeting, P2=Fallback. El fix más impactante es mejorar el router prompt para que entienda "qué estudió" ≠ antecedentes y "de quién es el partido" ≠ propuestas.
