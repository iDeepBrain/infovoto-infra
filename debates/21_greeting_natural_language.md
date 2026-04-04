# Debate 21: Greeting Detection — Saludos en Lenguaje Natural

**Rol:** UX Researcher
**Input:** Debate 20 (NLP Engineer) + datos eval
**Fecha:** 2026-04-03

---

## Contexto

El debate 20 del NLP Engineer identificó fallas de entity resolution, pero hay una falla de UX más fundamental que afecta la **primera impresión** del usuario:

| Score | Query | Respuesta real |
|-------|-------|---------------|
| 3.5 | "recién me entero de esta app a ver qué tal" | Perfil completo de César Acuña (1342 chars) |

Un usuario que llega por primera vez, curioso, escribiendo casualmente... y recibe un perfil de candidato que no pidió. Esto es **catastrófico para retención**. La primera interacción define si el usuario se queda o se va.

## Análisis UX

### Cómo escriben los peruanos al llegar a una app nueva

He observado patrones reales de usuarios peruanos en apps de chat:

**Patrones de saludo formal (el regex actual los detecta):**
- "hola" ✅
- "buenas tardes" ✅
- "hey" ✅

**Patrones de saludo informal/exploratorio (el regex NO los detecta):**
- "recién me entero de esta app a ver qué tal" ❌
- "a ver pe qué es esto" ❌
- "qué tal este app" ❌
- "acabo de instalar esto" ❌
- "oye me dijeron que aquí puedo saber de los candidatos" ❌
- "ya pe vamos a ver qué hay" ❌
- "mi pata me dijo que descargue esto" ❌
- "bueno aquí estoy a ver" ❌

### El problema con el regex actual

```python
_GREETING_RE = re.compile(
    r"^(hola|buenas|hey|...)...$",
    re.IGNORECASE,
)
```

**Dos problemas:**
1. **Anchor `^...$`**: Requiere que TODO el mensaje sea saludo. "recién me entero de esta app a ver qué tal" contiene "qué tal" pero no empieza con él.
2. **Vocabulario limitado**: No incluye frases de descubrimiento ("recién me entero", "acabo de instalar", "mi pata me dijo").

### Impacto en UX

| Escenario | Detección actual | Experiencia |
|-----------|-----------------|-------------|
| "hola" | ✅ Saludo | Bienvenida amigable |
| "recién me entero de esta app" | ❌ Query normal | Perfil de Acuña → **usuario confundido, se va** |
| "a ver pe qué es esto" | ❌ Query normal | Respuesta random → **usuario pierde confianza** |

La primera impresión fallida es más grave que una query específica mal respondida. Un usuario que ya entiende la app tolera un error; un usuario nuevo que no entiende qué pasó, no vuelve.

## Propuestas

### Propuesta 1: Ampliar regex con patrones de descubrimiento

```python
_GREETING_RE = re.compile(
    r"^(hola|buenas|hey|buenos?\s*d[ií]as?|buenas\s*tardes?|buenas\s*noches?|"
    r"qu[eé]\s*tal|holi|saludos|hi|hello)"
    r"(\s.*)?$"  # ← Permitir texto después del saludo
    + r"|"  # ← O patrones de descubrimiento
    + r"^(reci[eé]n\s+(me\s+enter[oé]|descubr[ií]|instal[eé]|baj[eé])|"
    r"a\s+ver\s+(pe|pues)?\s*(qu[eé]|c[oó]mo)|"
    r"acabo\s+de\s+(instalar|descargar|abrir)|"
    r"qu[eé]\s+(es\s+esto|tal\s+est[ea])|"
    r"mi\s+(pata|amig[oa])\s+me\s+dijo)",
    re.IGNORECASE,
)
```

**Problema:** El regex se vuelve inmantenible. Ya es complejo, agregar más patrones lo hace frágil.

### Propuesta 2: Detector de saludo/descubrimiento por keywords

