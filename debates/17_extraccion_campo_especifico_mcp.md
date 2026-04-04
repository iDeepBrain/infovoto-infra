# Debate 17: Deberia el MCP devolver solo el campo solicitado en vez del perfil completo?

**Fecha:** 2026-04-02
**Estado:** CERRADO
**Tema:** Actualmente `buscar_candidato_por_dni` retorna TODO el perfil (educacion, experiencia, patrimonio, legal, posiciones, hechos relevantes, bio). Alternativa: agregar parametro opcional `campo` para que el MCP retorne solo la seccion solicitada, con `_resumen_markdown` enfocado en ese campo.

---

## Contexto Tecnico

### Estructura actual del perfil retornado por `buscar_candidato_por_dni`

```python
# infovoto-mcp/src/mcp/perfiles/server.py -> _assemble_profile_dict()
{
  "dni": "10001234",
  "nombre_completo": "KEIKO SOFIA FUJIMORI HIGUCHI",
  "cargo": "presidente",
  "partido": "Fuerza Popular",
  "region": "Distrito Unico",
  "posicion_lista": 1,
  "sexo": "F",
  "fecha_nacimiento": "1975-05-25",

  # --- Secciones independientes ---
  "educacion": [...],                 # ~150 tokens
  "experiencia_laboral": [...],       # ~200 tokens
  "patrimonio": {...},                # ~60 tokens
  "situacion_legal": {                # ~1500 tokens (sin limite!)
    "sentencias_penales": [...],
    "sentencias_obligaciones": [...]
  },
  "hechos_relevantes": [...],         # ~400 tokens
  "resumen_bio": "...",               # ~80 tokens
  "bio_curada": "...",                # ~120 tokens
  "posiciones_politicas": [...],      # ~350 tokens (20 temas Decide.pe)

  # --- Metadata ---
  "_fuente": "...",
  "_fuente_posiciones": "...",
  "_candidate": {...},                # card frontend
  "_resumen_markdown": "..."          # passthrough para gateway (~400 tokens)
}
# TOTAL: ~3500 tokens / ~12000 chars
```

### Flujo actual completo

```
Usuario: "Cual es el patrimonio de Keiko?"
    |
    v
[Router LLM] -> tools=["buscar_candidato_por_dni"], args={nombre: "Keiko"}
    |
    v
[MCP perfiles] -> retorna perfil COMPLETO (~3500 tokens)
    |
    v
[Gateway] -> _build_passthrough_reply() usa _resumen_markdown
    |         (incluye educacion, experiencia, patrimonio, legal, posiciones)
    v
[Respuesta] -> Le muestra TODO al usuario, no solo patrimonio
```

### Problema identificado

El usuario pregunta por **patrimonio** y recibe un markdown con:
- Formacion (3 items)
- Experiencia (3 items)
- Patrimonio (lo que pidio)
- Situacion legal (3 items + "preguntame por mas")
- Posiciones politicas (8 temas)

**~80% del contenido es irrelevante para la pregunta.**

### Precedente: `estadisticas_candidatos` ya acepta `campo`

```python
# Ya existe en server.py linea 1305
campo: Annotated[
    str,
    Field(description="Campo de estadistica..."),
]
# Valores: 'genero', 'edad', 'educacion', 'sentencias', 'patrimonio', 'region', 'alertas', 'partidos'
```

### Opcion A: MCP siempre retorna perfil completo, gateway decide que mostrar

```
MCP: retorna todo -> Gateway: filtra por intent -> Synth/passthrough: responde enfocado
```

### Opcion B: MCP acepta parametro `campo` opcional

```python
# Propuesta de API
buscar_candidato_por_dni(
    dni="10001234",
    nombre="Keiko",
    campo="patrimonio"  # NUEVO: opcional
)
# Retorna solo:
{
  "dni": "10001234",
  "nombre_completo": "KEIKO SOFIA FUJIMORI HIGUCHI",
  "cargo": "presidente",
  "partido": "Fuerza Popular",
  "patrimonio": {...},
  "_resumen_markdown": "... solo patrimonio ..."
}
```

### Valores posibles de `campo`

| campo | Seccion retornada | Tokens aprox |
|-------|-------------------|-------------|
| `None` (default) | Todo (comportamiento actual) | ~3500 |
| `educacion` | educacion + bio_curada | ~270 |
| `experiencia` | experiencia_laboral | ~200 |
| `patrimonio` | patrimonio | ~60 |
| `legal` | situacion_legal + hechos_relevantes | ~1900 |
| `posiciones` | posiciones_politicas | ~350 |
| `bio` | resumen_bio + bio_curada | ~200 |

---

## Participantes

| # | Rol | Enfoque |
|---|-----|---------|
| 1 | Senior MLE #1 | Arquitectura hexagonal, separacion de responsabilidades |
| 2 | Senior MLE #2 | Optimizacion de tokens, costo LLM, observabilidad |
| 3 | Senior MLE #3 | API design, contratos MCP, backwards compatibility |
| 4 | Senior MLE #4 | Cache, performance, query planning |
| 5 | Senior MLE #5 | Testing, eval pipeline, metricas de calidad |
| 6 | Grandmaster CF #1 | Complejidad algoritmica, estructura de datos optima |
| 7 | Grandmaster CF #2 | Edge cases, invariantes, correctitud formal |
| 8 | Grandmaster CF #3 | Analisis de trade-offs cuantitativos |
| 9 | Grandmaster CF #4 | Optimizacion combinatoria, scheduling |
| 10 | Grandmaster CF #5 | Teoria de informacion, redundancia |
| 11 | AI Tech Lead | Decision arquitectural final, LLM ops, agentes |
| 12 | Junior MLE #1 | Testing, preguntas incomodas, edge cases |
| 13 | Junior MLE #2 | Mantenibilidad, onboarding, documentacion |
| 14 | Junior MLE #3 | Integracion, debugging, logs |
| 15 | Junior CF #1 | Simplicidad, principio de menor sorpresa |
| 16 | Junior CF #2 | Errores de usuario, validaciones |
| 17 | Junior CF #3 | Performance desde la perspectiva del frontend |
| 18 | Delivery Lead | Tiempos, ROI, riesgo, usuario final peruano |
| 19 | Stakeholder | Vision de producto, experiencia electoral, prioridades |
| 20 | Full Stack Lead | API design, DX, integracion gateway-MCP-frontend |

