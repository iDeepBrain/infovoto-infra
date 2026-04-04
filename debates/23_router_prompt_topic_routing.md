# Debate 23: Router Prompt — Topic Routing y Tool Selection

**Rol:** Prompt Engineer
**Input:** Debates 20-22 (NLP Engineer, UX Researcher, QA Lead) + system.py + router actual
**Fecha:** 2026-04-03

---

## Contexto

El QA Lead (debate 22) clasificó las 4 fallas de tool routing como **P0 — prioridad máxima**:

| Score | Query | Tool llamado | Problema |
|-------|-------|-------------|----------|
| 1.0 | "qué estudió lopez aliaga" | `verificar_antecedentes` | "estudió" interpretado como "investigaciones" |
| 1.2 | "qué propone lopez aliaga para la seguridad" | `buscar_propuesta_tema` (sin tema) | "seguridad" no extraído como parámetro tema |
| 3.2 | "alianza para el progreso de quién es" | `buscar_propuesta_tema(partido=APP)` | "de quién es" → debería buscar líder, no propuestas |
| 3.4 | "cuáles son los partidos principales" | `listar_candidatos_region` (36 candidatos) | No hay tool para listar partidos, pero la lista debería agruparse |

Además, el QA Lead reclasificó query 9 ("kien es keiko" → "Ya te di la información") como LLM context management, no entity resolution. Necesita instrucción en system prompt.

## Análisis del system prompt actual

El system prompt (`system.py`) tiene reglas de routing pero con gaps:

```
### Herramientas (OBLIGATORIO)
- PRIMERO llama herramienta, LUEGO responde.
- Si el usuario pregunta por propuestas SIN especificar partido, llama buscar_propuesta_tema(tema=X) SIN el parámetro partido
```

**Gap 1:** No hay regla para "qué estudió X". El LLM interpreta "estudió" ambiguamente:
- "qué estudió" = educación (contexto: formación académica)
- "está siendo estudiado/investigado" = antecedentes (contexto: fiscal)

Sin guidance explícita, el LLM router decide según su entrenamiento y a veces elige antecedentes.

**Gap 2:** No hay regla para "de quién es [partido]". El LLM ve "Alianza para el Progreso" y la única tool asociada a partidos es `buscar_propuesta_tema`. Entonces la llama.

**Gap 3:** `buscar_propuesta_tema` requiere parámetro `tema`. Cuando el query dice "para la seguridad", el LLM debería extraer `tema="seguridad"`. Pero si no lo hace, el MCP recibe `tema=""` y devuelve la visión general del plan.

**Gap 4:** No hay instrucción sobre "NUNCA digas ya te di la información". El LLM, en contexto de sesión, decide acortar diciendo que ya respondió.

## Propuestas

### Propuesta 1: Reglas explícitas de disambiguation en system prompt

Agregar al system prompt reglas claras para queries ambiguas:

```
### Disambiguation de queries
- "qué estudió X", "dónde estudió X", "educación de X", "formación de X", "carrera de X" → SIEMPRE `buscar_candidato_por_nombre(nombre=X)`. La educación está en el perfil del candidato, NO en antecedentes.
- "de quién es [partido]", "quién lidera [partido]", "candidato de [partido]" → `buscar_candidato_por_nombre(nombre="candidato de [partido]")` o `listar_candidatos_region(partido="[partido]", cargo="presidente")`.
- "qué propone X para/sobre [TEMA]" → `buscar_propuesta_tema(tema="[TEMA]", partido="[partido de X]")`. SIEMPRE extrae el tema de la pregunta.
- "cuáles son los partidos" → `listar_candidatos_region(cargo="presidente")` y agrupa por partido en la respuesta.
- NUNCA digas "ya te di la información" ni "ya respondí eso". Si el usuario pregunta algo, SIEMPRE responde con la información completa, incluso si fue mencionada antes.
```

**Ventaja:** Directo, sin cambios de código, solo cambiar el prompt.
**Riesgo:** Más reglas = más largo el prompt = más tokens = más lento. Actualmente el system prompt ya es largo.

### Propuesta 2: Ejemplos few-shot en el router prompt

En vez de reglas abstractas, agregar ejemplos concretos:

