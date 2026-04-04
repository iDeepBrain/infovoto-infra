# Debate 01: Template vs LLM Synthesizer para Perfiles Individuales

**Fecha:** 2026-04-02
**Estado:** CERRADO
**Tema:** Reemplazar el LLM synthesizer con templates Jinja2/Python para perfiles individuales de candidatos

---

## Contexto Tecnico

### Pipeline actual

```
Router LLM (gemini-2.5-flash-lite)  →  MCP tool call  →  Synthesizer LLM (gemini-2.0-flash)
        ~1-2s                              ~0.05s                    ~8-10s
                                                            TOTAL: 10-13s
```

### Que hace el synthesizer hoy

Recibe JSON estructurado del MCP (`buscar_candidato_por_dni`) y lo convierte en markdown legible. El JSON ya tiene TODOS los campos:

```json
{
  "nombre_completo": "KEIKO SOFÍA FUJIMORI HIGUCHI",
  "cargo": "presidente",
  "partido": "Fuerza Popular",
  "region": "Distrito Único",
  "sexo": "F",
  "fecha_nacimiento": "1975-05-25",
  "educacion": [
    {"nivel": "Postgrado", "institucion": "Boston University", "carrera": "MBA", "concluido": true}
  ],
  "experiencia_laboral": [
    {"cargo": "Congresista", "institucion": "Congreso de la República", "periodo": "2006-2011"}
  ],
  "patrimonio": {
    "ingreso_total": 850000.0,
    "bienes_inmuebles": 2,
    "bienes_inmuebles_valor": 500000.0,
    "bienes_muebles": 1
  },
  "situacion_legal": {
    "sentencias_penales": [{"tipo": "JNE_DJHV", "titulo": "Lavado de activos", "estado": "En proceso"}],
    "sentencias_obligaciones": []
  },
  "posiciones_politicas": [
    {"tema": "Pena de muerte", "posicion": "A favor", "score": 1.0},
    {"tema": "Unión civil", "posicion": "En contra", "score": 0.0}
  ],
  "hechos_relevantes": [
    {"tipo": "SEGURIDAD", "descripcion": "Propuso mano dura contra...", "fuente_medio": "RPP"}
  ],
  "resumen_bio": "Hija del expresidente Alberto Fujimori...",
  "bio_curada": "Keiko Fujimori es candidata presidencial por tercera vez..."
}
```

### Costos actuales del synthesizer

| Metrica | Valor |
|---------|-------|
| Latencia p50 | 8-10s |
| Latencia p99 | 12-15s (con retry) |
| Input tokens (system prompt + JSON + history) | ~3000-4000 tokens |
| Output tokens | ~300-600 tokens |
| Costo por llamada (Gemini 2.0 Flash) | ~$0.0003-0.0006 |
| Llamadas/dia estimadas | ~5000-10000 |
| Costo diario synthesizer | ~$1.50-6.00 |
| TimeBudget total del pipeline | 5s ceiling (frecuentemente excedido) |

### Ya existe un precedente: `_build_passthrough_reply`

El gateway ya tiene bypass del LLM para `listar_candidatos_region` cuando el MCP retorna `lista_formateada`:

```python
# core.py linea 1031-1036
elif len(tool_results) == 1 and _has_formatted_list(tool_results):
    name, data = next(iter(tool_results.items()))
    reply_text = _build_passthrough_reply(data)
    logger.info("[PASSTHROUGH] %s → reply_len=%d (skipped LLM synthesis)", name, len(reply_text))
```

---

## Roles del Debate

| # | Rol | Enfoque |
|---|-----|---------|
| 1 | **Codeforces Grandmaster** (CF-GM) | Complejidad algoritmica, O(1) vs O(LLM) |
| 2 | **Senior AI Engineer** (Sr-AI) | Capacidades del modelo, prompt engineering |
| 3 | **Senior MLE** (Sr-MLE) | Infraestructura, latencia, costo |
| 4 | **Junior MLE** (Jr-MLE) | Testing, edge cases, preguntas |
| 5 | **Junior Full Stack** (Jr-FS) | UX, implicaciones frontend |
| 6 | **AI Tech Lead** (AI-TL) | Arquitectura, trade-offs |
| 7 | **Full Stack Lead** (FS-Lead) | Diseno de sistema, contratos API |
| 8 | **Delivery Lead** (DL) | UX, stakeholders, empatia con usuario |
| 9 | **Staff Engineer** (Staff) | Mantenibilidad a largo plazo, deuda tecnica |
| 10 | **Product Manager** (PM) | Impacto de negocio, metricas, retencion |

---

## Ciclo 1: Planteamiento del Problema

**CF-GM:** El synthesizer actual es O(n) en tokens de input/output con constante alta (~8-10s por llamada LLM). Un template es O(k) donde k son los campos del JSON, ejecutado en CPU puro. En terminos concretos:

```
Template: ~0.1ms (string formatting, sin I/O de red)
LLM:      ~8000-10000ms (request HTTP + inferencia + streaming)
```

Eso es una diferencia de 5 ordenes de magnitud. Para una operacion que es esencialmente `json_to_markdown`, el LLM es equivalente a usar un sorting algorithm de O(n!) cuando tienes O(n log n) disponible.

**Sr-AI:** No estoy de acuerdo con la simplificacion. El LLM no solo formatea; tambien: (1) adapta el tono segun el contexto conversacional, (2) prioriza campos segun la pregunta del usuario ("que estudio?" enfoca educacion), (3) maneja edge cases como campos vacios o datos inconsistentes, (4) integra el historial de conversacion para evitar repetir informacion.

**Sr-MLE:** Los numeros de latencia son reales. Tenemos logs en Cloud Run:

