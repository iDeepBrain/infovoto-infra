# 08 — Debate: Single-Pass vs Multi-Pass Pipeline

## Tema Central

**El pipeline actual usa 2 llamadas LLM por request. Podemos eliminar una sin perder calidad? Cuando conviene 0, 1, o 2 passes?**

---

## Contexto Tecnico

### Pipeline actual (2-pass)

```
Usuario
  |
  v
Preprocessor (0ms) ──> instant_reply? ──> DONE (0-pass)
  |
  v
Fast-route? (regex, 0ms) ──> si matchea, skip router
  |
  v
[Pass 1] LLM Router (gemini-2.5-flash-lite, json_mode)
  Input: mensaje + tool catalog (~500 tokens prompt)
  Output: JSON {tools, args, reasoning}
  Latencia: 1-3s (P50 ~1.5s, P95 ~3s)
  |
  v
MCP calls (parallel, HTTP)
  Latencia: 0.05-0.3s (P95 ~0.5s, ChromaDB ~2-4s)
  |
  v
[Pass 2] LLM Synthesizer (gemini-2.0-flash)
  Input: tool results + user message + SYNTHESIZER_INSTRUCTION
  Output: respuesta natural en espanol
  Latencia: 1-5s (P50 ~2s, P95 ~5s, thinking model >8s)
  |
  v
Output filter + response validator (0ms)
  |
  v
Usuario
```

### Latencias observadas (del codigo)

| Componente | P50 | P95 | Budget max |
|---|---|---|---|
| Router LLM (flash-lite) | ~1.5s | ~3s | 5s cap |
| MCP calls (parallel) | ~0.2s | ~0.5s | 5s cap |
| Synthesizer LLM (flash) | ~2s | ~5s | 15s cap |
| Redis parallel fetch | ~0.1s | ~0.5s | 1.5s cap |
| **Total pipeline** | **~4s** | **~9s** | **20s hard** |

### Lo que ya existe como optimizacion

1. **Fast-routes** (preprocessor.py): regex para "candidatos presidenciales", "cuando son las elecciones", "donde voto" -- skip router LLM
2. **Passthrough** (core.py `_has_formatted_list`): si MCP devuelve `lista_formateada`, skip synthesizer LLM
3. **Instant replies**: saludos, meta-questions -- 0 LLM calls
4. **Gemini auto function calling deshabilitado**: `automatic_function_calling=disable=True, maximum_remote_calls=0` en `adapters/gemini.py:121`

### Arquitecturas alternativas a evaluar

| Opcion | LLM calls | Descripcion |
|---|---|---|
| A. 2-pass actual | 2 | Router JSON + Synthesizer NL |
| B. Single-pass native tool_use | 1 | LLM llama tools mid-generation (function_calling API) |
| C. 0-pass templates | 0 | MCP devuelve contenido pre-formateado, sin LLM |
| D. Speculative execution | 1-2 | Genera respuesta mientras tools ejecutan |
| E. Router-only + passthrough | 1 | Router decide tool, MCP devuelve respuesta final |
| F. Hibrido adaptativo | 0-2 | Selector por complejidad de query |

---

## Participantes

| # | Rol | Enfoque |
|---|-----|---------|
| 1 | Codeforces Grandmaster | Complejidad algoritmica, optimalidad, edge cases matematicos |
| 2 | Senior AI Engineer | Prompt engineering, model behavior, tool_use patterns |
| 3 | Senior MLE | Arquitectura ML, produccion, observabilidad |
| 4 | Junior MLE | Testing, preguntas incomodas, edge cases |
| 5 | Junior Full Stack | DX, onboarding, mantenibilidad |
| 6 | AI Tech Lead | Arquitectura de agentes, LLM ops, decision final tecnica |
| 7 | Full Stack Lead | API design, UX, latencia percibida |
| 8 | Delivery Lead | Tiempos, riesgo, usuario final, ROI |
| 9 | Staff Engineer | Sistemas distribuidos, reliability, escalabilidad |
| 10 | Product Manager | Metricas de producto, experiencia usuario, prioridades |

---

## Ciclo 1: Analisis de Latencia Pura

**Pregunta: Cual es el ahorro real de eliminar un LLM call?**

> **Codeforces Grandmaster:** Modelemos esto como un problema de scheduling. Tenemos dos tareas secuenciales LLM1 (router) y LLM2 (synth) con una tarea intermedia MCP. El critical path es:
>
> `T_total = T_LLM1 + T_MCP + T_LLM2`
>
> Con single-pass nativo: `T_total = T_LLM_single + T_MCP + T_resume`
>
> Pero aca esta el truco: con native tool_use, el LLM genera tokens ANTES de decidir la tool (preamble), luego pausa, ejecuta tool, luego resume generacion. El T_resume no es cero -- el modelo necesita re-atender todo el contexto. En Gemini, un tool_use round es internamente 2 llamadas al modelo. Entonces single-pass nativo NO ahorra una llamada real al modelo -- ahorra el overhead de HTTP y parsing JSON, que es ~50-100ms. El ahorro neto es **~100-200ms**, no los 1-3s que uno pensaria.

> **Senior AI Engineer:** Discrepo parcialmente. Con Gemini native function_calling, si la tool se resuelve rapido (<200ms), el modelo puede continuar generando en la misma "sesion" de inferencia. El ahorro no es solo HTTP -- es que el KV cache del primer forward pass se reutiliza. Esto ahorra ~30-40% de tokens de input en el segundo pass. Pero hay un problema grave que el codebase ya identifico: `automatic_function_calling=disable=True`. Lo deshabilitaron por una razon. Gemini auto function calling tiene bugs conocidos:
> - Llama tools que no existen
> - Inventa argumentos
> - Loops infinitos (max_remote_calls existe por algo)
> - No respeta json_mode para los args
>
> El router actual con json_mode=True tiene 100% de JSON parseable (segun el docstring). Eso no lo logras con native tool_use de Gemini.

> **Senior MLE:** La pregunta correcta no es "cuanto ahorramos en latencia" sino "cuanto ahorramos en costo + latencia combinados". Cada LLM call tiene costo por token. El router usa flash-lite (~$0.01/1M tokens), el synth usa flash (~$0.04/1M tokens). Con single-pass usariamos flash para todo (no puedes hacer tool_use con flash-lite). El ahorro en latencia de ~200ms viene con un **aumento de 4x en costo del routing**. A 10K queries/dia eso es... irrelevante ($0.40 vs $0.10). Pero a 200K queries en dia de eleccion: $8 vs $2 por el routing. Aun asi insignificante.

> **Junior MLE:** Esperen. Si el ahorro real es ~200ms, y el pipeline actual ya tiene fast-routes que ahorran 1-3s completos, no seria mejor **ampliar los fast-routes** en vez de cambiar la arquitectura? Cada regex nuevo que agregamos al preprocessor ahorra mas que migrar a single-pass.

> **Junior Full Stack:** Desde el punto de vista de mantenibilidad, el pipeline de 2-pass es mas facil de debuggear. Puedo ver en los logs: "[ROUTER] tools=buscar_candidato args={nombre: keiko} reason='perfil candidato'" y luego "[LLM] pass2 ok 2000ms reply_len=450". Con single-pass nativo, todo es una caja negra. No veo que tools eligio hasta que la respuesta ya salio.

> **AI Tech Lead:** El Junior tiene razon en lo de observabilidad. Pero el Grandmaster subestima un caso: **queries sin tools**. Cuando el router devuelve `tools=[]` (saludos complejos, preguntas generales electorales), el pipeline actual cae al fallback single-pass de todas formas (core.py linea 1102-1127). Ahi si son 2 LLM calls: router que dice "no tools" + single-pass que genera respuesta. Esas queries podrian ser 1 call.

