# Debate 04: Optimizacion de Datos MCP -- Como Reducir Tokens sin Perder Info

**Fecha:** 2026-04-02
**Estado:** CERRADO
**Tema:** El perfil JSON de candidatos consume ~3200 tokens. El gateway trunca brutalmente con `_safe_json_stringify()` (corta strings >200 chars, elimina items de listas >5). `_smart_truncate_tool_result()` solo maneja comparaciones, NO perfiles. Necesitamos reducir tokens sin perder informacion relevante para el votante.

---

## Contexto Tecnico

### Estructura actual del perfil (ejemplo: Keiko Fujimori)

```json
{
  "dni": "10001234",
  "nombre_completo": "KEIKO SOFIA FUJIMORI HIGUCHI",
  "cargo": "presidente",
  "partido": "Fuerza Popular",
  "region": "Distrito Unico",
  "posicion_lista": 1,
  "sexo": "F",
  "fecha_nacimiento": "1975-05-25",
  "educacion": [...],
  "experiencia_laboral": [...],
  "patrimonio": {...},
  "situacion_legal": {
    "sentencias_penales": [...10+ entries...],
    "sentencias_obligaciones": [...]
  },
  "hechos_relevantes": [...5 entries, 300 chars c/u...],
  "resumen_bio": "...",
  "bio_curada": "...",
  "posiciones_politicas": [...20 temas...],
  "_fuente": "...",
  "_fuente_posiciones": "...",
  "_candidate": {...},
  "_resumen_markdown": "..."
}
```

### Conteo de tokens por seccion (estimado, Keiko Fujimori)

| Seccion | Tokens aprox | Chars aprox | Notas |
|---------|-------------|-------------|-------|
| Datos basicos (nombre, cargo, partido, region, sexo, fecha) | ~80 | ~300 | Compresible |
| `educacion` (3-5 entries) | ~150 | ~500 | Ya limitado a query |
| `experiencia_laboral` (5 entries, LIMIT 5 en query) | ~200 | ~700 | Ya limitado |
| `patrimonio` (4 campos) | ~60 | ~200 | Compacto |
| `situacion_legal.sentencias_penales` (10+ entries) | ~1500 | ~5000 | SIN LIMITE -- mayor problema |
| `situacion_legal.sentencias_obligaciones` | ~50 | ~150 | Menor |
| `hechos_relevantes` (5 entries, 300 chars c/u) | ~400 | ~1500 | Limite de 300 chars ya aplicado |
| `resumen_bio` | ~80 | ~300 | Variable |
| `bio_curada` | ~120 | ~400 | Variable |
| `posiciones_politicas` (20 temas) | ~350 | ~1200 | 20 temas fijos de Decide.pe |
| `_resumen_markdown` | ~400 | ~1500 | DUPLICADO del contenido anterior |
| `_candidate` (metadata frontend) | ~80 | ~300 | Solo para frontend |
| `_fuente`, `_fuente_posiciones` | ~30 | ~100 | Metadata |
| **TOTAL** | **~3500** | **~12000** | Excede MAX_TOOL_RESULT_CHARS=6000 |

### Flujo actual de truncamiento en gateway

```
MCP retorna JSON completo (~12000 chars)
    |
    v
_smart_truncate_tool_result()  -- NO-OP para perfiles (solo maneja comparaciones)
    |
    v
_safe_json_stringify(data, max_chars=6000)
    |
    v
  if len > 6000:
    - dict? -> trunca strings >200 chars, corta listas a 5 items
    - list? -> pop() items del final
    - else? -> corta a 6000 chars
```

**Problema critico:** `_safe_json_stringify` no entiende la estructura del perfil. Puede cortar `descripcion` de antecedentes penales (la info mas relevante) o eliminar posiciones politicas (de 20 a 5), que son exactamente lo que los votantes quieren saber.

### Flujo passthrough existente

El MCP ya genera `_resumen_markdown` con `_format_profile_markdown()` y el gateway lo usa como passthrough cuando detecta ese campo. **Pero** el JSON completo tambien se pasa al LLM en `context_block` cuando se encadenan herramientas o se necesita responder preguntas de seguimiento.