```
RESULT zone=yellow total=12.3s router=1200ms mcp=45ms synth=9800ms
RESULT zone=red   total=15.1s router=1800ms mcp=52ms synth=12400ms (retry)
```

El TimeBudget es de 5s pero el synthesizer SOLO ya consume 8-10s. Estamos excediendo el budget sistematicamente. Eso genera fallbacks con `_fallback_message()` que degradan la experiencia.

**Jr-MLE:** Pregunta: si el synthesizer ya tiene un `synth_prompt` separado (sin tool catalog, mas liviano), por que sigue tardando 8-10s? El prompt es largo?

**Sr-MLE:** El `synth_prompt` incluye el `_BASE_PROMPT` completo (~200 lineas de system prompt) + el `SYNTHESIZER_INSTRUCTION` (~70 lineas) + el JSON del MCP (~1500-2000 tokens) + historial de conversacion (~6 mensajes). Total: ~3000-4000 tokens de input. El cuello de botella no es el prompt, es la inferencia del modelo.

**Jr-FS:** Desde frontend, 10-13s es una eternidad. El usuario ve un spinner durante todo ese tiempo. En mobile con 3G peruano, sumale 1-2s de red. Total percibido: 12-15s. La tasa de abandono en chatbots sube exponencialmente despues de 5 segundos.

**AI-TL:** El patron ya existe en el codebase: `_build_passthrough_reply` para listas. La pregunta no es SI es posible, sino CUANDO es correcto. Para perfiles individuales, el JSON tiene una estructura 100% predecible. No hay ambiguedad.

**FS-Lead:** Desde el contrato API, `ProcessResponse` ya tiene `reply: str`. No importa si el reply viene de un template o de un LLM. El frontend no necesita cambios.

**DL:** El usuario peruano pregunta "quien es Keiko?" y espera 12 segundos. Eso es inaceptable. Nuestro competidor (Google Search) responde en <1s. Si podemos bajar a 2-3s (router + MCP + template), la percepcion de calidad sube drasticamente.

**Staff:** Antes de decidir, necesitamos definir el alcance exacto: que tools se templatean y cuales no. No todo es un perfil individual. `comparar_planes_gobierno`, `buscar_en_debate` tienen outputs mucho mas variables.

**PM:** El dato clave: el 60-70% de consultas son perfiles individuales ("quien es X", "cuentame de Y", "antecedentes de Z"). Si optimizamos SOLO perfiles, cubrimos la mayoria del trafico con el menor esfuerzo.

**Veredicto Ciclo 1:** 🔄 Necesita mas debate -- hay consenso en el problema pero no en la solucion.

---

## Ciclo 2: Propuesta Concreta del Template

**CF-GM:** Propongo la siguiente arquitectura:

```python
# template_synthesizer.py

from typing import Any

TOOL_TEMPLATES = {
    "buscar_candidato_por_dni": _render_profile,
    "buscar_candidato_por_nombre": _render_profile,  # top match = same structure
    "verificar_antecedentes": _render_antecedentes,
    "formula_presidencial": _render_formula,
    "ranking_patrimonio": _render_ranking,
    "estadisticas_candidatos": _render_estadisticas,
}

def try_template(tool_name: str, data: dict, user_query: str) -> str | None:
    """Returns rendered markdown or None if no template matches."""
    renderer = TOOL_TEMPLATES.get(tool_name)
    if renderer is None:
        return None  # fallback to LLM
    return renderer(data, user_query)
```

Complejidad: O(1) lookup + O(k) rendering donde k = numero de campos. Tiempo total: <1ms.

**Sr-AI:** Tengo una objecion fuerte. Miren el `SYNTHESIZER_INSTRUCTION`:

```
RESPONDE A LO QUE EL USUARIO PREGUNTÓ. Si pregunta "qué piensa X sobre Y",
enfócate en la posición sobre Y, no en todo el perfil.
```

Un template siempre renderiza el perfil completo. Si el usuario pregunta "que estudio Keiko?", el template va a escupir nombre, partido, patrimonio, antecedentes... todo. El LLM sabe enfocar.

**CF-GM:** Solucion: keyword matching en `user_query` para determinar que secciones renderizar.

```python
_SECTION_KEYWORDS = {
    "educacion": ["estudi", "universidad", "carrera", "grado", "titulo"],
    "patrimonio": ["plata", "patrimonio", "gana", "ingreso", "bienes", "sueldo"],
    "antecedentes": ["antecedente", "sentencia", "penal", "legal", "juicio", "proceso"],
    "posiciones": ["piensa", "posicion", "favor", "contra", "opinion"],
    "experiencia": ["trabaj", "experiencia", "cargo", "labor"],
}

def _detect_focus(query: str) -> set[str]:
    query_lower = query.lower()
    focused = set()
    for section, keywords in _SECTION_KEYWORDS.items():
        if any(kw in query_lower for kw in keywords):
            focused.add(section)
    return focused or {"all"}  # si no matchea nada, renderiza todo
```

Esto es O(k*m) donde k=secciones y m=keywords. Total: ~50 comparaciones de string, <0.01ms.

**Jr-MLE:** Y si el usuario pregunta algo ambiguo como "que onda con Keiko?" o "cuentame de Keiko"? Ahi no hay keyword que matchee.

**CF-GM:** Por eso el fallback es `{"all"}` -- renderiza el perfil completo. Que es exactamente lo que el LLM hace hoy con esas queries.

**Sr-MLE:** Me gusta la arquitectura de `try_template` con fallback a LLM. Es el patron correcto: template first, LLM fallback. Si el template no puede manejar el caso, retorna `None` y el pipeline sigue como hoy.

**AI-TL:** El punto critico del Sr-AI es valido, pero la solucion de keyword matching es fragil. "cuanto gana" deberia ir a patrimonio pero "cuanto cuesta la multa" no. Necesitamos algo mas robusto o aceptar que para queries enfocadas (20-30% de los casos) seguimos usando LLM.

