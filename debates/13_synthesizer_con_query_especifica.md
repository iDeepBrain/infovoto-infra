# Debate 13 -- El Synthesizer con Queries Específicas

> **Fecha:** 2 de abril 2026
> **Entrada:** Debate 12 — regex patterns definidos, `is_specific_query` detecta preguntas específicas
> **Pregunta central:** Cuando `is_specific_query=True`, el synthesizer recibe TODOS los datos del MCP pero debe responder SOLO lo relevante. ¿Funciona esto automáticamente o necesita ajustes?

---

## Ciclo 1 -- Senior MLE

Analicemos el flujo actual del synthesizer. En `core.py`, cuando no hay passthrough, los datos del MCP se pasan al LLM con un prompt (`SYNTHESIZER_INSTRUCTION`) que dice:

```
"Eres VOTI, asistente electoral peruano. Responde SOLO con los datos proporcionados..."
```

El LLM recibe:
1. `enriched_message` — la pregunta original del usuario (ej: "cuánto gana acuña")
2. `tool_results` — TODOS los datos del MCP (perfil completo con `_resumen_markdown`)
3. `SYNTHESIZER_INSTRUCTION` — instrucciones de formato

**Pregunta clave:** ¿El `SYNTHESIZER_INSTRUCTION` actual le dice al LLM que responda SOLO lo que preguntó el usuario?

Revisando el prompt actual, dice "responde de forma concisa y directa" pero NO dice explícitamente "responde SOLO a lo que el usuario preguntó, no des información adicional no solicitada".

**Riesgo:** El LLM (gemini-2.0-flash) podría igual volcar todo el perfil porque tiene todos los datos disponibles. Flash tiende a ser verboso cuando tiene muchos datos.

### Veredicto: Necesitamos ajustar el SYNTHESIZER_INSTRUCTION para queries específicas.

---

## Ciclo 2 -- Codeforces Grandmaster

Este es un problema de **prompt engineering**, no de código. La solución óptima es pasar contexto al synthesizer sobre qué tipo de query es.

**Opciones:**

A. **Prompt estático mejorado:** Agregar al SYNTHESIZER_INSTRUCTION una regla general: "Si el usuario pregunta algo específico, responde SOLO eso."
   - Pro: Sin cambio de código
   - Contra: El LLM interpreta "específico" de forma variable

B. **Prompt dinámico:** Cuando `is_specific_query=True`, inyectar una instrucción adicional: "El usuario preguntó específicamente sobre X. Responde SOLO sobre eso."
   - Pro: El LLM sabe exactamente qué responder
   - Contra: +1 línea de código, prompt ligeramente más largo

C. **Filtrar datos antes del synthesizer:** Si la pregunta es sobre patrimonio, solo pasar la sección de patrimonio al LLM.
   - Pro: Menos tokens = más rápido y preciso
   - Contra: Requiere mapear patterns → secciones de datos (complejo)

**Análisis de complejidad:**
- Opción A: O(0) código nuevo, pero O(?) en calidad de respuesta
- Opción B: O(1) código nuevo, alta calidad
- Opción C: O(n) código nuevo donde n=número de secciones, alto riesgo de bugs

**Recomendación:** Opción B. Mínimo código, máximo impacto. La opción C es over-engineering para 10 días antes de elecciones.

### Veredicto: Opción B — prompt dinámico con hint de query específica.

---

## Ciclo 3 -- Delivery Lead

Opción B me gusta por la simplicidad. Pero ¿cómo se implementa exactamente?

**Propuesta concreta:**

En `core.py`, justo antes de llamar al synthesizer, si `is_specific_query=True`:

```python
# Antes del synthesizer prompt
synth_instruction = SYNTHESIZER_INSTRUCTION
if intent.is_specific_query:
    synth_instruction += (
        "\n\nIMPORTANTE: El usuario hizo una pregunta específica. "
        "Responde SOLO lo que preguntó. No incluyas el perfil completo "
        "ni información no solicitada. Sé breve y directo."
    )
```

**Eso es todo.** El LLM ya tiene la pregunta original en `enriched_message` y los datos completos en `tool_results`. Con este hint adicional, va a extraer solo la parte relevante.

**Ejemplo de lo que esperamos:**

Pregunta: "cuánto gana acuña"
Datos MCP: perfil completo (nombre, partido, educación, patrimonio, legal, posiciones...)
Hint: "responde SOLO lo que preguntó"