---

## Roles del Debate

| Rol | Persona |
|-----|---------|
| **Codeforces Grandmaster** | Optimizacion algoritmica, complejidad, estructuras de datos |
| **Senior AI Engineer** | Tokens, context window, prompt engineering |
| **Senior MLE** | Arquitectura de datos, pipelines ML |
| **Junior MLE** | Testing, edge cases, preguntas incomodas |
| **Junior Full Stack** | Frontend, UX, como se muestra al usuario |
| **AI Tech Lead** | Arquitectura global, integracion gateway-MCP |
| **Full Stack Lead** | API design, contratos, backward compatibility |
| **Delivery Lead** | UX, stakeholders, tiempos, usuario final |
| **Staff Engineer** | Escalabilidad, mantenimiento, deuda tecnica |
| **Product Manager** | Valor para el votante, prioridades, MVP |

---

## Ciclo 1: Diagnostico -- Que campos importan al votante?

**Product Manager:** Antes de optimizar, necesitamos entender QUE informacion es critica para la decision de voto. Propongo clasificar cada campo por valor para el votante:

| Prioridad | Campo | Razon |
|-----------|-------|-------|
| P0 (critico) | nombre, cargo, partido | Identidad basica |
| P0 (critico) | situacion_legal / sentencias_penales | Transparencia, corrupcion es tema #1 en Peru |
| P0 (critico) | posiciones_politicas | Alineamiento ideologico del votante |
| P1 (importante) | educacion | Preparacion del candidato |
| P1 (importante) | experiencia_laboral | Trayectoria |
| P1 (importante) | patrimonio | Transparencia financiera |
| P2 (contextual) | hechos_relevantes | Noticias, pero ya hay resumen_bio |
| P2 (contextual) | bio_curada / resumen_bio | Narrativa, pero duplica otros campos |
| P3 (interno) | _resumen_markdown | Passthrough -- no deberia ir al LLM |
| P3 (interno) | _candidate, _fuente | Metadata frontend/auditoria |

**Delivery Lead:** Coincido. En Peru, las preguntas mas frecuentes sobre candidatos son: (1) antecedentes penales, (2) posiciones en temas como pena de muerte o aborto, (3) patrimonio sospechoso. Si truncamos justo esos campos, fallamos al usuario.

**Veredicto Ciclo 1:** :white_check_mark: Aprobado -- La clasificacion P0/P1/P2/P3 es correcta. Cualquier solucion debe preservar integramente P0 y P1.

---

## Ciclo 2: Analisis del problema real -- Donde se pierden tokens?

**Codeforces Grandmaster:** Hagamos el analisis preciso. El JSON tiene 12000 chars pero MAX_TOOL_RESULT_CHARS=6000. Necesitamos cortar 6000 chars. Donde estan?

```
situacion_legal.sentencias_penales:  ~5000 chars (41% del total)  -- SIN LIMITE
_resumen_markdown:                   ~1500 chars (12% del total)  -- DUPLICADO
posiciones_politicas:                ~1200 chars (10% del total)  -- 20 entries
hechos_relevantes:                   ~1500 chars (12% del total)  -- 5 * 300 chars
bio_curada + resumen_bio:             ~700 chars  (6% del total)  -- redundantes entre si
educacion + experiencia:             ~1200 chars (10% del total)  -- ya limitados
patrimonio + datos basicos:           ~500 chars  (4% del total)  -- compactos
_candidate + _fuente:                 ~400 chars  (3% del total)  -- metadata
```

**Senior AI Engineer:** El dato clave: `_resumen_markdown` es 1500 chars que SON DUPLICADO del contenido que ya esta en los campos individuales. Si el gateway usa passthrough para mostrar el perfil directamente, el JSON que va al LLM como context NO necesita `_resumen_markdown`.

**Junior MLE:** Esperen. Si elimino `_resumen_markdown` del context que va al LLM, pero lo mantengo en el response para passthrough, ahorro 1500 chars inmediatamente. Eso es trivial y no pierde nada.

**AI Tech Lead:** Correcto, pero eso solo nos baja de 12000 a 10500. Seguimos 4500 chars por encima del limite. El problema de fondo son los antecedentes sin limite.

