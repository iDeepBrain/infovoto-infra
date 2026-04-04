# Debate 12 -- Regex Patterns y Edge Cases

> **Fecha:** 2 de abril 2026
> **Entrada:** Debate 11 — consenso: passthrough condicional con `is_specific_query` detectado por regex
> **Pregunta central:** ¿Qué patterns cubren el 80% de preguntas específicas? ¿Qué edge cases pueden fallar?

---

## Ciclo 1 -- Codeforces Grandmaster

El problema es de **clasificación binaria**: dado un string (pregunta del usuario), clasificar en {genérica, específica}. Regex es un clasificador basado en reglas — tiene alta precisión pero bajo recall (patrones no vistos se escapan).

**Análisis de falsos positivos y negativos:**

| Tipo | Ejemplo | Resultado regex | Resultado correcto | Impacto |
|------|---------|----------------|-------------------|---------|
| True Positive | "cuánto gana keiko" | específica | específica | Synthesis correcta |
| True Negative | "info de keiko" | genérica | genérica | Passthrough correcto |
| **False Positive** | "antecedentes de keiko" | específica (match `antecedentes`) | genérica (quiere todo) | Synthesis innecesaria, +3s |
| **False Negative** | "keiko tiene plata?" | genérica (no match) | específica (pregunta patrimonio) | Passthrough incorrecto |

**El false positive de "antecedentes"** es problemático. "antecedentes de keiko" dispara `verificar_antecedentes`, que tiene su propio `_resumen_markdown`. Si lo marcamos como específico, iría al synthesizer innecesariamente.

**Solución:** `antecedentes` NO debe estar en `_SPECIFIC_PATTERNS`. La excepción en core.py ya lo maneja: solo perfil tools son condicionales, `verificar_antecedentes` siempre hace passthrough.

**El false negative** ("tiene plata?") es aceptable. El costo es mostrar el perfil completo — no es un error grave, solo no es óptimo. Podemos agregar patterns iterativamente.

### Veredicto: Quitar `antecedentes` de los patterns. Aceptar false negatives como degradación graceful.

---

## Ciclo 2 -- Junior MLE

Intenté categorizar las preguntas reales que un peruano haría sobre un candidato:

**Categoría PATRIMONIO (debería ser específica):**
- "cuánto gana acuña" ✅ match `cuánto.*gana`
- "patrimonio de keiko" ✅ match `patrimonio`
- "keiko tiene plata?" ❌ no match
- "cuánto tiene acuña" ❌ no match (falta "gana")
- "bienes de keiko" ✅ match `bienes`
- "acuña es millonario?" ❌ no match

**Categoría EDUCACIÓN (debería ser específica):**
- "dónde estudió keiko" ✅ match `dónde estudi[oó]`
- "qué estudió acuña" ❌ no match (sin "dónde")
- "educación de keiko" ✅ match `educación`
- "keiko fue a la universidad?" ❌ no match

**Categoría LEGAL (debería ser específica):**
- "sentencias de keiko" ✅ match `sentencias`
- "keiko tiene juicios?" ❌ no match
- "está presa keiko?" ❌ no match
- "keiko es corrupta?" ❌ no match

**Categoría POSICIONES (debería ser específica):**
- "qué piensa keiko del aborto" ✅ match `aborto`
- "postura de acuña sobre educación" ✅ match `postura`
- "keiko está a favor de la pena de muerte" ✅ match `pena de muerte`

**Estimación de cobertura:** Con los patterns propuestos, cubrimos ~60% de preguntas específicas. El otro 40% son variaciones coloquiales que no matchean.

### Veredicto: Agregar más patterns coloquiales. Pero no obsesionarse — false negatives solo dan perfil completo, no error.

---

## Ciclo 3 -- Senior MLE

El Junior tiene razón en que la cobertura es ~60%. Puedo mejorarla sin explotar la lista de patterns:

**Patterns expandidos por categoría:**

```python
_SPECIFIC_PATTERNS = [
    # ── Patrimonio / dinero ──
    r"\bcuánto\b.*\b(?:gana|tiene|cobra)\b",
    r"\bpatrimonio\b",
    r"\bsueldo\b",
    r"\bingresos?\b",
    r"\binmuebles?\b",
    r"\bbienes?\b",
    r"\bmillonari[oa]\b",
    r"\bplata\b",                          # coloquial peruano
    r"\bdinero\b",
    r"\bricos?\b",                         # "es rico?"

    # ── Educación ──
    r"\b(?:dónde|qué)\s+estudi[oó]\b",    # "dónde estudió" Y "qué estudió"
    r"\beducaci[oó]n\b",
    r"\bformaci[oó]n\b",
    r"\buniversidad\b",
    r"\bprofesi[oó]n\b",

    # ── Experiencia laboral ──
    r"\bexperiencia\b",
    r"\btrabaj[oó]\b",
    r"\bcargos?\b.*\btuvo\b",

    # ── Legal / judicial ──
    r"\bsentencias?\b",
    r"\bjuicios?\b",
    r"\bpres[oa]\b",                       # "está preso?"
    r"\bcorrupt[oa]?\b",
    r"\bprocesos?\s+(?:judiciales?|penales?)\b",
    r"\binvestigad[oa]\b",

    # ── Rankings / encuestas ──
    r"\brankings?\b",
    r"\bencuestas?\b",
    r"\bestá en la cima\b",
    r"\bprimero\b.*\bencuesta\b",
    r"\bva ganando\b",

    # ── Posiciones políticas ──
    r"\bpostura\b",
    r"\bposici[oó]n\b",
    r"\baborto\b",
    r"\bpena de muerte\b",
    r"\bminería\b",
    r"\bqué piensa\b.*\bsobre\b",
    r"\ba favor\b",
    r"\ben contra\b",

    # ── Partido ──
    r"\bqué partido\b",
    r"\bde qué partido\b",
]
```

