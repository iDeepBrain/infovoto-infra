# Debate 10 -- Plan de Implementacion Final

> **Fecha:** 2 de abril 2026
> **Contexto:** Elecciones Peru 2026 el **12 de abril** -- quedan **10 dias**.
> **Estado actual:** Gateway y MCP desplegados en Cloud Run. Latencia promedio ~10s para perfiles individuales.
> **Objetivo:** Reducir latencia a <3s para el 80% de queries antes del dia de elecciones.

---

## Resumen de Optimizaciones Acordadas (Debates 1-9)

| # | Optimizacion | Impacto Estimado | Complejidad | Riesgo |
|---|-------------|------------------|-------------|--------|
| 1 | Templates `_resumen_markdown` en MCP perfiles (passthrough) | 10s -> 2s | Media | Bajo |
| 2 | `gemini-2.0-flash` para synthesizer (cuando se necesita LLM) | 10s -> 4s | Baja | Bajo |
| 3 | Cache por `tool+args` en Redis | Queries repetidas <100ms | Media | Bajo |
| 4 | Reduccion de datos MCP (top 5 antecedentes, limitar descripciones) | -30% tokens synth | Baja | Medio |
| 5 | Fast-routes expandidos en preprocessor | Skip router LLM +500ms | Baja | Bajo |
| 6 | Streaming SSE (diferido) | Percepcion de velocidad | Alta | Medio |
| 7 | Pre-computacion de perfiles (36 presidenciales) | Cache hit 100% perfiles | Media | Bajo |

### Archivos a Modificar

| Archivo | Cambio |
|---------|--------|
| `infovoto-mcp/src/mcp/perfiles/server.py` | Agregar `_resumen_markdown` a respuesta de `buscar_candidato_por_dni` |
| `infovoto-gateway/src/gateway/config.py` | Agregar `llm_synth_model` setting |
| `infovoto-gateway/src/agent/core.py` | Detectar `_resumen_markdown` passthrough, usar synth model, cache por tool+args |
| `infovoto-gateway/src/agent/adapters/factory.py` | Crear funcion `create_synth_adapter()` |
| `infovoto-gateway/cloudbuild.yaml` | Agregar `LLM_SYNTH_MODEL` env var |
| `infovoto-mcp/cloudbuild.yaml` | Ya corregido (ENVIRONMENT, DATABASE_URL, memory) |

### Configs Ya Corregidas (Pre-requisitos)

- MCP cloudbuild: `ENVIRONMENT=production`, `DATABASE_URL` secret, `memory=1Gi`
- Gateway cloudbuild: `memory=1Gi`, `min-instances=1`
- MCP `startup.sh`: skip tests en produccion
- Gateway config: `llm_call_max_timeout` 8s -> 15s

---

## Pregunta Central del Debate

> En que orden implementar? Que es MVP para produccion? Que puede esperar? Como testear cada cambio? Cual es el rollback plan?

---

## Ciclo 1 -- Priorizacion por Impacto/Riesgo

### Codeforces Grandmaster

La optimizacion es un problema de **scheduling con dependencias y restricciones de tiempo**. Tenemos 10 dias, un equipo pequeno, y produccion en vivo con usuarios reales.

**Analisis de dependencias:**

```
Opt 2 (synth model)  ---->  independiente
Opt 5 (fast-routes)  ---->  independiente
Opt 1 (templates)    ---->  requiere deploy MCP primero, luego gateway
Opt 3 (cache)        ---->  requiere templates para ser efectivo
Opt 4 (data reduction) -->  independiente pero riesgo de romper synthesizer
Opt 7 (pre-compute)  ---->  requiere templates funcionando
Opt 6 (streaming)    ---->  requiere frontend cambios, diferido
```

**Orden optimo (greedy por impacto/esfuerzo):**

1. Opt 2 + Opt 5 en paralelo (independientes, bajo riesgo, impacto inmediato)
2. Opt 1 (templates en MCP -- el mayor impacto individual)
3. Opt 3 (cache -- multiplica el efecto de templates)
4. Opt 4 (data reduction -- polish)
5. Opt 7 (pre-compute -- nice to have)
6. Opt 6 (streaming -- post-elecciones)