**Veredicto Ciclo 2:** :white_check_mark: Aprobado -- El 41% del payload son sentencias_penales sin limite. Eliminar `_resumen_markdown` del contexto LLM es quick win (-1500 chars), pero insuficiente.

---

## Ciclo 3: Propuesta A -- Limitar en el MCP (source)

**Senior MLE:** Propongo limitar en `_assemble_profile_dict()` del MCP directamente:

```python
# Actual: sin limite para ant_rows
ant_rows = (await session.execute(
    select(AntecedentePenal).where(...)
)).scalars().all()  # ALL -- sin limite

# Propuesta: top 5 por relevancia
ant_rows = (await session.execute(
    select(AntecedentePenal)
    .where(AntecedentePenal.candidato_dni == dni)
    .order_by(AntecedentePenal.fecha.desc().nullslast())
    .limit(5)
)).scalars().all()
```

Tambien limitar `descripcion` de antecedentes a 200 chars (igual que hechos_relevantes tiene 300).

**Staff Engineer:** Me preocupa la perdida de informacion en el source. Si el MCP limita a 5 antecedentes, y un candidato tiene 12, perdemos 7 en TODOS los contextos. Que pasa si manana necesitamos esos datos para un reporte completo o un tool diferente?

**Junior Full Stack:** El frontend tambien consume el MCP directamente? O siempre pasa por el gateway?

**AI Tech Lead:** Siempre pasa por el gateway. El MCP es interno. Pero el Staff Engineer tiene razon: limitar en el source es una decision irreversible para todos los consumidores. Mejor limitar en el gateway, que es quien tiene la restriccion de tokens.

**Full Stack Lead:** Hay un punto medio: el MCP puede recibir un parametro `compact=true` que devuelve version reducida, sin romper el API default.

**Veredicto Ciclo 3:** :arrows_counterclockwise: Necesita cambios -- No limitar en el MCP sin parametro explícito. La version completa debe seguir disponible.

---

## Ciclo 4: Propuesta B -- Smart truncate para perfiles en gateway

**AI Tech Lead:** Propongo extender `_smart_truncate_tool_result()` para manejar perfiles:

```python
def _smart_truncate_tool_result(data):
    # ... existing comparacion logic ...

    # Profile optimization: remove LLM-irrelevant fields
    if isinstance(data, dict) and "_resumen_markdown" in data:
        # 1. Remove duplicate/internal fields
        for key in ("_resumen_markdown", "_candidate", "_fuente", "_fuente_posiciones"):
            data.pop(key, None)

        # 2. Limit sentencias_penales
        legal = data.get("situacion_legal", {})
        sents = legal.get("sentencias_penales", [])
        if len(sents) > 5:
            legal["sentencias_penales"] = sents[:5]
            legal["_nota"] = f"Mostrando 5 de {len(sents)} registros"

        # 3. Truncate descriptions in sentencias
        for s in legal.get("sentencias_penales", []):
            desc = s.get("descripcion", "")
            if len(desc) > 200:
                s["descripcion"] = desc[:200] + "..."

        # 4. Limit posiciones to top 10 most polarized
        pos = data.get("posiciones_politicas", [])
        if len(pos) > 10:
            pos.sort(key=lambda p: abs(p.get("score", 0.5) - 0.5), reverse=True)
            data["posiciones_politicas"] = pos[:10]

        # 5. Remove bio_curada if resumen_bio exists (redundant)
        if "resumen_bio" in data and "bio_curada" in data:
            del data["bio_curada"]

    return data
```

**Codeforces Grandmaster:** Analicemos la reduccion:

```
Eliminados:
  _resumen_markdown:    -1500 chars
  _candidate:            -300 chars
  _fuente (2 campos):    -100 chars
  bio_curada:            -400 chars
Truncados:
  sentencias (10->5):   -2500 chars
  descripciones (200):   -500 chars (estimado)
  posiciones (20->10):   -600 chars
                        -----------
  Total reduccion:      ~-5900 chars
  Nuevo total:          ~6100 chars (apenas sobre el limite)
```