**Cobertura estimada:** ~75-80% de preguntas específicas.

**Compilación:** Usar `re.compile` con `re.IGNORECASE` una sola vez al importar el módulo, no en cada request:

```python
_SPECIFIC_RE = [re.compile(p, re.IGNORECASE) for p in _SPECIFIC_PATTERNS]

def _is_specific_query(text: str) -> bool:
    return any(r.search(text) for r in _SPECIFIC_RE)
```

Esto es O(n) con n=~35 patterns, cada uno O(m) con m=longitud del texto. Para textos cortos (<200 chars) es <0.1ms. Irrelevante vs los 3-5s del LLM.

### Veredicto: Patterns expandidos + compilados. Cobertura ~80%. Performance irrelevante.

---

## Ciclo 4 -- Peruano de a Pie

Veo los patterns y están bien, pero falta jerga peruana:

- "keiko tiene roche?" → debería detectar como legal/antecedentes
- "acuña es choro?" → debería detectar como legal
- "tiene antecedentes policialesss" → typos comunes

Pero... honestamente, si le pregunto "tiene roche" al chatbot y me da su perfil completo, no está MAL. Solo no está perfecto. No me voy a molestar por eso.

Lo que SÍ me molesta es cuando pregunto algo CLARO como "cuánto gana" y me da todo el perfil. Eso sí se siente como que no me escuchan.

### Veredicto: No agregar jerga. Los patterns actuales cubren lo que realmente molesta al usuario.

---

## Ciclo 5 -- Tech Lead (revisión final)

Revisando los patterns expandidos del Senior MLE, tengo una preocupación:

**Pattern peligroso:** `r"\bcargos?\b.*\btuvo\b"` — "cargos" también aparece en "qué cargo postula". El `.*\btuvo\b` lo acota, pero si alguien escribe "qué cargos tiene" (presente, no pasado), no matchea.

**Pattern demasiado amplio:** `r"\bricos?\b"` — "costa rica" matchearía. Solución: `r"\bes\s+ric[oa]\b"` (solo "es rico/a").

**Recomendación:** Empezar con la lista CONSERVADORA (la del Debate 11, ~20 patterns). Monitorear con logs qué preguntas caen a synthesis vs passthrough. Expandir patterns basándose en datos reales, no en especulación.

```python
# V1 — conservadora, para deploy inicial
_SPECIFIC_PATTERNS = [
    # Patrimonio
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
    # Rankings
    r"\brankings?\b",
    r"\bencuestas?\b",
    r"\bva ganando\b",
    # Posiciones
    r"\bpostura\b",
    r"\bposici[oó]n\b",
    r"\bqué piensa\b.*\bsobre\b",
    r"\ba favor\b",
    r"\ben contra\b",
    # Temas específicos (si mencionan un tema concreto, es específica)
    r"\baborto\b",
    r"\bpena de muerte\b",
    r"\bminería\b",
    r"\bseguridad\b",
    r"\bsalud\b",
]
```

**Logging:** Agregar log line cuando `is_specific_query=True` con el pattern que matcheó:

```python
def _is_specific_query(text: str) -> tuple[bool, str | None]:
    for r in _SPECIFIC_RE:
        if r.search(text):
            return True, r.pattern
    return False, None
```

Esto permite ver en logs de Cloud Run qué patterns se activan y cuáles faltan.

### Veredicto: Lista conservadora V1 (~30 patterns). Logging del pattern matcheado. Iterar con datos reales.

---

## Consenso del Debate 12

| Decisión | Detalle |
|----------|---------|
| Quitar `antecedentes` de patterns | Ya se maneja por excepción en core.py |
| Lista conservadora V1 | ~30 patterns, no jerga, no patterns ambiguos |
| Compilar regex al importar | `re.compile` una vez, no por request |
| Logging del pattern | Saber qué activó `is_specific_query` |
| False negatives aceptables | Solo dan perfil completo, no error |
| False positives minimizados | Evitar patterns ambiguos como `rico`, `cargos` |

**Entrada para Debate 13:** ¿Cómo afecta esto al synthesizer? Cuando `is_specific_query=True` y cae al LLM, ¿el synthesizer sabe qué parte responder? ¿Necesita instrucciones adicionales?