> **Full Stack Lead:** La metrica que importa al usuario no es latencia total sino **time-to-first-byte (TTFB)**. Con streaming SSE, el usuario ve caracteres a los ~500ms. Sin streaming (estado actual), espera 4-9s mirando un spinner. El delta de 200ms entre single vs 2-pass es invisible para el usuario comparado con implementar streaming.

> **Delivery Lead:** Numeros frios: 200ms de ahorro en un pipeline de 4-9s es un 2-5% de mejora. Cambiar a single-pass nativo requiere reescribir adapters, router, y el flujo en core.py. Estimacion: 3-5 dias de desarrollo + testing. El ROI es pesimo comparado con ampliar fast-routes (4 horas) o implementar streaming (2 dias).

> **Staff Engineer:** Punto critico de reliability: el pipeline de 2-pass tiene **fault isolation**. Si el router falla, el fallback single-pass toma el control. Si el synth falla, hay retry con budget. Con single-pass nativo, si la generacion falla a mitad (despues de llamar la tool), no puedes recuperar -- ya gastaste la tool call y no tienes respuesta. Habria que implementar un mecanismo de retry que re-ejecute todo, incluyendo la tool call (posible inconsistencia si la tool tiene side effects, aunque los MCPs actuales son read-only).

> **Product Manager:** El usuario promedio en Peru tiene 4G con 100-200ms de latencia de red. El round-trip web -> gateway -> LLM -> MCP -> LLM -> web agrega ~400ms de network overhead. Ahorrar 200ms en el server cuando el network agrega 400ms... El usuario no nota la diferencia. Pero SI nota si la respuesta es peor porque el single-pass eligio mal la tool.

**Veredicto Ciclo 1:** 🔄 **Necesita mas analisis**
- Single-pass nativo ahorra ~200ms, no 1-3s
- El costo economico es irrelevante en ambos casos
- El ROI de migrar a single-pass es bajo vs ampliar fast-routes o streaming
- Falta analizar calidad de respuesta (siguiente ciclo)

---

## Ciclo 2: Calidad de Respuesta

**Pregunta: La separacion router/synth mejora o empeora la calidad vs single-pass?**

> **Senior AI Engineer:** Hay un argumento fuerte a favor de 2-pass: **especializacion de prompts**. El router prompt son ~500 tokens ultra-enfocados en seleccion de tools. El synth prompt (SYNTHESIZER_INSTRUCTION) son ~800 tokens enfocados en tono, formato, neutralidad. En single-pass, necesitas AMBOS prompts en el mismo context window: ~1300 tokens de system prompt + tool catalog + historia. Esto diluye la atencion del modelo. He visto en produccion que cuando el system prompt excede ~1000 tokens, la adherencia a instrucciones cae ~15-20%.
>
> Resultado esperado: single-pass tendria peor seleccion de tools Y peor calidad de respuesta, porque un solo prompt no puede optimizar para ambas tareas simultaneamente.

> **Codeforces Grandmaster:** Hay un contraargumento informacion-teorico. En 2-pass, el synth NO ve el razonamiento del router. Solo ve: "aqui estan los resultados de tool X". Pierde el **porque** se eligio esa tool. En single-pass, el modelo tiene continuidad cognitiva -- sabe por que eligio la tool y puede tejer esa logica en la respuesta. Ejemplo:
>
> - 2-pass: Router elige `buscar_en_debate(candidato="keiko")`. Synth recibe JSON crudo. No sabe si el usuario pregunto por debate o por perfil general.
> - Single-pass: El modelo sabe que eligio debate porque el usuario dijo "en el debate" y puede contextualizar la respuesta.
>
> Pero esto se mitiga en el pipeline actual porque `intent.enriched_message` se pasa al synth, no solo los datos.

> **Senior MLE:** Datos concretos del eval baseline (eval_baseline_20260321): las sesiones evaluadas muestran que el 2-pass router tiene buena precision en seleccion de tools (el router prompt fue iterado extensivamente). Los problemas de calidad no vienen del routing sino del synth: respuestas demasiado largas, datos omitidos, tono inconsistente. Esos problemas existirian igual en single-pass -- son problemas de prompt, no de arquitectura.

> **Junior MLE:** Caso edge que me preocupa: comparaciones multi-candidato. El usuario dice "compara keiko con acuna en educacion". El router elige `comparar_candidatos_debate`. Pero que pasa si el MCP devuelve datos incompletos de un candidato? En 2-pass, el synth puede decir "no encontre datos de Acuna sobre educacion". En single-pass, el modelo ya empezo a generar "Comparando a Keiko y Acuna en educacion:" antes de tener los datos... y luego tiene que hacer backtracking textual. Los modelos son malos en backtracking.

> **AI Tech Lead:** Punto critico: el `ROUTER_PROMPT` actual incluye reglas de negocio complejas:
> - "debate en query -> SIEMPRE tools de debate"
> - "2+ nombres + debate -> comparar_candidatos_debate, NO buscar_en_debate"
> - "EXCLUIDOS: Castillo, Vizcarra..." -> tools=[]
> - "PEYORATIVOS -> tools=[], rechazar premisa"
>
> En single-pass, estas reglas estarian mezcladas con las reglas de formato de respuesta. La probabilidad de que el modelo ignore una regla aumenta con cada regla adicional. El 2-pass permite **reglas compartimentadas**: reglas de routing en un prompt, reglas de output en otro.

> **Full Stack Lead:** Desde el frontend: la calidad de respuesta tiene dos dimensiones que el usuario percibe: (1) relevancia (le respondio lo que pregunto) y (2) presentacion (formato, tono, completitud). El 2-pass optimiza ambas por separado. Si migramos a single-pass y la relevancia baja un 5%, el NPS cae mas que si la latencia sube 500ms.

> **Junior Full Stack:** Pregunta practica: si mantenemos 2-pass, podemos mejorar la calidad del synth SIN cambiar arquitectura? Por ejemplo, pasarle el `reasoning` del router como contexto adicional. Hoy se pierde esa info.

> **Delivery Lead:** El Junior Full Stack tiene un punto excelente. La mejora de calidad mas barata es pasar `llm_route.reasoning` al synthesizer. Cero cambio arquitectural, ~30 minutos de implementacion. Eso captura parte del beneficio que el Grandmaster menciono sobre continuidad cognitiva.

> **Staff Engineer:** Testing de calidad: para decidir si single-pass es mejor o peor, necesitariamos un A/B test con al menos 200 queries del eval set. Eso son 400 LLM calls (200 por variante). Costo: ~$1. Tiempo: 2-3 horas incluyendo evaluacion manual. Antes de cualquier decision arquitectural, hagamos el test.

> **Product Manager:** Nuestra base de usuarios son peruanos buscando info electoral. No son power users de AI. Un error en la seleccion de tool (le muestra datos de debate cuando pregunto por perfil) es mas danino que 2 segundos extra de espera. La calidad no es negociable.

**Veredicto Ciclo 2:** 🔄 **Necesita cambios menores, no migracion**
- 2-pass tiene ventaja en calidad por especializacion de prompts
- Quick win: pasar `reasoning` del router al synth
- Antes de decidir: A/B test con eval set (200 queries, $1, 3h)
- Single-pass nativo NO recomendado por riesgo de regresion en calidad

---

## Ciclo 3: 0-Pass Templates (Passthrough Expansion)

**Pregunta: Que porcentaje de queries podemos resolver con 0 LLM calls?**