**Junior MLE:** Eso es casi exacto al limite de 6000. Cualquier candidato con mas texto que Keiko se va a pasar. No es robusto.

**Senior AI Engineer:** Ademas, cortar posiciones a 10 pierde contexto. Un usuario que pregunta "que opina X sobre educacion?" y justo ese tema esta en la posicion 15... no lo ve.

**Veredicto Ciclo 4:** :arrows_counterclockwise: Necesita cambios -- La reduccion es insuficiente y fragil. Depende demasiado de "justo caber" en 6000 chars.

---

## Ciclo 5: Propuesta C -- Separar perfil base de detalle bajo demanda

**Staff Engineer:** El problema de fondo es que metemos TODA la informacion en UNA sola llamada. Propongo un patron split:

1. `buscar_candidato_por_dni` retorna perfil BASE (~3000 chars):
   - datos basicos, educacion (top 3), experiencia (top 3), patrimonio
   - conteos: "tiene 12 antecedentes", "20 posiciones politicas"
   - resumen_bio (narrativa corta)

2. Herramientas de detalle (ya existen parcialmente):
   - `verificar_antecedentes(dni)` -- ya existe, retorna antecedentes completos
   - `consultar_posiciones(dni)` -- NUEVA, retorna las 20 posiciones
   - hechos_relevantes se incluyen en el perfil base (son pocos)

**Senior AI Engineer:** Esto es elegante. El LLM recibe el perfil base (~3000 chars, ~750 tokens), ve los conteos, y decide si necesita mas detalle. Si el usuario pregunta "antecedentes de Keiko", el router ya llama `verificar_antecedentes` directamente.

**Product Manager:** Me preocupa la latencia. Si el usuario dice "cuentame todo sobre Keiko", necesitariamos 3 tool calls en secuencia?

**AI Tech Lead:** No necesariamente. El gateway ya tiene passthrough con `_resumen_markdown` que muestra un resumen con los datos mas relevantes de cada seccion. Solo si el usuario pide MAS detalle (e.g., "cuentame mas de sus antecedentes"), el agente hace la segunda llamada.

**Junior Full Stack:** Pero hoy `verificar_antecedentes` tambien retorna TODOS los antecedentes sin limite. Tendriamos el mismo problema ahi.

**Veredicto Ciclo 5:** :arrows_counterclockwise: Necesita cambios -- Buena direccion, pero requiere: (1) limitar antecedentes en verificar_antecedentes tambien, (2) no agregar latencia al caso comun.

---

## Ciclo 6: Propuesta D -- Hibrido: Optimizar JSON + Smart Truncate perfiles

**Full Stack Lead:** Combinemos lo mejor de B y C sin la complejidad de separar herramientas:

### Paso 1: Optimizar el JSON del MCP (no rompe API)

```python
# En _assemble_profile_dict():

# Limitar sentencias a 5 con nota
if len(ant_rows) > 5:
    response["situacion_legal"]["_total_registros"] = len(ant_rows)
    ant_rows = sorted(ant_rows, key=lambda a: a.fecha or datetime.min, reverse=True)[:5]

# Truncar descripcion de antecedentes a 200 chars (como hechos_relevantes tiene 300)
"descripcion": (a.resumen or a.descripcion or "")[:200]

# Posiciones: ya son compactas (~60 chars c/u), mantener las 20
```

### Paso 2: Smart truncate en gateway para perfiles

```python
# En _smart_truncate_tool_result():
if isinstance(data, dict) and "_resumen_markdown" in data:
    # Eliminar campos que no van al LLM
    for key in ("_resumen_markdown", "_candidate", "_fuente", "_fuente_posiciones"):
        data.pop(key, None)
    # Eliminar bio_curada si resumen_bio existe
    if "resumen_bio" in data and "bio_curada" in data:
        del data["bio_curada"]
```

### Resultado esperado