**FS-Lead:** Propongo un approach hibrido:
1. **Perfil completo** (query generica: "quien es X", "cuentame de X") → Template. Cubre ~50% de queries de perfil.
2. **Query enfocada** ("que estudio X", "antecedentes de X") → Template con seccion focusada. Cubre ~30%.
3. **Query compleja** ("que piensa X sobre la pena de muerte comparado con su historial") → LLM. Cubre ~20%.

**DL:** El approach hibrido me gusta. Pregunta: la respuesta del template se va a "sentir" diferente que la del LLM? El usuario nota si de repente el bot responde mas mecanico?

**Staff:** Eso es un riesgo real. El template tiene que producir texto natural, no un dump de datos. Necesitamos invertir en el template, no solo hacer `f"{nombre}: {partido}"`.

**PM:** Los numeros me convencen. Si el 50-80% de queries de perfil van por template (2-3s total) y solo el 20% restante va por LLM (10-13s), el p50 de latencia baja de 12s a 3s. Eso es game-changing para retencion.

**Veredicto Ciclo 2:** 🔄 Necesita mas debate -- la arquitectura hibrida tiene consenso pero faltan detalles de implementacion.

---

## Ciclo 3: Diseno del Template de Perfil

**CF-GM:** Implementacion concreta del renderer principal:

```python
def _render_profile(data: dict, user_query: str) -> str:
    focus = _detect_focus(user_query)
    parts = []

    nombre = data.get("nombre_completo", "")
    partido = data.get("partido", "")
    cargo = data.get("cargo", "")
    region = data.get("region", "")

    # Header siempre presente
    parts.append(f"**{nombre}** postula como **{cargo}** por **{partido}**")
    if region and region != "Distrito Único":
        parts[-1] += f" en **{region}**"
    parts[-1] += "."

    # Bio curada (si existe, siempre incluir como intro)
    bio = data.get("bio_curada") or data.get("resumen_bio")
    if bio and "all" in focus:
        parts.append(f"\n{bio}")

    # Educacion
    if ("educacion" in focus or "all" in focus) and data.get("educacion"):
        edu_lines = []
        for e in data["educacion"]:
            line = f"- {e.get('nivel', '')}"
            if e.get("carrera"):
                line += f" en {e['carrera']}"
            if e.get("institucion"):
                line += f" ({e['institucion']})"
            estado = "completado" if e.get("concluido") else "no concluido"
            line += f" - {estado}"
            edu_lines.append(line)
        parts.append("\n**Educacion:**\n" + "\n".join(edu_lines))

    # Experiencia laboral
    if ("experiencia" in focus or "all" in focus) and data.get("experiencia_laboral"):
        exp_lines = []
        for e in data["experiencia_laboral"]:
            exp_lines.append(f"- {e.get('cargo', '')} en {e.get('institucion', '')} ({e.get('periodo', '')})")
        parts.append("\n**Experiencia:**\n" + "\n".join(exp_lines))

    # Patrimonio
    if ("patrimonio" in focus or "all" in focus) and data.get("patrimonio"):
        p = data["patrimonio"]
        ingreso = f"S/ {p['ingreso_total']:,.0f}" if p.get("ingreso_total") else "No declarado"
        parts.append(f"\n**Patrimonio declarado:**\n- Ingreso total: {ingreso}")
        if p.get("bienes_inmuebles"):
            valor = f" (valor: S/ {p['bienes_inmuebles_valor']:,.0f})" if p.get("bienes_inmuebles_valor") else ""
            parts.append(f"- Bienes inmuebles: {p['bienes_inmuebles']}{valor}")

    # Situacion legal
    if ("antecedentes" in focus or "all" in focus):
        legal = data.get("situacion_legal", {})
        penales = legal.get("sentencias_penales", [])
        if penales:
            ant_lines = []
            for a in penales:
                line = f"- {a.get('titulo', 'Sin titulo')} — Estado: {a.get('estado', 'No especificado')}"
                if a.get("tipo") == "VOTABIEN":
                    line += f" (Fuente: {a.get('fuente_medio', 'fuente externa')})"
                ant_lines.append(line)
            parts.append("\n**Situacion legal:**\n" + "\n".join(ant_lines))
        elif "antecedentes" in focus:
            parts.append("\n**Situacion legal:** No registra sentencias penales segun su DJHV.")

    # Posiciones politicas (top 5)
    if ("posiciones" in focus or "all" in focus) and data.get("posiciones_politicas"):
        pos = data["posiciones_politicas"][:5]
        pos_lines = [f"- {p['tema']}: **{p['posicion']}**" for p in pos if p.get("tema")]
        if pos_lines:
            parts.append("\n**Posiciones politicas** (Fuente: Decide.pe):\n" + "\n".join(pos_lines))

    # Footer
    parts.append("\nSegun su Declaracion Jurada de Hoja de Vida ante el JNE.")
    parts.append("\nQuieres saber mas sobre sus propuestas, patrimonio o antecedentes?")

    return "\n".join(parts)
```

Tiempo de ejecucion: ~0.05ms. Cero tokens consumidos. Cero llamadas de red.

**Sr-AI:** El template se ve bien para el caso "quien es X". Pero noto varias perdidas respecto al LLM:

1. **Tono adaptativo:** El LLM ajusta "Te cuento:" vs "Mira," vs "Claro!" segun el contexto. El template es estatico.
2. **Jerga peruana:** Si el usuario dice "que onda con el pata?", el LLM responde con naturalidad. El template siempre responde igual.
3. **Deduplicacion con historial:** Si ya le mostraste la educacion en el turno anterior, el LLM evita repetir. El template no sabe que ya mostro.