---

## Ciclo 1: Analisis de Responsabilidades — Donde debe vivir el filtrado?

**Pregunta: Filtrar campos es responsabilidad del MCP o del gateway?**

> **Senior MLE #1:** Desde arquitectura hexagonal, el MCP es un **adaptador de datos**. Su responsabilidad es exponer la informacion del candidato de manera estructurada. El filtrado por campo es una decision de **presentacion**, que pertenece al gateway (capa de aplicacion). Si el MCP empieza a decidir que campos mostrar, estamos mezclando responsabilidades. El MCP no deberia saber que el usuario pregunto por patrimonio — eso es contexto conversacional que vive en el gateway.

> **Senior MLE #3:** Discrepo. El parametro `campo` no es presentacion, es **scope de consulta**. Es analogo a GraphQL vs REST. En REST traes todo el recurso; en GraphQL pides los campos que necesitas. El MCP ya tiene precedente con `estadisticas_candidatos(campo=...)`. No es una violacion de responsabilidades — es optimizacion del contrato de datos. El MCP no necesita saber POR QUE se pide patrimonio, solo necesita saber QUE se pide.

> **AI Tech Lead:** El punto del Senior MLE #3 es valido, pero hay una diferencia clave. `estadisticas_candidatos` usa `campo` porque son **consultas completamente distintas** (genero vs edad vs sentencias = queries SQL diferentes). En `buscar_candidato_por_dni`, el query SQL es el **mismo** independientemente del campo: `SELECT candidato JOIN partido WHERE dni = X`. El filtrado es puro post-processing de Python. Si el query no cambia, el parametro `campo` solo ahorra bytes en la respuesta HTTP, no trabajo de DB.

> **Grandmaster CF #1:** Formalizemos. Sea `Q` el costo del query, `F` el costo de filtrado, `T` el costo de transferencia, `P` el costo de procesamiento LLM.
>
> - Opcion A: `Q + F_gateway + T_full + P_full`
> - Opcion B: `Q + F_mcp + T_partial + P_partial`
>
> Donde `T_full >> T_partial` y `P_full >> P_partial`. `Q` es identico. `F_mcp ≈ F_gateway ≈ O(1)` (es un dict lookup). La diferencia real esta en `T` y `P`. El query cuesta ~5ms, la transferencia HTTP entre containers cuesta ~2ms para 12KB vs ~0.5ms para 2KB. La diferencia de transferencia es **1.5ms**. Irrelevante. El ahorro real esta en `P` — tokens enviados al LLM synthesizer.

> **Junior MLE #1:** Pero espera. Si usamos passthrough (`_resumen_markdown`), el perfil NO pasa por el LLM synthesizer. Gateway usa `_build_passthrough_reply()` directamente. Entonces `P = 0` en ambos casos. El ahorro de tokens por LLM solo aplica cuando el passthrough falla y el gateway cae al synth.

> **Senior MLE #2:** El Junior tiene razon parcialmente. Veamos los numeros del passthrough:
>
> | Escenario | Passthrough? | Tokens al LLM |
> |-----------|-------------|---------------|
> | Perfil con `_resumen_markdown` | Si | 0 (skip synth) |
> | Perfil sin markdown (error MCP) | No | ~3500 (todo el perfil) |
> | Comparacion 2 candidatos | No | ~7000 (2 perfiles) |
> | Follow-up "dime mas sobre su educacion" | Depende | ~3500 si re-fetches |
>
> El caso 1 (passthrough) cubre ~60% de queries de perfil. Pero el 40% restante SI pasa por el synth, y ahi los 3500 tokens duelen.

> **Grandmaster CF #3:** Cuantifiquemos el ahorro en el caso synth. Si el usuario pregunta por patrimonio y el MCP retorna solo patrimonio (~60 tokens vs ~3500), el ahorro es 3440 tokens de input al synth. Con Gemini Flash a $0.04/1M input tokens: ahorro de $0.000138 por query. A 10K queries/dia: $1.38/dia. A 200K en dia de eleccion: $27.60. No es dinero significativo, pero la reduccion de latencia si importa: ~3440 tokens menos en input = ~200-400ms menos de latencia del synth (P50).

> **Full Stack Lead:** Hay un angulo que no estamos considerando: el **frontend**. Hoy el frontend recibe `_candidate` para renderizar la card. Si el MCP filtra por campo, el frontend sigue recibiendo la card completa (datos basicos siempre se incluyen). Pero si en el futuro queremos tabs por seccion en el frontend (tab educacion, tab patrimonio, tab legal), tener `campo` en el MCP seria util para lazy-loading de secciones. Hoy no lo necesitamos, pero es forward-compatible.

> **Junior CF #1:** Principio de menor sorpresa: si tengo una funcion `buscar_candidato_por_dni`, espero que retorne el perfil del candidato. No espero que retorne solo una seccion. Agregar `campo` cambia la semantica implicita. Seria mas claro tener `buscar_campo_candidato(dni, campo)` como tool separada.

> **Delivery Lead:** Timeout. Estamos debatiendo donde poner 5 lineas de codigo de filtrado. El ROI de esta decision tiene que justificar el tiempo de debate. Pregunta concreta: cuantas horas de implementacion tiene cada opcion?
>
> - Opcion A (gateway filtra): ~2 horas. Modificar `_build_passthrough_reply` para recibir intent y generar markdown enfocado.
> - Opcion B (MCP campo): ~4 horas. Modificar signature del tool + generar markdowns por campo + actualizar router prompt + tests.
> - Tool separada (Junior CF #1): ~6 horas. Nuevo tool + actualizar tool catalog + router prompt + tests.

**Veredicto Ciclo 1:** 🔄 **Necesita mas analisis**
- El query SQL es identico — el filtrado es puro post-processing
- El ahorro de tokens solo importa en el 40% de queries que van al synth
- Ahorro de latencia estimado: 200-400ms en ese 40%
- Tool separada descartada: over-engineering para el mismo resultado
- Falta analizar: impacto en el router y en el passthrough

---

## Ciclo 2: Impacto en el Router y Passthrough

**Pregunta: Si agregamos `campo`, como afecta al router LLM y al passthrough?**

> **Senior MLE #2:** El router actual ve el tool catalog y decide args. Si agregamos `campo` a `buscar_candidato_por_dni`, el router prompt necesita reglas nuevas:
>
> ```
> "cual es el patrimonio de Keiko" -> buscar_candidato_por_dni(nombre="Keiko", campo="patrimonio")
> "cuentame sobre Keiko" -> buscar_candidato_por_dni(nombre="Keiko")  # sin campo
> "educacion y patrimonio de Acuna" -> ???  # 2 campos!
> ```
>
> El tercer caso es problematico. El usuario pide 2 campos. El router tiene que:
> a) Ignorar campo y retornar todo (fallback)
> b) Hacer 2 llamadas al MCP (malo para latencia)
> c) Inventar un campo "educacion,patrimonio" (parsing custom)
>
> Ninguna opcion es limpia.