**Complejidad temporal total:** O(dias) = 4-5 dias para Opts 1-5. Margen de 5 dias para testing y hotfixes.

### Veredicto: Aprobado -- El orden greedy es correcto. Paralelizar lo independiente.

---

## Ciclo 2 -- Definicion de MVP

### Senior AI Engineer

**MVP para produccion (dia D-7, 5 de abril):**

Solo necesitamos que el **80% de queries** (perfiles individuales + preguntas frecuentes) respondan en <3s. Eso se logra con:

1. **Opt 2 -- gemini-2.0-flash para synth** (gateway-only, 1 hora de trabajo)
   - Cambio minimo: agregar `llm_synth_model` en config, crear `create_synth_adapter()` en factory
   - El synth no necesita el modelo "pensante" (gemini-2.5-flash) -- solo formatea datos
   - Impacto: 10s -> ~4s para TODOS los queries que pasan por synthesizer

2. **Opt 1 -- Templates _resumen_markdown** (MCP + gateway, 3-4 horas)
   - MCP: `buscar_candidato_por_dni` retorna `_resumen_markdown` con perfil ya formateado
   - Gateway: `core.py` detecta el campo y hace passthrough (skip synthesizer)
   - Impacto: perfiles individuales de 10s -> 2s

3. **Opt 5 -- Fast-routes expandidos** (gateway-only, 1 hora)
   - Agregar patrones: "antecedentes de X", "propuestas de X sobre Y", "formula de X"
   - Skip del router LLM (-500ms en esos patterns)

**Lo que NO es MVP:**
- Cache (Opt 3): mejora queries repetidas, pero el primer query ya seria rapido
- Data reduction (Opt 4): mejora marginal si ya tenemos templates
- Pre-compute (Opt 7): optimizacion prematura si templates funcionan
- Streaming (Opt 6): post-elecciones

### Veredicto: Aprobado -- MVP = Opts 2 + 1 + 5. Tres cambios, maximo impacto.

---

## Ciclo 3 -- Arquitectura del Synth Model (Opt 2)

### Senior MLE

**Implementacion concreta:**

```python
# config.py -- agregar
llm_synth_model: str = "gemini-2.0-flash"  # Mas rapido, sin "thinking"

# factory.py -- agregar
def create_synth_adapter() -> LLMPort:
    """Adapter ligero para synthesizer (gemini-2.0-flash, sin thinking)."""
    api_key = settings.google_api_key or settings.gemini_api_key
    from src.agent.adapters.gemini import GeminiAdapter
    return GeminiAdapter(api_key=api_key, model=settings.llm_synth_model)

# core.py -- en InfoVotoAgent.__init__
from src.agent.adapters.factory import create_synth_adapter
self.synth_llm: LLMPort = create_synth_adapter()

# core.py -- en el loop de synthesis, reemplazar self.llm por self.synth_llm
```

**Por que NO un adapter separado:** `GeminiAdapter` ya es generico. Solo cambia el modelo. No necesitamos una clase nueva -- seria over-engineering.

**Riesgo:** `gemini-2.0-flash` tiene menor calidad de razonamiento que `gemini-2.5-flash`. Pero el synthesizer NO razona -- solo formatea datos de MCP en lenguaje natural. La calidad es suficiente.

**Rollback:** Si la calidad del synthesizer baja, cambiar `LLM_SYNTH_MODEL=gemini-2.5-flash` en Cloud Run env vars. Sin redeploy de codigo.

### Veredicto: Aprobado -- Adapter reutilizado, config-driven, rollback instantaneo.

---

## Ciclo 4 -- Templates _resumen_markdown (Opt 1)

### Junior MLE

Tengo dudas sobre la implementacion del template. Preguntas criticas:

1. **Quien genera el markdown?** El MCP en `server.py`, no el LLM. Es un template Python con f-strings.
2. **Que pasa si el gateway actual no reconoce `_resumen_markdown`?** Ignora el campo y pasa todo al synthesizer. Es backward-compatible.
3. **Que datos van en el template?** Nombre, partido, cargo, edad, educacion, experiencia, antecedentes (top 5), posiciones politicas (top 5), hechos relevantes (top 3).
4. **Y si falta algun dato?** El template usa condicionales -- si no hay antecedentes, no muestra la seccion.

**Propuesta de template en `perfiles/server.py`:**

```python
def _build_resumen_markdown(candidato: dict) -> str:
    """Genera resumen markdown pre-formateado para passthrough."""
    parts = []
    parts.append(f"**{candidato['nombre_completo']}** - {candidato['partido']}")
    parts.append(f"Cargo: {candidato['cargo']}")
    if candidato.get('edad'):
        parts.append(f"Edad: {candidato['edad']} anos")
    # ... educacion, experiencia, antecedentes top 5, posiciones top 5
    return "\n".join(parts)
```

**Test plan:**
- Unit test: `_build_resumen_markdown` con candidato completo vs incompleto
- Integration test: llamar `buscar_candidato_por_dni(nombre="keiko")` y verificar que retorna `_resumen_markdown`
- E2E: gateway recibe el campo y hace passthrough sin LLM

**Preocupacion:** Los antecedentes tienen dos fuentes (JNE_DJHV y VOTABIEN). El template debe respetar la misma agrupacion que el SYNTHESIZER_INSTRUCTION pide. Si no, el formato sera inconsistente con queries que SI pasen por synthesizer.

### Veredicto: Aprobado con observacion -- El template DEBE seguir las mismas reglas del SYNTHESIZER_INSTRUCTION (agrupar por fuente, mencionar medios).

---

## Ciclo 5 -- Deteccion Passthrough en Gateway

### Junior Full Stack

**Cambio en `core.py` -- metodo `process()`:**

Actualmente el flujo es:
```
mensaje -> preprocessor -> router LLM -> MCP call -> synthesizer LLM -> respuesta
```

Con passthrough:
```
mensaje -> preprocessor -> router LLM -> MCP call -> [detectar _resumen_markdown] -> respuesta directa
```

**Implementacion:**

```python
# Despues de recibir tool_results en el loop de rounds:
for tool_name, result in tool_results.items():
    if isinstance(result, dict) and "_resumen_markdown" in result:
        # Passthrough: usar markdown pre-formateado, skip synthesizer
        reply = result["_resumen_markdown"]
        # Extraer sources y candidates como antes
        _extract_source(result, sources)
        _extract_candidates(result, candidates)
        return ProcessResponse(reply=reply, sources=sources, candidates=candidates)
```

**Posicion en el codigo:** Debe ir ANTES del check de `_has_formatted_list` (que ya existe para listas). El patron es el mismo: datos pre-formateados = skip LLM.

**Riesgo:** Si el usuario pregunta algo especifico ("que piensa keiko sobre la pena de muerte"), el MCP retorna todo el perfil con `_resumen_markdown`, pero el usuario no queria todo el perfil. Solucion: `_resumen_markdown` SOLO se incluye cuando el router llama a `buscar_candidato_por_dni` sin filtro especifico. Si hay `tema` en los args, no incluir el campo.

### Veredicto: Aprobado -- Passthrough solo para perfil completo, no para queries filtradas.

---

## Ciclo 6 -- Cache por Tool+Args (Opt 3)

### AI Tech Lead

**Arquitectura del cache:**

El cache actual en `core.py` es por **query normalizada** del usuario. El problema: "cuentame de keiko" y "info keiko" son queries distintas pero llaman al mismo tool con los mismos args.

**Propuesta: cache en DOS niveles:**

1. **Cache L1 (actual):** query normalizada -> respuesta final. TTL 24h.
2. **Cache L2 (nuevo):** `tool_name:args_hash` -> resultado MCP. TTL 24h.

L2 es mas valioso porque:
- Absorbe variaciones de lenguaje ("cuentame de", "info de", "perfil de" -> mismo tool call)
- Funciona para comparaciones parciales (si ya tenemos el perfil de keiko cacheado)
- Es deterministico (mismo tool + args = mismo resultado de DB)

