# Debate 11 -- El Problema: Passthrough Devuelve Siempre lo Mismo

> **Fecha:** 2 de abril 2026
> **Entrada:** Debates 1-10 (optimizaciones de latencia ya implementadas)
> **Problema:** El passthrough de templates `_resumen_markdown` siempre devuelve el perfil completo, sin importar qué preguntó el usuario.

---

## Evidencia del Problema

```
Usuario: "info de keiko"        → Perfil completo ✅ (correcto)
Usuario: "cuánto gana acuña"    → Perfil completo ❌ (debería solo patrimonio)
Usuario: "acuña está en la cima?" → Perfil completo ❌ (debería encuestas/ranking)
Usuario: "dónde estudió keiko?" → Perfil completo ❌ (debería solo educación)
```

**Causa raíz técnica:** En `core.py` línea 1092, `_has_preformatted_content()` detecta `_resumen_markdown` y SIEMPRE hace passthrough. No mira qué preguntó el usuario.

---

## Ciclo 1 -- Peruano de a Pie

Yo como usuario, si pregunto "cuánto gana Acuña", quiero que me diga cuánto gana. No quiero un resumen de 3 pantallas con educación, experiencia, partidos... Eso me abruma. Si quiero todo eso, pregunto "quién es Acuña".

El chatbot debería ser como preguntarle a un amigo que sabe de política: si le digo "oye, cuánto gana Acuña?", me dice "tiene patrimonio de X soles, gana Y al mes". No me recita su CV completo.

**Problema real:** Me siento ignorado. El bot no me escucha. Da lo mismo qué pregunte, siempre me da lo mismo.

### Veredicto: El passthrough actual rompe la confianza del usuario. Hay que arreglarlo.

---

## Ciclo 2 -- Stakeholder (Product Owner)

Desde negocio, este es un problema de **retención**. Si el usuario siente que el bot no entiende su pregunta, no vuelve. Y el día de elecciones (12 de abril), necesitamos que el usuario confíe.

**Datos del tradeoff:**
- Passthrough actual: 0.7-1.5s, pero respuesta genérica siempre
- LLM synthesis: 3-5s, pero respuesta precisa a lo que preguntó

**Mi posición:** Prefiero 3-5s con respuesta precisa que 0.7s con respuesta incorrecta. La velocidad no sirve si la respuesta no es la que el usuario pidió.

PERO -- para preguntas genéricas como "quién es keiko" o "info de acuña", el perfil completo SÍ es la respuesta correcta. El passthrough ahí sí funciona.

**Lo que necesito:** Un sistema que distinga:
1. Pregunta genérica ("info de X") → passthrough rápido ✅
2. Pregunta específica ("cuánto gana X") → síntesis precisa, aunque tarde más ✅

### Veredicto: Tradeoff velocidad/precisión. No eliminar passthrough, hacerlo condicional.

---

## Ciclo 3 -- Delivery Lead

Estoy de acuerdo con el stakeholder, pero me preocupa el **scope creep**. Quedan 10 días para las elecciones. No podemos reescribir el pipeline entero.

**Restricciones:**
- El cambio debe ser mínimo en líneas de código
- No puede romper lo que ya funciona (listas, antecedentes)
- Debe ser testeable en local antes de deploy
- Rollback fácil si falla

**Mi propuesta:** El cambio más pequeño que resuelve el 80% del problema:
1. Detectar con regex si la pregunta es específica (tiene palabras como "cuánto gana", "patrimonio", "dónde estudió")
2. Si es específica → no hacer passthrough, dejar que el synthesizer use los datos del MCP
3. Si es genérica → passthrough como ahora

Dos archivos: `preprocessor.py` (detectar) y `core.py` (decidir). Nada más.

### Veredicto: Alcance mínimo. Regex en preprocessor + condicional en core.py. 2 archivos.

---

## Ciclo 4 -- Tech Lead

El Delivery Lead tiene razón en limitar el alcance. Pero necesito asegurar que la arquitectura sea correcta.

**Análisis del flujo actual:**
```
mensaje → preprocessor (IntentResult) → router → MCP call → passthrough O synthesis → respuesta
```

La decisión passthrough/synthesis se toma en `core.py` línea 1092. En ese punto ya tenemos:
- `intent` (IntentResult del preprocessor) — con `enriched_message`, `resolved_entities`
- `tool_results` — datos del MCP con `_resumen_markdown`
- `valid_calls` — qué tools se llamaron

**Punto clave:** `IntentResult` ya pasa por el pipeline completo. Si le agregamos `is_specific_query: bool`, la decisión en core.py es trivial:

```python
if _has_preformatted_content(tool_results) and not intent.is_specific_query:
    # passthrough
else:
    # synthesis
```

**Excepciones que NO deben cambiar:**
- `lista_formateada` → SIEMPRE passthrough (es una lista, no un perfil)
- `verificar_antecedentes` con `_resumen_markdown` → SIEMPRE passthrough (el usuario pidió explícitamente antecedentes)
- Solo `buscar_candidato_por_dni`/`buscar_candidato_por_nombre` deben ser condicionales

### Veredicto: Agregar `is_specific_query` a IntentResult. Condicional solo para tools de perfil.

---

## Ciclo 5 -- Senior MLE

Concuerdo con Tech Lead. La implementación concreta:

**En preprocessor.py:**
```python
@dataclass
class IntentResult:
    # ... campos existentes ...
    is_specific_query: bool = False  # NEW

_SPECIFIC_PATTERNS = [
    r"\bcuánto\b.*\bgana\b", r"\bpatrimonio\b", r"\bsueldo\b",
    r"\bdónde\s+estudi[oó]\b", r"\beducaci[oó]n\b", r"\bformaci[oó]n\b",
    r"\bexperiencia\b", r"\btrabaj[oó]\b",
    r"\bsentencias?\b", r"\bantecedentes?\b",
    r"\brankings?\b", r"\bencuestas?\b", r"\bestá en la cima\b",
    r"\bpostura\b", r"\bposici[oó]n\b",
    r"\bingresos?\b", r"\binmuebles?\b", r"\bbienes?\b",
]

# En preprocess(), antes del return:
is_specific = any(re.search(p, stripped, re.IGNORECASE) for p in _SPECIFIC_PATTERNS)
```

**En core.py línea ~1092:**
```python
elif len(tool_results) == 1 and _has_preformatted_content(tool_results):
    name, data = next(iter(tool_results.items()))
    is_profile_tool = name in ("buscar_candidato_por_dni", "buscar_candidato_por_nombre")
    if is_profile_tool and intent.is_specific_query:
        pass  # Fall through to LLM synthesis
    else:
        reply_text = _build_passthrough_reply(data)
```

**Líneas de código nuevas:** ~25 en preprocessor, ~5 en core. Mínimo.

### Veredicto: Aprobado. Implementación clara, mínima, reversible.

---

## Consenso del Debate 11

| Rol | Posición | Veredicto |
|-----|----------|-----------|
| Peruano de a pie | "Que me entienda, no me recite el CV" | Arreglar |
| Stakeholder | Tradeoff velocidad/precisión | Passthrough condicional |
| Delivery Lead | Mínimo cambio, 2 archivos | Regex + condicional |
| Tech Lead | IntentResult.is_specific_query | Condicional por tool name |
| Senior MLE | ~30 líneas de código total | Aprobado |

**Decisión:** Passthrough condicional. Preguntas genéricas → rápido. Preguntas específicas → síntesis precisa.

**Entrada para Debate 12:** ¿Qué patterns de regex cubren el 80% de preguntas específicas? ¿Hay edge cases peligrosos?