**Jr-MLE:** Pregunta sobre el punto 3: el historial se pasa al synthesizer como `synth_history[-6:]`. Si usamos template, perdemos esa deduplicacion. Cuanto impacta?

**Sr-AI:** Bastante. Si el usuario pregunta "quien es Keiko?" y luego "cuentame mas", ambas queries generan la misma llamada MCP y el template renderizaria el mismo perfil identico. El LLM sabe decir "como te mencionaba, ademas de lo anterior..."

**AI-TL:** Eso se resuelve diferente. El "cuentame mas" deberia ser manejado por el router mandando una tool diferente o con parametros diferentes, no por el synthesizer repitiendo todo y esperando que el LLM filtre.

**CF-GM:** Correcto. La deduplicacion en el synthesizer es un hack. El router deberia manejar el intent "expandir respuesta anterior". El template no pierde funcionalidad real -- pierde un workaround costoso.

**Staff:** Preocupacion de mantenibilidad: cada vez que el MCP agrega un campo al JSON (ej: `partido_alianzas`), hay que actualizar el template. Con el LLM, el campo nuevo aparece automaticamente porque esta en el JSON.

**FS-Lead:** Eso es cierto pero manejable. El template tiene un catch-all: si hay campos no renderizados, se puede agregar una seccion generica. Ademas, los cambios al schema del MCP son infrecuentes (el scraper corre pocas veces al anio).

**DL:** Me preocupa el punto del tono. El VOTI actual es calido y cercano. Si de repente responde como un formulario, los usuarios lo notan. Necesitamos variaciones aleatorias en frases de apertura y cierre.

**PM:** Pongamos numeros: estamos hablando de ahorrar ~8-10s por request. Con 5000-10000 requests/dia, eso es 11-28 HORAS de tiempo de espera acumulado de usuarios ahorrado por dia. El tono es importante, pero la velocidad es mas importante.

**Veredicto Ciclo 3:** 🔄 Necesita mas debate -- template viable pero se necesita resolver tono y "cuentame mas".

---

## Ciclo 4: Resolviendo el Tono y Follow-ups

**Sr-AI:** Propongo una solucion para el tono: frases de apertura y cierre aleatorias.

```python
import random

_OPENERS = [
    "Te cuento sobre {nombre}:",
    "Mira, {nombre} es candidato/a interesante:",
    "Aqui va lo que sabemos de {nombre}:",
    "Claro! {nombre} postula por {partido}:",
    "{nombre} — te doy el resumen:",
]

_CLOSERS = [
    "Quieres saber mas sobre sus propuestas o antecedentes?",
    "Te interesa conocer sus propuestas de gobierno?",
    "Puedo contarte mas sobre su patrimonio o situacion legal.",
    "Preguntame lo que quieras sobre este candidato/a!",
]

def _random_opener(data: dict) -> str:
    template = random.choice(_OPENERS)
    return template.format(
        nombre=data.get("nombre_completo", "este candidato"),
        partido=data.get("partido", "su partido"),
    )
```

No es tan sofisticado como un LLM pero rompe la monotonia. Costo: ~0ms extra.

**Jr-MLE:** Y para "cuentame mas"? Ahi el template no puede saber que ya mostro.

**AI-TL:** Propongo que "cuentame mas" NO se resuelva en el synthesizer. Dos opciones:

1. **Router-level:** El router detecta "cuentame mas" y en lugar de llamar `buscar_candidato_por_dni` de nuevo, llama a una tool especifica como `buscar_propuesta_tema(partido=X)` para dar informacion NUEVA.
2. **Gateway-level:** Si el tool result es identico al anterior (hash match con cache), agregar instruccion al template de "profundizar en un aspecto especifico".

La opcion 1 es la correcta arquitecturalmente. El synthesizer no deberia ser responsable de deduplicacion -- eso es responsabilidad del router.

**CF-GM:** Exacto. El router ya tiene `entity_context` con `last_tool` y `candidate`. Si detecta "cuentame mas" + mismo candidato, puede rutear a `buscar_propuesta_tema` o `verificar_antecedentes` en vez de repetir `buscar_candidato_por_dni`. Esto es O(1) en el router, no O(LLM) en el synthesizer.

**FS-Lead:** Me convence. Pero ojo: eso es un cambio en `router.py`, no en el template. Estamos mezclando dos mejoras. Sugiero:

- **PR 1:** Template synthesizer para perfiles (este debate).
- **PR 2:** Router inteligente para follow-ups (debate separado).

El PR 1 funciona incluso sin el PR 2: el "cuentame mas" simplemente renderiza el perfil completo de nuevo (igual que hoy pero en 0.1ms en vez de 10s). No es ideal pero es estrictamente mejor que el status quo.

**DL:** Entiendo. Entonces el peor caso del template es: usuario recibe el mismo perfil dos veces rapidamente. El peor caso del LLM es: usuario espera 10s y recibe un timeout fallback de "Uy, tarde mas de lo normal". Prefiero el template sin duda.

**Jr-FS:** Pregunta de UX: si la respuesta llega en 0.3s (router 0.2s + MCP 0.05s + template 0.05s), el usuario podria sentir que es una respuesta pre-armada, no personalizada. Deberiamos agregar un delay artificial?

**Staff:** Absolutamente NO. Nunca agreges latencia artificial. Si la respuesta es rapida, celebralo. Los usuarios quieren velocidad.

**PM:** Datos de UX research: en chatbots, respuestas de <2s tienen 40% mayor engagement que respuestas de >5s. No hay tal cosa como "demasiado rapido" en un chatbot. El typing indicator del frontend ya simula un mini-delay visual de todas formas.

**CF-GM:** Resumiendo: template + frases aleatorias resuelve el tono al 80%. El 20% restante (follow-ups sofisticados) se resuelve en el router, no en el synthesizer.