> **Grandmaster CF #2:** Edge cases formales del parametro `campo`:
>
> 1. `campo="patrimonio"` — OK, seccion unica
> 2. `campo=None` — OK, perfil completo (backwards compatible)
> 3. `campo="educacion,patrimonio"` — Multi-campo, necesita parsing
> 4. `campo="todo"` — Redundante con `None`, pero el LLM podria generarlo
> 5. `campo="antecedentes"` — Es `legal` o es el tool separado `verificar_antecedentes`?
> 6. `campo="propuestas"` — No existe en el perfil, es otro MCP (planes_gobierno)
> 7. `campo="debate"` — Confusion con `buscar_en_debate`
>
> Los casos 5-7 son problematicos porque el LLM podria confundir `campo` con otros tools. El router ya tiene reglas complejas sobre "debate en query -> tools de debate". Agregar `campo` aumenta la superficie de confusion.

> **AI Tech Lead:** Este es el punto critico. El ROUTER_PROMPT actual tiene reglas de negocio delicadas:
>
> ```
> - "debate en query -> SIEMPRE tools de debate"
> - "2+ nombres + debate -> comparar_candidatos_debate"
> - "antecedentes -> verificar_antecedentes, NO buscar_candidato_por_dni"
> ```
>
> Si agregamos `campo`, necesitamos reglas adicionales:
>
> ```
> - "patrimonio de X -> buscar_candidato_por_dni(nombre=X, campo='patrimonio')"
> - "educacion de X -> buscar_candidato_por_dni(nombre=X, campo='educacion')"
> - "antecedentes de X -> verificar_antecedentes(nombre=X)"  # NO campo='legal'!
> - "cuentame de X -> buscar_candidato_por_dni(nombre=X)"  # sin campo
> ```
>
> Cada regla nueva es una oportunidad de error del LLM. El router con flash-lite tiene adherencia ~95% a las reglas actuales. Cada regla nueva baja esa adherencia ~1-2%. Con 5 reglas nuevas de campo, bajamos a ~88-90%. Eso son 10-12 queries de cada 100 con campo incorrecto.

> **Senior MLE #4:** Pensemos en cache. Hoy el gateway cachea respuestas por `tool_name + args_hash`. Si agregamos `campo`, la cache key cambia:
>
> ```
> Sin campo: cache["buscar_candidato_por_dni:{dni:10001234}"] = perfil_completo
> Con campo: cache["buscar_candidato_por_dni:{dni:10001234,campo:patrimonio}"] = patrimonio
>            cache["buscar_candidato_por_dni:{dni:10001234,campo:educacion}"] = educacion
>            cache["buscar_candidato_por_dni:{dni:10001234}"] = perfil_completo
> ```
>
> Pasamos de 1 cache entry por candidato a potencialmente 7 (6 campos + completo). Pero peor aun: si el usuario primero pregunta por patrimonio (cache: patrimonio) y luego por educacion (cache miss, nuevo query), hacemos 2 queries cuando con perfil completo habriamos hecho 1.
>
> **El cache hit rate baja con campo.** Con perfil completo, cualquier pregunta sobre el mismo candidato es cache hit. Con campo, solo es hit si pregunta el mismo campo.

> **Junior MLE #3:** Punto de debugging: hoy cuando veo en logs `[MCP] buscar_candidato_por_dni(dni=10001234) -> 12KB`, se que retorno el perfil completo. Con `campo`, necesito ver `[MCP] buscar_candidato_por_dni(dni=10001234, campo=patrimonio) -> 2KB` y preguntarme "el campo fue correcto? debio ser legal?". Agrega una dimension de debugging que no existia.

> **Grandmaster CF #5:** Analisis de redundancia informacion-teorica. El perfil completo tiene ~3500 tokens de informacion. Si el usuario pregunta por patrimonio, la informacion relevante son ~60 tokens. La **redundancia** es 3500/60 = 58x. Eso es brutal. Pero la pregunta no es si hay redundancia (la hay, claramente), sino si la redundancia causa dano. En passthrough, el markdown tiene ~400 tokens con todo incluido. El usuario lee en ~15 segundos. Si el markdown solo tuviera patrimonio, serian ~50 tokens, 2 segundos de lectura. Ahorro de 13 segundos de lectura del usuario. Eso si es significativo para UX.

> **Senior MLE #5:** Desde el eval pipeline: nuestras metricas de calidad evaluan "respondio la pregunta?" y "la respuesta es relevante?". Hoy, cuando el usuario pregunta por patrimonio y recibe todo, el evaluador marca "respondio: si" pero "relevancia: parcial" porque hay ruido. Si filtramos por campo, la relevancia sube. Pero necesitamos confirmar: nuestro eval set tiene preguntas campo-especificas? Revisando... si: "cual es el patrimonio de Acuna?", "educacion de Keiko", "tiene antecedentes Lopez Aliaga?". Aproximadamente 30% del eval set son preguntas sobre un campo especifico.

> **Stakeholder:** Como votante peruano, cuando pregunto "cuanto gana Keiko?" no quiero leer sobre sus 20 posiciones politicas de Decide.pe. Quiero un numero y contexto minimo. La experiencia actual es como buscar algo en Google y que te devuelvan la pagina entera de Wikipedia en vez del snippet relevante. El filtrado por campo mejora directamente la experiencia del votante.

> **Junior CF #2:** Pero que pasa si el campo que el LLM eligio es incorrecto? Si el usuario pregunta "tiene problemas Keiko?" y el LLM elige `campo="legal"` pero el usuario se referia a problemas economicos... Retorna solo antecedentes penales y omite patrimonio. Con perfil completo, al menos el synth puede elegir que mostrar de toda la data.