Respuesta esperada del LLM:
> "Según la DJHV de César Acuña, su patrimonio declarado es de S/ X. Sus ingresos anuales son S/ Y y declara Z inmuebles."

vs sin hint (actual):
> "**César Acuña** - Alianza para el Progreso. Cargo: Presidente. Edad: 73 años. Educación: ... Experiencia: ... Patrimonio: ... Legal: ... Posiciones: ..."

### Veredicto: Aprobado. Una línea de prompt adicional. Sin cambios arquitecturales.

---

## Ciclo 4 -- Peruano de a Pie

Probé mentalmente estas preguntas:

1. "cuánto gana keiko" → Synthesis con hint → me da solo patrimonio → **perfecto**
2. "info de keiko" → Passthrough → perfil completo → **perfecto**
3. "keiko tiene sentencias?" → Synthesis con hint → me da solo legal → **perfecto**
4. "antecedentes de keiko" → Passthrough de `verificar_antecedentes` → antecedentes completos → **perfecto**
5. "compara a keiko y acuña" → No es perfil individual, va a synthesis normal → **correcto**
6. "keiko" (solo el nombre) → ¿Genérica o específica? No matchea patterns → genérica → passthrough → **correcto**

**Edge case 6 es interesante:** Si escribo solo "keiko", no matchea ningún pattern específico, entonces es genérica. El passthrough me da el perfil completo. Tiene sentido — si solo pongo un nombre, probablemente quiero saber todo.

**Pero qué pasa con:** "keiko y la pena de muerte"? Match `pena de muerte` → específica → synthesis con hint → me da solo su posición sobre pena de muerte. **Correcto.**

### Veredicto: El flujo funciona bien para los casos que me importan como usuario.

---

## Ciclo 5 -- Tech Lead (síntesis técnica)

Consolidando los 4 ciclos anteriores, el cambio total en el synthesizer es:

**1 cambio en core.py** — agregar hint condicional al prompt del synthesizer:

```python
# En el bloque de synthesis (~línea 1100 de core.py)
extra_instruction = ""
if intent.is_specific_query:
    extra_instruction = (
        "\n\nIMPORTANTE: El usuario hizo una pregunta específica. "
        "Responde SOLO lo que preguntó, de forma breve y directa. "
        "No incluyas el perfil completo ni secciones no solicitadas."
    )

# Pasar al synthesizer
synth_prompt = SYNTHESIZER_INSTRUCTION + extra_instruction
```

**Impacto en latencia:**
- Query genérica: 0 cambio (passthrough como antes, ~1s)
- Query específica: +0ms de prompt (unas pocas palabras extra), synthesis normal (~3-5s)
- El hint NO agrega latencia significativa — son ~30 tokens extras en el prompt

**Impacto en calidad:**
- Gemini 2.0 Flash respeta well instrucciones directivas en español
- El hint "responde SOLO lo que preguntó" es claro e inequívoco
- Si el LLM igual da información extra, es un problema de modelo, no de arquitectura

**Testing:** Probar con 5 queries específicas y verificar que las respuestas son focalizadas:
1. "cuánto gana keiko" → solo patrimonio
2. "dónde estudió acuña" → solo educación
3. "keiko tiene sentencias" → solo legal
4. "qué piensa keiko del aborto" → solo esa posición
5. "keiko está en la cima de las encuestas" → solo ranking/encuestas

### Veredicto: Aprobado. Cambio mínimo, testeable, sin riesgo arquitectural.

---

## Consenso del Debate 13

| Decisión | Detalle |
|----------|---------|
| Prompt dinámico (Opción B) | Hint condicional en SYNTHESIZER_INSTRUCTION |
| NO filtrar datos del MCP | El LLM puede extraer la sección relevante solo |
| NO modificar SYNTHESIZER_INSTRUCTION base | Solo agregar hint cuando `is_specific_query=True` |
| El hint es breve | ~30 tokens extra, impacto en latencia: 0 |
| Testing con 5 queries | Verificar respuestas focalizadas antes de deploy |

**Cambios de código acumulados hasta ahora:**
1. `preprocessor.py`: +`is_specific_query` field + `_SPECIFIC_PATTERNS` + `_is_specific_query()` (~25 líneas)
2. `core.py`: condicional passthrough (~5 líneas) + hint synthesizer (~5 líneas)
3. **Total: ~35 líneas de código nuevo en 2 archivos**

**Entrada para Debate 14:** ¿Cómo testeamos esto end-to-end? ¿Qué logs necesitamos? ¿Cuál es el plan de deploy en dev?
