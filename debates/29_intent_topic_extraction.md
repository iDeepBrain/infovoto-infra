# Debate 29: Intent Classification y Topic Extraction

**Rol:** ML Engineer
**Input:** Debates 20-28 (todos los anteriores)
**Fecha:** 2026-04-03

---

## Contexto

El Backend Architect (debate 28) diseñó fixes quirúrgicos: greeting detector, _NICKNAMES ampliado, y prompt disambiguation. El Prompt Engineer (debate 23) propuso reglas de routing y few-shot examples. Mi pregunta es: **¿es suficiente el enfoque de regex + prompt, o necesitamos un clasificador más sofisticado?**

## Análisis del approach actual

### is_specific_query (regex, ya implementado)

El passthrough inteligente usa `_SPECIFIC_PATTERNS` (30 regex compilados) para detectar si una query es específica. Score global: 4.79/5. Funciona bien.

**Pero las 4 fallas de routing NO son del passthrough inteligente**, son del LLM router que elige el tool incorrecto. El passthrough inteligente decide "¿mostrar perfil completo o ir a synthesis?", mientras que el router decide "¿llamar buscar_candidato_por_nombre o verificar_antecedentes?".

Son dos decisiones distintas:
1. **Passthrough vs Synthesis** (preprocessor → core.py) — FUNCIONA BIEN (95.4%)
2. **Tool selection** (LLM router → system prompt) — FALLA en 4 queries

### ¿Por qué falla el LLM router?

El router es Gemini 2.0 Flash con system prompt. Las fallas son:

| Query | Decisión del LLM | Correcta | Causa |
|-------|------------------|----------|-------|
| "qué estudió lopez aliaga" | verificar_antecedentes | buscar_candidato_por_nombre | "estudió" → LLM confunde educación con investigación |
| "qué propone para seguridad" | buscar_propuesta_tema(tema="") | buscar_propuesta_tema(tema="seguridad") | LLM no extrae "seguridad" como tema |
| "de quién es APP" | buscar_propuesta_tema | listar_candidatos_region | "de quién es" → LLM no tiene regla |
| "partidos principales" | listar_candidatos_region | (misma, pero sin agrupación) | No hay tool de partidos |

**Root cause:** El LLM tiene 23 tools disponibles (MCP registry). Sin guidance explícita, elige el tool "más parecido" semánticamente. "estudió" → "investigación" → "antecedentes" es una cadena semántica razonable para el LLM.

## ¿Necesitamos un clasificador ML dedicado?

### Opción A: Prompt engineering (propuesto por debates 23, 28)

- Agregar disambiguation rules + few-shot al system prompt
- 0 código ML adicional, solo cambio de prompt
- Cubre los 4 casos fallidos con ejemplos exactos

**Pros:** Simple, barato, rápido de implementar.
**Contras:** No generaliza — solo cubre los 4 patrones que conocemos. Si mañana aparece "en qué se graduó keiko" (educación), necesitamos agregar otro ejemplo.

### Opción B: Topic classifier pre-routing

Antes del LLM router, clasificar el topic de la query:

```python
TOPIC_PATTERNS = {
    "educación": [r"\bestudi[oó]\b", r"\beducaci[oó]n\b", r"\bformaci[oó]n\b", r"\buniversidad\b", r"\bcarrera\b", r"\btítulo\b", r"\bgradu[oó]\b"],
    "patrimonio": [r"\bcuánto\s+(?:gana|tiene|cobra)\b", r"\bpatrimonio\b", r"\bsueldo\b", r"\bplata\b", r"\bbienes\b"],
    "antecedentes": [r"\bantecedentes?\b", r"\bsentencias?\b", r"\bjuicios?\b", r"\bprocesos?\b"],
    "propuestas": [r"\bpropone\b", r"\bpropuestas?\b", r"\bplan\b.*\bgobierno\b"],
    "partido": [r"\bpartido\b", r"\bde\s+quién\s+es\b", r"\bquién\s+lidera\b"],
}

def classify_topic(msg: str) -> str | None:
    for topic, patterns in TOPIC_PATTERNS.items():
        if any(re.search(p, msg, re.I) for p in patterns):
            return topic
    return None
```