**Veredicto Ciclo 2:** 🔄 **Necesita cambios**
- El router perderia ~5-10% de precision al agregar reglas de campo
- La cache se fragmenta: de 1 entry/candidato a potencialmente 7
- El caso multi-campo ("educacion y patrimonio") no tiene solucion limpia
- UX del votante mejora significativamente con respuestas enfocadas
- Riesgo de campo incorrecto es real y no tiene fallback facil

---

## Ciclo 3: La Tercera Via — Filtrado en el Gateway con _resumen_markdown por campo

**Pregunta: Podemos obtener el beneficio de UX sin modificar el MCP?**

> **Senior MLE #1:** Propongo Opcion C. El MCP sigue retornando perfil completo. Pero `_format_profile_markdown()` acepta un parametro `campo` que genera markdown enfocado. El gateway, al tener el intent del usuario (del router o del preprocessor), pasa el campo al formateador.
>
> ```python
> # En gateway, core.py -> _build_passthrough_reply()
> def _build_passthrough_reply(data: dict, campo: str | None = None) -> str:
>     if md := data.get("_resumen_markdown"):
>         if campo:
>             return _format_field_markdown(data, campo)  # NUEVO
>         return md
> ```
>
> Pero esto tiene un problema: el passthrough usa `_resumen_markdown` que ya viene del MCP. Para generar un markdown enfocado, necesitamos acceso a los datos raw. Y los datos raw viajan completos en el dict... asi que estamos de vuelta al principio: 3500 tokens viajan por HTTP.

> **Grandmaster CF #4:** Optimicemos. El cuello de botella no son los bytes HTTP (2ms de diferencia). Es lo que le llega al **usuario final**. Hay 3 puntos de decision:
>
> 1. **MCP** decide que datos enviar -> Opcion B
> 2. **Gateway** decide que markdown generar -> Opcion C
> 3. **Frontend** decide que mostrar -> Opcion D (nueva)
>
> La Opcion D es interesante: el MCP retorna todo, el gateway retorna todo, y el frontend renderiza solo la seccion relevante (basandose en el intent que el gateway le pasa como metadata). Esto es "client-side filtering".

> **Full Stack Lead:** La Opcion D es elegante pero irreal para nuestro caso. Tenemos WhatsApp como canal (texto plano, no hay "tabs" ni "secciones colapsables"). En WhatsApp, el usuario recibe UN mensaje de texto. No puede elegir que seccion ver. Para WhatsApp, el filtrado TIENE que ser server-side.

> **Senior MLE #3:** Volvamos a Opcion C con un twist. El MCP retorna perfil completo + multiples markdowns:
>
> ```python
> response["_resumen_markdown"] = _format_profile_markdown(response)  # existente
> response["_resumen_educacion"] = _format_educacion_markdown(response)
> response["_resumen_patrimonio"] = _format_patrimonio_markdown(response)
> response["_resumen_legal"] = _format_legal_markdown(response)
> response["_resumen_posiciones"] = _format_posiciones_markdown(response)
> response["_resumen_experiencia"] = _format_experiencia_markdown(response)
> ```
>
> El gateway elige cual `_resumen_*` usar basandose en el intent. Si no sabe el campo, usa `_resumen_markdown` (completo). Esto mantiene el MCP stateless, el gateway inteligente, y el usuario contento.

> **AI Tech Lead:** Me gusta la idea pero odiemos los numeros. Estamos retornando 6 markdowns pre-generados en cada respuesta. Eso agrega ~1500 tokens adicionales al response. Pasamos de ~3500 a ~5000 tokens viajando por HTTP. Es contra-intuitivo: para optimizar estamos enviando MAS datos.

> **Grandmaster CF #1:** La solucion del Senior MLE #3 es O(n) en campos, y solo se usa 1 de los 6. Eso es wasteful. Hay una solucion O(1) mas elegante: que el MCP retorne los datos estructurados (como hoy) pero que el **gateway tenga funciones de formato** locales. El gateway ya parsea el dict para `_build_passthrough_reply`. Agregar un `_format_field_from_data(data, campo)` en el gateway es trivial y no requiere cambiar el MCP.
>
> ```python
> # En gateway, nuevo helper
> def _format_field_markdown(data: dict, campo: str) -> str:
>     nombre = data.get("nombre_completo", "")
>     if campo == "patrimonio":
>         pat = data.get("patrimonio", {})
>         return f"**{nombre}** declara ingresos por S/ {pat.get('ingreso_total', 0):,.2f}..."
>     elif campo == "educacion":
>         ...
> ```

> **Junior MLE #2:** Eso mueve la logica de formato al gateway. Hoy `_format_profile_markdown` vive en el MCP y tiene conocimiento del dominio (que campos existen, como formatearlos, que fuentes citar). Si duplicamos esa logica en el gateway, tenemos **2 lugares** que saben formatear perfiles. Cuando agreguemos un campo nuevo al MCP, hay que actualizar ambos. Eso viola DRY.

> **Senior MLE #1:** El Junior MLE #2 tiene un punto excelente. Pero hay una solucion: el MCP genera el `_resumen_markdown` completo (como hoy) y el gateway lo **trunca** por seccion usando headers markdown. El markdown ya tiene secciones claras: `**Formacion:**`, `**Experiencia:**`, `**Patrimonio declarado:**`, `**Situacion legal**`, `**Posiciones politicas**`. El gateway puede hacer split por `**...**` y retornar solo la seccion relevante.

> **Grandmaster CF #3:** Analicemos la robustez del split por headers:
>
> ```markdown
> Te cuento sobre **KEIKO SOFIA FUJIMORI HIGUCHI**.
> Postula como **presidente** por **Fuerza Popular**.
>
> **Formacion:**
> - Maestria en Administracion, Boston University
> ...
>
> **Experiencia:**
> - Congresista, Congreso de la Republica (2006-2011)
> ...
>
> **Patrimonio declarado:** S/ 250,000.00
> - 2 inmueble(s)
>
> **Situacion legal** (5 registro(s)):
> - Lavado de activos (en proceso)
> ...
> ```
>
> El parsing por `**seccion:**` es fragil: si alguien cambia el formato del markdown en el MCP, el gateway se rompe silenciosamente. Tendriamos un acoplamiento implicito entre el formato del MCP y el parser del gateway. Eso es peor que tener `campo` explicito.