```
### Ejemplos de routing correcto
- "qué estudió keiko" → buscar_candidato_por_nombre(nombre="Keiko Fujimori") [educación está en perfil]
- "antecedentes de keiko" → verificar_antecedentes(dni=...) [requiere DNI, primero buscar por nombre]
- "qué propone acuña para seguridad" → buscar_propuesta_tema(tema="seguridad", partido="Alianza para el Progreso")
- "de quién es Fuerza Popular" → buscar_candidato_por_nombre(nombre="candidato Fuerza Popular")
- "cuáles son los partidos" → listar_candidatos_region(cargo="presidente", por_pagina=36) [agrupa por partido]
```

**Ventaja:** Few-shot es más efectivo que reglas para LLMs. El LLM generaliza mejor con ejemplos.
**Riesgo:** Más tokens en el prompt. Pero 5 ejemplos son ~100 tokens, aceptable.

### Propuesta 3: Topic extraction en el prompt

Agregar instrucción para que el LLM extraiga el tema ANTES de elegir tool:

```
### Proceso de routing
1. Identifica el CANDIDATO o PARTIDO mencionado
2. Identifica el TEMA específico (educación, patrimonio, seguridad, antecedentes, etc.)
3. Elige la herramienta correcta según el tema:
   - Perfil/educación/patrimonio/experiencia → buscar_candidato_por_nombre
   - Antecedentes penales/judiciales → verificar_antecedentes (necesita DNI)
   - Propuestas/planes → buscar_propuesta_tema(tema=TEMA)
   - Lista de candidatos → listar_candidatos_region
4. SIEMPRE pasa el tema como parámetro cuando la herramienta lo acepta
```

**Ventaja:** Estructura el pensamiento del LLM. Reduce ambigüedad.
**Riesgo:** Puede hacer el routing más lento si el LLM "piensa más" antes de actuar.

### Propuesta 4: Fix específico para "qué propone X para TEMA"

El MCP `buscar_propuesta_tema` acepta `tema` como parámetro. Cuando el query dice "para la seguridad" o "sobre educación", el router DEBE extraer ese tema. Agregar:

```
- IMPORTANTE: Cuando el usuario dice "qué propone X para/sobre [ALGO]", el parámetro tema DEBE ser "[ALGO]". Ejemplos:
  - "qué propone keiko sobre educación" → tema="educación"
  - "propuestas de seguridad" → tema="seguridad"
  - "qué dice sobre salud" → tema="salud"
  - NUNCA dejes tema vacío si el usuario especificó un tema.
```

## Combinación recomendada

Mezclar Propuestas 1 + 2 + 4:

1. **Reglas de disambiguation** (Prop 1): 5-6 reglas claras para los casos más comunes
2. **Few-shot examples** (Prop 2): 5 ejemplos de routing correcto
3. **Topic extraction obligatorio** (Prop 4): Instrucción específica para `buscar_propuesta_tema`
4. **"NUNCA digas ya te lo dije"**: Regla directa

### Estimación de tokens adicionales en system prompt

- Reglas de disambiguation: ~150 tokens
- Few-shot examples: ~100 tokens
- Topic extraction: ~80 tokens
- "Nunca ya te lo dije": ~20 tokens
- **Total: ~350 tokens adicionales** (~0.5% del context window de Gemini Flash)

Completamente aceptable. No impacta latencia.

## Trade-offs

| Aspecto | Antes | Después |
|---------|-------|---------|
| System prompt length | ~800 tokens | ~1150 tokens |
| Tool routing accuracy | 95% (249/261) | ~99% (estimado) |
| Latencia | Sin cambio | Sin cambio |
| Mantenimiento | Bajo | Medio (más reglas que mantener) |

## Veredicto

✅ **Aprobado.** La combinación de reglas + few-shot + topic extraction es el fix más impactante con mínimo esfuerzo. Resuelve las 4 queries de routing (P0) y la query de "ya te lo dije" (P1). Sin cambios de código, solo system prompt.

**Pido al Data Engineer (debate 24)** que confirme si `buscar_propuesta_tema(tema="seguridad")` realmente devuelve propuestas de seguridad, y si hay tools faltantes que necesitemos crear.
