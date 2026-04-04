# Debate 14 -- Testing, Logging y Plan de Deploy

> **Fecha:** 2 de abril 2026
> **Entrada:** Debates 11-13 — solución definida: `is_specific_query` + passthrough condicional + hint synthesizer
> **Pregunta central:** ¿Cómo validamos que funciona? ¿Qué observabilidad necesitamos? ¿Cómo deployamos en dev primero?

---

## Ciclo 1 -- Junior MLE

Necesito un plan de testing claro. Propongo 3 niveles:

**Nivel 1 — Unit tests (sin servicios):**
```python
# test_preprocessor.py
def test_specific_query_patrimonio():
    result = preprocess("cuánto gana keiko", history=[])
    assert result.is_specific_query is True

def test_generic_query_info():
    result = preprocess("info de keiko", history=[])
    assert result.is_specific_query is False

def test_specific_query_educacion():
    result = preprocess("dónde estudió acuña", history=[])
    assert result.is_specific_query is True

def test_solo_nombre_es_generico():
    result = preprocess("keiko", history=[])
    assert result.is_specific_query is False

def test_antecedentes_no_es_especifico():
    # "antecedentes" no está en _SPECIFIC_PATTERNS
    # Se maneja por excepción en core.py
    result = preprocess("antecedentes de keiko", history=[])
    # Puede ser True o False, no importa — core.py lo maneja por tool name
```

**Nivel 2 — Integration (docker compose up):**
```bash
# Pregunta genérica → passthrough (log dice [PASSTHROUGH])
curl -X POST localhost:2080/api/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "info de keiko", "user_id": "test"}'
# Verificar: respuesta en <2s, log tiene [PASSTHROUGH]

# Pregunta específica → synthesis (log dice [SYNTHESIS])
curl -X POST localhost:2080/api/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "cuánto gana keiko", "user_id": "test"}'
# Verificar: respuesta solo de patrimonio, log tiene [SYNTHESIS]
```

**Nivel 3 — E2E en dev Cloud Run:**
Las mismas queries contra el servicio en Cloud Run dev. Verificar en Cloud Logging.

### Veredicto: 3 niveles de testing. Unit → Integration → E2E.

---

## Ciclo 2 -- Tech Lead

Los tests del Junior son buenos pero le falta lo más importante: **observabilidad**. Necesitamos saber EN PRODUCCIÓN qué decisión tomó el sistema y por qué.

**Logs requeridos:**

```python
# En preprocessor.py, cuando se detecta specific query:
logger.info(
    "[PREPROCESS] is_specific_query=%s pattern=%s msg='%s'",
    is_specific, matched_pattern, stripped[:80]
)

# En core.py, decisión passthrough vs synthesis:
logger.info(
    "[PIPELINE] tool=%s is_profile=%s is_specific=%s → %s",
    name, is_profile_tool, intent.is_specific_query,
    "SYNTHESIS" if (is_profile_tool and intent.is_specific_query) else "PASSTHROUGH"
)
```

**Por qué importa:** Si en producción vemos que "cuánto gana acuña" sigue haciendo passthrough, el log nos dice exactamente dónde falló la detección. Sin estos logs, debuggear en Cloud Run es imposible.

**Structured logging:** Estos logs ya siguen el pattern del gateway (`[COMPONENT] key=value`). Cloud Logging los indexa automáticamente.

### Veredicto: Agregar 2 log lines. Sin ellos, no deployamos.

---

## Ciclo 3 -- Delivery Lead

Ok, tenemos la solución y el testing. Plan de deploy:

**Prerrequisito:** Todo en branch `dev`. El usuario pidió explícitamente NO usar main.

**Paso 1 — Gateway en dev:**
```bash
cd infovoto-gateway
git checkout dev
# ... hacer cambios en preprocessor.py y core.py ...
git add -A && git commit -m "feat: passthrough condicional por intent específico"
git push origin dev
```

**Paso 2 — Build local:**
```bash
cd infovoto-infra
docker compose up gateway -d --build
```