Luego, inyectar el topic en el router prompt:

```
El usuario pregunta sobre: [EDUCACIÓN]
Herramienta correcta para educación: buscar_candidato_por_nombre (la educación está en el perfil)
```

**Pros:** Generaliza mejor. "en qué se graduó keiko" → topic="educación" → routing correcto sin ejemplo específico.
**Contras:** Más código, más complejidad. Requiere mantener TOPIC_PATTERNS.

### Opción C: Embedding-based intent classifier

Usar embeddings del LLM para clasificar intent:
1. Pre-compute embeddings de queries de referencia por categoría
2. En runtime, compute embedding de la query del usuario
3. Cosine similarity → categoría más cercana

**Pros:** Máxima generalización, cubre typos, jerga, sinónimos.
**Contras:** Latencia adicional (~100ms por embedding call), complejidad, overengineering para 4 fallas de 261.

## Mi recomendación

**Opción A (prompt) + Opción B lite (topic hints).**

La Opción A cubre los 4 casos exactos. La Opción B lite agrega generalización sin complejidad excesiva.

### Implementación Opción B lite

En lugar de un classifier completo, agregar **topic hints al enriched_message** del preprocessor:

```python
# En preprocessor.py, al final de preprocess():
topic = _classify_topic(stripped)
if topic:
    enriched = f"[TOPIC: {topic}] {enriched}"
    logger.info("[PREPROCESS] topic=%s msg='%s'", topic, stripped[:80])
```

El LLM router ve `[TOPIC: educación] qué estudió lopez aliaga` y entiende que debe buscar educación, no antecedentes.

**Ventaja sobre Opción A pura:** Si aparece un nuevo patrón ("en qué se graduó", "tiene título"), el topic classifier lo cubre sin agregar más few-shot.

**Cantidad de código nuevo:** ~25 líneas (dict de patterns + función + 3 líneas en preprocess()).

### ¿Es overengineering?

4 fallas de 261 = 1.5%. ¿Vale la pena crear un topic classifier para 1.5%?

**Sí, porque:**
1. Estas 4 fallas tienen los scores más bajos (1.0, 1.2, 3.2, 3.4) — son las peores experiencias
2. El topic classifier también MEJORA la synthesis de queries que ya funcionan bien — más contexto = mejor respuesta
3. El costo es ~25 líneas, no es un modelo ML complejo

**No vale la pena:** Opción C (embeddings). Overkill total para 4 queries.

## Trade-offs

| Aspecto | Solo prompt (A) | Prompt + topic hints (A+B) | Embeddings (C) |
|---------|----------------|---------------------------|----------------|
| Cobertura | 4 queries exactas | 4 + generalización | Máxima |
| Latencia | +0ms | +0ms (regex) | +100ms |
| Código nuevo | 0 (solo prompt) | ~25 líneas | ~150 líneas + deps |
| Mantenimiento | Agregar examples | Agregar patterns | Actualizar embeddings |
| Riesgo de regresión | Bajo | Bajo | Medio |

## Sobre el `is_specific_query` existente

El topic classifier (Opción B) NO reemplaza `is_specific_query`. Son complementarios:

- `is_specific_query` → decide passthrough vs synthesis (core.py)
- `topic` → ayuda al router a elegir el tool correcto (system.py/router)

Pueden coexistir sin conflicto. De hecho, `_classify_topic()` podría reutilizar algunos patterns de `_SPECIFIC_PATTERNS_RAW` para evitar duplicación.

## Veredicto

✅ **Aprobado: Opción A + B lite.** Prompt disambiguation + topic hints en preprocessor. Cubre los 4 casos fallidos con generalización mínima. Sin overengineering.

**Pido al Delivery Lead (debate 30) que diseñe los fallback messages amigables para cuando el bot no tiene datos.**