**Veredicto Ciclo 4:** ✅ Aprobado -- la arquitectura de template + frases aleatorias + fallback a LLM es solida.

---

## Ciclo 5: Alcance Exacto -- Que Tools se Templatean

**AI-TL:** Definamos el scope exacto. De los tools del MCP perfiles:

| Tool | Template? | Razon |
|------|-----------|-------|
| `buscar_candidato_por_dni` | SI | JSON 100% predecible, perfil fijo |
| `buscar_candidato_por_nombre` | SI | Top match = mismo JSON de perfil |
| `verificar_antecedentes` | SI | Lista de antecedentes, estructura fija |
| `formula_presidencial` | SI | Lista de 3 candidatos (P + 2 VPs) |
| `ranking_patrimonio` | SI | Lista ordenada, formato tabla |
| `estadisticas_candidatos` | SI | Datos numericos, formato tabla/chart |
| `listar_candidatos_region` | YA EXISTE | `_build_passthrough_reply` |
| `comparar_candidatos` | PARCIAL | Template si son 2 candidatos, LLM si son 3+ |

De los tools de otros MCPs:

| Tool | Template? | Razon |
|------|-----------|-------|
| `buscar_propuesta_tema` | NO | Extractos de texto libre, necesitan sintesis |
| `comparar_planes_gobierno` | NO | Requiere integracion narrativa de multiples propuestas |
| `buscar_en_debate` | NO | Fragmentos de discurso, altamente variables |
| `buscar_info_electoral` | NO | Respuestas de knowledge base, longitud variable |
| `consultar_local_votacion` | SI | Datos fijos: local, mesa, direccion |
| `info_dia_elecciones` | SI | Info estatica, formato fijo |

**Sr-MLE:** Eso nos da:
- **8 tools con template** (perfiles + logistica basica)
- **5+ tools con LLM** (planes, debates, proceso electoral)
- **Cobertura estimada:** 65-75% de queries van por template

**Jr-MLE:** Como se decide en runtime si usar template o LLM? Propongo:

```python
# En core.py, reemplazando la seccion de Pass 2

elif tool_results:
    # Try template first (O(1))
    if len(tool_results) == 1:
        tool_name, data = next(iter(tool_results.items()))
        template_reply = try_template(tool_name, data, intent.enriched_message)
        if template_reply:
            reply_text = template_reply
            logger.info("[TEMPLATE] %s → reply_len=%d (0ms)", tool_name, len(reply_text))
            # saltar synthesizer LLM completamente
```

Si `try_template` retorna `None`, sigue al LLM como hoy. Zero risk.

**Staff:** Me gusta el diseno. El `try_template` es un pure function (sin side effects, sin I/O). Si falla, retorna `None` y el flujo continua. El peor caso es identico al sistema actual.

**CF-GM:** Importante: si hay multiples tool results (`len(tool_results) > 1`), SIEMPRE va al LLM. Los templates solo manejan single-tool results. Las multi-tool queries son inherentemente complejas.

**FS-Lead:** Eso simplifica mucho el contrato. Un template siempre recibe exactamente un dict de un tool. No hay ambiguedad.

**DL:** Un concern: `consultar_local_votacion` retorna datos con DNI del usuario. El template debe respetar la regla de privacidad: "NUNCA muestres el DNI en tu respuesta".

**Jr-MLE:** Buen catch. El template para `consultar_local_votacion` debe sanitizar el DNI:

```python
def _render_local_votacion(data: dict, query: str) -> str:
    # NUNCA incluir DNI en la respuesta
    local = data.get("local_votacion", "")
    mesa = data.get("numero_mesa", "")
    direccion = data.get("direccion", "")
    return f"Tu local de votacion es **{local}**, mesa **{mesa}**.\nDireccion: {direccion}"
```

**PM:** Pregunta de negocio: si bajamos la latencia de 12s a 3s para el 70% de queries, cual es el impacto en metricas?

- **Tasa de rebote esperada:** baja de ~40% a ~15% (basado en benchmarks de chatbots)
- **Messages per session:** sube de 3.2 a 5-6 (usuarios que no abandonan por lentitud)
- **Costo diario:** baja de ~$3/dia a ~$1/dia (70% menos llamadas al synthesizer)

**Veredicto Ciclo 5:** ✅ Aprobado -- scope claro, implementacion de bajo riesgo.

---

## Ciclo 6: Edge Cases y Errores

**Jr-MLE:** Listemos los edge cases que el template debe manejar:

1. **Campos vacios:** `educacion: []`, `patrimonio: null`, `experiencia_laboral: []`
2. **Candidato sin partido:** Independientes no existen en Peru 2026, pero el campo podria estar vacio por error de scraping.
3. **MCP retorna error:** `{"error": "No se encontro candidato..."}`
4. **JSON malformado:** El MCP retorna algo inesperado.
5. **Campos nuevos no mapeados:** MCP agrega `militancia_partidaria` y el template no lo conoce.
6. **Unicode/encoding:** Nombres con tildes, enies, caracteres especiales.
7. **Datos extremos:** Patrimonio de S/ 0 (candidato sin bienes) o S/ 999,999,999 (formato numerico).

**CF-GM:** Para cada caso:

```python
def try_template(tool_name: str, data: dict, user_query: str) -> str | None:
    # Case 3: MCP error → return None, let LLM handle or use fallback
    if isinstance(data, dict) and "error" in data and len(data) == 1:
        return None

    # Case 4: unexpected type → return None
    renderer = TOOL_TEMPLATES.get(tool_name)
    if renderer is None:
        return None

    try:
        return renderer(data, user_query)
    except Exception:
        logger.warning("[TEMPLATE] render failed for %s, falling back to LLM", tool_name)
        return None  # Case 4, 5, 6, 7: any crash → fallback to LLM
```