> **Delivery Lead:** Llevamos 3 ciclos y han surgido 5 opciones:
>
> | Opcion | Modifica MCP | Modifica Gateway | Complejidad | DRY |
> |--------|-------------|-----------------|-------------|-----|
> | A: MCP full, gateway todo | No | No | 0 | OK |
> | B: MCP campo param | Si | Si (router) | Alta | OK |
> | C: MCP multi-markdown | Si | Si (selector) | Media | OK |
> | C2: Gateway format local | No | Si | Media | Viola DRY |
> | C3: Gateway split markdown | No | Si | Media | Acoplamiento |
>
> Necesitamos converger. Cuales descartamos?

> **Stakeholder:** Desde producto, me importa: (1) el usuario recibe respuesta enfocada, (2) no rompemos lo que funciona, (3) se implementa rapido. No me importa donde vive el codigo.

**Veredicto Ciclo 3:** 🔄 **Opciones reducidas**
- Descartada Opcion D (frontend filtering): WhatsApp no lo soporta
- Descartada C (multi-markdown): envia mas datos, no menos
- Descartada C2 (gateway format): viola DRY
- Quedan: A (status quo), B (campo en MCP), C3 (split markdown en gateway)
- C3 tiene riesgo de acoplamiento implicito
- Falta analizar: implementacion concreta de B vs A mejorada

---

## Ciclo 4: Implementacion Concreta — Opcion B vs Opcion A Mejorada

**Pregunta: Si implementamos B, cuales son los detalles? Y si mejoramos A sin tocar el MCP?**

> **Senior MLE #3:** Implementacion de Opcion B — MCP con `campo`:
>
> ```python
> @mcp.tool(...)
> async def buscar_candidato_por_dni(
>     dni: str | None = None,
>     nombre: str | None = None,
>     campo: Annotated[
>         str | None,
>         Field(description=(
>             "Seccion especifica del perfil. Si no se especifica, retorna todo.\n"
>             "Valores: 'educacion', 'experiencia', 'patrimonio', 'legal', 'posiciones', 'bio'\n"
>             "Usar cuando el usuario pregunta sobre un tema especifico del candidato.\n"
>             "Ejemplos:\n"
>             "- 'patrimonio de Keiko' -> campo='patrimonio'\n"
>             "- 'que estudio Acuna?' -> campo='educacion'\n"
>             "- 'cuentame de Lopez Aliaga' -> campo=None (perfil completo)\n"
>         )),
>     ] = None,
> ) -> dict:
>     # ... (resolver DNI, query DB - igual que hoy)
>     profile = await _assemble_profile_dict(session, candidato, partido)
>     if campo:
>         profile = _filter_profile_by_campo(profile, campo)
>     return profile
> ```
>
> Y la funcion de filtrado:
>
> ```python
> _CAMPO_KEYS = {
>     "educacion": ["educacion", "bio_curada"],
>     "experiencia": ["experiencia_laboral"],
>     "patrimonio": ["patrimonio"],
>     "legal": ["situacion_legal", "hechos_relevantes"],
>     "posiciones": ["posiciones_politicas", "_fuente_posiciones"],
>     "bio": ["resumen_bio", "bio_curada", "hechos_relevantes"],
> }
>
> _ALWAYS_KEYS = {"dni", "nombre_completo", "cargo", "partido", "region", "_fuente", "_candidate"}
>
> def _filter_profile_by_campo(profile: dict, campo: str) -> dict:
>     campo = campo.strip().lower()
>     keys = _CAMPO_KEYS.get(campo)
>     if not keys:
>         return profile  # campo invalido -> retorna todo (fallback seguro)
>     allowed = _ALWAYS_KEYS | set(keys)
>     filtered = {k: v for k, v in profile.items() if k in allowed}
>     filtered["_resumen_markdown"] = _format_field_markdown(profile, campo)
>     return filtered
> ```
>
> Son ~30 lineas de codigo en el MCP + 6 funciones `_format_*_markdown` (~20 lineas cada una).

> **Senior MLE #4:** El fallback a perfil completo cuando `campo` es invalido es clave. Eso significa que si el router se equivoca y pasa `campo="antecedentes"` (que no esta en _CAMPO_KEYS), el MCP retorna todo. El usuario no pierde informacion. Es degradacion graceful.

> **Grandmaster CF #2:** Analizo los invariantes de la implementacion:
>
> 1. **Backwards compatible:** `campo=None` retorna exactamente lo mismo que hoy. Ningun caller existente se rompe.
> 2. **Idempotente:** multiples llamadas con mismo (dni, campo) retornan lo mismo.
> 3. **Monotono en informacion:** `campo=None` siempre retorna un superset de `campo=X`. Nunca se pierde info.
> 4. **Fallback seguro:** `campo` invalido = perfil completo.
>
> Los 4 invariantes se cumplen. La implementacion es correcta por construccion.

> **Junior MLE #1:** Pregunta incomoda: que pasa con el cache del gateway? Hoy:
>
> ```
> cache_key = hash("buscar_candidato_por_dni" + str({"dni": "10001234"}))
> ```
>
> Si agrego `campo`:
>
> ```
> cache_key = hash("buscar_candidato_por_dni" + str({"dni": "10001234", "campo": "patrimonio"}))
> ```
>
> El mismo candidato ahora tiene N cache entries. PERO: si la primera query fue sin campo (perfil completo), y la segunda es con campo... cache miss. Propuesta: cuando hay cache hit del perfil completo, el gateway podria filtrar localmente el campo del resultado cacheado.

> **Senior MLE #4:** Excelente punto del Junior. La solucion es un **cache inteligente**:
>
> ```python
> # Pseudocodigo del cache lookup en gateway
> def get_cached_or_fetch(tool, args):
>     # 1. Buscar cache exacto
>     result = cache.get(tool, args)
>     if result:
>         return result
>
>     # 2. Si tiene campo, buscar cache del perfil completo
>     if args.get("campo"):
>         full_args = {k: v for k, v in args.items() if k != "campo"}
>         full_result = cache.get(tool, full_args)
>         if full_result:
>             return _filter_profile_by_campo(full_result, args["campo"])
>
>     # 3. Fetch del MCP
>     return await fetch_from_mcp(tool, args)
> ```
>
> Esto requiere que el gateway tenga `_filter_profile_by_campo`. Eso es duplicacion... pero es una funcion de 10 lineas, y es critica para el cache.