```
ANTES:                              DESPUES:
sentencias:    5000 chars           sentencias (5, desc 200): ~1500 chars
_resumen_md:   1500 chars           eliminado:                    0 chars
_candidate:     300 chars           eliminado:                    0 chars
bio_curada:     400 chars           eliminado:                    0 chars
posiciones:    1200 chars           posiciones (20):           1200 chars
hechos:        1500 chars           hechos (5, desc 300):      1500 chars
educacion:      500 chars           educacion:                  500 chars
experiencia:    700 chars           experiencia:                700 chars
patrimonio:     200 chars           patrimonio:                 200 chars
basicos:        300 chars           basicos:                    300 chars
bio:            300 chars           resumen_bio:                300 chars
fuentes:        100 chars           eliminado:                    0 chars
                -----                                           -----
TOTAL:        ~12000 chars          TOTAL:                    ~6200 chars
```

**Codeforces Grandmaster:** 6200 chars. Seguimos sobre el limite de 6000. Necesitamos 200 chars mas.

**Senior AI Engineer:** Podemos subir MAX_TOOL_RESULT_CHARS a 7000. La razon original de 6000 era ~1500 tokens. Con 7000 serian ~1750 tokens. Para Gemini 2.0 Flash con 1M de context, eso es irrelevante. El verdadero costo es latencia de inferencia, y la diferencia entre 1500 y 1750 tokens de input es negligible.

**AI Tech Lead:** No me gusta mover el limite para que "quepa". Es una solucion fragil. Pero el punto del Senior AI Engineer es valido: 6000 fue arbitrario. Con el passthrough de perfiles (que NO pasa por el LLM), el JSON solo va al LLM en follow-up questions. Y ahi 1750 tokens de contexto es perfectamente aceptable.

**Veredicto Ciclo 6:** :white_check_mark: Aprobado con condiciones -- El hibrido es solido. Falta definir el nuevo MAX_TOOL_RESULT_CHARS y confirmar que 5 antecedentes son suficientes.

---

## Ciclo 7: Cuantos antecedentes son suficientes?

**Product Manager:** Necesito data real. Cuantos antecedentes tiene cada candidato presidencial?

**Senior MLE:** Basado en los datos del scraper:

| Candidato | Antecedentes penales | Sentencias/obligaciones |
|-----------|---------------------|------------------------|
| Keiko Fujimori | 12 | 0 |
| Antauro Humala | 8 | 1 |
| Rafael Lopez Aliaga | 4 | 2 |
| Candidato promedio | 1-2 | 0-1 |
| Candidatos sin antecedentes | ~60% | ~80% |

**Delivery Lead:** Los candidatos con MAS antecedentes son justamente los mas consultados. Si limitamos a 5 y Keiko tiene 12, perdemos 7. El votante que pregunta "que antecedentes tiene Keiko?" merece ver todos.

**Staff Engineer:** Pero "todos" en el contexto del LLM no significa que el usuario los ve todos. El LLM ya sintetiza y resume. Si le damos 5 de los 12 mas recientes, el LLM puede decir "tiene 12 registros, los mas recientes son..." y eso es honesto e informativo.

**Junior MLE:** Podemos agregar un campo `_total_antecedentes: 12` para que el LLM sepa que hay mas y pueda mencionarlo. El usuario siempre puede preguntar "cuentame mas" y ahi el agente llama `verificar_antecedentes` con la lista completa.

**Codeforces Grandmaster:** Analisis de costo-beneficio:

```
5 antecedentes * ~250 chars c/u (con desc truncada) = 1250 chars (~310 tokens)
12 antecedentes * ~250 chars c/u = 3000 chars (~750 tokens)

Diferencia: 1750 chars (~440 tokens)
Costo Gemini 2.0 Flash: ~$0.0001 por 440 tokens input
Llamadas/dia estimadas: ~500
Costo diario de mantener 12: ~$0.05/dia = $1.50/mes
```

**Senior AI Engineer:** El costo monetario es irrelevante. Lo que importa es la calidad de la respuesta. Con 5 antecedentes + `_total`, el LLM tiene suficiente contexto para responder bien el 95% de las preguntas. Para el 5% que quiere el listado completo, existe `verificar_antecedentes`.

**Veredicto Ciclo 7:** :white_check_mark: Aprobado -- Limitar a 5 antecedentes con `_total_antecedentes` es correcto. Ordenar por fecha DESC para mostrar los mas recientes.

---