> **Codeforces Grandmaster:** El problema de maximizar passthrough es un problema de cobertura de conjuntos. Tenemos N patrones de query y queremos cubrir el maximo con regex/templates sin falsos positivos. El trade-off es:
>
> ```
> Cobertura = f(num_reglas)
> Precision = g(1/complejidad_reglas)
> ```
>
> Las fast-routes actuales cubren 3 patrones. Segun los logs de produccion (doc 07-performance: passthrough rate ~15%), hay espacio para crecer. Estimacion teorica de queries templateables:
>
> | Categoria | % de queries | Templateable? |
> |---|---|---|
> | Lista candidatos | ~10% | SI - ya existe |
> | Fecha elecciones | ~5% | SI - ya existe |
> | Local votacion (DNI) | ~3% | SI - ya existe |
> | Perfil candidato simple | ~25% | PARCIAL - MCP puede pre-formatear |
> | Comparaciones | ~15% | NO - necesita sintesis |
> | Debate | ~10% | NO - necesita sintesis |
> | Propuestas por tema | ~12% | PARCIAL - lista + contexto |
> | Preguntas generales | ~8% | NO - necesita LLM |
> | Saludos / meta | ~7% | SI - ya existe (instant_reply) |
> | Antecedentes | ~5% | PARCIAL - datos sensibles necesitan tono |

> **Senior AI Engineer:** El passthrough actual funciona porque `lista_formateada` es un campo que el MCP genera como texto plano markdown. Podemos expandir esto a cualquier MCP que devuelva un campo `respuesta_formateada`. Pero hay un riesgo: si el MCP genera la respuesta final, pierde la capa de personalizacion del synth (tono VOTI, emojis, disclaimer). Tendriamos que duplicar esa logica en cada MCP server. Eso viola DRY y hace que cambiar el tono requiera deploys en 5+ MCPs.

> **Senior MLE:** Propuesta concreta para maximizar 0-pass sin mover logica a MCPs:
>
> 1. **Template engine en gateway**: Para queries con estructura predecible, un template Jinja2 en el gateway toma los datos del MCP y genera la respuesta.
> 2. Los templates viven en `src/agent/templates/` -- un archivo por patron.
> 3. El router (regex o LLM) decide si aplica template o synth.
>
> ```
> Preprocessor -> Fast-route -> MCP call -> Template render -> Output filter
>                                            (sin LLM!)
> ```
>
> Esto ahorra el synth LLM call (1-5s) sin tocar los MCPs.

> **Junior MLE:** Pero los templates no manejan edge cases. Que pasa si el usuario dice "cuentame de keiko, la china" y el template recibe datos de Keiko Fujimori? El template no sabe que "la china" es un apodo y no va a decir "Te cuento sobre Keiko Fujimori, conocida como 'la china'...". El LLM synth SI hace esa conexion porque tiene el mensaje original.

> **AI Tech Lead:** Los numeros del Grandmaster son utiles. Si cubrimos "perfil candidato simple" con templates, pasamos de 15% a ~30% passthrough. Eso es 30% de queries con latencia de ~0.5s (solo MCP call) en vez de ~4s. Masivo.
>
> Pero necesitamos un mecanismo de **fallback**: si el template no puede generar una respuesta satisfactoria (datos incompletos, query ambigua), cae al synth LLM. Esto es exactamente el patron actual de fast-route -> LLM router fallback.
>
> Arquitectura propuesta:
>
> ```
> Preprocessor
>   |
>   v
> [0-pass] Instant reply? ------> DONE
>   |
>   v
> [0-pass] Fast-route + Template? --> Template render --> DONE
>   |                                    |
>   |                                    v (template fallo)
>   v                                    |
> [1-pass] Router LLM -------> MCP ------+
>   |                                    |
>   v                                    v
> [2-pass] Synth LLM <----- datos MCP complejos
>   |
>   v
> DONE
> ```

> **Full Stack Lead:** Me gusta la idea de templates, pero el mantenimiento es clave. Cada template es un archivo que alguien tiene que actualizar cuando cambia el formato de datos del MCP. Si el MCP de perfiles agrega un campo `hechos_relevantes`, el template tiene que actualizarse manualmente. Con el LLM synth, se adapta automaticamente.

> **Junior Full Stack:** Podemos usar templates con fallback automatico? Si el template tiene un campo `{{ candidato.hechos_relevantes }}` y el MCP no lo devuelve, Jinja2 puede renderizar sin ese bloque. Es resiliente por defecto si usamos `{% if candidato.hechos_relevantes %}`.

> **Delivery Lead:** El trade-off es claro:
>
> | Factor | Templates | LLM Synth |
> |---|---|---|
> | Latencia | ~0.5s | ~2-5s |
> | Costo LLM | $0 | ~$0.001/query |
> | Mantenimiento | Manual por campo nuevo | Automatico |
> | Tono/personalidad | Estatico | Dinamico |
> | Edge cases | Falla silenciosamente | Se adapta |
>
> Recomendacion: templates SOLO para queries de tipo "lista" (candidatos, propuestas por partido). Para perfiles individuales, el LLM synth sigue siendo necesario por la variabilidad del tono.

> **Staff Engineer:** Un punto que nadie ha mencionado: los templates son **deterministas**. Dado el mismo input MCP, siempre producen el mismo output. Esto es una ventaja enorme para testing y cache. Puedo escribir un unit test que diga: "dado este JSON de candidato, el template produce este markdown". Imposible con LLM synth.

> **Product Manager:** Si pasamos de 15% a 30% passthrough, eso es un 30% de usuarios que reciben respuesta en <1s en vez de 4s. En mobile Peru, eso es la diferencia entre "esta app vuela" y "esta app es lenta". Prioridad alta.

**Veredicto Ciclo 3:** ✅ **Aprobado: Expandir passthrough con templates**
- Implementar template engine para: listas de candidatos, propuestas por partido, perfil simple
- Templates con fallback a LLM synth
- Meta: passthrough 15% -> 30-35%
- Esfuerzo: 2-3 dias
- NO mover logica de tono a los MCPs

---

## Ciclo 4: Speculative Execution

**Pregunta: Podemos empezar a generar la respuesta mientras los tools ejecutan?**

> **Codeforces Grandmaster:** Speculative execution en LLMs es un problema interesante. La idea es:
>
> ```
> t=0:    Router LLM empieza
> t=1.5s: Router termina, MCP calls empiezan
> t=1.5s: SIMULTANEAMENTE, Synth LLM empieza con placeholder
> t=1.7s: MCP calls terminan
> t=1.7s: Synth LLM recibe datos reales, continua generacion
> ```
>
> El problema: **no puedes inyectar datos a mitad de una generacion LLM**. Los LLMs actuales (Gemini, Claude, GPT) no soportan "pause, inject context, resume". El KV cache se invalida si cambias el input.
>
> La unica forma seria: empezar la generacion con un "skeleton" ("Sobre [candidato], te cuento: ...") y luego hacer un fill-in. Pero eso es basicamente 2 llamadas LLM disfrazadas.

> **Senior AI Engineer:** Hay una variante que SI funciona: **streaming the router while preparing the synth**. El router responde en JSON (~100-300 tokens). En cuanto parseamos el primer tool del JSON (incluso antes de que termine la generacion), podemos disparar la MCP call. Con streaming del router:
>
> ```
> t=0:      Router streaming empieza
> t=0.8s:   Primer tool visible en stream parcial
> t=0.8s:   MCP call 1 dispara (paralelo al router)
> t=1.5s:   Router termina, MCP call 2 dispara
> t=1.0s:   MCP call 1 ya termino
> t=1.7s:   MCP call 2 termina
> t=1.7s:   Synth empieza (tenia MCP 1 desde t=1.0)
> ```
>
> Ahorro: ~0.5-0.7s overlap entre router streaming y MCP calls. Pero la complejidad de implementacion es alta: parsear JSON parcial en streaming, manejar errores mid-stream, timeout por tool individual.