El `try/except` aqui es JUSTIFICADO: es un error conocido y esperado (datos malformados). El fallback es el LLM, que sabe manejar JSONs raros.

**Sr-AI:** Caso 5 es interesante. Si el MCP agrega un campo nuevo, el template lo ignora silenciosamente. Con el LLM, el campo nuevo aparece en la respuesta automaticamente. Esto es una regresion potencial.

**Staff:** Solucion: agregar un catch-all al final del template:

```python
# Campos no renderizados explicitamente
_KNOWN_FIELDS = {"nombre_completo", "cargo", "partido", "region", "educacion",
                 "experiencia_laboral", "patrimonio", "situacion_legal",
                 "posiciones_politicas", "hechos_relevantes", "resumen_bio",
                 "bio_curada", "sexo", "fecha_nacimiento", "posicion_lista",
                 "dni", "_fuente", "_candidate", "_fuente_posiciones", "match_score"}

def _render_unknown_fields(data: dict) -> str:
    unknown = {k: v for k, v in data.items() if k not in _KNOWN_FIELDS and not k.startswith("_")}
    if not unknown:
        return ""
    lines = []
    for k, v in unknown.items():
        key_display = k.replace("_", " ").title()
        if isinstance(v, list):
            lines.append(f"\n**{key_display}:** {len(v)} registros")
        elif isinstance(v, str) and len(v) < 200:
            lines.append(f"\n**{key_display}:** {v}")
    return "\n".join(lines)
```

Asi los campos nuevos no se pierden completamente. Y agregamos un log `WARNING` cuando hay campos desconocidos para que sepamos que el template necesita actualizacion.

**AI-TL:** Me gusta. El log de warning es clave para mantenibilidad. Sin el, los campos nuevos se pierden silenciosamente.

**Jr-FS:** Edge case 7 (datos extremos): que pasa si `ingreso_total` es `0.0`? El template dice "S/ 0" que suena raro. Deberia decir "No declara ingresos".

**CF-GM:** Facil:

```python
if p.get("ingreso_total") and p["ingreso_total"] > 0:
    ingreso = f"S/ {p['ingreso_total']:,.0f}"
else:
    ingreso = "No declara ingresos"
```

**Sr-MLE:** Caso 6 (Unicode): Python 3 maneja UTF-8 nativo. Los nombres con tildes ("LOPEZ ALIAGA") funcionan sin problema. El unico riesgo seria si el MCP retorna bytes en vez de str, pero eso no pasa porque FastMCP serializa a JSON (que es siempre UTF-8).

**DL:** Hay un edge case de UX: el usuario pregunta algo como "es buena candidata Keiko?" (juicio de valor). El template no puede responder eso -- deberia ir al LLM que sabe decir "como VOTI soy imparcial". Como lo manejamos?

**AI-TL:** Eso lo maneja el router, no el synthesizer. Si la pregunta es un juicio de valor sin tool call, `tools=[]` y va al single-pass LLM directamente. El template solo se activa cuando hay un tool result.

**Veredicto Ciclo 6:** ✅ Aprobado -- edge cases cubiertos con fallback robusto.

---

## Ciclo 7: Metricas y Observabilidad

**Sr-MLE:** Necesitamos medir el impacto. Propongo estas metricas:

```python
# Logging existente en core.py (linea 1165):
# "RESULT zone=%s total=%.1fs router=%.0fms mcp=%.0fms synth=%.0fms"

# Nuevo campo: synth_type
logger.info(
    "RESULT zone=%s total=%.1fs router=%.0fms mcp=%.0fms synth=%.0fms synth_type=%s",
    zone, elapsed, router_ms, mcp_ms, synth_ms,
    "template" | "llm" | "passthrough"
)
```

Metricas a trackear post-deploy:

| Metrica | Antes (baseline) | Esperado |
|---------|-------------------|----------|
| p50 latencia total | 12.3s | 2.5s |
| p99 latencia total | 15.1s | 13s (queries complejas siguen con LLM) |
| % template hits | 0% | 65-75% |
| % LLM fallbacks del template | N/A | <5% |
| % zone=green (<8s) | ~20% | ~75% |
| % zone=red (>15s) | ~15% | ~5% |
| Tokens consumidos/dia | ~20M | ~7M |
| Costo Gemini/dia | ~$3 | ~$1 |

**Jr-MLE:** Como medimos si la CALIDAD de las respuestas template es comparable al LLM? Propongo un A/B test:

```python
# Feature flag en config.py
TEMPLATE_SYNTHESIZER_ENABLED: bool = True
TEMPLATE_AB_TEST_RATIO: float = 0.5  # 50% template, 50% LLM

# En core.py
import random
use_template = (
    settings.template_synthesizer_enabled
    and random.random() < settings.template_ab_test_ratio
)
```

**PM:** El A/B test es critico. Metricas de calidad:
- **Messages per session** (template vs LLM group)
- **Repeat queries** (usuario repite la misma pregunta = respuesta no satisfactoria)
- **Explicit feedback** (si tenemos thumbs up/down)

Si el grupo template tiene mas messages/session (porque la velocidad incentiva engagement), es una clara victoria.

**AI-TL:** El A/B test agrega complejidad. Propongo algo mas simple: deploy el template con feature flag ON para todos. Comparar metricas semana-sobre-semana (antes vs despues). Si hay degradacion en messages/session, rollback con el flag.

**Staff:** Prefiero el approach del AI-TL. El A/B test divide tu trafico y necesitas mas tiempo para alcanzar significancia estadistica. Con ~5000 requests/dia, una comparacion antes/despues es suficiente.

**CF-GM:** De acuerdo. El feature flag es lo minimo necesario. Si el flag esta OFF, `try_template` retorna `None` siempre y el pipeline es identico al actual.