**Implementacion:**

```python
def _cache_key_tool(tool_name: str, args: dict) -> str:
    """Cache key basada en tool + args (deterministico)."""
    args_sorted = json.dumps(args, sort_keys=True, ensure_ascii=False)
    h = hashlib.md5(f"{tool_name}:{args_sorted}".encode()).hexdigest()[:12]
    return f"tcache:{tool_name}:{h}"
```

**Donde va en el flujo:**
- ANTES de llamar al MCP: check L2 cache
- DESPUES de recibir resultado MCP: guardar en L2
- El cache L1 (query -> respuesta) se mantiene como esta

**Riesgo:** Datos de DB cambian (scraper actualiza). TTL de 24h es aceptable para datos electorales que cambian poco. En dia de elecciones, podemos bajar a 1h.

**Veredicto del AI Tech Lead:** Cache L2 por tool+args es la optimizacion correcta. PERO -- no es MVP. El impacto real es para usuarios recurrentes. Para un usuario nuevo que pregunta por primera vez, no ayuda. **Diferir a post-MVP.**

### Veredicto: Aprobado como post-MVP. No bloquea el lanzamiento.

---

## Ciclo 7 -- Fast-Routes Expandidos (Opt 5)

### Full Stack Lead

**Fast-routes actuales en `preprocessor.py`:**

El preprocessor ya tiene `FastRoute` para greetings y algunos patrones. Expandir para:

```python
# Patrones nuevos para fast-route (skip router LLM)
_FAST_PATTERNS = [
    # Perfil individual
    (r"^(?:info|perfil|quien es|datos de)\s+(.+)$",
     lambda m: [{"name": "buscar_candidato_por_dni", "args": {"nombre": m.group(1)}}]),

    # Antecedentes
    (r"^antecedentes?\s+(?:de\s+)?(.+)$",
     lambda m: [{"name": "verificar_antecedentes", "args": {"nombre": m.group(1)}}]),

    # Formula presidencial
    (r"^formula\s+(?:de\s+)?(.+)$",
     lambda m: [{"name": "formula_presidencial", "args": {"nombre": m.group(1)}}]),

    # Candidatos por cargo
    (r"^(?:candidatos?|lista)\s+(?:presidenciales?|al?\s+(?:la\s+)?presidencia)$",
     lambda m: [{"name": "listar_candidatos_region", "args": {"cargo": "presidente"}}]),

    # Dia de elecciones
    (r"^(?:cuando|fecha|dia)\s+(?:son|es|de)\s+(?:las?\s+)?elecciones?",
     lambda m: [{"name": "info_dia_elecciones", "args": {}}]),
]
```

**Impacto:** -500ms por query que matchea. Con 36 candidatos presidenciales, los patrones de perfil individual cubren ~40% del trafico esperado.

**Riesgo:** Falsos positivos. "info electoral" matchearia con "info (nombre)" y buscaria un candidato llamado "electoral". Solucion: los fast-routes son **sugerencias** -- si el MCP no encuentra el candidato, el error se maneja normalmente.

**Preocupacion:** Los fast-routes NO deben duplicar la logica del router. Si un pattern es ambiguo, dejarlo para el LLM. Solo patterns con >95% de certeza.

### Veredicto: Aprobado -- Solo patterns inequivocos. Ante duda, dejar al router LLM.

---

## Ciclo 8 -- Testing Strategy y Deploy Order

### Delivery Lead

**Perspectiva de usuario:** Un peruano promedio va a preguntar "quien es keiko" o "antecedentes de acuna" el dia de las elecciones. Si tarda >5s, cierra la app. Si tarda <3s, se queda y pregunta mas. La retencion depende de la primera impresion.

**Plan de testing por optimizacion:**