> **Senior MLE:** He visto este patron en produccion en otros sistemas. El problema es que el JSON del router no es parseable hasta que se cierra el bracket. No puedes saber que el tool es `buscar_candidato` hasta que ves `"name": "buscar_candidato"`. Con streaming, eso llega en los primeros ~50 tokens (~200ms). El ahorro real es:
>
> ```
> Sin overlap:  Router(1.5s) + MCP(0.2s) + Synth(2s) = 3.7s
> Con overlap:  Router(1.5s) + max(0, MCP(0.2s) - overlap(0.7s)) + Synth(2s) = 3.0s
> Ahorro: ~0.7s (19%)
> ```
>
> No esta mal, pero la complejidad del codigo aumenta significativamente.

> **Junior MLE:** Pregunta incomoda: y si el router cambia de opinion sobre la tool a mitad del streaming? Empieza con `"name": "buscar_cand` y pensamos que es `buscar_candidato_por_dni` pero termina siendo `buscar_candidatos_region`. Ya disparamos la MCP call equivocada. Wasted call + posible inconsistencia.

> **AI Tech Lead:** El Junior identifica el riesgo central de speculative execution: **branch misprediction**. En CPUs, un branch misprediction cuesta ~15 ciclos. En nuestro sistema, un MCP call incorrecto cuesta ~0.2s y una MCP connection del pool. Con 5% de misprediction rate:
>
> - 95% de queries: ahorra 0.7s
> - 5% de queries: desperdicia 0.2s + agrega complejidad de manejo de error
> - Net: 0.95 * 0.7 - 0.05 * 0.2 = **0.655s ahorro promedio**
>
> Pero la complejidad del codigo pasa de "secuencial lineal" a "concurrent state machine with rollback". Los bugs de concurrencia son los mas dificiles de debuggear.

> **Full Stack Lead:** Si implementamos streaming al frontend (SSE), la speculative execution se vuelve menos relevante. El usuario ya esta viendo "Buscando informacion de Keiko..." mientras el pipeline ejecuta. El TTFB es ~200ms (mensaje de estado). El ahorro de 0.7s es real pero el impacto percibido es menor con streaming.

> **Junior Full Stack:** La complejidad de esta feature me asusta. El `_process_with_budget` en core.py ya tiene 180+ lineas con manejo de budget, retries, fallbacks. Agregarle concurrencia especulativa lo haria inmantenible.

> **Delivery Lead:** Costo-beneficio:
> - Implementacion: 5-7 dias (streaming JSON parser + concurrent MCP dispatch + rollback + tests)
> - Ahorro: ~0.7s por query
> - Riesgo: bugs de concurrencia en produccion, dia de eleccion
> - Alternativa: streaming SSE al frontend (2 dias) tiene mejor impacto percibido
>
> **Rechazado por ROI negativo**.

> **Staff Engineer:** Concuerdo con el Delivery Lead. Speculative execution es una optimizacion prematura clasica. El pipeline actual es correcto, secuencial, debuggeable. Si en el futuro medimos que el cuello de botella es el overlap router/MCP (con datos de produccion), reconsideramos. Hoy no.

> **Product Manager:** Paso. No vale el riesgo. Siguiente.

**Veredicto Ciclo 4:** ❌ **Rechazado**
- Ahorro real: ~0.7s (19%)
- Complejidad: alta (concurrent state machine)
- Riesgo: bugs de concurrencia en dia critico
- Alternativa mejor: streaming SSE al frontend

---

## Ciclo 5: Router-Only + Passthrough Expandido

**Pregunta: Podemos hacer que el MCP devuelva respuestas finales, eliminando el synth para mas queries?**

> **Codeforces Grandmaster:** Esto es un trade-off clasico de acoplamiento vs performance. Si el MCP genera la respuesta final, movemos la logica de presentacion al MCP layer. Formalmente:
>
> ```
> Antes:  MCP = f(query) -> datos_estructurados
>         Synth = g(datos_estructurados, tono, formato) -> respuesta_NL
>
> Despues: MCP = h(query, tono, formato) -> respuesta_NL
> ```
>
> El problema es que `h` acopla datos + presentacion. Cualquier cambio en tono/formato requiere deploy de 5 MCPs. Es el anti-patron "smart endpoint, dumb pipe" invertido.

> **Senior AI Engineer:** Hay un termino medio: **MCP genera datos + template hint**. El MCP devuelve:
>
> ```json
> {
>   "data": { ... },
>   "template": "perfil_candidato",
>   "can_passthrough": true,
>   "fallback_context": "perfil completo con antecedentes"
> }
> ```
>
> El gateway decide: si `can_passthrough && template exists`, usa template. Si no, synth LLM. Los MCPs no generan texto -- solo dicen "mis datos son suficientemente simples para un template".

> **Senior MLE:** Esto es elegante pero requiere que cada MCP conozca la lista de templates disponibles. Acoplamiento inverso. Mejor: el gateway tiene una tabla de `{tool_name, query_pattern} -> template`. El gateway decide, no el MCP.

> **Junior MLE:** Ya existe esto. `_has_formatted_list` en core.py checa si el resultado tiene `lista_formateada`. Es un mecanismo ad-hoc para un caso. La propuesta es generalizarlo.

> **AI Tech Lead:** Propuesta concreta de expansion:
>
> ```python
> # Tabla de templates en gateway (no en MCPs)
> TOOL_TEMPLATES = {
>     "listar_candidatos_region": "templates/lista_candidatos.jinja2",
>     "info_dia_elecciones": "templates/fecha_eleccion.jinja2",
>     "buscar_candidato_por_dni": "templates/perfil_simple.jinja2",  # solo si datos completos
>     "buscar_propuesta_tema": "templates/propuestas_tema.jinja2",
>     "estadisticas_candidatos": "templates/estadisticas.jinja2",
> }
>
> # En el pipeline, despues de MCP calls:
> if tool_name in TOOL_TEMPLATES and _data_is_complete(result):
>     reply = render_template(TOOL_TEMPLATES[tool_name], result)
> else:
>     reply = await synth_llm(result, message)  # fallback a LLM
> ```
>
> Esto mantiene la separacion datos/presentacion. Los MCPs no cambian. El gateway es el unico que sabe de templates.

> **Full Stack Lead:** Me gusta. El flujo adaptativo seria:
>
> ```
> Query simple + datos completos  ->  0-pass (template)       ~0.5s
> Query compleja + datos simples  ->  1-pass (router + template) ~2s
> Query compleja + datos complejos -> 2-pass (router + synth)    ~4s
> ```
>
> La latencia media bajaria de ~4s a ~2.5s si el 30% de queries usa templates.

> **Junior Full Stack:** Quien decide si los datos son "completos" para el template? Necesitamos un `_data_is_complete()` por template. Eso es mantenimiento extra. Sugiero: si el template renderiza sin errores y tiene >100 chars de output, es completo. Si no, fallback.

> **Delivery Lead:** Esta propuesta es la ganadora. Resume:
> - Sin cambios a MCPs
> - Templates viven en gateway
> - Fallback automatico a LLM synth
> - Esfuerzo: 2-3 dias (mismo que ciclo 3)
> - Impact: 30% de queries bajan de 4s a <1s

> **Staff Engineer:** Agrego un punto: los templates deben pasar por el output_filter existente. No podemos bypassear las validaciones de neutralidad solo porque no usamos LLM. Un template mal escrito puede tener sesgo.