## Ciclo 8: Posiciones politicas -- Mantener 20 o reducir?

**Product Manager:** Las 20 posiciones de Decide.pe son: pena de muerte, aborto, union civil, cannabis medicinal, cannabis recreativa, eutanasia, enfoque de genero, cuotas de genero, mineria, fracking, transgénicos, privatizacion, AFP privada, sueldo minimo, impuesto a riqueza, negociacion colectiva, voto voluntario, reeleccion, inmunidad parlamentaria, bicameralidad.

Todas son relevantes. Pero no todas son igualmente consultadas.

**Delivery Lead:** Basado en las 500 sesiones de eval, los temas mas preguntados son:
1. Pena de muerte (~18% de preguntas de posiciones)
2. Union civil (~15%)
3. Aborto (~12%)
4. Cannabis (~10%)
5. Impuestos (~8%)

El top 10 cubre ~85% de las preguntas.

**Senior AI Engineer:** Cada posicion es ~60 chars: `{"tema": "Pena de muerte", "posicion": "A favor", "score": 1.0}`. Las 20 son ~1200 chars (~300 tokens). Si cortamos a 10, ahorramos ~600 chars (~150 tokens).

**Codeforces Grandmaster:** 150 tokens de ahorro vs perder el 15% de preguntas que caen en temas 11-20. El ratio beneficio/costo es malo. Mantener las 20.

**Junior MLE:** Ademas, las posiciones ya son el campo mas compacto por unidad de informacion. Cada posicion es 3 campos (tema, posicion, score). No hay texto largo que truncar.

**Staff Engineer:** Hay otra optimizacion: el campo `score` es redundante con `posicion` (que ya dice "A favor"/"En contra"/"Neutral"). Eliminando `score` de cada posicion ahorramos ~200 chars sin perder info visible.

**AI Tech Lead:** Buen punto. El `score` es util para la logica de ordenamiento en Propuesta B (ordenar por polarizacion), pero si mantenemos las 20, no necesitamos ordenar. Podemos eliminar `score` del JSON que va al LLM.

**Veredicto Ciclo 8:** :white_check_mark: Aprobado -- Mantener las 20 posiciones. Eliminar `score` del output (queda solo `tema` + `posicion`). Ahorro: ~200 chars.

---

## Ciclo 9: Implementacion final -- Plan de cambios

**AI Tech Lead:** Consolidemos todo en un plan de implementacion ordenado:

### Cambio 1: MCP (`infovoto-mcp/src/mcp/perfiles/server.py`)

```python
# En _assemble_profile_dict():

# A) Limitar antecedentes penales a 5, ordenados por fecha DESC
ant_rows = (await session.execute(
    select(AntecedentePenal)
    .where(AntecedentePenal.candidato_dni == dni)
    .order_by(AntecedentePenal.fecha.desc().nullslast())
    .limit(5)
)).scalars().all()

# Contar total para metadata
ant_total = (await session.execute(
    select(func.count()).select_from(AntecedentePenal)
    .where(AntecedentePenal.candidato_dni == dni)
)).scalar() or 0

# B) Truncar descripcion de antecedentes a 200 chars
"descripcion": (a.resumen or a.descripcion or "")[:200]

# C) Agregar total en situacion_legal
if ant_total > len(ant_rows):
    response["situacion_legal"]["_total_registros"] = ant_total

# D) Posiciones: quitar score, dejar solo tema + posicion
response["posiciones_politicas"] = [
    {"tema": p["tema"], "posicion": p["posicion"]}
    for p in posiciones
]
```

### Cambio 2: Gateway (`infovoto-gateway/src/agent/core.py`)

```python
# Extender _smart_truncate_tool_result() para perfiles:

def _smart_truncate_tool_result(data):
    # ... existing comparacion/propuesta logic (unchanged) ...

    # Profile optimization: strip LLM-irrelevant fields before serialization
    if isinstance(data, dict) and "_resumen_markdown" in data:
        import copy
        data = copy.deepcopy(data)
        for key in ("_resumen_markdown", "_candidate", "_fuente", "_fuente_posiciones"):
            data.pop(key, None)
        if "resumen_bio" in data and "bio_curada" in data:
            del data["bio_curada"]

    return data
```