| Opt | Test Local | Test Staging | Criterio de Exito |
|-----|-----------|-------------|-------------------|
| 2 (synth model) | Unit: synth adapter crea correctamente | Smoke: `/api/chat` con query compleja | Respuesta coherente en <5s |
| 1 (templates) | Unit: `_build_resumen_markdown` formato correcto | E2E: "info keiko" retorna perfil en <2.5s | Passthrough sin LLM, formato legible |
| 5 (fast-routes) | Unit: patterns matchean correctamente | Smoke: patterns comunes skip router | Latencia -500ms en matched queries |
| 3 (cache) | Unit: cache key deterministica | E2E: segunda query identica <100ms | Hit rate >50% en queries repetidas |

**Deploy order (dev primero, luego prod):**

```
Dia 1 (2 abril):
  - Implementar Opt 2 (synth model) en gateway
  - Implementar Opt 5 (fast-routes) en gateway
  - Deploy gateway dev -> test

Dia 2 (3 abril):
  - Implementar Opt 1 (templates) en MCP
  - Deploy MCP dev -> test
  - Implementar passthrough en gateway
  - Deploy gateway dev -> test E2E

Dia 3 (4 abril):
  - Deploy MCP prod
  - Deploy gateway prod
  - Smoke test produccion (5 queries criticas)

Dia 4-5 (5-6 abril):
  - Monitorear latencia en prod (Cloud Run metrics)
  - Implementar Opt 3 (cache) si hay tiempo
  - Hotfixes si algo falla

Dia 6-10 (7-12 abril):
  - Monitoring intensivo
  - Cache warm-up con los 36 candidatos presidenciales
  - Dia 12: dia D, zero-deploy, solo monitoring
```

**Criterio de go/no-go para produccion:**
- P50 latencia < 4s
- P95 latencia < 8s
- Zero errores 500 en smoke test
- Todas las fuentes (JNE, VotaBien) se muestran correctamente

### Veredicto: Aprobado -- Timeline agresivo pero realista. El buffer de 5 dias post-deploy es critico.

---

## Ciclo 9 -- Rollback Plan

### Staff Engineer

**Principio:** Cada cambio debe poder revertirse en <5 minutos sin downtime.

### Rollback por Optimizacion

**Opt 2 -- Synth Model:**
```bash
# Rollback: cambiar env var en Cloud Run (sin redeploy de codigo)
gcloud run services update gateway \
  --set-env-vars LLM_SYNTH_MODEL=gemini-2.5-flash \
  --region us-central1
# Tiempo: ~60s (nueva revision Cloud Run)
```
**Riesgo de rollback:** Ninguno. Vuelve al modelo original.

**Opt 1 -- Templates Passthrough:**
```bash
# Rollback nivel 1: gateway ignora _resumen_markdown
# El campo existe en MCP response pero gateway no lo usa
# Simplemente remover el check en core.py y redeploy gateway

# Rollback nivel 2: MCP deja de enviar _resumen_markdown
# Redeploy MCP sin el cambio en server.py
```
**Riesgo de rollback:** Bajo. El campo `_resumen_markdown` es aditivo -- no rompe nada si se ignora.

**Opt 5 -- Fast Routes:**
```bash
# Rollback: vaciar _FAST_PATTERNS en preprocessor.py y redeploy
# O: feature flag FAST_ROUTES_ENABLED=false
```
**Riesgo de rollback:** Ninguno. Los queries vuelven al router LLM.

**Opt 3 -- Cache L2:**
```bash
# Rollback: CACHE_TOOL_TTL_SECONDS=0 en env vars
# O: redis-cli FLUSHDB (nuclear, borra todo el cache)
```
**Riesgo de rollback:** Bajo. Sin cache, vuelve a latencia pre-optimizacion.

### Estrategia General de Rollback

1. **Cloud Run revisions:** Cada deploy crea una nueva revision. Rollback = dirigir trafico a revision anterior.
   ```bash
   gcloud run services update-traffic gateway \
     --to-revisions REVISION_ANTERIOR=100 \
     --region us-central1
   ```

2. **Orden de rollback:** Si algo falla en produccion:
   - Paso 1: Verificar que el error es del cambio nuevo (no preexistente)
   - Paso 2: Rollback la revision de Cloud Run (1 minuto)
   - Paso 3: Diagnosticar con logs (`gcloud logging read`)
   - Paso 4: Fix forward o revert commit