> **Senior MLE #5:** Veamos el impacto en el eval. Hoy, el eval runner llama a `buscar_candidato_por_dni` y evalua el resultado. Si agregamos `campo`, el eval runner necesita:
>
> 1. Seguir testeando `campo=None` (regresion del perfil completo)
> 2. Agregar tests para cada valor de `campo` (6 valores)
> 3. Agregar tests de campo invalido (fallback)
> 4. Agregar tests de cache hit cross-campo
>
> Eso son ~25 test cases nuevos. No es trivial pero es manejable. Lo que me preocupa mas es el eval de calidad end-to-end: "el usuario pregunto por patrimonio, el router eligio campo=patrimonio, el MCP retorno solo patrimonio, el passthrough genero markdown de patrimonio, el usuario recibio una respuesta enfocada?" Ese flujo completo necesita tests nuevos.

> **Grandmaster CF #4:** Veamos la Opcion A mejorada para comparar. Sin cambiar el MCP:
>
> ```python
> # En gateway, core.py
> # El synth prompt incluye: "Si el usuario pregunta por un tema especifico,
> # enfoca tu respuesta en ese tema. No incluyas informacion de otros temas
> # a menos que sea directamente relevante."
> ```
>
> Es decir: dejar que el LLM synth filtre. El synth ya recibe todo el perfil y la pregunta del usuario. Deberia ser capaz de responder "patrimonio de Keiko: S/ 250,000" sin incluir sus posiciones politicas. Costo: modificar 2 lineas del SYNTHESIZER_INSTRUCTION.

> **AI Tech Lead:** La Opcion A mejorada (synth filtra) tiene un problema: el **passthrough bypass**. Cuando `_resumen_markdown` existe, el gateway NO llama al synth. El markdown pre-generado incluye todo. Para que funcione la Opcion A mejorada, tendriamos que:
>
> a) Deshabilitar passthrough para preguntas campo-especificas (forzar synth) -> agrega 2-5s de latencia
> b) O modificar `_format_profile_markdown` en el MCP de todas formas
>
> Opcion (a) es un retroceso: estamos forzando un LLM call que el passthrough nos ahorraba. Opcion (b) nos lleva de vuelta a modificar el MCP. No hay escape.

> **Junior CF #3:** Desde perspectiva de latencia percibida por el usuario: hoy el perfil llega en ~200ms (passthrough, sin LLM). Si deshabilitamos passthrough para campo-especifico, sube a ~2-5s. Eso es 10-25x mas lento. El usuario nota. Mucho.

> **Grandmaster CF #5:** Resumo los trade-offs cuantitativos:
>
> | Metrica | A (status quo) | A mejorada (synth filtra) | B (campo en MCP) |
> |---------|---------------|--------------------------|-------------------|
> | Latencia perfil completo | ~200ms (passthrough) | ~200ms | ~200ms |
> | Latencia campo especifico | ~200ms (respuesta ruidosa) | ~2-5s (synth limpio) | ~200ms (passthrough limpio) |
> | Tokens al LLM (campo) | 0 (passthrough) | ~3500 (synth) | 0 (passthrough) |
> | Relevancia (campo) | ~60% (ruido) | ~95% (synth filtra) | ~95% (campo filtrado) |
> | Cambios en MCP | 0 | 0 | ~150 lineas |
> | Cambios en Gateway | 0 | ~5 lineas prompt | ~30 lineas cache |
> | Cambios en Router | 0 | 0 | ~10 lineas prompt |
> | Riesgo de regresion | 0 | Medio (synth puede fallar) | Bajo (fallback a completo) |
> | Cache efficiency | 100% (1 entry) | 100% | ~85% (cross-campo fix) |
>
> **B domina a A mejorada en latencia Y en tokens.** B vs A status quo: B es mejor en relevancia, peor en complejidad.

> **Delivery Lead:** Los numeros hablan. Opcion B tiene la mejor combinacion de latencia + relevancia. El riesgo es bajo por el fallback. La complejidad es manejable (~150 lineas MCP + 30 gateway + 10 router). Estimacion: 1 dia de implementacion + 0.5 dia de testing. ROI positivo si el 30% de queries son campo-especificas.

**Veredicto Ciclo 4:** ✅ **Opcion B recomendada con condiciones**
- B domina en latencia + relevancia + tokens
- Fallback a perfil completo elimina el riesgo de campo invalido
- Cache cross-campo resuelve la fragmentacion
- A mejorada descartada: fuerza synth donde passthrough funciona
- Condiciones: implementar con fallback, cache cross-campo, tests exhaustivos

---

## Ciclo 5: Diseno Final, Riesgos Residuales y Plan de Implementacion

**Pregunta: Como implementamos B de forma segura? Que riesgos quedan?**

> **AI Tech Lead:** Diseno final aprobado. Tres componentes:
>
> **1. MCP (infovoto-mcp/src/mcp/perfiles/server.py):**
> - Agregar `campo: str | None = None` a `buscar_candidato_por_dni`
> - Implementar `_filter_profile_by_campo(profile, campo)`
> - Implementar 6 funciones `_format_{campo}_markdown(data)`
> - Campo invalido -> retorna perfil completo (fallback)
> - Campo valido -> retorna datos basicos + seccion + markdown enfocado
>
> **2. Gateway (src/agent/core.py):**
> - `_build_passthrough_reply` ya funciona: lee `_resumen_markdown` del dict
> - Agregar cache cross-campo: si hay hit del perfil completo, filtrar localmente
> - Duplicar `_CAMPO_KEYS` y `_filter_profile_by_campo` en gateway para cache (10 lineas)
>
> **3. Router (src/agent/prompts/system.py o router.py):**
> - Agregar al tool description de `buscar_candidato_por_dni`:
>   `"campo: seccion especifica (educacion|experiencia|patrimonio|legal|posiciones|bio). Omitir para perfil completo."`
> - Agregar ejemplos al router prompt:
>   `"patrimonio de X -> campo='patrimonio'"`
>   `"que estudio X -> campo='educacion'"`
>   `"antecedentes de X -> verificar_antecedentes (NO campo='legal')"`

> **Senior MLE #1:** Riesgo residual #1: **El router elige campo incorrecto**. Mitigacion: fallback a perfil completo + el usuario puede decir "cuentame todo" para forzar `campo=None`. Impacto: bajo (el usuario recibe info parcial pero correcta, solo la seccion equivocada).

