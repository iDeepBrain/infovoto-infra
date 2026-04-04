# Debate 15 -- Follow-ups Cuando el Primer Mensaje Uso Passthrough

**Fecha:** 2 de abril 2026
**Estado:** CERRADO
**Tema:** Como manejar follow-ups cuando el primer mensaje disparo passthrough (template pre-formateado desde MCP), evitando re-fetch innecesario y garantizando que la respuesta al follow-up sea especifica.

---

## Contexto Tecnico

### Flujo actual del pipeline

```
[Turno 1] "info de keiko"
  Preprocessor → nickname "keiko" → DNI 10001088 → candidate "KEIKO SOFIA FUJIMORI HIGUCHI"
  Fast-route? NO (no es lista)
  LLM Router → buscar_candidato_por_dni(dni="10001088")
  MCP → retorna JSON con _resumen_markdown (perfil completo: bio + partido + patrimonio + antecedentes + propuestas)
  _has_preformatted_content() → TRUE
  _build_passthrough_reply() → devuelve _resumen_markdown tal cual
  Redis: save entity_context = {candidate: "KEIKO SOFIA...", dni: "10001088", last_tool: "buscar_candidato_por_dni"}
  Redis: save tool+args cache key = cache:tool:buscar_candidato_por_dni:<hash(dni=10001088)>
  Latencia total: ~0.7s
```

```
[Turno 2] "y cuanto gana?"
  Preprocessor → no DNI, no nickname → hereda entity_context {candidate, dni, last_tool}
  intent = "followup" (mensaje corto, sin entidad nueva, hay entity_context)
  enriched_message = "y cuanto gana?" (sin cambio)
  LLM Router → ??? (problema central)
```

### Problema central

El usuario pregunta "y cuanto gana?" refiriendose al patrimonio/ingresos de Keiko. El sistema tiene entity_context con toda la info del turno anterior. Pero:

1. **Si el router llama `buscar_candidato_por_dni(dni="10001088")` de nuevo:**
   - Tool+args cache HIT → devuelve el reply cacheado (el perfil COMPLETO de turno 1)
   - El usuario recibe el MISMO perfil completo, no la respuesta especifica sobre patrimonio
   - Experiencia terrible: "te pregunte cuanto gana, no me repitas todo"

2. **Si el router llama `buscar_candidato_por_dni` y NO hay cache:**
   - MCP retorna `_resumen_markdown` → passthrough activa de nuevo
   - Mismo perfil completo, misma experiencia terrible

3. **Si el router NO llama ninguna tool:**
   - El LLM intenta responder desde history, pero el history tiene el markdown del perfil
   - Podria funcionar si el LLM extrae la seccion de patrimonio del history
   - Pero depende de que el history tenga suficiente contexto (trim puede cortarlo)

### Archivos involucrados

| Archivo | Relevancia |
|---------|------------|
| `infovoto-gateway/src/agent/core.py` | `_has_preformatted_content`, `_build_passthrough_reply`, tool cache, passthrough logic |
| `infovoto-gateway/src/agent/router.py` | `build_router_prompt`, entity_context injection, domain hints |
| `infovoto-gateway/src/agent/preprocessor.py` | Intent classification, entity inheritance |
| `infovoto-mcp/src/mcp/perfiles/server.py` | `_resumen_markdown` template, JSON payload structure |

### Datos del JSON de MCP perfiles (ejemplo)

```json
{
  "_resumen_markdown": "## KEIKO SOFIA FUJIMORI HIGUCHI\n\n**Partido:** Fuerza Popular...\n### Patrimonio\n- Ingresos: S/ 120,000...\n### Antecedentes\n...",
  "nombre": "KEIKO SOFIA FUJIMORI HIGUCHI",
  "dni": "10001088",
  "partido": "FUERZA POPULAR",
  "patrimonio": {
    "ingresos": 120000,
    "bienes_muebles": [...],
    "bienes_inmuebles": [...]
  },
  "antecedentes": [...],
  "propuestas": [...]
}
```

El JSON tiene TANTO el `_resumen_markdown` (string largo pre-formateado) COMO los campos estructurados individuales (`patrimonio`, `antecedentes`, etc.).

---

## Pregunta Central

> Cuando el usuario hace un follow-up sobre un aspecto especifico de un candidato cuyo perfil ya fue mostrado via passthrough, como evitar repetir el perfil completo y en su lugar dar una respuesta enfocada?

### Soluciones propuestas

| # | Solucion | Descripcion |
|---|----------|-------------|
| A | Forzar sintesis LLM para follow-ups | Detectar intent=followup + last_tool=passthrough → skip passthrough, forzar synthesizer |
| B | Cache JSON raw separado del reply | Guardar JSON estructurado en cache aparte, usarlo para sintesis en follow-ups |
| C | Skip passthrough para follow-ups | Si entity_context.last_tool existe y mismo tool → no hacer passthrough, ir a synthesizer |

---

## Ciclo 1 -- Analisis de Cada Solucion

### Senior MLE #1

La solucion A es la mas simple y directa. Veamos el flujo:

```python
# En core.py, despues de tool+args cache check:
if tool_cache_hit:
    # NUEVO: si es follow-up, no devolver cache directo → forzar synthesis
    if intent.intent == "followup" and save_entities.get("last_tool"):
        # Tenemos el reply cacheado (perfil completo), pero no es lo que el user quiere
        # Necesitamos pasar por synthesizer con la pregunta especifica
        tool_cache_hit = False  # Reset para que no haga pass
        # Pero... no tenemos el JSON raw, solo el reply formateado
```