3. **Canary deploy:** Cloud Run soporta traffic splitting. Para cambios riesgosos:
   ```bash
   gcloud run services update-traffic gateway \
     --to-revisions NEW=10,OLD=90 \
     --region us-central1
   ```

### Veredicto: Aprobado -- Cada cambio es reversible en <2 minutos via Cloud Run traffic management.

---

## Ciclo 10 -- Riesgos Globales y Decision Final

### Product Manager

**Riesgos que me preocupan:**

| Riesgo | Probabilidad | Impacto | Mitigacion |
|--------|-------------|---------|-----------|
| Template mal formateado para algun candidato | Media | Medio | Test con los 36 presidenciales antes de deploy |
| `gemini-2.0-flash` genera respuestas de menor calidad | Baja | Alto | A/B test manual: 10 queries con 2.0-flash vs 2.5-flash |
| Fast-route matchea incorrectamente | Baja | Bajo | Solo patterns inequivocos, fallback a router |
| MCP deploy falla (DATABASE_URL, memoria) | Baja | Alto | Ya corregido en cloudbuild, tested |
| Pico de trafico dia de elecciones satura Cloud Run | Media | Alto | `min-instances=1`, `max-instances=5`, cache activo |
| Redis (Upstash) tiene latencia alta cross-region | Media | Medio | Circuit breaker ya implementado, TTL generoso |
| Cambio rompe formato de `_candidate` o `_fuente` | Baja | Medio | E2E test verifica campos metadata |

**Metricas de exito (dia de elecciones):**

| Metrica | Target | Actual | Estado |
|---------|--------|--------|--------|
| P50 latencia | <3s | ~10s | Pendiente optimizaciones |
| P95 latencia | <8s | ~15s | Pendiente optimizaciones |
| Error rate | <1% | ~2% (timeouts) | Mejora con latencia |
| Queries/hora pico | 500+ | No probado | Stress test pendiente |

**Decision de negocio:** El chatbot es una herramienta informativa para las elecciones del 12 de abril. Si no funciona bien ese dia, pierde todo su valor. Es mejor lanzar con 3 optimizaciones solidas que con 7 a medio terminar.

### Veredicto: Aprobado -- MVP de 3 optimizaciones (Opt 2, 1, 5) es la decision correcta.

---

## Timeline Gantt

```
Abril 2026
         Lun 31  Mar 1  Mie 2  Jue 3  Vie 4  Sab 5  Dom 6  Lun 7  ... Sab 12
         ------  -----  -----  -----  -----  -----  -----  -----      ------

Opt 2    ................[████]                                        synth model
(gateway)               Impl   Test                                   (1h impl)

Opt 5    ................[████]                                        fast-routes
(gateway)               Impl   Test                                   (1h impl)

Gateway  ........................[DEPLOY DEV]                          deploy dev
deploy                         Mie 2 PM                               con Opt 2+5

Opt 1    ................[████████████]                                templates
(MCP)                   Impl   Impl   Test                            (3h impl)

MCP      ..............................[DEPLOY DEV][DEPLOY PROD]       deploy
deploy                                Jue 3       Vie 4

Gateway  ......................................[IMPL PASSTHROUGH]      passthrough
Opt 1                                              Vie 4              en core.py

Gateway  ............................................[DEPLOY PROD]     deploy prod
prod                                                Sab 5

Opt 3    ................................................[████████]    cache L2
(post-MVP)                                          Sab 5  Dom 6     (si hay tiempo)

Monitoring............................................................[24/7]
                                                    Lun 7 ---> Sab 12

DIA D    .............................................................[████]
                                                                      Sab 12
                                                                      ELECCIONES
```

**Hitos criticos:**
- **2 abril PM:** Gateway dev con Opt 2 + 5 deployed
- **3 abril PM:** MCP dev con templates deployed, E2E test passthrough
- **4 abril:** MCP prod deployed
- **5 abril:** Gateway prod deployed con todas las optimizaciones MVP
- **7-11 abril:** Monitoring, cache warm-up, hotfixes
- **12 abril:** Dia de elecciones -- zero deploys, solo monitoring