> **Product Manager:** Apruebo. La experiencia de "respuesta instantanea para preguntas simples" es un diferenciador. Los usuarios de WhatsApp (4G lento) se benefician enormemente.

**Veredicto Ciclo 5:** ✅ **Aprobado: Template engine en gateway**
- Misma conclusion que ciclo 3, pero con diseno mas concreto
- Tabla TOOL_TEMPLATES en gateway
- _data_is_complete() por template
- Output filter SIEMPRE aplica
- Esfuerzo: 2-3 dias

---

## Ciclo 6: El Caso "tools=[]" (Router Dice No Tools)

**Pregunta: Cuando el router dice tools=[], el pipeline hace 2 LLM calls para una respuesta sin datos. Podemos optimizarlo?**

> **Codeforces Grandmaster:** Segun el codigo, cuando `llm_route.tools == []` y el pipeline no genera `reply_text`, cae al bloque de fallback single-pass (linea 1102). Ahi hace una llamada LLM completa con `self._tool_declarations` (lista de tools en el prompt). Total: 2 LLM calls para una respuesta conversacional.
>
> Esto es suboptimo. Si el router ya decidio que no necesita tools, podemos ir directo a una generacion sin tools:
>
> ```
> Router dice tools=[] + reasoning="saludo complejo"
>   -> Generar respuesta sin tool catalog en prompt
>   -> Ahorra ~500 tokens de input (tool catalog no incluido)
>   -> Respuesta mas rapida (menos tokens = menos latencia)
> ```

> **Senior AI Engineer:** El fix es simple. Despues de que el router devuelve `tools=[]`, en vez de caer al fallback generico, hacer una llamada synth directa con el reasoning del router como contexto:
>
> ```python
> if llm_route.routed and not llm_route.tools:
>     # Router dijo "no tools needed" — generar respuesta directa
>     messages = self._build_messages(history, intent.enriched_message)
>     response, elapsed = await self._llm_call(
>         messages, budget, reserve=0.3,
>         tools=[],  # sin tool catalog
>         system_prompt=self.synth_prompt,  # prompt liviano
>     )
>     reply_text = response.text or ""
> ```
>
> Ahorro: eliminamos ~500 tokens de tool catalog del input. Con flash, eso es ~100ms menos de latencia y cero costo extra.

> **Senior MLE:** Mas agresivo: para `tools=[]`, podemos hacer **0-pass** si el reasoning indica una categoria conocida:
>
> - reasoning="saludo" -> instant_reply (ya cubierto por preprocessor)
> - reasoning="fuera de tema" -> template de rechazo
> - reasoning="figura excluida" -> template de "X no es candidato 2026"
> - reasoning="peyorativo" -> template de rechazo de premisa
>
> Solo el caso "pregunta general electoral" (explicar que es segunda vuelta, etc.) realmente necesita LLM.

> **Junior MLE:** Cuantas queries caen en `tools=[]`? Sin ese dato no podemos estimar el impacto. Si es 5% de queries, el ahorro es marginal. Si es 30%, es significativo.

> **AI Tech Lead:** Estimacion basada en el router prompt: los unicos casos de `tools=[]` son "saludos puros" (ya capturados por preprocessor), "temas no electorales", y "figuras excluidas". Si el preprocessor funciona bien, muy pocos saludos llegan al router. Estimacion: 5-10% de queries llegan al router y reciben `tools=[]`. De esas, la mayoria son "fuera de tema" o "excluidos".
>
> Fix propuesto (bajo esfuerzo, alto impacto por query):
>
> ```python
> # Despues del router, antes del fallback
> if llm_route.routed and not llm_route.tools:
>     # Clasificar por reasoning
>     r = llm_route.reasoning.lower()
>     if "excluido" in r or "no es candidato" in r:
>         reply_text = "Esa persona no es candidato en las elecciones 2026. Puedo ayudarte con los candidatos actuales?"
>     elif "peyorativo" in r or "ofensivo" in r:
>         reply_text = "Prefiero no usar esos terminos. Puedo darte informacion objetiva sobre cualquier candidato."
>     elif "fuera de tema" in r or "no electoral" in r:
>         reply_text = "Solo puedo ayudarte con temas electorales. Que quieres saber sobre las elecciones 2026?"
>     else:
>         # Genuina pregunta general -> LLM sin tools
>         messages = self._build_messages(history, intent.enriched_message)
>         response, _ = await self._llm_call(messages, budget, tools=[], system_prompt=self.synth_prompt)
>         reply_text = response.text or ""
> ```

> **Full Stack Lead:** Me gusta. Esto elimina la 2da LLM call para el 80% de los `tools=[]`. Solo las preguntas generales electorales genuinas (5-10% del 5-10%) pasan al LLM.

> **Junior Full Stack:** Cuestion: si dependemos del `reasoning` del router para clasificar, y el reasoning cambia de formato ("no es candidato" vs "excluido por regla"), los templates se rompen. Mejor: que el router devuelva un campo `category` ademas de `reasoning`.

> **Delivery Lead:** El fix del AI Tech Lead es de 2-4 horas. Impact bajo en porcentaje total de queries, pero alto por query afectada (elimina 1-3s de latencia). Aprobado como quick win.

> **Staff Engineer:** Concuerdo. Es una optimizacion quirurgica que no cambia la arquitectura. Bajo riesgo.

> **Product Manager:** Apruebo. Es invisible para el usuario (misma respuesta, mas rapido) y mejora la experiencia de "VOTI no sabe de eso" sin espera innecesaria.

**Veredicto Ciclo 6:** ✅ **Aprobado: Template responses para tools=[]**
- Templates estaticos para: excluidos, peyorativos, fuera de tema
- LLM solo para preguntas generales electorales genuinas
- Esfuerzo: 2-4 horas
- Impact: elimina 1 LLM call para 80% de queries tools=[]

---

## Ciclo 7: Native Tool Use de Gemini -- Deep Dive Tecnico

**Pregunta: Hay algun escenario donde activar Gemini native function_calling (hoy deshabilitado) tenga sentido?**

> **Codeforces Grandmaster:** Revisemos por que se deshabilito. El codigo dice `automatic_function_calling=disable=True, maximum_remote_calls=0`. Esto significa que Gemini PUEDE sugerir function calls (en su respuesta), pero NO las ejecuta automaticamente. El gateway las ejecuta manualmente en `_handle_response`. El problem no es function_calling per se -- es AUTOMATIC function calling (donde Gemini ejecuta las funciones el mismo via HTTP).
>
> Entonces ya usamos native function_calling en el fallback single-pass path. Solo deshabilitamos la ejecucion automatica. El debate es: activar `automatic_function_calling`? o ampliar el uso de function_calling manual (que ya existe) al hot path?

> **Senior AI Engineer:** Excelente distincion. El hot path actual (2-pass) usa json_mode en el router, NO function_calling. Podriamos reemplazar el router por function_calling:
>
> ```
> Hoy (hot path):
>   Router: json_mode=True, tools=[] -> JSON {tools, args}
>   (parsing manual)
>
> Alternativa:
>   Router: json_mode=False, tools=TOOL_DECLARATIONS -> tool_call response
>   (parsing nativo de Gemini)
> ```
>
> Ventaja: Gemini ya entiende los schemas de las tools (type, required, description). El JSON del router actual requiere que el prompt describa las tools en texto plano. Con function_calling nativo, Gemini usa los JSON Schemas directamente.
>
> Desventaja: function_calling nativo de Gemini solo devuelve UNA tool call por turno (sin parallel function calling). El router actual puede devolver multiples tools en un JSON array.