```python
def try_template(tool_name: str, data: dict, user_query: str) -> str | None:
    if not settings.template_synthesizer_enabled:
        return None
    # ... rest of logic
```

**FS-Lead:** En el trace log (`trace_service.py`), agregar `synth_type` al trace para que podamos filtrar en el dashboard de analytics.

**Veredicto Ciclo 7:** ✅ Aprobado -- feature flag + metricas before/after.

---

## Ciclo 8: Plan de Implementacion

**Staff:** Propongo este orden de implementacion:

### PR 1: Template Synthesizer Core (2-3 horas)

```
src/agent/
├── template_synthesizer.py    ← NUEVO: try_template(), renderers, _detect_focus()
├── core.py                    ← EDIT: agregar template check antes de LLM pass2
```

Cambios en `core.py` (minimos):

```python
# Linea ~1038, antes de "Pass 2: LLM Synthesize"
elif tool_results:
    # Try template first (O(1), no network I/O)
    if len(tool_results) == 1:
        tool_name, data = next(iter(tool_results.items()))
        from src.agent.template_synthesizer import try_template
        template_reply = try_template(tool_name, data, intent.enriched_message)
        if template_reply:
            reply_text = template_reply
            synth_ms = 0.0
            synth_type = "template"
            logger.info("[TEMPLATE] %s → reply_len=%d", tool_name, len(reply_text))

    # Fallback: LLM Synthesize (existing code, unchanged)
    if not reply_text:
        # ... existing pass2 code ...
        synth_type = "llm"
```

### PR 2: Tests (1-2 horas)

```
tests/
├── test_template_synthesizer.py  ← Unit tests con JSON fixtures reales
```

Tests minimos:
- `test_render_profile_full` -- JSON completo → markdown con todas las secciones
- `test_render_profile_focused` -- "que estudio X" → solo seccion educacion
- `test_render_profile_empty_fields` -- campos vacios no generan secciones vacias
- `test_try_template_unknown_tool` -- tool no templateado → None
- `test_try_template_mcp_error` -- {"error": ...} → None
- `test_try_template_crash` -- JSON malformado → None (no crash)
- `test_detect_focus_keywords` -- keyword matching correcto
- `test_render_antecedentes` -- sanitiza datos legales
- `test_render_local_votacion` -- no muestra DNI

### PR 3: Feature flag + observabilidad (30 min)

```
src/gateway/config.py  ← EDIT: agregar TEMPLATE_SYNTHESIZER_ENABLED
```

**Sr-MLE:** El deploy es zero-risk:
1. Merge PR 1 + PR 2 + PR 3 con flag OFF
2. Deploy a Cloud Run (dev)
3. Test manual con queries reales
4. Flag ON en config
5. Monitor metricas 24h
6. Si todo OK, deploy a prod

**AI-TL:** Los PRs podrian ser un solo PR dado el tamano. No es un cambio grande:
- 1 archivo nuevo (~200 lineas)
- 1 archivo editado (~15 lineas en core.py)
- 1 archivo editado (~1 linea en config.py)
- 1 archivo de tests (~150 lineas)

Total: ~370 lineas. Es un cambio pequeno con impacto enorme.

**Jr-FS:** Necesito cambiar algo en el frontend?

**FS-Lead:** No. El `ProcessResponse.reply` sigue siendo `str`. El frontend no sabe ni le importa si vino de un template o un LLM.

**DL:** Timeline? Si son 3-4 horas de implementacion, podemos tenerlo en prod hoy?

**PM:** Si los tests pasan y el flag funciona, si. Prioridad P0 -- esto impacta directamente la retencion de usuarios.

**Veredicto Ciclo 8:** ✅ Aprobado -- plan de implementacion claro y acotado.

---

## Ciclo 9: Riesgos y Mitigacion

**Staff:** Documentemos los riesgos formalmente:

| Riesgo | Probabilidad | Impacto | Mitigacion |
|--------|-------------|---------|------------|
| Template produce texto poco natural | Media | Medio | Frases aleatorias + iteracion rapida sobre el template |
| Campo nuevo del MCP no renderizado | Baja | Bajo | Log WARNING + catch-all `_render_unknown_fields` |
| Template crash por JSON inesperado | Baja | Nulo | try/except → fallback a LLM |
| Usuario nota diferencia de calidad | Media | Medio | Feature flag para rollback instantaneo |
| Template leak de DNI | Baja | Alto | Sanitizacion explicita + test unitario |
| Keyword matching incorrecto | Media | Bajo | Fallback a "all" sections si no hay match |
| Mantenimiento de templates | Baja | Bajo | Esquema MCP cambia pocas veces, templates son ~20 lineas c/u |

**Sr-AI:** Mi riesgo principal: queries complejas que parecen simples. Ejemplo: "Keiko tiene antecedentes?" llama a `buscar_candidato_por_dni` (no `verificar_antecedentes`) y el template renderiza el perfil completo. El usuario queria solo antecedentes.

**CF-GM:** Eso se resuelve con `_detect_focus`. "antecedentes" es un keyword que activa la seccion `antecedentes`. El template renderiza solo esa seccion.

**Sr-AI:** Pero si el router decide llamar `buscar_candidato_por_dni` en vez de `verificar_antecedentes`, el JSON de perfil tiene antecedentes basicos (de DJHV) mientras que `verificar_antecedentes` tiene datos mas completos (cruza multiples fuentes). El template con datos incompletos es peor que el LLM con datos completos.

**AI-TL:** Eso es un problema del ROUTER, no del synthesizer. Si el router manda al tool equivocado, ni el LLM ni el template pueden compensar. La solucion correcta es mejorar el router, no mantener un synthesizer LLM costoso como compensacion.