**NOTA CRITICA:** El `data.pop("_resumen_markdown")` solo se aplica al contexto LLM. El passthrough en `_build_passthrough_reply()` se ejecuta ANTES de `_smart_truncate`, asi que `_resumen_markdown` sigue disponible para la respuesta directa al usuario.

### Cambio 3: No tocar MAX_TOOL_RESULT_CHARS

Con los cambios 1 y 2, el perfil optimizado queda en ~5500-5800 chars, dentro del limite de 6000.

### Resultado final esperado

```
Seccion                          Antes       Despues     Ahorro
-------------------------------------------------------------------
sentencias_penales (5, desc 200) 5000 chars  1250 chars  -3750
_resumen_markdown                1500 chars     0 chars  -1500
_candidate                        300 chars     0 chars   -300
_fuente (2 campos)                100 chars     0 chars   -100
bio_curada                        400 chars     0 chars   -400
posiciones (sin score)           1200 chars  1000 chars   -200
hechos_relevantes                1500 chars  1500 chars      0
educacion                         500 chars   500 chars      0
experiencia                       700 chars   700 chars      0
patrimonio                        200 chars   200 chars      0
datos basicos                     300 chars   300 chars      0
resumen_bio                       300 chars   300 chars      0
-------------------------------------------------------------------
TOTAL                           12000 chars  5750 chars  -6250 (52%)
Tokens                           ~3500       ~1440       -2060 (59%)
```

**Codeforces Grandmaster:** De 12000 a 5750 chars. De ~3500 a ~1440 tokens. Reduccion del 59% en tokens sin perder informacion relevante para el votante. El perfil ahora cabe holgadamente en MAX_TOOL_RESULT_CHARS=6000.

**Junior MLE:** Y para el caso extremo donde un candidato tenga MAS datos (e.g., 5 educaciones largas + 5 experiencias largas + 5 antecedentes largos), la `_safe_json_stringify` sigue ahi como safety net. Pero ahora es improbable que se active.

**Full Stack Lead:** Necesito confirmar backward compatibility:
1. `_resumen_markdown` sigue en el response original -> passthrough funciona -> OK
2. `_candidate` sigue en el response original -> frontend card funciona -> OK
3. Solo se eliminan del contexto LLM -> OK, ningun consumidor pierde funcionalidad

**Veredicto Ciclo 9:** :white_check_mark: Aprobado -- Plan completo, backward compatible, 59% de reduccion de tokens.

---

## Ciclo 10: Riesgos y rollback plan

**Staff Engineer:** Antes de cerrar, evaluemos riesgos:

| Riesgo | Probabilidad | Impacto | Mitigacion |
|--------|-------------|---------|------------|
| Limitar a 5 antecedentes pierde info critica | Baja | Medio | `_total_registros` + `verificar_antecedentes` como fallback |
| Quitar `score` rompe algun consumer downstream | Baja | Bajo | Solo el MCP lo generaba, ningun otro consumer lo usa |
| `_smart_truncate` muta data que passthrough necesita | Media | Alto | Usar `copy.deepcopy()` -- ya contemplado |
| Candidatos con bio_curada MUY larga sin resumen_bio | Baja | Bajo | Si solo tiene bio_curada, se mantiene (el `del` es condicional) |
| Futuras features que necesiten el JSON completo en LLM | Media | Medio | Mantener herramienta `verificar_antecedentes` sin truncar |

**Delivery Lead:** Plan de rollback es simple: revertir los 2 commits (uno en MCP, uno en gateway). Los cambios son aditivos en gateway (extender funcion existente) y conservadores en MCP (agregar LIMIT y contador).

**Product Manager:** Metricas de exito:
1. `avg_profile_tokens` baja de ~3500 a ~1500 (medible en logs gateway)
2. `truncation_events` (veces que `_safe_json_stringify` trunca perfiles) baja a ~0
3. Calidad de respuestas de follow-up sobre antecedentes no se degrada (eval manual, 20 preguntas)

