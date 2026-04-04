# Debate 15 -- Consenso Global: Passthrough Inteligente

> **Fecha:** 2 de abril 2026
> **Entrada:** Debates 1-14 completos
> **Objetivo:** Síntesis final de todas las decisiones. Plan de implementación definitivo.

---

## Resumen de 14 Debates

### Debates 1-10: Optimizaciones de Latencia (YA IMPLEMENTADOS)
| Opt | Estado | Resultado |
|-----|--------|-----------|
| Templates `_resumen_markdown` | ✅ Implementado | Perfiles de 10s → 1s |
| `gemini-2.0-flash` para synthesizer | ✅ Implementado | Synthesis de 10s → 3-5s |
| Cache por `tool+args` en Redis | ✅ Implementado | Queries repetidas <100ms |
| Fast-routes en preprocessor | ✅ Parcial | Algunos patterns |
| Source attribution corregido | ✅ Implementado | DJHV, VotaBienPerú, Decide.pe |
| Legal UX mejorado | ✅ Implementado | 3 títulos + CTA |

### Debates 11-14: Passthrough Inteligente (POR IMPLEMENTAR)
| Debate | Decisión clave |
|--------|---------------|
| 11 — Problema | Passthrough ignora la pregunta. Solución: condicional por intent |
| 12 — Patterns | ~30 regex conservadores. False negatives aceptables. Logging del match |
| 13 — Synthesizer | Hint dinámico "responde SOLO lo que preguntó" cuando es específica |
| 14 — Deploy | Branch dev. Test local. Deploy dev. Verificar. Luego prod |

---

## Plan de Implementación Definitivo

### Archivo 1: `infovoto-gateway/src/agent/preprocessor.py`

**Cambio A — Campo nuevo en IntentResult (línea ~36):**
```python
@dataclass
class IntentResult:
    intent: str
    instant_reply: str | None = None
    enriched_message: str = ""
    resolved_entities: dict = field(default_factory=dict)
    fast_route: FastRoute | None = None
    is_specific_query: bool = False          # ← NUEVO
```

**Cambio B — Patterns de detección (constante de módulo):**
```python
import re

_SPECIFIC_PATTERNS_RAW = [
    # Patrimonio / dinero
    r"\bcuánto\b.*\b(?:gana|tiene|cobra)\b",
    r"\bpatrimonio\b",
    r"\bsueldo\b",
    r"\bingresos?\b",
    r"\binmuebles?\b",
    r"\bbienes?\b",
    r"\bplata\b",
    # Educación
    r"\b(?:dónde|qué)\s+estudi[oó]\b",
    r"\beducaci[oó]n\b",
    r"\bformaci[oó]n\b",
    r"\buniversidad\b",
    # Experiencia
    r"\bexperiencia\b",
    r"\btrabaj[oó]\b",
    # Legal
    r"\bsentencias?\b",
    r"\bjuicios?\b",
    r"\bprocesos?\s+(?:judiciales?|penales?)\b",
    # Rankings / encuestas
    r"\brankings?\b",
    r"\bencuestas?\b",
    r"\bva ganando\b",
    # Posiciones políticas
    r"\bpostura\b",
    r"\bposici[oó]n\b",
    r"\bqué piensa\b.*\bsobre\b",
    r"\ba favor\b",
    r"\ben contra\b",
    # Temas específicos
    r"\baborto\b",
    r"\bpena de muerte\b",
    r"\bminería\b",
    r"\bseguridad\b",
    r"\bsalud\b",
]

_SPECIFIC_RE = [re.compile(p, re.IGNORECASE) for p in _SPECIFIC_PATTERNS_RAW]

def _is_specific_query(text: str) -> tuple[bool, str | None]:
    """Detecta si la pregunta es sobre un aspecto específico del candidato."""
    for r in _SPECIFIC_RE:
        if r.search(text):
            return True, r.pattern
    return False, None
```