> **Senior MLE #2:** Riesgo residual #2: **El router NO usa campo cuando deberia**. Ejemplo: "patrimonio de Keiko" -> `buscar_candidato_por_dni(nombre="Keiko")` sin campo. Impacto: nulo (es el comportamiento actual, no hay regresion). El usuario recibe el perfil completo en vez de solo patrimonio. No ideal, pero no es peor que hoy.

> **Grandmaster CF #2:** Riesgo residual #3: **Confusion con `verificar_antecedentes`**. El router podria elegir `buscar_candidato_por_dni(nombre="Keiko", campo="legal")` en vez de `verificar_antecedentes(nombre="Keiko")`. Son tools distintas: `verificar_antecedentes` tiene mas detalle de cada antecedente (descripcion completa, sancion, fuente_medio). La regla en el router debe ser explicita:
>
> ```
> "antecedentes" / "sentencias" / "juicios" / "procesos" -> verificar_antecedentes
> "situacion legal" (generico) -> buscar_candidato_por_dni(campo="legal")
> ```
>
> Esta distincion es sutil. Recomiendo agregar a la description de `campo` en el MCP:
> `"Para antecedentes detallados, usar verificar_antecedentes en vez de campo='legal'."`

> **Senior MLE #5:** Plan de testing:
>
> **Unit tests (infovoto-mcp):**
> - `test_filter_profile_patrimonio` — retorna solo patrimonio + datos basicos
> - `test_filter_profile_educacion` — retorna solo educacion + bio_curada
> - `test_filter_profile_legal` — retorna situacion_legal + hechos_relevantes
> - `test_filter_profile_invalid` — campo invalido retorna perfil completo
> - `test_filter_profile_none` — campo=None retorna perfil completo
> - `test_format_patrimonio_markdown` — markdown enfocado correcto
> - `test_format_educacion_markdown` — markdown enfocado correcto
> - `test_format_legal_markdown` — markdown enfocado correcto
>
> **Integration tests (gateway):**
> - `test_cache_cross_campo` — hit de completo sirve para campo especifico
> - `test_campo_passthrough` — `_resumen_markdown` de campo funciona en passthrough
> - `test_router_campo_patrimonio` — "patrimonio de Keiko" genera campo=patrimonio
> - `test_router_campo_none` — "cuentame de Keiko" genera campo=None
> - `test_router_antecedentes_not_campo` — "antecedentes" usa verificar_antecedentes
>
> **Eval end-to-end:**
> - Agregar 10 queries campo-especificas al eval set
> - Medir relevancia antes/despues del cambio
> - Target: relevancia >90% en queries campo-especificas (hoy ~60%)

> **Junior MLE #2:** Documentacion necesaria:
> - Actualizar `infovoto-mcp/docs/technical/tools-catalog.md` con el parametro `campo`
> - Actualizar `infovoto-mcp/docs/technical/perfiles/README.md`
> - Agregar ejemplos en el CLAUDE.md del MCP
> - Nota en el CHANGELOG

> **Junior CF #1:** Una cosa mas sobre simplicidad: el nombre `campo` ya se usa en `estadisticas_candidatos` con valores **distintos** ('genero', 'edad', 'educacion', 'sentencias', 'patrimonio', 'region', 'alertas', 'partidos'). En `buscar_candidato_por_dni` los valores serian ('educacion', 'experiencia', 'patrimonio', 'legal', 'posiciones', 'bio'). El overlap es parcial: 'educacion' y 'patrimonio' existen en ambos, pero 'genero' y 'edad' no tienen sentido para un perfil. El LLM podria confundir los valores. Sugiero nombrar el parametro `seccion` en vez de `campo` para evitar ambiguedad.

> **AI Tech Lead:** Buen punto. `seccion` es mas semantico: "dame la seccion de patrimonio del perfil" vs "dame el campo patrimonio". Adopto el renombre: `seccion` para perfiles, `campo` para estadisticas.

> **Grandmaster CF #4:** Un ultimo analisis. La implementacion debe ser **incremental**:
>
> **Fase 1 (dia 1):** MCP acepta `seccion`, filtra profile, genera markdown enfocado. Sin cambios en gateway ni router. El parametro existe pero nadie lo usa. Zero risk.
>
> **Fase 2 (dia 2):** Gateway agrega cache cross-seccion. Aun sin cambios en router. El MCP retorna datos filtrados si alguien pasa seccion manualmente (test).
>
> **Fase 3 (dia 3):** Router prompt actualizado. Ahora el LLM empieza a usar `seccion`. Monitorear logs por 24h. Si la precision del router baja >5%, revertir solo el cambio del router (Fase 3) sin tocar MCP.
>
> Esta separacion permite rollback granular. Cada fase es independiente y reversible.

> **Senior MLE #3:** El plan incremental es solido. Punto adicional: la descripcion del tool en el MCP (`description=...`) es lo que el router LLM ve. Si cambiamos la description para incluir `seccion`, el router automaticamente ve la opcion. No necesitamos modificar el router prompt por separado si la description del tool es suficientemente clara. El router ya lee el tool catalog en `_get_tools_catalog()`.

> **Grandmaster CF #3:** Confirmado con los numeros finales:
>
> | Metrica | Antes | Despues (con seccion) |
> |---------|-------|-----------------------|
> | Tokens/query (campo especifico, passthrough) | ~400 (markdown completo) | ~80 (markdown enfocado) |
> | Tokens/query (campo especifico, synth) | ~3500 (perfil completo) | ~200-500 (seccion) |
> | Latencia (campo especifico) | ~200ms (passthrough ruidoso) | ~200ms (passthrough enfocado) |
> | Relevancia (campo especifico) | ~60% | ~95% (estimado) |
> | Cache entries/candidato | 1 | 1-7 (mitigado con cross-cache) |
> | Lineas de codigo nuevas | 0 | ~200 (MCP) + ~40 (gateway) |
> | Tests nuevos | 0 | ~20 |
> | Riesgo de regresion | 0 | Bajo (fallback a completo) |

> **Delivery Lead:** Plan de implementacion aprobado. 3 fases, 3 dias, rollback independiente por fase. El ahorro en UX (respuestas enfocadas) justifica la complejidad incremental. Las 200 lineas de MCP son mayormente funciones `_format_*_markdown` que son plantillas simples.

> **Stakeholder:** Desde la vision de producto: esto mejora directamente la experiencia del votante. "Cuanto gana Keiko?" recibe un numero directo, no un wall of text. Aprobado.

