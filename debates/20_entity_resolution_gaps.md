# Debate 20: Gaps en Entity Resolution — Typos, Fuzzy Matching y Pronombres

**Rol:** NLP Engineer
**Input:** Resultados eval 261 queries (4.79/5 global), 12 queries con score < 4.0
**Fecha:** 2026-04-03

---

## Contexto

La evaluación reveló que 3 de las 12 fallas más graves son directamente causadas por problemas de entity resolution en el preprocessor:

| Score | Query | Problema |
|-------|-------|----------|
| 3.5 | "kien es keiko" | Typo "kien" → no resuelve entidad → "Ya te di la información" |
| 3.4 | "ese lescano de qué partido es pe" | "ese" como pronombre + "lescano" sin match → "No encontré esa info" |
| 3.5 | "acuña es empresario cierto? cuánto tiene?" | Falla en sesión multi-turno → "No encontré esa info" |

## Análisis técnico

### Estado actual del preprocessor

`preprocessor.py` línea 101-107 — `_resolve_nickname()`:

```python
def _resolve_nickname(message: str) -> dict:
    msg = message.lower()
    for nick, (name, party) in sorted(_NICKNAMES.items(), key=lambda x: -len(x[0])):
        if re.search(rf"\b{re.escape(nick)}\b", msg):
            return {"candidate": name, "party": party}
    return {}
```

**Problema 1: Solo exact-match.** El diccionario `_NICKNAMES` tiene "keiko" pero NO "kien", "kiko", "keilo", etc. No hay fuzzy matching.

**Problema 2: No hay resolución de pronombres.** "ese lescano" contiene "ese" (pronombre demostrativo) + "lescano" (apellido). El preprocessor debería:
1. Detectar "lescano" como apellido parcial
2. Resolver a "YONHY LESCANO ANCIETA"
3. Ignorar "ese" como ruido conversacional

Pero `_resolve_nickname()` solo busca en `_NICKNAMES` (apodos exactos). No busca en apellidos parciales.

**Problema 3: Entity context en sesiones.** "acuña es empresario cierto? cuánto tiene?" en sesión. El preprocessor tiene carry-forward de entidades (línea 289-290):

```python
if not entities.get("candidate") and entity_context.get("candidate"):
    entities = {**entity_context, **entities}
```

Pero si en el turno anterior se habló de OTRO candidato y el usuario dice "acuña", hay conflicto entre entity_context (candidato anterior) y "acuña" (nuevo candidato mencionado). El nickname "acuña" SÍ está en `_NICKNAMES`, así que debería resolverse... a menos que el LLM router falle después.

### Diagnóstico por query

**"kien es keiko" (score 1.0 → 3.5):**
1. `_resolve_nickname("kien es keiko")` → busca "kien" en _NICKNAMES → NO MATCH
2. Pero "keiko" SÍ está en _NICKNAMES → DEBERÍA MATCHEAR
3. El problema es que la iteración `for nick, (name, party)` itera en orden de longitud descendente
4. "keiko" tiene 5 chars → se procesa y SÍ matchea
5. **Entonces el nickname SÍ se resuelve**... pero la respuesta dice "Ya te di la información"
6. Esto sugiere que el problema NO es el preprocessor sino el **query cache o el LLM router**
7. Hipótesis: esta query estaba en una sesión donde "keiko" ya se había preguntado → el LLM dice "ya te lo dije"

**"ese lescano de qué partido es pe" (score 3.4):**
1. `_resolve_nickname("ese lescano de qué partido es pe")` → itera _NICKNAMES
2. "lescano" NO está en _NICKNAMES (verificar — puede que sí esté)
3. Si no está → entities vacías → router sin contexto → falla
4. Además "de qué partido es" no matchea ningún specific_pattern → no se sabe qué buscar

**"acuña es empresario cierto? cuánto tiene?" (score 3.5):**
1. "acuña" SÍ está en _NICKNAMES → resuelve a "CESAR ACUÑA PERALTA"
2. is_specific_query → `\bcuánto\b.*\btiene\b` matchea → TRUE
3. Pipeline debería: buscar perfil → synthesis focalizada en patrimonio
4. Pero responde "No encontré esa info" → ¿falla el MCP? ¿timeout? ¿sesión corrupta?
5. Hipótesis: en contexto de sesión, el entity_context tiene otro candidato y hay conflicto