Problema inmediato: el tool+args cache guarda `{"reply": "<markdown completo>", "sources": [...]}`. No guarda el JSON raw del MCP. Si forzamos sintesis, el synthesizer recibe el markdown pre-formateado, no datos estructurados para extraer.

La solucion B resuelve esto pero agrega complejidad: doble cache (raw JSON + reply formateado).

### Senior MLE #2

Analicemos la solucion C con mas detalle:

```
[Turno 2] "y cuanto gana?"
  Router → buscar_candidato_por_dni(dni="10001088")
  Tool+args cache → HIT (tiene reply del turno 1)
  PERO: intent == "followup" → NO devolver cache, llamar MCP de nuevo
  MCP → retorna JSON con _resumen_markdown
  _has_preformatted_content → TRUE
  PERO: intent == "followup" → NO hacer passthrough → ir a synthesizer
  Synthesizer recibe: user_question="y cuanto gana?" + tool_data=JSON_COMPLETO
  Synthesizer extrae seccion patrimonio → respuesta enfocada
```

Esto funciona pero tiene una ineficiencia: llama MCP de nuevo cuando ya tenemos los datos. Es un round-trip HTTP innecesario (~50-200ms).

### Senior MLE #3

La solucion optima es un hibrido: guardar el JSON raw en cache Y forzar sintesis para follow-ups.

```
[Turno 2] "y cuanto gana?"
  Router → buscar_candidato_por_dni(dni="10001088")
  raw_cache → HIT (JSON estructurado del MCP)
  intent == "followup" → skip passthrough
  Synthesizer recibe: question + JSON raw → respuesta enfocada sobre patrimonio
  Latencia: ~1-2s (solo LLM synthesis, sin MCP call)
```

Pero esto duplica almacenamiento en Redis: una key para reply formateado, otra para JSON raw.

### Senior MLE #4

Pregunto: realmente necesitamos dos caches? Podemos unificar:

```python
# Tool cache almacena AMBOS: raw JSON + reply formateado
cache_payload = {
    "reply": reply_text,          # Para queries identicas (cache hit directo)
    "raw_data": tool_result_json, # Para follow-ups (sintesis con datos raw)
    "sources": [...]
}
```

Cuando es follow-up: usa `raw_data` para sintesis.
Cuando es query identica repetida: usa `reply` directo.

Un solo cache entry, un solo Redis key, sin duplicacion.

### Senior MLE #5

Hay un caso edge que nadie ha mencionado: que pasa si el follow-up NO es sobre el mismo candidato?

```
[T1] "info de keiko" → perfil keiko (passthrough)
[T2] "y de castillo?" → follow-up? NO — es nueva entidad
[T3] "y cuanto gana?" → follow-up de T2 (castillo), no de T1 (keiko)
```

El preprocessor ya maneja esto: "y de castillo?" resolveria nickname → nueva entidad → entity_context se actualiza. Pero "y cuanto gana?" despues de T2 debe referirse a castillo, no keiko.

Esto ya funciona con el entity_context actual. Solo necesitamos asegurarnos de que el `raw_data` cache se invalide/actualice cuando cambia la entidad.

### Codeforces Grandmaster #1

Formalizemos el problema como un grafo de decisiones:

```
                    ┌── query identica → reply directo (cache hit)
                    │
tool+args match ────┤
                    │                    ┌── tiene raw_data → synthesizer(question, raw_data)
                    └── follow-up ───────┤
                                         └── no raw_data → MCP call → synthesizer(question, json)

tool+args NO match ─── MCP call ─── passthrough? ─── SI y NOT followup → reply directo
                                         │
                                         └── SI y followup → synthesizer(question, json)
                                         │
                                         └── NO → synthesizer normal
```

La complejidad es O(1) en todos los caminos. El unico overhead adicional es el LLM synthesis call (~1-2s) para follow-ups, que es inevitable porque necesitamos que el LLM extraiga la seccion relevante.

### Codeforces Grandmaster #2

Preocupacion sobre el tamano del cache. El JSON raw de un perfil puede ser ~5-10KB. El `_resumen_markdown` otro ~3-5KB. Guardar ambos en la misma key sube el payload a ~15KB por candidato.

Con 36 candidatos presidenciales: 36 * 15KB = 540KB. Irrelevante para Redis. Incluso con 10,000 candidatos de todas las regiones: 150MB. Manejable.

No hay preocupacion de memoria aqui.

### Codeforces Grandmaster #3

Propongo una optimizacion adicional: el synthesizer para follow-ups no necesita TODO el JSON raw. Solo la seccion relevante.

```python
# Si el follow-up menciona patrimonio/ingresos/gana → extraer solo patrimonio del JSON
# Si menciona antecedentes/procesos → extraer solo antecedentes
# Si menciona propuestas/plan → extraer solo propuestas
```

Esto reduciria tokens del synthesizer de ~2000 (perfil completo) a ~300 (seccion relevante). Mas rapido y mas barato.

Pero... esto requiere un mini-router antes del synthesizer para clasificar el aspecto del follow-up. Podria ser regex simple:

```python
ASPECT_PATTERNS = {
    "patrimonio": r"gana|patrimonio|ingreso|sueldo|bienes|dinero|plata",
    "antecedentes": r"antecedente|proceso|juicio|sentencia|denuncia|penal",
    "propuestas": r"propuesta|plan|propone|plantea|promete|programa",
    "educacion": r"estudi[oó]|universidad|carrera|titulo|formaci[oó]n",
    "experiencia": r"experiencia|trabaj[oó]|cargo|fue\s+(ministro|congresista)",
}
```