> **Senior MLE:** Correccion: Gemini SI soporta parallel function calling desde 2.0. Puede devolver multiples `function_call` parts en una sola respuesta. Pero hay un bug conocido: a veces mezcla text parts con function_call parts, y el parsing es inconsistente.
>
> El json_mode actual es mas confiable: 100% parseable, formato predecible, multi-tool natural.

> **Junior MLE:** He testeado Gemini function_calling con tools similares a las nuestras (buscar_candidato, listar_candidatos). Resultados:
> - Precision de seleccion de tool: ~92% (vs ~95% con router json_mode actual)
> - Inventar parametros no existentes: ~8% de las veces
> - Latencia: similar (~1.5s)
>
> El router custom con json_mode + prompt optimizado es MEJOR que el function_calling nativo de Gemini. Esto tiene sentido: nuestro prompt tiene reglas de negocio especificas ("debate en query -> tools de debate") que el function_calling nativo no puede seguir.

> **AI Tech Lead:** Conclusion clara: el function_calling nativo de Gemini es un buen default para sistemas genericos, pero nuestro router custom es superior para nuestro caso de uso especifico. Las reglas de negocio del ROUTER_PROMPT son el diferenciador.
>
> Hay UN caso donde function_calling nativo seria util: el **fallback single-pass** (linea 1102). Hoy cuando el router falla, el single-pass genera una respuesta Y puede sugerir una tool call. Si sugiere tool call, se ejecuta y se hace un segundo LLM call. Ahi el function_calling nativo ya esta en uso y funciona. No hay nada que cambiar.

> **Full Stack Lead:** Desde la perspectiva de API, el function_calling nativo seria relevante si migraramos a un modelo mas potente (Claude, GPT-4o) para el synth. Esos modelos tienen function_calling mas robusto. Pero eso es un cambio de provider, no de arquitectura.

> **Junior Full Stack:** Me quedo con la conclusion: no tocar el function_calling. El router custom funciona mejor para nuestro caso.

> **Delivery Lead:** Sin accion requerida. El codebase ya tiene la configuracion correcta. Siguiente.

> **Staff Engineer:** Acuerdo. La desicion de deshabilitar automatic function calling fue correcta. La configuracion actual (disable=True, manual execution en fallback) es el mejor balance.

> **Product Manager:** Entendido. No tocar.

**Veredicto Ciclo 7:** ✅ **Confirmado: Mantener configuracion actual**
- `automatic_function_calling=disable=True` es correcto
- Router custom (json_mode) > function_calling nativo para nuestro caso
- El fallback single-pass ya usa function_calling manual correctamente
- 0 horas de esfuerzo (no hacer nada)

---

## Ciclo 8: Hibrido Adaptativo -- Arquitectura Final

**Pregunta: Como se ve el pipeline optimo combinando todas las conclusiones?**

> **Codeforces Grandmaster:** Formalizando el decision tree optimo:
>
> ```
> Input: mensaje M, historial H, entidades E
>
> Paso 0: Preprocessor (0ms)
>   - Greeting puro?       -> instant_reply [0 LLM calls, ~0ms]
>   - Meta-question?       -> instant_reply [0 LLM calls, ~0ms]
>   - Neutralidad?         -> instant_reply [0 LLM calls, ~0ms]
>
> Paso 1: Fast-route check (0ms)
>   - Regex match?         -> MCP call -> Template render [0 LLM calls, ~0.5s]
>                             (fallback a Paso 3 si template falla)
>
> Paso 2: Router LLM (1-3s)
>   - tools=[]?
>     - Excluido/peyorativo/fuera_tema? -> Template estatico [1 LLM call, ~1.5s]
>     - Pregunta general?              -> LLM sin tools [1 LLM call, ~3s total]
>   - tools=[T1, T2...]?
>     -> MCP calls paralelas (~0.2s)
>     -> Datos completos + template existe? -> Template render [1 LLM call, ~2s]
>     -> Datos complejos?                   -> Synth LLM [2 LLM calls, ~4s]
>
> Paso 3: Fallback single-pass (si router fallo)
>   -> LLM con tool declarations [1-2 LLM calls, ~3-5s]
> ```

> **Senior AI Engineer:** Diagrama de latencia esperada por tipo de query:
>
> ```
> Query Type          | Calls | Latency | % Queries
> --------------------|-------|---------|----------
> Saludo puro         |   0   |  ~0ms   |   ~7%
> Lista candidatos    |   0   | ~0.5s   |  ~10%
> Fecha elecciones    |   0   | ~0.3s   |   ~5%
> Local votacion      |   0   | ~0.5s   |   ~3%
> Perfil simple       |   1   | ~2.0s   |  ~15%  (router + template)
> Excluido/off-topic  |   1   | ~1.5s   |   ~5%
> Propuestas tema     |   1   | ~2.0s   |  ~10%  (router + template)
> Perfil complejo     |   2   | ~4.0s   |  ~15%
> Comparacion         |   2   | ~4.5s   |  ~15%
> Debate              |   2   | ~5.0s   |  ~10%
> General electoral   |   1   | ~3.0s   |   ~5%
> --------------------|-------|---------|----------
> Promedio ponderado  | ~1.1  | ~2.3s   |  100%
> ```
>
> Vs pipeline actual:
> ```
> Pipeline actual promedio: ~1.7 LLM calls, ~3.8s latencia media
> Pipeline hibrido:        ~1.1 LLM calls, ~2.3s latencia media
> Mejora: -35% LLM calls, -39% latencia
> ```

> **Senior MLE:** Los numeros son convincentes. Pero la complejidad del codigo aumenta. Hoy `_process_with_budget` tiene 3 paths: instant_reply, 2-pass, fallback. Con el hibrido tendria 6+ paths. Propongo: NO refactorizar en un megametodo. Extraer a un `PipelineStrategy` con polimorfismo:
>
> ```python
> class PipelineStrategy(Protocol):
>     async def execute(self, intent, budget, ...) -> ProcessResponse: ...
>
> class InstantReplyStrategy: ...    # 0 LLM calls
> class TemplateStrategy: ...        # 0 LLM calls (fast-route + template)
> class RouterTemplateStrategy: ...  # 1 LLM call (router + template)
> class RouterSynthStrategy: ...     # 2 LLM calls (router + synth)
> class FallbackStrategy: ...        # 1-2 LLM calls (single-pass)
> ```
>
> Cada strategy es testeable en aislamiento.

> **Junior MLE:** Eso es elegante pero es over-engineering? Hoy funciona con un if/elif chain. Agregar polimorfismo para 5 strategies es mas codigo, mas archivos, mas indirection. El CLAUDE.md dice "No Over-Engineering: la solucion mas simple que funcione".

> **AI Tech Lead:** El Junior tiene razon en citar los principios. Pero 180 lineas en `_process_with_budget` ya estan en el limite. Con 6 paths seria ~250 lineas. Compromise: extraer helpers, no crear classes. Un `_try_template_response()` y un `_try_static_response()` como funciones helper dentro de core.py.

> **Full Stack Lead:** Concuerdo con el AI Tech Lead. Helpers > strategies. Mantenemos la legibilidad del flujo lineal pero extraemos la logica a funciones con nombres descriptivos.

> **Junior Full Stack:** Me gusta que cada path tenga su propio logger.info con el nombre del path. Asi puedo grep "TEMPLATE" o "PASSTHROUGH" o "2-PASS" en los logs y entender que paso.

> **Delivery Lead:** Resumen de implementacion:
>
> | Fase | Que | Esfuerzo | Impact |
> |------|-----|----------|--------|
> | 1 | Templates estaticos para tools=[] | 2-4h | -1 LLM call para ~5% queries |
> | 2 | Template engine (Jinja2) para fast-routes | 2d | -2 LLM calls para ~15% queries |
> | 3 | Router + template para perfil simple | 1d | -1 LLM call para ~15% queries |
> | 4 | Pasar reasoning al synth | 30min | Mejor calidad, 0 cambio arq |
> | **Total** | | **~4 dias** | **~35% menos LLM calls, ~39% menos latencia** |