## Propuestas

### Propuesta 1: Fuzzy matching con Levenshtein para nombres

Agregar segunda capa de matching después de exact nicknames:

```python
def _fuzzy_resolve(message: str, threshold: int = 2) -> dict:
    """Fuzzy match against known candidate names and nicknames."""
    words = re.findall(r'\b\w+\b', message.lower())
    all_names = {**_NICKNAMES}
    # Add apellidos parciales
    all_names.update({
        "lescano": ("YONHY LESCANO ANCIETA", "Acción Popular"),
        "fujimori": ("KEIKO SOFIA FUJIMORI HIGUCHI", "Fuerza Popular"),
        "luna": ("JOSE LUNA GALVEZ", "Podemos Perú"),
        # ... etc
    })
    for word in words:
        if len(word) < 3:
            continue
        for name in all_names:
            dist = levenshtein(word, name)
            if dist <= threshold and dist < len(name) * 0.3:
                return all_names[name]
    return {}
```

**Trade-off:** Levenshtein es O(n*m) por comparación. Con ~50 nicknames y ~10 words, son 500 comparaciones. Despreciable en latencia (<1ms). Pero puede generar **false positives** con nombres cortos (ej: "luna" matchea con "una").

### Propuesta 2: Apellidos parciales como lookup directo

Sin fuzzy matching, solo agregar apellidos comunes al diccionario:

```python
_NICKNAMES = {
    # Existing...
    "keiko": ("KEIKO SOFIA FUJIMORI HIGUCHI", "Fuerza Popular"),
    "acuña": ("CESAR ACUÑA PERALTA", "Alianza para el Progreso"),
    # Agregar apellidos parciales
    "lescano": ("YONHY LESCANO ANCIETA", "Acción Popular"),
    "fujimori": ("KEIKO SOFIA FUJIMORI HIGUCHI", "Fuerza Popular"),
    "lopez aliaga": ("RAFAEL BERNARDO LOPEZ ALIAGA CAZORLA", "Renovación Popular"),
    "luna galvez": ("JOSE LUNA GALVEZ", "Podemos Perú"),
    "luna": ("JOSE LUNA GALVEZ", "Podemos Perú"),
    "williams": ("JOSE DANIEL WILLIAMS ZAPATA", "Avanza País"),
    # ... todos los apellidos de candidatos
}
```

**Trade-off:** Más simple, zero false positives, pero no resuelve typos como "kien".

### Propuesta 3: Normalización de typos comunes

Tabla de typos peruanos comunes antes del nickname lookup:

```python
_TYPO_MAP = {
    "kien": "quien",
    "kiko": "keiko",
    "kien": "quien",
    "acuna": "acuña",
    "fuji": "fujimori",
    "aliaga": "lopez aliaga",
}

def _normalize_typos(msg: str) -> str:
    for typo, fix in _TYPO_MAP.items():
        msg = re.sub(rf'\b{re.escape(typo)}\b', fix, msg, flags=re.I)
    return msg
```

**Trade-off:** Requiere curar manualmente typos. Pero es determinístico y sin riesgo.

## Trade-offs globales

| Propuesta | Latencia | False positives | Mantenimiento | Cobertura typos |
|-----------|----------|-----------------|---------------|-----------------|
| Fuzzy Levenshtein | +1ms | Medio | Bajo | Alto |
| Apellidos parciales | +0ms | Zero | Medio (curar lista) | Ninguno |
| Typo map | +0ms | Zero | Alto (curar typos) | Medio |

**Mi recomendación:** Combinar Propuesta 2 (apellidos) + Propuesta 3 (typos comunes). Es lo más seguro y cubre los 3 casos fallidos. Fuzzy matching es riesgoso para nombres cortos.

## Preguntas abiertas

1. ¿"kien es keiko" realmente falla por entity resolution o por otro motivo? El nickname "keiko" debería matchear.
2. ¿El reply "Ya te di la información" viene del LLM o del cache? Necesito ver logs.
3. ¿"acuña es empresario cierto?" falla por entity o por pipeline de sesión?

## Veredicto

🔄 **Necesita más investigación.** Las propuestas 2+3 son sólidas, pero antes de implementar necesito confirmar que las fallas de "kien es keiko" y "acuña es empresario" son realmente de entity resolution y no de otra parte del pipeline. Pido al QA Lead (debate 22) que clasifique con precisión.
