# Debate 28: Cambios Mínimos en Pipeline

**Rol:** Backend Architect
**Input:** Debates 20-27 (todos los anteriores)
**Fecha:** 2026-04-03

---

## Contexto

El Product Manager (debate 27) priorizó 5 fixes para el sprint actual. Mi trabajo es diseñar la implementación mínima que resuelva todo sin romper nada.

**Constraint principal:** El pipeline ya funciona al 95.4% (249/261 queries OK). Cualquier cambio debe ser **quirúrgico** — resolver las 12 fallas sin regresar las 249 que funcionan.

## Archivos a modificar

Solo 2 archivos:

| Archivo | Cambios |
|---------|---------|
| `src/agent/preprocessor.py` | Greeting detector + _NICKNAMES ampliado |
| `src/agent/prompts/system.py` | Routing rules + fallback + "nunca ya te lo dije" |

**No tocar `core.py`.** El passthrough inteligente ya funciona. Los fixes son upstream (preprocessor) y prompt (system.py).

## Fix 1: Greeting/Discovery Detector

**Archivo:** `preprocessor.py`

**Estado actual:**
```python
_GREETING_RE = re.compile(
    r"^(hola|buenas|hey|...)...$",
    re.IGNORECASE,
)
```

**Cambio propuesto:** Reemplazar con detector de 2 capas.

```python
# ── Greetings (Layer 1: exact match) ────────────────────────────
_GREETING_RE = re.compile(
    r"^(hola|buenas|hey|buenos?\s*d[ií]as?|buenas\s*tardes?|buenas\s*noches?|"
    r"qu[eé]\s*tal|holi|saludos|hi|hello)"
    r"(\s*,?\s*(hola|buenas|buenas\s*tardes?|buenos?\s*d[ií]as?|"
    r"qu[eé]\s*tal|amigos?|gente))?\s*[!.,?]*$",
    re.IGNORECASE,
)

# ── Discovery patterns (Layer 2: new user exploration) ──────────
_DISCOVERY_RE = [
    re.compile(p, re.IGNORECASE) for p in [
        r"reci[eé]n\s+(?:me\s+enter|descubr|instal|baj|abr)",
        r"acabo\s+de\s+(?:instalar|descargar|abrir|bajar)",
        r"(?:primera|1era?)\s+vez\s+(?:que|aqu[ií]|uso)",
        r"a\s+ver\s+(?:pe\s+)?qu[eé]\s+(?:tal|hay|es\s+esto)",
        r"qu[eé]\s+(?:es\s+esto|tal\s+est[ae]\s+(?:app|bot))",
        r"(?:mi\s+)?(?:pata|amig[oa]|primo|sobrin).*(?:dijo|mand[oó]|recomend)",
    ]
]

def _is_greeting_or_discovery(msg: str) -> bool:
    """Detect greetings AND exploration messages from new users."""
    stripped = msg.strip()
    # Layer 1: exact greeting
    if _GREETING_RE.match(stripped):
        return True
    # Layer 2: discovery pattern (only if no electoral keywords)
    if _has_electoral_keyword(stripped):
        return False  # "recién me enteré de que keiko tiene problemas" → NOT a greeting
    return any(r.search(stripped) for r in _DISCOVERY_RE)

def _has_electoral_keyword(msg: str) -> bool:
    """Check if message contains actual electoral content."""
    return bool(re.search(
        r'\b(candidat|propuest|vot[ao]r|partido|antecedent|patrimoni|sentenci|'
        r'educaci|keiko|acuña|lopez\s*aliaga|lescano|luna|porky|fujimori)\b',
        msg, re.IGNORECASE
    ))
```

**En `preprocess()`:** Reemplazar el check actual de `_GREETING_RE.match(stripped)` con `_is_greeting_or_discovery(stripped)`.

**Impacto:** Solo afecta mensajes que NO tienen contenido electoral. "recién me entero de esta app a ver qué tal" → greeting. "recién me enteré de que keiko robó" → NO greeting (tiene "keiko").

**Riesgo:** BAJO. El filtro `_has_electoral_keyword` previene false positives.

## Fix 2: Ampliar _NICKNAMES con apellidos

**Archivo:** `preprocessor.py`