> **Staff Engineer:** La fase 1 y 4 son quick wins. Implementar primero, medir, luego decidir si las fases 2-3 valen la pena con datos de produccion.

> **Product Manager:** Apruebo el plan por fases. Cada fase entrega valor independientemente. Si la fase 1+4 ya muestra mejora, podemos priorizar otras features sobre la fase 2-3.

**Veredicto Ciclo 8:** ✅ **Aprobado: Pipeline hibrido adaptativo por fases**
- Fase 1 (quick wins): templates estaticos + reasoning al synth (1 dia)
- Fase 2 (template engine): Jinja2 para fast-routes (2 dias)
- Fase 3 (router+template): perfil simple sin synth (1 dia)
- Helpers en core.py, NO strategy pattern
- Meta: 1.7 -> 1.1 LLM calls/request, 3.8s -> 2.3s latencia media

---

## Ciclo 9: Riesgos y Mitigaciones

**Pregunta: Que puede salir mal con el pipeline hibrido?**

> **Codeforces Grandmaster:** Riesgo formal: el pipeline hibrido tiene mas decision points = mas superficie de bugs. Cuantifico:
>
> ```
> Pipeline actual: 3 paths -> 3 test scenarios minimos
> Pipeline hibrido: 6 paths -> 6 test scenarios minimos
>
> Pero las combinaciones con error handling:
> - Actual: 3 paths * 3 failure modes = 9 scenarios
> - Hibrido: 6 paths * 3 failure modes = 18 scenarios
>
> Test coverage duplica. Pero cada path es MAS SIMPLE que el path actual
> (templates son deterministicos, no hay LLM non-determinism).
> ```
>
> Conclusion: mas paths pero cada path mas predecible. El testing total es manejable.

> **Senior AI Engineer:** Riesgo #1: **template drift**. El MCP agrega un campo nuevo (ej: `hechos_relevantes`), el template no lo muestra, el usuario no ve informacion disponible. Mitigacion: CI check que compara campos del MCP schema vs campos usados en templates. Alerta si hay mismatch.

> **Senior MLE:** Riesgo #2: **clasificacion incorrecta por el router**. Si el router dice tools=[] y clasificamos como "excluido" basandonos en el reasoning, pero la query era genuina... el usuario recibe un template generico en vez de informacion real. Mitigacion: log + alerta cuando `tools=[] && reasoning no matchea ningun template category`. Review manual semanal.

> **Junior MLE:** Riesgo #3: **regression en calidad de templates vs LLM**. Los templates son estaticos, no se adaptan al tono del usuario. Si el usuario escribe en jerga peruana y el template responde formal, hay disonancia. Mitigacion: A/B test templates vs LLM synth con metricas de satisfaccion.

> **AI Tech Lead:** Riesgo #4: **cascading fallbacks**. Template falla -> LLM synth falla -> fallback single-pass falla -> timeout. Son 3 niveles de fallback. Necesitamos un limit: si el template falla, ir directo a fallback con mensaje amigable, no intentar el path completo. Maximos 2 attempts por request.

> **Full Stack Lead:** Riesgo #5: **inconsistencia de UX**. Queries similares toman paths distintos y producen respuestas con estilos diferentes (template vs LLM). El usuario nota que a veces "suena diferente". Mitigacion: templates escritos con el tono de VOTI (calido, tuteo, emojis moderados). Revision de tono por el Delivery Lead.

> **Junior Full Stack:** Riesgo #6: **mantenimiento de templates**. Hoy, cambiar el tono de VOTI es cambiar SYNTHESIZER_INSTRUCTION (1 archivo). Con templates, es cambiar N templates + SYNTHESIZER_INSTRUCTION. Mitigacion: templates heredan de un `base_template.jinja2` con el tono comun.

> **Delivery Lead:** Consolidando riesgos y mitigaciones:
>
> | Riesgo | Probabilidad | Impacto | Mitigacion |
> |---|---|---|---|
> | Template drift (campos nuevos) | Media | Medio | CI schema check |
> | Clasificacion incorrecta tools=[] | Baja | Alto | Log + review semanal |
> | Calidad template < LLM | Media | Medio | A/B test |
> | Cascading fallbacks | Baja | Alto | Max 2 attempts |
> | Inconsistencia UX | Media | Bajo | Base template + review tono |
> | Mantenimiento N templates | Media | Bajo | Herencia Jinja2 |
>
> Ninguno es bloqueante. Todos tienen mitigacion razonable.

> **Staff Engineer:** Agrego: monitoreo. Necesitamos metricas por path:
>
> ```
> RESULT zone=green path=template total=0.5s tools=listar_candidatos
> RESULT zone=green path=router_template total=2.0s tools=buscar_candidato
> RESULT zone=yellow path=router_synth total=4.5s tools=comparar_debate
> RESULT zone=red path=fallback total=8.0s tools=none
> ```
>
> El campo `path` en el log permite dashboards por tipo de pipeline. Si vemos que `router_template` tiene >5% fallback a synth, ajustamos los templates o la logica `_data_is_complete`.

> **Product Manager:** El monitoring por path es excelente. Nos permite medir el impacto real de cada fase y decidir si seguir invirtiendo. Apruebo.

**Veredicto Ciclo 9:** ✅ **Aprobado con mitigaciones**
- 6 riesgos identificados, todos con mitigacion concreta
- Requisito: CI schema check + log por path + A/B test post-launch
- Ningun riesgo es bloqueante

---

## Ciclo 10: Decision Final y Roadmap

**Pregunta: Cual es la decision final y en que orden implementamos?**

> **Codeforces Grandmaster:** Resumen matematico:
>
> ```
> Latencia media actual:     ~3.8s (1.7 LLM calls promedio)
> Latencia media objetivo:   ~2.3s (1.1 LLM calls promedio)
> Reduccion:                  39% latencia, 35% LLM calls
> Costo adicional:            $0 (menos LLM calls = menos costo)
> Esfuerzo total:             ~4 dias
> ```
>
> ROI: 39% mejora de latencia / 4 dias = ~10% por dia de trabajo. Excelente.

> **Senior AI Engineer:** Decision tecnica sobre "1 pass vs 2 passes vs 0 passes":
>
> **No hay UNA respuesta. La respuesta correcta es ADAPTAR el numero de passes por query.**
>
> - 0 passes: saludos, fast-routes con template, exclusiones
> - 1 pass: perfil simple (router + template), preguntas generales (LLM directo)
> - 2 passes: comparaciones, debates, perfiles complejos (router + synth)
>
> El pipeline 2-pass actual NO se elimina. Se mantiene como el path de mayor calidad para queries complejas. Se complementa con paths mas rapidos para queries simples.

> **Senior MLE:** Descartamos definitivamente:
>
> - ❌ Single-pass nativo (Gemini auto function calling): ahorro marginal (~200ms), peor calidad, bugs conocidos
> - ❌ Speculative execution: complejidad alta, ahorro modesto (~0.7s), riesgo de bugs de concurrencia
> - ❌ Mover logica de presentacion a MCPs: viola separacion de concerns
>
> Aprobamos:
>
> - ✅ Templates estaticos para tools=[] (2-4h)
> - ✅ Pasar reasoning del router al synth (30min)
> - ✅ Template engine Jinja2 para fast-routes y perfiles simples (2-3d)
> - ✅ Logging por pipeline path (1h)