**Jr-MLE:** De acuerdo. Pero eso significa que la calidad del template depende de la calidad del router. Si mejoramos el template pero el router sigue mandando a tools sub-optimos, el usuario puede percibir peor calidad.

**DL:** Riesgo real pero independiente. El template no empeora el routing -- solo muestra lo que el MCP retorna, igual que el LLM. La diferencia es que lo hace en 0ms en vez de 10s.

**PM:** Riesgo de negocio: si el template falla y el flag no funciona, tenemos degradacion en produccion. Mitigacion: probar el flag en staging antes de prod.

**FS-Lead:** El flag es una variable de entorno (`TEMPLATE_SYNTHESIZER_ENABLED=false`). Se puede cambiar en Cloud Run sin re-deploy: solo update del env var y restart del servicio (~30s).

**Veredicto Ciclo 9:** ✅ Aprobado -- riesgos identificados y mitigados.

---

## Ciclo 10: Decision Final

**CF-GM:** Resumen tecnico: estamos reemplazando una operacion O(LLM) de ~10s con una operacion O(k) de ~0.1ms para el 65-75% del trafico. Es la optimizacion mas obvia posible. El codebase ya tiene el precedente (`_build_passthrough_reply`). El riesgo es cercano a cero con el feature flag.

**Sr-AI:** Mis objeciones fueron: tono adaptativo, deduplicacion con historial, y queries enfocadas. Todas se resolvieron satisfactoriamente:
- Tono: frases aleatorias (80% de calidad, 0% de costo)
- Deduplicacion: responsabilidad del router, no del synthesizer
- Queries enfocadas: `_detect_focus` con keyword matching

Cambio mi posicion a favor. El LLM synthesizer para perfiles individuales es overkill.

**Sr-MLE:** Los numeros son irrefutables:

```
ANTES:  p50=12.3s, costo=$3/dia, zone=yellow/red
DESPUES: p50=2.5s,  costo=$1/dia, zone=green
```

70% menos latencia, 70% menos costo, 70% menos tokens. La infraestructura agradece.

**Jr-MLE:** Mis preguntas fueron respondidas. El fallback a LLM cubre todos los edge cases. Los tests cubren los escenarios criticos. Voto a favor.

**Jr-FS:** Sin cambios en frontend. La mejora de latencia se traduce directamente en mejor UX sin trabajo adicional de mi parte. Voto a favor.

**AI-TL:** La arquitectura es correcta: template first → LLM fallback. Es extensible (agregar templates para nuevos tools es trivial), es reversible (feature flag), y sigue el principio de hexagonal architecture (el synthesizer es un adaptador intercambiable). Voto a favor.

**FS-Lead:** El contrato API no cambia. El flujo de datos es limpio. Un solo punto de decision (`try_template` retorna `str | None`). Voto a favor.

**DL:** El usuario peruano va a recibir respuestas en 2-3s en vez de 12-15s. Eso vale mas que cualquier mejora de "tono" que el LLM pueda dar. La velocidad ES calidad de UX. Voto a favor.

**Staff:** El cambio es pequeno (~370 lineas), reversible (feature flag), testeable (unit tests + before/after metricas), y mantiene el principio de "la solucion mas simple que funcione". Cero over-engineering. Voto a favor.

**PM:** Impacto de negocio:
- **Latencia p50:** 12.3s → 2.5s (reduccion del 80%)
- **Costo de API:** $3/dia → $1/dia (reduccion del 67%)
- **Tokens consumidos:** 20M/dia → 7M/dia (reduccion del 65%)
- **Tasa de abandono estimada:** 40% → 15%
- **Messages per session estimados:** 3.2 → 5-6
- **Esfuerzo de implementacion:** 3-4 horas, 1 desarrollador

ROI inmediato. Voto a favor.

---

## VEREDICTO FINAL

### Resultado: ✅ APROBADO POR UNANIMIDAD (10/10)

**Decision:** Reemplazar el LLM synthesizer con templates Python para perfiles individuales y herramientas de estructura fija.

### Que se implementa

1. **Nuevo archivo** `src/agent/template_synthesizer.py` con:
   - `try_template(tool_name, data, user_query) -> str | None`
   - Renderers para 8 tools (perfiles, antecedentes, formula, ranking, estadisticas, local_votacion, info_elecciones)
   - `_detect_focus()` para queries enfocadas
   - Frases de apertura/cierre aleatorias
   - Catch-all para campos desconocidos con log WARNING
   - try/except global con fallback a `None`

2. **Edicion minima** en `src/agent/core.py`:
   - Agregar template check antes de LLM pass2 (~15 lineas)
   - Agregar `synth_type` al log RESULT

3. **Feature flag** en `src/gateway/config.py`:
   - `TEMPLATE_SYNTHESIZER_ENABLED: bool = True`

4. **Tests** en `tests/test_template_synthesizer.py`

### Que NO se implementa (fuera de scope)

- Templates para `buscar_propuesta_tema`, `comparar_planes_gobierno`, `buscar_en_debate` (requieren sintesis narrativa, siguen con LLM)
- Mejoras al router para follow-ups inteligentes (debate separado)
- A/B testing (comparacion before/after es suficiente con el volumen actual)

### Metricas de exito (medir 1 semana post-deploy)

- p50 latencia total < 4s (hoy: 12.3s)
- % zone=green > 70% (hoy: ~20%)
- messages/session >= 3.2 (no regresion vs hoy)
- 0 crashes del template en produccion

### Rollback plan

```bash
# Si hay problemas:
# Opcion 1: Feature flag
gcloud run services update infovoto-gateway --update-env-vars TEMPLATE_SYNTHESIZER_ENABLED=false

# Opcion 2: Revert
git revert <commit-hash>
gcloud builds submit --config=cloudbuild.yaml
```