---

## Risk Assessment Matrix

```
                        IMPACTO
                 Bajo        Medio       Alto
            +----------+----------+----------+
    Alta    |          | Redis    | Pico     |
            |          | latencia | trafico  |
P   --------+----------+----------+----------+
R   Media   | Fast-    | Template | Gemini   |
O           | route FP | formato  | 2.0 baja |
B   --------+----------+----------+----------+
    Baja    |          | Metadata | MCP      |
            |          | roto     | deploy   |
            +----------+----------+----------+
```

**Zona roja (alta prob + alto impacto):** Pico de trafico dia de elecciones.
- Mitigacion: `min-instances=1`, cache agresivo, pre-warm con 36 perfiles.

**Zona amarilla:** Redis latencia, template formato.
- Mitigacion: circuit breaker, tests exhaustivos con todos los candidatos.

---

## VEREDICTO FINAL

### Aprobado por unanimidad (10/10 roles)

### Action Items Priorizados

**P0 -- Critico (dia 2-5 abril):**

1. **Opt 2: Synth Model** -- Gateway only
   - [ ] Agregar `llm_synth_model: str = "gemini-2.0-flash"` en `config.py`
   - [ ] Agregar `create_synth_adapter()` en `factory.py`
   - [ ] Usar `self.synth_llm` en lugar de `self.llm` para synthesis en `core.py`
   - [ ] Agregar `LLM_SYNTH_MODEL=gemini-2.0-flash` en `cloudbuild.yaml`
   - [ ] Test: 10 queries manuales comparando calidad

2. **Opt 5: Fast-Routes** -- Gateway only
   - [ ] Expandir `_FAST_PATTERNS` en `preprocessor.py`
   - [ ] Solo patterns con >95% certeza
   - [ ] Test: unit tests para cada pattern

3. **Opt 1: Templates MCP** -- MCP + Gateway
   - [ ] Implementar `_build_resumen_markdown()` en `perfiles/server.py`
   - [ ] Incluir solo en `buscar_candidato_por_dni` sin filtro de tema
   - [ ] Respetar formato del SYNTHESIZER_INSTRUCTION (fuentes agrupadas)
   - [ ] Test: unit test con los 36 candidatos presidenciales
   - [ ] Implementar deteccion passthrough en `core.py`
   - [ ] Test E2E: "info keiko" retorna en <2.5s sin LLM synthesis

**P1 -- Importante (dia 5-7 abril):**

4. **Opt 3: Cache L2 por tool+args** -- Gateway only
   - [ ] Implementar `_cache_key_tool()` en `core.py`
   - [ ] Cache ANTES de MCP call, guardar DESPUES
   - [ ] TTL: 24h default, configurable via env var
   - [ ] Test: segunda query identica <100ms

**P2 -- Nice to Have (post-elecciones):**

5. **Opt 4: Data Reduction** -- Diferido (templates ya resuelven)
6. **Opt 7: Pre-compute** -- Diferido (cache L2 cubre el caso)
7. **Opt 6: Streaming SSE** -- Diferido (requiere cambios frontend)

### Deploy Checklist

```
[ ] Gateway dev: Opt 2 + 5 deployed y testeado
[ ] MCP dev: Opt 1 templates deployed y testeado
[ ] E2E test: passthrough funciona dev-to-dev
[ ] MCP prod: deploy con templates
[ ] Gateway prod: deploy con synth model + fast-routes + passthrough
[ ] Smoke test prod: 5 queries criticas < 3s
[ ] Latencia P50 < 4s confirmada en Cloud Run metrics
[ ] Los 36 candidatos presidenciales renderizan correctamente
[ ] Rollback plan verificado (traffic split test)
```

### Regla de Oro

> Si algo falla el dia 12, rollback via Cloud Run traffic management en <2 minutos. Nunca hacer deploy el dia de las elecciones.

---

*Debate finalizado. 10 ciclos, 10 roles, consenso unanime. MVP = 3 optimizaciones que llevan el P50 de 10s a <3s.*