**Cambio C — Llamar en `preprocess()` antes del return final (~línea 258):**
```python
is_specific, matched_pattern = _is_specific_query(stripped)
if is_specific:
    logger.info("[PREPROCESS] specific_query pattern=%s msg='%s'", matched_pattern, stripped[:80])

return IntentResult(
    intent="query",
    enriched_message=enriched,
    resolved_entities=entities,
    fast_route=fast_route,
    is_specific_query=is_specific,       # ← NUEVO
)
```

---

### Archivo 2: `infovoto-gateway/src/agent/core.py`

**Cambio D — Passthrough condicional (~línea 1092):**
```python
# ANTES (actual):
elif len(tool_results) == 1 and _has_preformatted_content(tool_results):
    name, data = next(iter(tool_results.items()))
    reply_text = _build_passthrough_reply(data)
    tool_used = tool_used or name
    logger.info("[PASSTHROUGH] %s → reply_len=%d", name, len(reply_text))

# DESPUÉS (nuevo):
elif len(tool_results) == 1 and _has_preformatted_content(tool_results):
    name, data = next(iter(tool_results.items()))
    is_profile_tool = name in ("buscar_candidato_por_dni", "buscar_por_nombre")
    if is_profile_tool and intent.is_specific_query:
        logger.info("[PIPELINE] %s specific_query → SYNTHESIS", name)
        # Fall through to LLM synthesis below
    else:
        reply_text = _build_passthrough_reply(data)
        tool_used = tool_used or name
        logger.info("[PASSTHROUGH] %s → reply_len=%d", name, len(reply_text))
```

**Cambio E — Hint para synthesizer cuando es específica (~línea 1100+):**

Donde se construye el prompt del synthesizer, agregar:
```python
extra_synth_hint = ""
if intent.is_specific_query:
    extra_synth_hint = (
        "\n\nIMPORTANTE: El usuario hizo una pregunta específica. "
        "Responde SOLO lo que preguntó, de forma breve y directa. "
        "No incluyas el perfil completo ni secciones no solicitadas."
    )
# Pasar al synthesizer: SYNTHESIZER_INSTRUCTION + extra_synth_hint
```

---

## Resumen de Cambios

| Archivo | Cambio | Líneas nuevas |
|---------|--------|--------------|
| `preprocessor.py` | `is_specific_query` field | +1 |
| `preprocessor.py` | `_SPECIFIC_PATTERNS_RAW` + `_SPECIFIC_RE` | +35 |
| `preprocessor.py` | `_is_specific_query()` función | +6 |
| `preprocessor.py` | Llamada en `preprocess()` + log | +4 |
| `core.py` | Passthrough condicional por tool name | +6 |
| `core.py` | Hint synthesizer para query específica | +6 |
| **TOTAL** | | **~58 líneas** |

---

## Flujo Completo (Después del Cambio)

```
┌─────────────────────────────────────────────────────────────────┐
│ Usuario: "cuánto gana keiko"                                     │
│                                                                   │
│ 1. preprocessor.py                                                │
│    ├─ enrich: "cuánto gana fujimori higuchi keiko (10001088)"    │
│    ├─ _is_specific_query("cuánto gana keiko") → True, "cuánto.*gana" │
│    └─ IntentResult(is_specific_query=True)                        │
│                                                                   │
│ 2. router → buscar_candidato_por_dni(nombre="keiko")              │
│                                                                   │
│ 3. MCP → retorna {_resumen_markdown: "**Keiko**...", ...}         │
│                                                                   │
│ 4. core.py passthrough check:                                     │
│    ├─ _has_preformatted_content? → True                           │
│    ├─ is_profile_tool? → True (buscar_candidato_por_dni)          │
│    ├─ intent.is_specific_query? → True                            │
│    └─ → SKIP passthrough, fall to synthesis                       │
│                                                                   │
│ 5. synthesizer (gemini-2.0-flash):                                │
│    ├─ SYNTHESIZER_INSTRUCTION + hint "responde SOLO lo preguntado"│
│    ├─ enriched_message: "cuánto gana keiko"                       │
│    ├─ tool_results: perfil completo                               │
│    └─ → "Según la DJHV, Keiko Fujimori declara patrimonio de..." │
│                                                                   │
│ Latencia: ~3-4s (vs 1s passthrough pero RESPUESTA CORRECTA)      │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ Usuario: "info de keiko"                                          │
│                                                                   │
│ 1. preprocessor.py                                                │
│    ├─ _is_specific_query("info de keiko") → False, None           │
│    └─ IntentResult(is_specific_query=False)                       │
│                                                                   │
│ 2-3. router → MCP → {_resumen_markdown: "**Keiko**...", ...}      │
│                                                                   │
│ 4. core.py passthrough check:                                     │
│    ├─ is_profile_tool? → True                                     │
│    ├─ intent.is_specific_query? → False                           │
│    └─ → PASSTHROUGH ✅                                            │
│                                                                   │
│ 5. _build_passthrough_reply → perfil completo                     │
│                                                                   │
│ Latencia: ~1s (passthrough rápido, respuesta correcta)            │
└─────────────────────────────────────────────────────────────────┘
```