En vez de un regex monolítico, usar dos detectores:

```python
_GREETING_STARTERS = {"hola", "buenas", "hey", "buenos", "saludos", "hi", "hello", "holi"}
_DISCOVERY_PATTERNS = [
    r"reci[eé]n\s+(?:me\s+enter|descubr|instal|baj)",
    r"acabo\s+de\s+(?:instalar|descargar|abrir|bajar)",
    r"a\s+ver\s+(?:pe\s+)?qu[eé]",
    r"qu[eé]\s+(?:es\s+esto|tal\s+est[ea]\s+app)",
    r"(?:mi\s+)?(?:pata|amig[oa]).*(?:dijo|recomend|mand)",
    r"(?:primera|1era?)\s+vez\s+(?:que|aqu[ií])",
]

def _is_greeting_or_discovery(msg: str) -> bool:
    stripped = msg.strip().lower()
    # Check if starts with greeting word
    first_word = stripped.split()[0] if stripped else ""
    if first_word.rstrip("!.,") in _GREETING_STARTERS:
        return True
    # Check discovery patterns
    for pat in _DISCOVERY_PATTERNS:
        if re.search(pat, stripped, re.I):
            return True
    return False
```

**Ventaja:** Más fácil de mantener, agregar patterns es trivial.
**Riesgo:** "recién me enteré de que keiko tiene problemas" → matchea descubrimiento pero es una query real.

### Propuesta 3: Detector de "no intención informativa"

En vez de detectar saludos, detectar **ausencia de intención informativa**:

```python
def _has_informative_intent(msg: str) -> bool:
    """Returns True if user is asking for actual electoral info."""
    # If message mentions a candidate, party, or electoral topic → informative
    if _resolve_nickname(msg):
        return True
    if any(re.search(p, msg, re.I) for p in _SPECIFIC_PATTERNS):
        return True
    # Electoral keywords
    if re.search(r'\b(candidat|eleccion|vot|partido|propuest|plan|encuest)', msg, re.I):
        return True
    return False
```

Si `_has_informative_intent()` es False → tratar como saludo/descubrimiento → bienvenida.

**Ventaja:** No necesitamos enumerar todos los saludos, sino verificar si hay contenido electoral.
**Riesgo:** "cuándo son las elecciones" sí tiene intent informativo pero no menciona candidato → la detección funciona por keyword "eleccion".

## Trade-offs

| Propuesta | Mantenimiento | False positives | Cobertura |
|-----------|---------------|-----------------|-----------|
| Ampliar regex | Alto (frágil) | Bajo | Medio |
| Keywords + discovery | Medio | Medio | Alto |
| "No intención informativa" | Bajo | Bajo | Alto |

**Mi recomendación:** Propuesta 3 (detectar ausencia de intent) complementada con Propuesta 2 (discovery patterns para mensajes ambiguos). Si el mensaje no tiene intent electoral claro, dar bienvenida. Si tiene intent, procesarlo normalmente.

## Respuesta ideal para "recién me entero de esta app a ver qué tal"

```
¡Bienvenid@! Soy VOTI, tu asistente para las elecciones 2026.

Puedo ayudarte con:
- Info de candidatos: "quién es Keiko", "info de Acuña"
- Comparar candidatos: "compara a Keiko y Acuña"
- Ver propuestas: "qué propone Keiko sobre educación"
- Ver antecedentes: "antecedentes de López Aliaga"
- Proceso electoral: "cuándo se vota", "es obligatorio votar"

¿Qué te gustaría saber?
```

Breve, útil, da ejemplos concretos de lo que puede hacer. Esto convierte un momento de confusión en un onboarding efectivo.

## Veredicto

✅ **Aprobado.** La Propuesta 3 es la más robusta. Pero necesita input del QA Lead (debate 22) para definir los edge cases y del Prompt Engineer (debate 23) para ver si esto se puede resolver en el system prompt en vez del preprocessor.