> **Junior MLE:** Mi checklist de tests para cada fase:
>
> 1. **Templates tools=[]**: test con queries excluidas, peyorativos, off-topic. Verificar que el template no filtra info util.
> 2. **Reasoning al synth**: test que el synth produce respuestas mas contextuales. Evaluacion cualitativa con 20 queries.
> 3. **Template engine**: test con cada template + datos completos, datos parciales, datos vacios. Verificar fallback a LLM.
> 4. **Logging**: test que cada path produce el log esperado con el campo `path=`.

> **AI Tech Lead:** Orden de implementacion (dependencias):
>
> ```
> Semana 1:
>   Dia 1: Templates tools=[] + reasoning al synth (quick wins)
>   Dia 2: Logging por path + metricas baseline
>
> Semana 2:
>   Dia 3-4: Template engine Jinja2 + templates para fast-routes
>   Dia 5: Templates para perfil simple (router + template path)
>
> Post-launch:
>   Semana 3: A/B test templates vs LLM con metricas de satisfaccion
>   Semana 4: CI schema check para template drift
> ```

> **Full Stack Lead:** Del lado del frontend, estos cambios son invisibles. El response schema no cambia. La unica diferencia visible seria que algunas respuestas llegan mas rapido. Cero cambios en infovoto-web.

> **Junior Full Stack:** Documentacion necesaria:
> - README para `src/agent/templates/` explicando como agregar un template nuevo
> - Actualizar docs/technical/internals/02-pipeline-request.md con los nuevos paths
> - Actualizar el diagrama de pipeline (01-pipeline-completo.mmd)

> **Delivery Lead:** Timing: estamos a 4 meses de la eleccion. 4 dias de esfuerzo para 39% menos latencia es un trade-off excelente. Apruebo la ejecucion inmediata de Semana 1, con Semana 2 condicional a los resultados de Semana 1.

> **Staff Engineer:** Feature flags: recomiendo un flag `TEMPLATE_ENGINE_ENABLED=true/false` en config.py para poder desactivar templates en produccion si detectamos problemas. Rollback instantaneo sin deploy.

> **Product Manager:** Resumen ejecutivo para stakeholders:
>
> **"Optimizamos el pipeline de respuesta sin cambiar la arquitectura. Las preguntas simples (30% del trafico) se responden 5-8x mas rapido. Las preguntas complejas mantienen la misma calidad. Costo de implementacion: 4 dias. Costo operativo: se reduce (menos llamadas al LLM). Riesgo: bajo, con rollback instantaneo via feature flag."**
>
> Apruebo.

**Veredicto Ciclo 10:** ✅ **Aprobado unanimemente**

---

## VEREDICTO FINAL

### Decision

**Pipeline hibrido adaptativo: 0, 1, o 2 passes segun la complejidad de la query.**

El pipeline de 2-pass actual se MANTIENE como backbone para queries complejas. Se COMPLEMENTA con paths rapidos (0-pass y 1-pass) para queries simples.

### Que NO hacemos

| Alternativa | Razon de rechazo |
|---|---|
| Single-pass nativo (Gemini auto function_calling) | Ahorro marginal (~200ms), peor calidad, bugs conocidos |
| Speculative execution | Complejidad alta, riesgo de concurrencia, ROI bajo |
| Mover presentacion a MCPs | Viola separacion de concerns, mantenimiento distribuido |

### Que SI hacemos

| Fase | Accion | Esfuerzo | Impacto estimado |
|---|---|---|---|
| 1a | Templates estaticos para router tools=[] | 2-4h | -1 LLM call para ~5% queries |
| 1b | Pasar reasoning del router al synth | 30min | Mejor calidad, 0 costo |
| 1c | Logging por pipeline path | 1h | Observabilidad para medir impacto |
| 2a | Template engine Jinja2 en gateway | 2d | -2 LLM calls para ~15% queries |
| 2b | Templates para perfil simple (router+template) | 1d | -1 LLM call para ~15% queries |
| 3 | A/B test + CI schema check | 2d | Validacion de calidad |

### Metricas objetivo

| Metrica | Actual | Objetivo | Metodo |
|---|---|---|---|
| LLM calls/request (media) | ~1.7 | ~1.1 | Log path distribution |
| Latencia P50 | ~3.8s | ~2.3s | Tracing |
| Latencia P95 | ~9s | ~6s | Tracing |
| Passthrough rate | ~15% | ~35% | Log template vs synth |
| Calidad (eval score) | 7.1/10 | >= 7.1/10 | A/B test eval set |
| Costo LLM/query | ~$0.005 | ~$0.003 | Token tracking |

### Diagrama final del pipeline

```
                    ┌─────────────────┐
                    │   User Message   │
                    └────────┬────────┘
                             │
                    ┌────────▼────────┐
                    │  Preprocessor    │ ~0ms
                    │  (regex, lookup) │
                    └────────┬────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
     ┌────────▼──────┐      │     ┌────────▼────────┐
     │ Instant Reply  │      │     │  Fast Route?     │
     │ (greeting/meta)│      │     │  (regex match)   │
     │ [0 LLM, ~0ms] │      │     └────────┬────────┘
     └───────┬───────┘      │              │
             │              │         ┌────▼────┐
             │              │         │ MCP Call │
             │              │         └────┬────┘
             │              │              │
             │              │     ┌────────▼────────┐
             │              │     │ Template Engine  │
             │              │     │ [0 LLM, ~0.5s]  │
             │              │     └────────┬────────┘
             │              │              │ (fallback if template fails)
             │     ┌────────▼────────┐     │
             │     │  LLM Router     │◄────┘
             │     │  (flash-lite)   │
             │     │  [1 LLM, ~1.5s] │
             │     └────────┬────────┘
             │              │
             │    ┌─────────┼──────────┐
             │    │         │          │
             │ ┌──▼───┐ ┌──▼───┐ ┌────▼─────┐
             │ │tools  │ │tools │ │ tools    │
             │ │= []   │ │= [T]│ │ = [T1,T2]│
             │ └──┬────┘ └──┬──┘ └────┬─────┘
             │    │         │         │
             │ ┌──▼──────┐  │    ┌────▼─────┐
             │ │Static   │  │    │MCP Calls  │
             │ │Template │  │    │(parallel) │
             │ │[0 extra]│  │    └────┬─────┘
             │ └────┬────┘  │         │
             │      │    ┌──▼───┐  ┌──▼──────────┐
             │      │    │MCP   │  │ Template ok? │
             │      │    │Call  │  └──┬───────┬──┘
             │      │    └──┬──┘     │       │
             │      │    ┌──▼──────┐ │  ┌────▼─────┐
             │      │    │Template │ │  │LLM Synth │
             │      │    │Render  │ │  │(flash)   │
             │      │    │[0 extra]│ │  │[+1 LLM] │
             │      │    └───┬────┘ │  └────┬─────┘
             │      │        │      │       │
             ▼      ▼        ▼      ▼       ▼
          ┌──────────────────────────────────────┐
          │         Output Filter + Validator     │
          └──────────────────────────────────────┘
                             │
                    ┌────────▼────────┐
                    │    Response      │
                    └─────────────────┘
```

### Prerequisitos

1. Feature flag: `TEMPLATE_ENGINE_ENABLED` en `config.py`
2. Base template Jinja2 con tono VOTI
3. Metricas baseline (log actual ya tiene `RESULT` structured)
4. Eval set de 200 queries para A/B test

### Principio rector

> **El numero optimo de LLM calls es el MINIMO necesario para mantener la calidad de respuesta.** Para queries predecibles, 0. Para queries con datos estructurados, 1 (router + template). Para queries complejas, 2 (router + synth). Nunca mas de 2.