---

## Verificación

```bash
# 0. Checkout dev
cd infovoto-gateway && git checkout dev

# 1. Implementar cambios en preprocessor.py y core.py

# 2. Rebuild local
cd infovoto-infra && docker compose up gateway -d --build

# 3. Test genérica → passthrough (~1s)
curl -s -X POST localhost:2080/api/chat \
  -H "Content-Type: application/json" \
  -d '{"message":"info de keiko","user_id":"test"}' | jq -r .reply | head -10
# Esperar: perfil completo

# 4. Test específica → synthesis (~3-5s)
curl -s -X POST localhost:2080/api/chat \
  -H "Content-Type: application/json" \
  -d '{"message":"cuánto gana acuña","user_id":"test"}' | jq -r .reply
# Esperar: SOLO patrimonio

# 5. Test "está en la cima" → synthesis
curl -s -X POST localhost:2080/api/chat \
  -H "Content-Type: application/json" \
  -d '{"message":"acuña está en la cima?","user_id":"test"}' | jq -r .reply
# Esperar: respuesta sobre encuestas/ranking, NO perfil completo

# 6. Test antecedentes → siempre passthrough
curl -s -X POST localhost:2080/api/chat \
  -H "Content-Type: application/json" \
  -d '{"message":"antecedentes de keiko","user_id":"test"}' | jq -r .reply | head -10
# Esperar: lista completa de antecedentes

# 7. Test lista → siempre passthrough
curl -s -X POST localhost:2080/api/chat \
  -H "Content-Type: application/json" \
  -d '{"message":"candidatos presidenciales","user_id":"test"}' | jq -r .reply | head -10
# Esperar: lista de candidatos

# 8. Verificar logs
docker compose logs gateway --tail=30 | grep -E "PASSTHROUGH|SYNTHESIS|specific_query"

# 9. Deploy dev Cloud Run
gcloud builds submit --config=cloudbuild-dev.yaml --project=proyectosia-423918
```

---

## Aprobación Final por Roles

| Rol | Veredicto | Comentario |
|-----|-----------|------------|
| Peruano de a pie | ✅ Aprobado | "Por fin me va a entender" |
| Stakeholder | ✅ Aprobado | "Tradeoff costo/UX correcto" |
| Delivery Lead | ✅ Aprobado | "~58 líneas, 2 archivos, testeable, reversible" |
| Tech Lead | ✅ Aprobado | "Arquitectura limpia, sin over-engineering" |
| Senior MLE | ✅ Aprobado | "Regex compilado, logging, hint dinámico" |
| Junior MLE | ✅ Aprobado | "Tests claros en 3 niveles" |
| Codeforces GM | ✅ Aprobado | "Clasificador binario O(n) con n pequeño, solución óptima" |

### Consenso: **APROBADO POR UNANIMIDAD (7/7)**

**Implementar en branch `dev`. Deploy a dev primero. Verificar. Luego prod.**

---

*Fin de los debates. 15 ciclos, 7+ roles, consenso global alcanzado. El passthrough inteligente distingue preguntas genéricas (rápidas) de específicas (precisas).*