**AI Tech Lead:** Orden de implementacion:
1. Primero MCP (reduce data en la fuente) -> deploy
2. Luego gateway (smart truncate para perfiles) -> deploy
3. Monitorear 24h
4. Si algo falla, rollback gateway primero (es el que modifica el flujo)

**Junior Full Stack:** Una pregunta final: si el usuario pregunta "dame TODOS los antecedentes de Keiko" y el perfil ya vino con 5 de 12, el agente sabe que debe llamar `verificar_antecedentes`?

**AI Tech Lead:** Si. El campo `_total_registros: 12` en `situacion_legal` le indica al LLM que hay mas. Y `verificar_antecedentes` ya existe como herramienta separada. El system prompt del agente ya instruye usar herramientas especificas para detalle.

**Senior AI Engineer:** Confirmado. El flujo seria:

```
Usuario: "dame todos los antecedentes de Keiko"
Router: detecta pregunta sobre antecedentes -> llama verificar_antecedentes(nombre="Keiko Fujimori")
MCP: retorna los 12 antecedentes (verificar_antecedentes NO tiene el limite de 5)
Gateway: _smart_truncate para antecedentes (ya existente? No...)
```

Hmm, hay un gap. `verificar_antecedentes` tampoco tiene limite y puede retornar payloads grandes. Pero su JSON es mas simple (sin educacion, experiencia, posiciones, etc.), asi que el payload es mas manejable. Podemos agregar un LIMIT ahi como follow-up.

**Veredicto Ciclo 10:** :white_check_mark: Aprobado -- Riesgos aceptables, rollback claro, metricas definidas. Follow-up: evaluar truncamiento de `verificar_antecedentes` por separado.

---

## VEREDICTO FINAL

### Decision: Implementar Propuesta D (Hibrido: Optimizar MCP + Smart Truncate Gateway)

### Cambios aprobados

| # | Repo | Archivo | Cambio |
|---|------|---------|--------|
| 1 | infovoto-mcp | `src/mcp/perfiles/server.py` | `_assemble_profile_dict`: LIMIT 5 antecedentes con ORDER BY fecha DESC |
| 2 | infovoto-mcp | `src/mcp/perfiles/server.py` | `_assemble_profile_dict`: agregar `_total_registros` cuando hay mas de 5 |
| 3 | infovoto-mcp | `src/mcp/perfiles/server.py` | `_assemble_profile_dict`: truncar `descripcion` antecedentes a 200 chars |
| 4 | infovoto-mcp | `src/mcp/perfiles/server.py` | `_assemble_profile_dict`: posiciones sin `score` (solo `tema` + `posicion`) |
| 5 | infovoto-gateway | `src/agent/core.py` | `_smart_truncate_tool_result`: strip `_resumen_markdown`, `_candidate`, `_fuente*`, `bio_curada` del contexto LLM |
| 6 | infovoto-gateway | `src/agent/core.py` | `_smart_truncate_tool_result`: usar `copy.deepcopy()` para no mutar data original |

### Cambios NO aprobados

- NO subir MAX_TOOL_RESULT_CHARS (innecesario con las optimizaciones)
- NO separar herramientas (agregar `consultar_posiciones` -- innecesario, las 20 posiciones caben bien)
- NO limitar posiciones politicas (mantener las 20, son compactas)

### Metricas de exito

| Metrica | Antes | Objetivo |
|---------|-------|----------|
| Tokens por perfil en contexto LLM | ~3500 | ~1440 |
| Chars por perfil JSON | ~12000 | ~5750 |
| Truncation events en perfiles | Frecuente | ~0 |
| Info perdida para votante | 0 | 0 (con `_total_registros` + `verificar_antecedentes`) |

### Orden de deploy

1. `infovoto-mcp` (cambios 1-4)
2. `infovoto-gateway` (cambios 5-6)
3. Monitorear 24h
4. Eval: 20 preguntas sobre antecedentes de candidatos con >5 registros

### Follow-ups identificados

- Evaluar truncamiento de `verificar_antecedentes` (puede retornar >6000 chars para candidatos con muchos registros)
- Considerar cache de perfiles optimizados en Redis (evitar recomputar en follow-ups)
- Agregar metrica `profile_context_tokens` en logs del gateway para monitoreo continuo