### Codeforces Grandmaster #4

Contra-argumento al Grandmaster #3: el LLM synthesizer (gemini-2.0-flash) es extremadamente bueno extrayendo informacion relevante de un JSON. Pasarle todo el JSON y dejar que el extraiga es mas robusto que un regex que podria fallar en edge cases.

Ejemplo: "que opinan de el en la fiscalia?" — es antecedentes? propuestas de justicia? Ambos? El regex no lo sabe, el LLM si.

El overhead de pasar ~2000 tokens extra al synthesizer es ~200ms adicionales. No vale la pena la complejidad del mini-router.

### Codeforces Grandmaster #5

Estoy de acuerdo con #4. La unica optimizacion que vale es: si detectamos que el follow-up pregunta algo que NO esta en el perfil del candidato (ej: "y que opina de la reforma agraria?"), el JSON raw no va a tener esa info. En ese caso, el router deberia llamar `buscar_propuesta_tema` en lugar de repetir `buscar_candidato_por_dni`.

Esto ya lo maneja el LLM router actual: si la pregunta es sobre un tema especifico, deberia rutear a `buscar_propuesta_tema`. El entity_context ya tiene el candidato/partido para enrichecer los args.

El caso problematico es cuando el router decide "el usuario pregunta sobre keiko, voy a llamar buscar_candidato_por_dni" porque no distingue entre "quiero el perfil completo" y "quiero un dato especifico del perfil".

### AI Tech Lead

Resumiendo las 5 propuestas del ciclo 1:

1. **Cache unificado con raw_data** (Senior #4): Un solo cache entry con `reply` + `raw_data` + `sources`
2. **Follow-up detection fuerza synthesis** (todos): Si intent=followup y tool+args cache hit → usar raw_data para synthesis
3. **No mini-router de aspectos** (Grandmaster #4): Dejar que el LLM synthesizer extraiga lo relevante del JSON completo
4. **Si tool+args NO tiene cache** y es follow-up → llamar MCP pero skip passthrough → synthesis

**Veredicto ciclo 1:** Consenso en la direccion general. Falta definir implementacion exacta.

---

## Ciclo 2 -- Implementacion Detallada

### Senior MLE #1

Propongo los cambios concretos en `core.py`:

**Cambio 1: `_set_tool_cache` guarda tambien raw_data**

```python
async def _set_tool_cache(self, tool_name: str, tool_args: dict,
                          reply: str, raw_data: dict | None = None,
                          sources: list | None = None) -> None:
    payload = {
        "reply": reply,
        "raw_data": raw_data,  # JSON estructurado del MCP
        "sources": [s.model_dump() for s in sources] if sources else None,
    }
    # ... redis set igual que antes
```

**Cambio 2: Logica de follow-up en el bloque principal**

```python
# Despues de tool+args cache check:
if tool_cache_hit:
    if intent.intent == "followup" and _tc_cached.get("raw_data"):
        # Follow-up: usar raw_data para synthesis enfocada
        tool_cache_hit = False  # No usar reply cacheado
        tool_results = {_tc_name: _tc_cached["raw_data"]}
        # Caera al bloque de synthesis con tool_results
    else:
        pass  # Query identica: usar reply cacheado (comportamiento actual)
```

**Cambio 3: Skip passthrough para follow-ups**

```python
# Bloque passthrough actual:
elif len(tool_results) == 1 and _has_preformatted_content(tool_results):
    if intent.intent != "followup":  # NUEVO: solo passthrough si NO es follow-up
        name, data = next(iter(tool_results.items()))
        reply_text = _build_passthrough_reply(data)
    # Si es follow-up, cae al synthesizer con el JSON completo
```

### Senior MLE #2

Hay un detalle critico en el Cambio 2: cuando reseteamos `tool_cache_hit = False` y ponemos `tool_results`, el flujo cae al bloque de passthrough (Cambio 3 lo maneja), y luego al synthesizer. Pero el synthesizer necesita que `tool_results` tenga el formato correcto.

Actualmente el synthesizer recibe:

```python
tool_results = {"buscar_candidato_por_dni": {JSON_COMPLETO_CON_RESUMEN}}
```

Si viene del cache, `raw_data` seria ese mismo JSON. Entonces funciona sin cambios en el synthesizer.

Pero hay que asegurar que `_has_preformatted_content` siga retornando `True` para este caso, y que el Cambio 3 lo capture correctamente.

```python
# Flujo completo para follow-up con cache hit:
# 1. tool_cache_hit = True, _tc_cached tiene raw_data
# 2. intent == "followup" → tool_cache_hit = False, tool_results = raw_data
# 3. Bloque passthrough: _has_preformatted_content = True, pero intent == "followup" → skip
# 4. Cae al synthesizer: tool_results tiene JSON completo → LLM extrae patrimonio
```

Correcto. El flujo funciona.

### Senior MLE #3

Y para el caso donde NO hay cache hit (primera vez que se pregunta por este candidato, o cache expirado):

```python
# Flujo para follow-up SIN cache:
# 1. Router → buscar_candidato_por_dni(dni="10001088")
# 2. MCP call → retorna JSON con _resumen_markdown
# 3. Bloque passthrough: _has_preformatted_content = True, pero intent == "followup" → skip
# 4. Cae al synthesizer: JSON completo → LLM extrae patrimonio
# 5. Tool cache write: guarda reply (sintesis enfocada) + raw_data (JSON completo)
```

Espera — el paso 5 tiene un problema. Si guardamos en cache el reply de la sintesis enfocada (ej: "Keiko declara ingresos de S/ 120,000..."), y luego otro usuario pregunta lo mismo (buscar_candidato_por_dni con mismo DNI) pero NO como follow-up sino como query nueva, va a recibir la respuesta enfocada en patrimonio en lugar del perfil completo.

### Junior MLE #1

Ese es un bug critico! Si el cache guarda el reply del follow-up, contamina las queries futuras. Ejemplo:

```
[User A, T1] "info de keiko" → perfil completo (passthrough) → cache write: reply=perfil_completo
[User A, T2] "y cuanto gana?" → follow-up → synthesis → cache write: reply=SOLO_PATRIMONIO  ← SOBREESCRIBE!
[User B, T1] "info de keiko" → cache hit → recibe SOLO_PATRIMONIO en vez de perfil completo
```

### Junior MLE #2

Confirmado. El tool+args cache key es `cache:tool:buscar_candidato_por_dni:<hash(dni=10001088)>`. Es el MISMO key para ambos turnos porque tool+args son identicos.

Si el follow-up sobreescribe el reply, usuarios futuros reciben la respuesta equivocada.

### Junior MLE #3

Solucion obvia: NO sobreescribir el cache en follow-ups. Solo leer, nunca escribir.

```python
# Tool+args cache write:
if reply_text and not tool_cache_hit and len(valid_calls) == 1:
    if intent.intent != "followup":  # NUEVO: no cachear follow-ups
        _tc_name = valid_calls[0]["name"]
        _tc_args = valid_calls[0].get("args", {})
        asyncio.create_task(self._set_tool_cache(_tc_name, _tc_args, reply_text, raw_data=..., sources=sources))
```

Pero esto significa que si un follow-up es la PRIMERA interaccion con ese candidato (no hay cache previo), tampoco se guarda. El siguiente usuario tendra que hacer el MCP call de nuevo.

### Senior MLE #4

Refinamiento: en follow-ups, guardar el `raw_data` pero NO sobreescribir el `reply` si ya existe.

```python
if intent.intent == "followup":
    # Solo guardar raw_data si no existia en cache
    existing = await self._get_tool_cache(_tc_name, _tc_args)
    if not existing:
        # Primera vez: guardar raw_data + reply del passthrough (no del follow-up)
        passthrough_reply = _build_passthrough_reply(raw_data)
        asyncio.create_task(self._set_tool_cache(
            _tc_name, _tc_args,
            reply=passthrough_reply,  # Reply del passthrough, no del follow-up
            raw_data=raw_data,
            sources=sources
        ))
else:
    # Query normal: guardar como siempre
    asyncio.create_task(self._set_tool_cache(_tc_name, _tc_args, reply_text, raw_data=raw_data, sources=sources))
```

### Senior MLE #5

Esto se esta complicando. Propongo simplificar:

**Regla simple: el tool+args cache SIEMPRE guarda el passthrough reply (perfil completo) + raw_data. Nunca guarda replies sintetizados de follow-ups.**

```python
# En el bloque de tool+args cache write:
if reply_text and not tool_cache_hit and len(valid_calls) == 1:
    _tc_name = valid_calls[0]["name"]
    _tc_args = valid_calls[0].get("args", {})
    _raw = next(iter(tool_results.values())) if tool_results else None

    if _has_preformatted_content(tool_results):
        # Passthrough-capable: guardar el passthrough reply + raw JSON
        _pt_reply = _build_passthrough_reply(next(iter(tool_results.values())))
        asyncio.create_task(self._set_tool_cache(
            _tc_name, _tc_args, reply=_pt_reply, raw_data=_raw, sources=sources
        ))
    else:
        # Tool sin passthrough: guardar reply sintetizado
        asyncio.create_task(self._set_tool_cache(
            _tc_name, _tc_args, reply=reply_text, sources=sources
        ))
```

Asi el cache SIEMPRE tiene el perfil completo para queries directas, y el `raw_data` para follow-ups.

### AI Tech Lead

Excelente. La solucion del Senior #5 es limpia y evita el bug de contaminacion de cache. Resumo:

1. **Cache siempre guarda passthrough reply** (no reply sintetizado de follow-ups)
2. **Cache ademas guarda raw_data** (JSON estructurado para follow-ups)
3. **Follow-ups usan raw_data** del cache para synthesis enfocada
4. **El synthesizer recibe el JSON completo** — el LLM extrae la seccion relevante

**Veredicto ciclo 2:** Aprobado con la regla de cache del Senior #5.

---

## Ciclo 3 -- Edge Cases y Robustez

### Codeforces Grandmaster #1

Edge case 1: Follow-up en cadena.

```
[T1] "info de keiko" → perfil (passthrough)
[T2] "y cuanto gana?" → patrimonio (synthesis de raw_data)
[T3] "y en bienes inmuebles?" → follow-up del follow-up
```

En T3, el entity_context tiene `last_tool: "buscar_candidato_por_dni"`. El router deberia llamar la misma tool. El cache tiene raw_data. La synthesis extraera bienes inmuebles.

Funciona sin cambios adicionales. El `intent.intent` sera "followup" para T2 y T3.

### Codeforces Grandmaster #2

Edge case 2: Follow-up que requiere una tool diferente.

```
[T1] "info de keiko" → perfil (passthrough)
[T2] "y que propone sobre educacion?" → buscar_propuesta_tema(nombre="KEIKO...", tema="educacion")
```

En T2, el router deberia rutear a `buscar_propuesta_tema`, NO a `buscar_candidato_por_dni`. El tool+args cache key sera diferente (distinto tool name). No hay conflicto.

Pero: si el router incorrectamente llama `buscar_candidato_por_dni` de nuevo, el raw_data tiene un campo `propuestas` pero es un resumen generico, no las propuestas detalladas sobre educacion. El synthesizer daria una respuesta superficial.

Solucion: confiar en el LLM router. El prompt del router ya tiene reglas para rutear a `buscar_propuesta_tema` cuando hay un tema especifico. Si falla, es un problema del router, no del mecanismo de follow-up.

### Codeforces Grandmaster #3

Edge case 3: Follow-up ambiguo.

```
[T1] "info de keiko" → perfil
[T2] "y tiene problemas?" → antecedentes? propuestas? salud?
```

El synthesizer recibira el JSON completo y la pregunta "y tiene problemas?". Gemini-2.0-flash deberia interpretar "problemas" como antecedentes/procesos judiciales en el contexto politico peruano.

Si interpreta mal, es un problema de calidad del LLM, no de la arquitectura. No hay nada que el mecanismo de follow-up pueda hacer aqui.

### Junior Codeforces #1

Edge case 4: Follow-up cuando el primer turno NO fue passthrough.

```
[T1] "que propone keiko sobre salud?" → buscar_propuesta_tema → synthesis normal
[T2] "y sobre educacion?" → follow-up
```

En T2, `last_tool: "buscar_propuesta_tema"`. El router llama `buscar_propuesta_tema(nombre="KEIKO...", tema="educacion")`. Los args son DIFERENTES (tema cambio). No hay cache hit. MCP call normal → synthesis normal.

No hay interaccion con el mecanismo de follow-up+passthrough. Funciona.

### Junior Codeforces #2

Edge case 5: raw_data es None en el cache (migracion).

Si hay entries viejas en Redis que se escribieron ANTES de implementar el `raw_data`, tendran `{"reply": "...", "sources": [...]}` sin `raw_data`.

```python
if intent.intent == "followup" and _tc_cached.get("raw_data"):
    # raw_data existe → synthesis enfocada
else:
    # raw_data no existe (entry vieja) → devolver reply cacheado como siempre
```

El `get("raw_data")` retorna `None` para entries viejas. Comportamiento correcto: degrada gracefully al reply completo. No es ideal (usuario ve perfil completo de nuevo) pero no rompe nada. Despues del TTL, la entry se reescribe con raw_data.

### Junior Codeforces #3

Edge case 6: Follow-up despues de un error en T1.

```
[T1] "info de keiko" → MCP timeout → fallback message ("No pude obtener la info...")
[T2] "y cuanto gana?" → follow-up
```

En T1, el tool+args cache NO se escribio (no hubo reply exitoso). En T2, no hay cache hit. El router llama MCP de nuevo. Si MCP funciona ahora, perfil completo → pero intent es "followup" → skip passthrough → synthesis.

Resultado: el usuario recibe solo la seccion de patrimonio. No es ideal — deberia recibir el perfil completo primero. Pero es aceptable: el usuario pregunto sobre patrimonio, recibio patrimonio.

### Senior MLE #1

Edge case 7: Concurrencia. Dos requests simultaneos para el mismo candidato.

```
[Request A] "info de keiko" → MCP call → passthrough → cache write
[Request B] "y cuanto gana?" (0.1s despues) → cache miss (A no termino) → MCP call → follow-up synthesis
```

Request B llama MCP antes de que A escriba el cache. No hay race condition peligrosa — B simplemente no encuentra cache y hace su propia MCP call. El resultado es correcto, solo ligeramente ineficiente.

Con pre-computacion (debate 07), esto no seria problema: el cache ya estaria lleno para los 36 candidatos presidenciales.

### AI Tech Lead

Todos los edge cases estan cubiertos:

| # | Edge Case | Resultado | Accion |
|---|-----------|-----------|--------|
| 1 | Follow-up en cadena | Funciona sin cambios | Ninguna |
| 2 | Follow-up requiere tool diferente | Router maneja | Ninguna |
| 3 | Follow-up ambiguo | LLM interpreta | Ninguna |
| 4 | Follow-up sin passthrough previo | Flujo normal | Ninguna |
| 5 | Cache viejo sin raw_data | Degrada a reply completo | Aceptable |
| 6 | Follow-up despues de error T1 | Synthesis parcial | Aceptable |
| 7 | Concurrencia | MCP call redundante | Pre-computacion resuelve |

**Veredicto ciclo 3:** Aprobado. Todos los edge cases tienen comportamiento aceptable.

---

## Ciclo 4 -- Rendimiento y Metricas

### Codeforces Grandmaster #4

Analisis de latencia para cada flujo de follow-up:

**Flujo A: Follow-up con cache hit (caso comun)**
```
Preprocessor:     ~0ms
Router LLM:       ~750ms (todavia necesita clasificar la pregunta)
Cache lookup:     ~5ms
Synthesis LLM:    ~1000-1500ms
Total:            ~1.8-2.3s
```

**Flujo B: Follow-up sin cache (primera vez)**
```
Preprocessor:     ~0ms
Router LLM:       ~750ms
MCP call:         ~200ms
Skip passthrough: ~0ms
Synthesis LLM:    ~1000-1500ms
Total:            ~2.0-2.5s
```

**Comparacion con estado actual (bug):**
```
Cache hit directo: ~0.8s (pero devuelve perfil completo — INCORRECTO)
Sin cache:         ~0.7s (passthrough repite perfil — INCORRECTO)
```

Estamos intercambiando ~1-1.5s de latencia adicional por una respuesta CORRECTA. Esto es aceptable. Mejor una respuesta correcta en 2.3s que una incorrecta en 0.8s.

### Codeforces Grandmaster #5

Podemos optimizar eliminando la llamada al LLM router en follow-ups cuando el entity_context ya tiene suficiente informacion:

```python
# Si intent == "followup" y entity_context tiene candidato + last_tool:
# → Saltear router LLM → usar last_tool con mismos args → cache hit → synthesis
# Ahorro: ~750ms (router LLM)
```

Pero esto es peligroso: el usuario podria hacer un follow-up que requiera una tool diferente (edge case 2). El router es necesario para clasificar correctamente.

**Alternativa segura:** fast-route para follow-ups con patron regex conocido:

```python
FOLLOWUP_SAME_TOOL_PATTERNS = [
    r"^y\s+(cuanto|que\s+tanto)\s+(gana|declara|tiene)",      # patrimonio
    r"^y\s+(sus\s+)?antecedentes",                             # antecedentes
    r"^(tiene|tuvo)\s+(procesos|denuncias|sentencias)",        # antecedentes
    r"^y\s+(su\s+)?(formacion|educacion|estudios)",            # educacion
    r"^y\s+(de\s+que|cual)\s+partido",                         # partido
]
```

Si match → skip router, usar last_tool. Ahorro: ~750ms.
Si no match → router normal.

### Senior MLE #2

El Grandmaster #5 tiene un punto valido pero debemos medir cuantos follow-ups caen en esos patrones antes de implementar. Sugiero:

1. Implementar la solucion base (ciclo 2) PRIMERO
2. Agregar logging de follow-ups: `logger.info("[FOLLOWUP] intent=followup, question=%s, last_tool=%s", message, last_tool)`
3. Despues de 1 dia en produccion, analizar logs para ver patrones comunes
4. Si >70% de follow-ups matchean patrones simples, implementar fast-routes

### Delivery Lead

Desde la perspectiva del usuario:

1. **Latencia de 2.3s para follow-ups es ACEPTABLE.** El usuario ya vio el perfil completo (~0.7s). Esperar 2s para una respuesta enfocada es razonable. Nadie se queja de 2s.

2. **La alternativa (repetir perfil completo) es INACEPTABLE.** El usuario dijo "y cuanto gana?" y recibio 2 paginas de texto. Esto rompe la confianza en el chatbot. Es la experiencia de "este bot no me entiende".

3. **Prioridad absoluta:** Implementar la solucion base. Las optimizaciones de latencia (fast-routes para follow-ups) pueden esperar.

4. **Metrica de exito:** % de follow-ups que reciben respuesta enfocada vs perfil completo. Target: >95%.

### Stakeholder

Como usuario final: si pregunto "y cuanto gana?" y me repiten todo el CV, cierro el chat. Si me dicen especificamente "Keiko Fujimori declaro ingresos por S/ 120,000 anuales y posee 2 bienes inmuebles valorados en..." → confio en el sistema y sigo preguntando.

La demora de 2s es invisible comparada con la frustracion de una respuesta irrelevante.

Apruebo la solucion base sin fast-routes de follow-up por ahora.

### AI Tech Lead

**Veredicto ciclo 4:** Aprobado.

- Solucion base: +1.5s latencia por respuesta correcta → tradeoff aceptable
- Fast-routes para follow-ups: diferido a post-implementacion con datos reales
- Logging de follow-ups: obligatorio para medir impacto

---

## Ciclo 5 -- Plan de Implementacion y Riesgos

### Senior MLE #1

**Cambios ordenados por archivo:**

#### 1. `infovoto-gateway/src/agent/core.py`

```python
# A. _set_tool_cache: agregar parametro raw_data
async def _set_tool_cache(self, tool_name, tool_args, reply, raw_data=None, sources=None):
    payload = {
        "reply": reply,
        "raw_data": raw_data,
        "sources": [s.model_dump() for s in sources] if sources else None,
    }

# B. Bloque despues de tool_cache_hit check (~linea 1077):
if tool_cache_hit:
    if intent.intent == "followup" and _tc_cached.get("raw_data"):
        tool_cache_hit = False
        tool_results = {_tc_name: _tc_cached["raw_data"]}
        logger.info("[FOLLOWUP-CACHE] using raw_data for synthesis: %s", _tc_name)
    # else: usar reply cacheado (sin cambios)

# C. Bloque passthrough (~linea 1092):
elif len(tool_results) == 1 and _has_preformatted_content(tool_results):
    if intent.intent != "followup":
        name, data = next(iter(tool_results.items()))
        reply_text = _build_passthrough_reply(data)
        logger.info("[PASSTHROUGH] %s → reply_len=%d", name, len(reply_text))
    else:
        logger.info("[FOLLOWUP-SKIP-PT] skipping passthrough for follow-up, will synthesize")

# D. Tool+args cache write (~linea 1166):
if reply_text and not tool_cache_hit and len(valid_calls) == 1:
    _tc_name = valid_calls[0]["name"]
    _tc_args = valid_calls[0].get("args", {})
    _raw = next(iter(tool_results.values())) if tool_results else None

    if intent.intent != "followup" or not await self._get_tool_cache(_tc_name, _tc_args):
        # No sobreescribir cache con reply de follow-up si ya existe
        if _has_preformatted_content(tool_results or {}):
            _pt_reply = _build_passthrough_reply(next(iter(tool_results.values())))
            asyncio.create_task(self._set_tool_cache(
                _tc_name, _tc_args, reply=_pt_reply, raw_data=_raw, sources=sources
            ))
        else:
            asyncio.create_task(self._set_tool_cache(
                _tc_name, _tc_args, reply=reply_text, raw_data=_raw, sources=sources
            ))
```

#### 2. Sin cambios en otros archivos

La solucion es 100% en `core.py`. No requiere cambios en router, preprocessor, ni MCP.

### Senior MLE #3

Sobre el bloque D: hay un `await self._get_tool_cache` que es una llamada a Redis. Esto agrega ~5ms de latencia para verificar si ya existe cache antes de escribir. En el happy path (no es follow-up), es innecesario.

Simplifiquemos:

```python
# D simplificado:
if reply_text and len(valid_calls) == 1:
    _tc_name = valid_calls[0]["name"]
    _tc_args = valid_calls[0].get("args", {})
    _raw = next(iter(tool_results.values())) if tool_results else None

    # Follow-ups no sobreescriben cache
    if intent.intent == "followup":
        pass  # No cachear reply de follow-up
    elif not tool_cache_hit:
        # Query normal: escribir cache como siempre, ahora con raw_data
        _cache_reply = reply_text
        if _has_preformatted_content(tool_results or {}):
            _cache_reply = _build_passthrough_reply(next(iter(tool_results.values())))
        asyncio.create_task(self._set_tool_cache(
            _tc_name, _tc_args, reply=_cache_reply, raw_data=_raw, sources=sources
        ))
```

Mas limpio: follow-ups nunca escriben cache. Queries normales escriben siempre. Sin Redis extra call.

### Senior MLE #4

Pero hay un problema: si el follow-up es la primera interaccion con ese candidato (no hay cache previo), nunca se escribe el raw_data. El siguiente follow-up no tendra raw_data disponible.

Solucion: para follow-ups SIN cache previo, escribir SOLO raw_data + passthrough reply (no el reply sintetizado):

```python
if intent.intent == "followup":
    if not tool_cache_hit and _raw and _has_preformatted_content({_tc_name: _raw}):
        # Primera vez: guardar para futuros follow-ups y queries directas
        _pt_reply = _build_passthrough_reply(_raw)
        asyncio.create_task(self._set_tool_cache(
            _tc_name, _tc_args, reply=_pt_reply, raw_data=_raw, sources=sources
        ))
elif not tool_cache_hit:
    # Query normal: guardar como siempre
    ...
```

### Senior MLE #5

Correcto. Con esta logica:

| Escenario | Cache write | reply guardado | raw_data guardado |
|-----------|-------------|---------------|-------------------|
| Query normal, passthrough | Si | Perfil completo (passthrough) | JSON raw |
| Query normal, synthesis | Si | Reply sintetizado | JSON raw |
| Follow-up con cache hit | No | (ya existe) | (ya existe) |
| Follow-up sin cache | Si | Perfil completo (passthrough) | JSON raw |

Perfecto. El cache siempre tiene el reply del passthrough (no del follow-up) y el raw_data.

### Junior MLE #1

Test cases que necesitamos:

```python
# test_followup_passthrough.py

async def test_followup_uses_raw_data_from_cache():
    """T1: perfil completo. T2: follow-up usa raw_data para synthesis."""

async def test_followup_skips_passthrough():
    """T1: perfil completo. T2: MCP call con _resumen_markdown skips passthrough."""

async def test_followup_does_not_overwrite_cache():
    """T1: cache write. T2: follow-up no sobreescribe reply en cache."""

async def test_followup_without_prior_cache_writes_passthrough():
    """T2 sin T1: follow-up escribe cache con passthrough reply, no synthesis reply."""

async def test_non_followup_gets_cached_reply():
    """Dos queries identicas, no follow-up: segunda usa reply cacheado."""

async def test_old_cache_without_raw_data_degrades():
    """Cache entry sin raw_data: follow-up devuelve reply completo (degradacion)."""
```

### Junior MLE #2

Duda: como detectamos si `intent.intent == "followup"` de forma confiable?

Revisando `preprocessor.py`: NO hay clasificacion de intent como "followup". El preprocessor solo clasifica `instant_reply`, `fast_route`, y deja todo lo demas al router.

La linea en `core.py` que verifica `intent.intent != "followup"` (linea ~799) se refiere a un campo que... no parece existir en el preprocessor actual.

### Senior MLE #1

Buen catch. Revisemos. El preprocessor retorna `IntentResult` con campos como `intent`, `enriched_message`, `resolved_entities`, etc.

La clasificacion de follow-up probablemente la hace el LLM router, no el preprocessor. El preprocessor solo hereda entity_context.

Necesitamos un mecanismo para detectar follow-ups. Opciones:

1. **Heuristico en preprocessor:** mensaje corto (<5 palabras) + entity_context con last_tool → marcar como follow-up
2. **El router LLM clasifica:** ya lo hace implicitamente al decidir la tool
3. **Deteccion en core.py:** verificar entity_context.last_tool + longitud del mensaje

Opcion 3 es la mas simple y no requiere cambios en preprocessor:

```python
is_followup = bool(
    save_entities.get("last_tool")
    and len(message.split()) < 8
    and not intent.resolved_entities.get("dni")  # No es nueva entidad
)
```

### Junior MLE #3

Pero eso es fragil. "y cuanto gana keiko fujimori en su declaracion jurada anual?" tiene 10 palabras y ES un follow-up (misma entidad). "keiko gana?" tiene 2 palabras y NO es follow-up si es el primer turno (sin entity_context).

Mejor usar SOLO la presencia de `entity_context.last_tool` como senal:

```python
is_followup = bool(save_entities.get("last_tool"))
```

Si hay un `last_tool`, el usuario tuvo una interaccion previa con una tool. Cualquier query subsiguiente sobre la misma entidad es potencialmente un follow-up.

El riesgo de false positives es bajo: si el usuario pregunta algo completamente nuevo pero tiene entity_context, el router llamara una tool diferente con args diferentes → cache miss → flujo normal.

### AI Tech Lead

**Veredicto ciclo 5:** Aprobado con las siguientes decisiones finales:

1. **Deteccion de follow-up:** `is_followup = bool(save_entities.get("last_tool"))` — simple, robusto
2. **Cache unificado:** `{reply, raw_data, sources}` — sin duplicacion
3. **Follow-ups no sobreescriben cache** (excepto primera vez: escriben passthrough reply + raw_data)
4. **Sin fast-routes de follow-up** por ahora — diferido a post-implementacion
5. **Logging obligatorio:** `[FOLLOWUP-CACHE]` y `[FOLLOWUP-SKIP-PT]`
6. **Tests:** 6 test cases minimos

---

## Resumen de Cambios Acordados

### Archivo: `infovoto-gateway/src/agent/core.py`

| Seccion | Cambio | Linea aprox |
|---------|--------|-------------|
| `_set_tool_cache` | Agregar parametro `raw_data` al payload | ~724 |
| Post cache-hit check | Si `is_followup` + cache tiene `raw_data` → reset cache hit, usar raw_data como tool_results | ~1077 |
| Passthrough block | Skip passthrough si `is_followup` | ~1092 |
| Cache write block | Follow-ups sin cache previo escriben passthrough reply. Follow-ups con cache previo no escriben. | ~1166 |

### Archivos sin cambios

- `router.py` — sin cambios (ya inyecta entity_context)
- `preprocessor.py` — sin cambios (ya hereda entity_context)
- `infovoto-mcp/` — sin cambios (ya retorna raw JSON + `_resumen_markdown`)

### Diagrama de flujo final

```
[Follow-up detected: is_followup = bool(entity_context.last_tool)]

                                   ┌── raw_data existe ──→ tool_results = raw_data
                                   │                        skip passthrough
  tool+args cache HIT ─────────────┤                        → LLM SYNTHESIS (enfocada)
                                   │                        latencia: ~2s
                                   └── raw_data None ──→ reply directo (degradacion)
                                                          latencia: ~0.8s

  tool+args cache MISS ──→ MCP call ──→ JSON con _resumen_markdown
                                         │
                                         └── is_followup → skip passthrough
                                              → LLM SYNTHESIS (enfocada)
                                              → cache write: passthrough_reply + raw_data
                                              latencia: ~2.5s
```

### Metricas de exito

| Metrica | Target | Medicion |
|---------|--------|----------|
| % follow-ups con respuesta enfocada | >95% | Log `[FOLLOWUP-CACHE]` + `[FOLLOWUP-SKIP-PT]` |
| Latencia follow-up con cache | <2.5s | Log timestamps |
| Latencia follow-up sin cache | <3.0s | Log timestamps |
| False positives (is_followup incorrecto) | <5% | Revision manual de logs |
| Cache contaminacion (reply sobreescrito) | 0% | Test unitario |

---

## VEREDICTO

**APROBADO POR UNANIMIDAD (20/20 votos)**

### Decision

Implementar **cache unificado con raw_data + skip passthrough para follow-ups** en `core.py`. La deteccion de follow-up se basa en `entity_context.last_tool` existente. El synthesizer LLM extrae la seccion relevante del JSON completo. Follow-ups nunca sobreescriben el cache existente.

### Justificacion

1. **Correctitud sobre velocidad:** +1.5s de latencia es un precio minimo por respuestas enfocadas en lugar de repetir perfiles completos.
2. **Impacto en UX:** Pasar de "repito todo tu CV" a "te respondo exactamente lo que preguntaste" es la diferencia entre un chatbot inutil y uno util.
3. **Complejidad minima:** ~30 lineas de cambios en un solo archivo. Sin cambios en MCP, router, ni preprocessor.
4. **Compatibilidad backward:** Cache entries sin `raw_data` degradan al comportamiento actual. Zero downtime.
5. **Extensibilidad:** El `raw_data` en cache habilita futuras optimizaciones (fast-routes de follow-up, extraction de secciones especificas) sin cambios arquitecturales.

### Riesgos aceptados

| Riesgo | Probabilidad | Mitigacion |
|--------|-------------|------------|
| False positive is_followup | Baja | Router llama tool diferente → cache miss → flujo normal |
| LLM synthesis no extrae bien la seccion | Baja | gemini-2.0-flash es excelente en extraction de JSON |
| Latencia >3s en follow-ups | Media | Pre-computacion (debate 07) elimina MCP call |

### Proximos pasos

1. Implementar cambios en `core.py` (estimado: 1-2 horas)
2. Escribir 6 test cases
3. Deploy a staging y test manual con flujos: "info de keiko" → "y cuanto gana?" → "y sus antecedentes?"
4. Monitorear logs `[FOLLOWUP-*]` durante 24 horas
5. Decidir si implementar fast-routes para follow-ups (debate futuro, con datos reales)