> **Full Stack Lead:** Desde API design: el parametro `seccion` es opcional con default None, backwards compatible, bien documentado, con fallback seguro. El rename de `campo` a `seccion` evita confusion con `estadisticas_candidatos`. La cache cross-seccion en el gateway es elegante. Aprobado.

> **Junior MLE #3:** Desde debugging: los logs mostraran `[MCP] buscar_candidato_por_dni(dni=..., seccion=patrimonio) -> 2KB` lo cual es mas informativo que el actual `-> 12KB`. Puedo ver inmediatamente si la seccion fue correcta. Aprobado.

> **Junior CF #2:** Ultimo edge case: que pasa si el usuario dice "patrimonio y educacion de Keiko"? El router podria generar `seccion="patrimonio"` e ignorar educacion. Mitigacion: si el router no sabe que seccion elegir (multi-campo), debe omitir seccion (perfil completo). Agregar regla: `"Si el usuario pide multiples temas, NO usar seccion."`.

> **Grandmaster CF #5:** Esa regla de multi-campo es la correcta. Formalmente: `seccion` es un filtro de **exactamente 1 seccion**. Si el intent tiene >1 seccion, fallback a perfil completo. Es la semantica mas simple y robusta.

---

## VEREDICTO FINAL

**Decision: OPCION B (con rename a `seccion`) — APROBADA por 18/20**

### Que se implementa

1. **MCP** (`buscar_candidato_por_dni`): Agregar parametro `seccion: str | None = None` con valores `educacion`, `experiencia`, `patrimonio`, `legal`, `posiciones`, `bio`. Retorna datos basicos + seccion solicitada + `_resumen_markdown` enfocado. Campo invalido o None -> perfil completo (fallback seguro).

2. **MCP** (funciones de formato): Implementar `_format_{seccion}_markdown()` para cada seccion. Templates simples con tono VOTI. ~20 lineas cada una.

3. **MCP** (`_filter_profile_by_campo`): Dict lookup O(1) con `_CAMPO_KEYS` + `_ALWAYS_KEYS`. ~15 lineas.

4. **Gateway** (cache): Cache cross-seccion: si hay hit del perfil completo y el query pide una seccion, filtrar del cache sin ir al MCP. ~30 lineas.

5. **Router** (tool description): Actualizar description de `buscar_candidato_por_dni` para incluir `seccion` con ejemplos. El router LLM lo lee automaticamente del tool catalog. Agregar regla: "multi-tema -> omitir seccion".

### Como se implementa (3 fases incrementales)

| Fase | Dia | Cambios | Rollback |
|------|-----|---------|----------|
| 1 | 1 | MCP: parametro seccion + filtrado + markdowns | Revertir commit MCP |
| 2 | 2 | Gateway: cache cross-seccion | Revertir commit gateway |
| 3 | 3 | Router: tool description actualizada | Revertir commit router |

### Que NO se implementa

- Tool separada `buscar_campo_candidato` — over-engineering
- Multi-markdown pre-generado — envia mas datos, no menos
- Frontend filtering — WhatsApp no lo soporta
- Opcion A mejorada (synth filtra) — fuerza LLM call donde passthrough funciona

### Metricas de exito

- Relevancia en queries campo-especificas: de ~60% a >90%
- Latencia: sin regresion (sigue en ~200ms passthrough)
- Tokens/query (campo especifico): de ~400 a ~80 (passthrough), de ~3500 a ~200-500 (synth)
- Router precision: no debe bajar mas de 3% (monitorear en Fase 3)
- Cache hit rate: no debe bajar mas de 5% (monitorear cross-seccion)

### Riesgos aceptados

| Riesgo | Probabilidad | Impacto | Mitigacion |
|--------|-------------|---------|------------|
| Router elige seccion incorrecta | 10% | Bajo (info parcial correcta) | Fallback a completo + usuario puede pedir "todo" |
| Router no usa seccion cuando deberia | 15% | Nulo (es el comportamiento actual) | Iterar prompt del tool catalog |
| Confusion seccion vs verificar_antecedentes | 5% | Medio (menos detalle) | Regla explicita en description |
| Cache fragmentacion | 10% | Bajo | Cross-seccion lookup implementado |
| Multi-campo no detectado | 5% | Bajo (retorna 1 seccion) | Regla "multi-tema -> sin seccion" |

### Votos

| Rol | Voto | Nota |
|-----|------|------|
| Senior MLE #1 | ✅ | "Separation of concerns OK con fallback" |
| Senior MLE #2 | ✅ | "Los numeros de tokens justifican el cambio" |
| Senior MLE #3 | ✅ | "API design solido, backwards compatible" |
| Senior MLE #4 | ✅ | "Cache cross-seccion resuelve mi preocupacion" |
| Senior MLE #5 | ✅ | "Plan de testing claro y manejable" |
| Grandmaster CF #1 | ✅ | "O(1) filtering, invariantes correctos" |
| Grandmaster CF #2 | ✅ | "4 invariantes formales se cumplen" |
| Grandmaster CF #3 | ✅ | "Numeros favorecen B en todas las metricas" |
| Grandmaster CF #4 | ✅ | "Plan incremental permite rollback granular" |
| Grandmaster CF #5 | ✅ | "Semantica de 1 seccion es robusta y simple" |
| AI Tech Lead | ✅ | "Aprobado con rename a seccion y 3 fases" |
| Junior MLE #1 | ✅ | "Fallback seguro elimina mi preocupacion de campo incorrecto" |
| Junior MLE #2 | ✅ | "Documentacion y DRY resueltos" |
| Junior MLE #3 | ✅ | "Logs mas informativos con seccion explicita" |
| Junior CF #1 | ✅ | "Rename a seccion resuelve ambiguedad con estadisticas" |
| Junior CF #2 | 🔄 | "Multi-campo queda debil, pero aceptable con regla de fallback" |
| Junior CF #3 | ✅ | "Latencia sin regresion, UX mejorada" |
| Delivery Lead | ✅ | "3 dias, ROI positivo, rollback independiente" |
| Stakeholder | ✅ | "El votante recibe lo que pidio, no ruido" |
| Full Stack Lead | 🔄 | "Aceptable, pero monitorear precision del router en Fase 3" |

**Resultado: 18 ✅ / 2 🔄 / 0 ❌ — APROBADO**