Agregar apellidos parciales de los 36 candidatos presidenciales al dict `_NICKNAMES`:

```python
_NICKNAMES = {
    # ── Apodos existentes (no cambiar) ──
    "keiko": ("KEIKO SOFIA FUJIMORI HIGUCHI", "Fuerza Popular"),
    "la china": ("KEIKO SOFIA FUJIMORI HIGUCHI", "Fuerza Popular"),
    # ... existentes ...

    # ── Apellidos parciales (nuevos) ──
    "lescano": ("YONHY LESCANO ANCIETA", "Acción Popular"),
    "fujimori": ("KEIKO SOFIA FUJIMORI HIGUCHI", "Fuerza Popular"),
    "la fujimori": ("KEIKO SOFIA FUJIMORI HIGUCHI", "Fuerza Popular"),
    "la fuji": ("KEIKO SOFIA FUJIMORI HIGUCHI", "Fuerza Popular"),
    "williams": ("JOSE DANIEL WILLIAMS ZAPATA", "Avanza País"),
    "molinelli": ("FIORELLA GIANNINA MOLINELLI ARISTONDO", "Fuerza y Libertad"),
    "sanchez": ("ROBERTO HELBERT SANCHEZ PALOMINO", "Juntos por el Perú"),
    "bermejo": ("GUILLERMO BERMEJO ROJAS", "???"),
    # ... completar con apellidos principales ...
}
```

**Sobre typos:** NO agregar fuzzy matching por ahora. El riesgo de false positives es alto y el beneficio es bajo (solo 1 query de 261). Si "kien es keiko" realmente falla por entity resolution (debate 22 dice que NO), entonces no necesitamos typo handling.

**Impacto:** "ese lescano de qué partido es pe" → "lescano" matchea → entity resuelta → pipeline funciona.

## Fix 3: Router prompt disambiguation

**Archivo:** `system.py`

Agregar al `_BASE_PROMPT`, sección "### Herramientas (OBLIGATORIO)":

```
### Disambiguation de queries (IMPORTANTE)
- "qué estudió X", "dónde estudió X", "educación de X", "formación de X", "carrera de X" → `buscar_candidato_por_nombre(nombre="X")`. La educación está en el PERFIL, no en antecedentes.
- "de quién es [PARTIDO]", "quién lidera [PARTIDO]", "candidato de [PARTIDO]" → `listar_candidatos_region(partido="[PARTIDO]", cargo="presidente")`.
- "cuáles son los partidos", "partidos principales" → `listar_candidatos_region(cargo="presidente")`. En tu respuesta, AGRUPA por partido, no listes candidatos individuales.
- "qué propone X para/sobre [TEMA]" → `buscar_propuesta_tema(tema="[TEMA]")`. SIEMPRE extrae el tema. NUNCA llames sin tema cuando el usuario especificó uno.

### Ejemplos de routing correcto
- "qué estudió keiko" → buscar_candidato_por_nombre(nombre="Keiko Fujimori")
- "de quién es Fuerza Popular" → listar_candidatos_region(partido="Fuerza Popular", cargo="presidente")
- "qué propone acuña para seguridad" → buscar_propuesta_tema(tema="seguridad", partido="Alianza para el Progreso")
- "antecedentes de keiko" → buscar_candidato_por_nombre(nombre="Keiko") para obtener DNI, luego verificar_antecedentes(dni=...)
```

**Impacto:** Resuelve Q1 (educación → perfil), Q2 (seguridad → tema extraído), Q3 (partido → listar por partido), Q6 (partidos → agrupar).

## Fix 4: "Nunca digas ya te lo dije"

**Archivo:** `system.py`

Agregar al `_BASE_PROMPT`:

```
### Contexto de conversación
- NUNCA respondas "ya te di la información" ni "ya respondí eso anteriormente". Si el usuario pregunta algo, SIEMPRE responde con la información completa, incluso si la mencionaste antes en la conversación. El usuario puede no haberla leído o querer verla de nuevo.
```

**Impacto:** Resuelve Q9 ("kien es keiko" → "Ya te di la información").

## Fix 5: Fallback para datos no disponibles

**Archivo:** `system.py`

Agregar al `_BASE_PROMPT`:

```
### Datos no disponibles
- Si el usuario pregunta sobre gasto de campaña, financiamiento de campaña, donaciones, o aportantes: informa que no cuentas con esos datos y ofrece lo que SÍ tienes (patrimonio declarado, antecedentes, propuestas).
- NUNCA devuelvas un perfil completo cuando el usuario preguntó algo específico que no tienes. En ese caso, di claramente que no tienes la información específica.
- NO redirijas a páginas externas a menos que el usuario lo pida. Mejor ofrece alternativas con datos que SÍ tienes.
```

**Impacto:** Resuelve Q7 (gasto campaña → "no tengo, te ofrezco patrimonio"), Q11 (financiamiento → fallback útil).

## Cambios exactos por archivo

### `preprocessor.py` (~40 líneas nuevas)

| Cambio | Línea aprox. | Tipo |
|--------|-------------|------|
| `_DISCOVERY_RE` lista de patterns | Después de `_GREETING_RE` (L122) | Constante nueva |
| `_is_greeting_or_discovery()` | Después de `_DISCOVERY_RE` | Función nueva |
| `_has_electoral_keyword()` | Junto a `_is_greeting_or_discovery` | Función nueva |
| Ampliar `_NICKNAMES` con apellidos | Dentro del dict existente (L60-98) | Agregar entradas |
| Usar `_is_greeting_or_discovery()` en `preprocess()` | Donde se llama `_GREETING_RE.match()` | Reemplazar call |

### `system.py` (~200 tokens nuevos en prompt)

| Cambio | Sección |
|--------|---------|
| Reglas de disambiguation | Después de "### Herramientas (OBLIGATORIO)" |
| Ejemplos de routing | Nueva subsección |
| "Nunca ya te lo dije" | Nueva subsección "### Contexto de conversación" |
| Fallback para datos no disponibles | Nueva subsección "### Datos no disponibles" |

## Testing plan

### Smoke test (las 12 queries problemáticas)

| Query | Antes | Expected después |
|-------|-------|-----------------|
| "qué estudió lopez aliaga" | Antecedentes (1.0) | Educación del perfil |
| "qué propone lopez aliaga para la seguridad" | Visión general (1.2) | Propuestas de seguridad |
| "alianza para el progreso de quién es" | Ejes estratégicos (3.2) | César Acuña, candidato de APP |
| "ese lescano de qué partido es pe" | "No encontré" (3.4) | Acción Popular |
| "cuáles son los partidos principales" | 36 candidatos (3.4) | Partidos agrupados |
| "cuánto ha gastado cada candidato" | Perfil Acuña (3.4) | "No tengo datos de gasto" |
| "recién me entero de esta app" | Perfil Acuña (3.5) | Bienvenida de VOTI |
| "kien es keiko" | "Ya te di la info" (3.5) | Perfil de Keiko |
| "acuña es empresario cierto?" | "No encontré" (3.5) | Patrimonio de Acuña |
| "quién financia a keiko" | Perfil completo (3.6) | Info legal relevante a financiamiento |
| "quién defiende a los trabajadores" | "No encontré" (3.9) | Propuestas laborales |
| "candidatos a presidente 2026" | 36 candidatos (3.2) | (no cambia, P5) |

### Regression test (261 queries completas)

Correr `save_eval_report.py` después de los cambios. Criterio: score global ≥ 4.79 (no debe bajar).

## Riesgos

| Riesgo | Mitigación |
|--------|-----------|
| Greeting detector captura queries reales | `_has_electoral_keyword()` como filtro |
| Prompt más largo → latencia | +200 tokens es <0.5% del context, despreciable |
| Router sigue confundido con few-shot | Los ejemplos son exactos para los 4 casos fallidos |
| _NICKNAMES con apellidos ambiguos | "luna" puede matchear con Jose Luna o con otra persona → usar "luna galvez" |

## Veredicto

✅ **Aprobado.** 5 fixes quirúrgicos en 2 archivos, ~40 líneas de código + ~200 tokens de prompt. Sin cambios en core.py ni en la lógica de passthrough/synthesis. Resolución esperada: 10 de 12 queries.

**Pido al ML Engineer (debate 29) que evalúe si el topic extraction del Prompt Engineer es suficiente o necesitamos algo más sofisticado.**