**Paso 3 — Test local:**
```bash
# Test genérica
curl -s -X POST localhost:2080/api/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "info de keiko", "user_id": "test"}' | jq .reply | head -5
# Esperar: perfil completo

# Test específica
curl -s -X POST localhost:2080/api/chat \
  -H "Content-Type: application/json" \
  -d '{"message": "cuánto gana acuña", "user_id": "test"}' | jq .reply
# Esperar: solo patrimonio

# Verificar logs
docker compose logs gateway --tail=20 | grep -E "PASSTHROUGH|SYNTHESIS|is_specific"
```

**Paso 4 — Deploy dev Cloud Run:**
```bash
cd infovoto-gateway
gcloud builds submit --config=cloudbuild-dev.yaml --project=proyectosia-423918
```

**Paso 5 — Verificar en dev:**
Mismos curls pero contra la URL de dev Cloud Run. Verificar en Cloud Logging.

**NO deployar en prod hasta confirmar que dev funciona.**

### Veredicto: dev first, siempre. Verificar logs antes de seguir.

---

## Ciclo 4 -- Stakeholder

Una preocupación de negocio: ¿cuántas queries van a caer en "synthesis" ahora que antes eran passthrough?

**Estimación:**
- ~60% de queries son genéricas ("info de X", "quién es X") → passthrough (sin cambio)
- ~25% son específicas ("cuánto gana X", "dónde estudió X") → synthesis (NUEVO: antes eran passthrough incorrecto)
- ~15% son otras (comparaciones, listas, saludos) → no afectadas

**Impacto en latencia general:**
- Antes: 100% perfiles → passthrough (1s) pero respuesta incorrecta 40% del tiempo
- Después: 60% → passthrough (1s), 40% → synthesis (3-5s) pero respuesta CORRECTA

**Impacto en costos:** Más queries al synthesizer = más tokens Gemini. Con gemini-2.0-flash el costo es bajo (~$0.10/1M tokens input). Para 500 queries/hora el costo adicional es ~$0.02/hora. Irrelevante.

**Lo que gano:** Usuarios satisfechos que sienten que el bot entiende su pregunta. Eso vale infinitamente más que $0.02/hora.

### Veredicto: El tradeoff costo/UX es claro. Proceder.

---

## Ciclo 5 -- Senior MLE (plan de rollback)

Si el cambio genera problemas en producción:

**Rollback inmediato (sin redeploy):**
No aplica — este cambio requiere redeploy para revertir.

**Rollback con redeploy (<5 min):**
```bash
# Opción 1: Revertir a revision anterior de Cloud Run
gcloud run services update-traffic gateway \
  --to-revisions REVISION_ANTERIOR=100 \
  --region us-central1

# Opción 2: Desactivar con cambio mínimo
# En core.py, cambiar la condición para que NUNCA sea específica:
# if is_profile_tool and False:  # DISABLED
```

**Monitoreo post-deploy:**
1. Cloud Run latency metrics — P50 y P95
2. Error rate — debería mantenerse o bajar
3. Logs: ratio PASSTHROUGH vs SYNTHESIS — esperar ~60/40
4. Respuestas: spot-check manual 10 queries variadas

**Criterio de rollback:**
- Error rate > 5% → rollback
- P95 > 15s → rollback
- Respuestas incoherentes en spot-check → rollback

### Veredicto: Rollback plan claro. Cloud Run traffic management es la salida de emergencia.

---

## Consenso del Debate 14

| Decisión | Detalle |
|----------|---------|
| 3 niveles de testing | Unit → Integration → E2E |
| 2 log lines obligatorios | Preprocessor + core pipeline decision |
| Branch dev SIEMPRE | Nunca main directamente |
| Test local antes de Cloud Run | docker compose up → curl → logs |
| Deploy dev antes de prod | Verificar en dev, luego prod |
| Ratio esperado | 60% passthrough, 40% synthesis |
| Costo adicional | ~$0.02/hora, irrelevante |
| Rollback | Cloud Run traffic split, <5 min |

**Entrada para Debate 15:** Síntesis final. ¿Cuál es el plan de implementación definitivo con todos los detalles?
