# Debate 19 -- Metricas de Calidad de Respuesta

> **Fecha:** 2 de abril 2026
> **Contexto:** Elecciones Peru 2026 el **12 de abril** -- quedan **10 dias**.
> **Estado actual:** Pipeline optimizado (passthrough + synthesis dual-mode), latencia reducida. Ahora necesitamos medir si las respuestas son buenas.
> **Feedback del usuario:** "No quiero la misma respuesta cada rato, que me entienda lo que estoy preguntando."
> **Objetivo:** Definir metricas, metodos de evaluacion e infraestructura de logging para medir calidad de respuesta de forma continua.

---

## Metricas Propuestas

| Metrica | Tipo | Descripcion | Rango |
|---------|------|-------------|-------|
| Relevance | Calidad | La respuesta contesta lo que se pregunto | 0-5 |
| Completeness | Calidad | Incluye toda la informacion solicitada | 0-5 |
| Conciseness | Calidad | Apropiadamente scoped, no sobrecarga | 0-5 |
| Latency | Performance | Tiempo de respuesta total (ms) | 0-inf |
| Cache Hit Rate | Eficiencia | % de queries resueltas desde cache | 0-100% |
| Follow-up Rate | Proxy UX | % de sesiones donde el usuario hace otra pregunta | 0-100% |
| Session Length | Proxy UX | Numero de mensajes por sesion | 1-inf |
| Abandonment Rate | Proxy UX | % de sesiones con 1 solo mensaje (posible insatisfaccion) | 0-100% |

## Metodos de Evaluacion Propuestos

1. **A/B testing** -- passthrough vs synthesis para mismas queries
2. **Logging estructurado** -- query_type + response_type + latency + tokens
3. **Evaluation set manual** -- 20 preguntas con respuestas esperadas
4. **LLM-as-judge** -- Un segundo LLM evalua la respuesta del primero

---

## Pregunta Central del Debate

> Como implementar un sistema de metricas de calidad que sea (a) barato, (b) automatizable, (c) accionable antes del 12 de abril, y (d) que capture la queja del usuario de "no me entiende"?

---

## Ciclo 1 -- Definicion del Problema y Prioridades

### Senior MLE #1 (Infraestructura de Logging)

El primer paso no es LLM-as-judge ni nada sofisticado. El primer paso es **tener datos**.

Hoy no loggeamos nada estructurado. El gateway tiene `logger.info()` generico pero no tenemos:

```
- query_text (sanitizado, sin PII)
- query_type (perfil, comparacion, lista, saludo, off-topic)
- response_type (passthrough, synthesis, cached, error)
- latency_ms (total, router, mcp, synth)
- tool_called (nombre del MCP tool)
- tool_args (hash de los args, para agrupar queries identicas)
- tokens_in / tokens_out (cuando hay LLM)
- session_id
- message_index_in_session
```

Sin esto, cualquier metrica de calidad es anecdotica. Propongo:

```python
# gateway/src/agent/metrics.py
@dataclass
class ResponseMetrics:
    session_id: str
    message_index: int
    query_text_hash: str        # SHA256, no el texto
    query_type: str             # perfil, comparacion, lista, saludo, off_topic
    response_type: str          # passthrough, synthesis, cached, error, greeting
    tool_called: str | None
    tool_args_hash: str | None
    latency_total_ms: int
    latency_router_ms: int
    latency_mcp_ms: int
    latency_synth_ms: int
    tokens_in: int | None
    tokens_out: int | None
    cache_hit: bool
    timestamp: datetime
```

Y un endpoint `/api/metrics/summary` para ver agregados.

### Senior MLE #2 (Evaluacion Offline)

Logging es necesario pero no suficiente. Necesitamos un **evaluation set** -- una lista de preguntas con respuestas esperadas que podamos correr de forma automatizada.

Propongo 20 queries cubiertas:

| # | Query | Tipo | Respuesta Esperada (criterio) |
|---|-------|------|------------------------------|
| 1 | "Quien es Keiko Fujimori?" | perfil_individual | Nombre, partido, cargo, educacion, experiencia |
| 2 | "Candidatos de Lima" | lista_region | Lista con nombres y partidos de Lima |
| 3 | "Comparame a Lopez Aliaga con Keiko" | comparacion | Tabla o lista comparando ambos |
| 4 | "Que propone Antauro sobre seguridad?" | posicion_tematica | Posiciones de Antauro en seguridad |
| 5 | "Hola" | saludo | Saludo amigable, mencion de que puede hacer |
| 6 | "Quien tiene mas patrimonio?" | ranking | Lista ordenada por patrimonio |
| 7 | "Candidatos con sentencias penales" | filtro_legal | Lista de candidatos con antecedentes |
| 8 | "Que opinas de Keiko?" | off_topic_opinion | Declina dar opinion, ofrece datos |
| 9 | "Dime todo sobre Castillo" | perfil_amplio | Perfil completo con todas las secciones |
| 10 | "Cuantos candidatos hay?" | meta_conteo | Numero total de candidatos |
| 11 | "Hay alguna candidata mujer?" | filtro_genero | Lista de candidatas mujeres |
| 12 | "Quien estudio en el extranjero?" | filtro_educacion | Candidatos con educacion internacional |
| 13 | "Como esta el clima?" | off_topic | Redirige al tema electoral |
| 14 | "Keiko vs Keiko" | edge_case | Maneja comparacion consigo misma |
| 15 | "Candidatos de Tacna para congreso" | lista_region_cargo | Lista filtrada por region y cargo |
| 16 | "Que partidos hay?" | meta_partidos | Lista de partidos registrados |
| 17 | "Lopez Aliaga patrimonio" | perfil_seccion | Seccion especifica de patrimonio |
| 18 | "Resumen rapido de Bermejo" | perfil_corto | Resumen breve, no perfil completo |
| 19 | "Explica las elecciones" | contexto_general | Informacion sobre el proceso electoral |
| 20 | "DNI 12345678" | busqueda_dni | Busqueda directa por DNI |

Cada query tiene criterios de evaluacion medibles:
- **Relevance**: Responde lo que se pregunto? (0-5)
- **Completeness**: Incluye todos los campos esperados? (0-5)
- **Conciseness**: No incluye informacion no solicitada? (0-5)

### Grandmaster Codeforces #1 (Eficiencia Computacional)

Cuidado con el overhead. Si cada request ahora tiene que pasar por un LLM-as-judge, estamos duplicando la latencia y el costo.

Propongo separar claramente:

1. **Metricas online (por request)**: latency, cache_hit, response_type, session_length. Costo: ~0.
2. **Evaluacion offline (batch, diaria)**: LLM-as-judge sobre sample de 50-100 queries del dia. Costo: ~$0.05/dia.
3. **Evaluacion manual (semanal)**: Humano revisa 20 queries del eval set. Costo: 30 min de tiempo.

Nunca meter LLM-as-judge en el hot path. Siempre batch.

### Junior MLE #1

Pregunta: si loggeamos `query_text_hash` y no el texto real, como vamos a evaluar relevance despues? Necesitamos el texto para saber que pregunto el usuario.

### Senior MLE #1 (Respuesta)

Buen punto. Podemos loggear el texto completo en un log separado con retention de 7 dias, solo accesible para evaluacion. O mejor: loggear en la misma tabla pero con una columna `query_text` que se trunca a 500 chars y se elimina despues de 7 dias via cron. No es PII porque son preguntas sobre candidatos, no datos personales del usuario.

### AI Tech Lead

De acuerdo con la separacion online/offline. Pero agrego un punto critico: **necesitamos una baseline antes de hacer cambios**. Si no medimos ahora, no sabremos si mejoramos.

Propuesta de timeline:

1. **Dia 1** (hoy): Implementar logging estructurado (ResponseMetrics)
2. **Dia 1** (hoy): Correr eval set manual, registrar scores baseline
3. **Dia 2-3**: Implementar cambios de optimizacion (debates anteriores)
4. **Dia 3**: Re-correr eval set, comparar con baseline
5. **Dia 4+**: Iterar basado en resultados

Sin baseline, estamos ciegos.

### Delivery Lead

El usuario dijo algo muy especifico: "que me entienda lo que estoy preguntando". Esto no es solo precision de datos -- es **comprension de intent**. Necesitamos medir:

1. El router clasifica correctamente el tipo de query?
2. Se llama al tool correcto?
3. Se pasan los parametros correctos?

Si el usuario pregunta "comparame a Keiko con Lopez Aliaga" y el router lo clasifica como `perfil_individual` y solo devuelve el perfil de Keiko, los datos son correctos pero la respuesta es mala. Relevance = 1/5.

Propongo una metrica adicional: **Intent Match** -- el query_type detectado por el router coincide con lo que el usuario realmente queria?

---

## Ciclo 2 -- Diseno de LLM-as-Judge

### Senior MLE #3 (Especialista en Evaluacion)

LLM-as-judge es la forma mas escalable de evaluar calidad. Pero hay trampas conocidas:

1. **Self-bias**: Si el juez es el mismo modelo que genera, tiende a dar scores altos
2. **Position bias**: En comparaciones A/B, favorece la primera respuesta
3. **Verbosity bias**: Respuestas mas largas suelen recibir scores mas altos
4. **Inconsistencia**: El mismo query puede recibir scores diferentes en runs distintos

Para mitigar:

```python
# evaluator.py
JUDGE_PROMPT = """
Eres un evaluador de calidad para un chatbot electoral peruano.

## Pregunta del usuario
{query}

## Respuesta del chatbot
{response}

## Criterios de evaluacion (puntua cada uno de 0 a 5)

1. RELEVANCE: La respuesta contesta directamente lo que se pregunto?
   - 5: Responde exactamente lo que se pregunto
   - 3: Responde parcialmente o incluye informacion tangencial
   - 1: No responde lo que se pregunto
   - 0: Completamente off-topic

2. COMPLETENESS: Incluye toda la informacion que el usuario esperaria?
   - 5: Completa, no falta nada relevante
   - 3: Falta algun dato importante
   - 1: Muy incompleta
   - 0: Sin informacion util

3. CONCISENESS: Es apropiadamente concisa?
   - 5: Longitud justa para lo preguntado
   - 3: Un poco larga o corta para lo preguntado
   - 1: Mucho mas larga o corta de lo necesario
   - 0: Completamente desproporcionada

4. INTENT_MATCH: El chatbot entendio la intencion del usuario?
   - 5: Entendio perfectamente que queria el usuario
   - 3: Entendio parcialmente
   - 1: Malinterpreto la pregunta
   - 0: Ignoro completamente la intencion

## Formato de respuesta (JSON estricto)
{
  "relevance": <int 0-5>,
  "completeness": <int 0-5>,
  "conciseness": <int 0-5>,
  "intent_match": <int 0-5>,
  "overall": <float 0-5>,
  "reasoning": "<explicacion breve>"
}
"""
```

Para evitar self-bias, usar un modelo diferente como juez. Si generamos con Gemini 2.0 Flash, evaluar con Gemini 2.5 Flash o incluso GPT-4o-mini (son ~$0.15/1M tokens, baratisimo como juez).

### Grandmaster Codeforces #2 (Analisis de Complejidad)

Veamos los numeros:

```
Eval set: 20 queries
LLM-as-judge por query: ~200 tokens input + ~100 tokens output = ~300 tokens
Costo por evaluacion completa (20 queries):
  - Gemini 2.5 Flash: 20 * 300 tokens ~= 6000 tokens ~= $0.0004
  - GPT-4o-mini: 20 * 300 tokens ~= 6000 tokens ~= $0.001
```

Es despreciable. Podemos correr la evaluacion 10 veces por dia sin preocuparnos por costo.

Para el sample diario de produccion (50-100 queries aleatorias):

```
100 queries * 300 tokens = 30,000 tokens ~= $0.002/dia con Gemini
```

Irrelevante en costo. La pregunta no es si es caro -- es si es util.

### Junior MLE #2

Y si el LLM-as-judge se equivoca? Si da 5/5 a una respuesta mala?

### Senior MLE #3 (Respuesta)

Buena pregunta. Por eso necesitamos **calibracion**. El proceso es:

1. Un humano evalua las 20 queries del eval set (ground truth)
2. LLM-as-judge evalua las mismas 20 queries
3. Calculamos correlacion entre scores humanos y LLM
4. Si la correlacion es > 0.7, el LLM-as-judge es confiable para monitoreo continuo
5. Si es < 0.7, ajustamos el prompt del juez y repetimos

Esto toma 1 hora la primera vez y nos da confianza en el sistema.

### Grandmaster Codeforces #3

Agrego un punto tecnico sobre la correlacion. No basta con Pearson -- necesitamos ver los **falsos positivos** (LLM dice 5, humano dice 2). Estos son peligrosos porque nos dan falsa confianza.

Propongo usar Cohen's Kappa o al menos una confusion matrix discretizada (0-2 = malo, 3 = regular, 4-5 = bueno).

### Senior MLE #4 (Arquitectura)

Dejame proponer la arquitectura completa del sistema de evaluacion:

```
                    ONLINE (por request)
                    ====================
User Request
    |
    v
[Gateway Pipeline] -----> [ResponseMetrics Logger]
    |                              |
    v                              v
User Response               [metrics_log table]
                                   |
                            (cada noche, cron)
                                   |
                                   v
                    OFFLINE (batch diario)
                    =====================
                    [Sample 100 queries]
                            |
                            v
                    [LLM-as-Judge Batch]
                            |
                            v
                    [quality_scores table]
                            |
                            v
                    [Dashboard / Alerts]


                    MANUAL (semanal o pre-deploy)
                    =============================
                    [20 eval set queries]
                            |
                            v
                    [Run through pipeline]
                            |
                            v
                    [LLM-as-Judge + Human review]
                            |
                            v
                    [eval_results table]
                            |
                            v
                    [Baseline comparison]
```

### Senior MLE #5 (Storage)

Para las tablas, propongo:

```sql
-- Logging online (alta cardinalidad, se puede purgar semanalmente)
CREATE TABLE response_metrics (
    id SERIAL PRIMARY KEY,
    session_id VARCHAR(64) NOT NULL,
    message_index INT NOT NULL,
    query_text TEXT,            -- se purga despues de 7 dias
    query_type VARCHAR(32),
    response_type VARCHAR(32),
    tool_called VARCHAR(64),
    tool_args_hash VARCHAR(64),
    latency_total_ms INT,
    latency_router_ms INT,
    latency_mcp_ms INT,
    latency_synth_ms INT,
    tokens_in INT,
    tokens_out INT,
    cache_hit BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Index para queries analiticas
CREATE INDEX idx_metrics_created ON response_metrics(created_at);
CREATE INDEX idx_metrics_session ON response_metrics(session_id);
CREATE INDEX idx_metrics_type ON response_metrics(query_type, response_type);

-- Evaluacion offline (baja cardinalidad, retener indefinidamente)
CREATE TABLE quality_scores (
    id SERIAL PRIMARY KEY,
    metric_id INT REFERENCES response_metrics(id),
    judge_model VARCHAR(64),
    relevance INT CHECK (relevance BETWEEN 0 AND 5),
    completeness INT CHECK (completeness BETWEEN 0 AND 5),
    conciseness INT CHECK (conciseness BETWEEN 0 AND 5),
    intent_match INT CHECK (intent_match BETWEEN 0 AND 5),
    overall FLOAT,
    reasoning TEXT,
    is_human BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Eval set (fijo, 20 queries)
CREATE TABLE eval_set (
    id SERIAL PRIMARY KEY,
    query_text TEXT NOT NULL,
    query_type VARCHAR(32) NOT NULL,
    expected_tool VARCHAR(64),
    expected_criteria JSONB,     -- {"must_include": ["partido", "cargo"], "must_not_include": ["opinion"]}
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

### AI Tech Lead

Me gusta el esquema pero tengo dos objeciones:

1. **No agregar tablas nuevas a la DB de produccion.** La DB de produccion tiene candidatos, planes, etc. Las metricas deben ir a un esquema separado o incluso a BigQuery si estamos en GCP. Mezclar analytics con produccion es receta para problemas de performance.

2. **Simplificar para los 10 dias que quedan.** No necesitamos PostgreSQL para esto. Un archivo JSONL en Cloud Storage o incluso en disco local del container es suficiente por ahora. Sobreingenieria es el enemigo con deadline.

Propuesta alternativa para los 10 dias:

```python
# Opcion simple: JSONL local
import json
from pathlib import Path

METRICS_LOG = Path("/tmp/metrics.jsonl")

def log_metric(metric: ResponseMetrics):
    with METRICS_LOG.open("a") as f:
        f.write(json.dumps(asdict(metric), default=str) + "\n")
```

Si queremos persistencia entre deploys, subir el JSONL a Cloud Storage cada hora con un background task.

---

## Ciclo 3 -- A/B Testing Passthrough vs Synthesis

### Senior MLE #2 (Evaluacion Offline)

El A/B mas importante es: **passthrough (template) vs synthesis (LLM)**.

En debates anteriores decidimos usar passthrough para perfiles individuales. Pero no medimos si la calidad bajo. El usuario dijo "que me entienda" -- quiza el passthrough es demasiado rigido y no adapta la respuesta al contexto de la pregunta.

Ejemplo:

```
Query: "Que estudia Keiko?"
Passthrough: [Perfil completo de Keiko con TODAS las secciones]
Synthesis:   "Keiko Fujimori estudio un MBA en Boston University (concluido)."

Query: "Dime sobre Keiko"
Passthrough: [Perfil completo -- correcto aqui]
Synthesis:   [Perfil completo pero con tono conversacional]
```

En el primer caso, synthesis es claramente mejor (relevance 5 vs 2). En el segundo, ambos son aceptables.

### Grandmaster Codeforces #4

Formalizando: necesitamos un **router de response_type** que decida cuanto contexto incluir basado en la query.

```
Query "Quien es X?"       -> perfil_completo   -> passthrough OK
Query "Que estudia X?"    -> perfil_seccion     -> passthrough con filtro de seccion
Query "Comparame X con Y" -> comparacion        -> synthesis necesario
Query "X tiene sentencias?" -> perfil_seccion   -> passthrough con filtro de seccion
```

El passthrough funciona bien cuando la query pide "todo". Falla cuando pide algo especifico y le tiramos todo el perfil encima.

### Senior MLE #1 (Respuesta)

Esto ya lo detectamos parcialmente. El preprocessor del gateway tiene `fast_routes` que clasifican queries. Pero el problema es que `_build_passthrough_reply` siempre devuelve el perfil completo. Necesitamos:

1. Passthrough completo: para "quien es X", "dime sobre X"
2. Passthrough con filtro: para "que estudia X", "patrimonio de X"
3. Synthesis: para comparaciones, preguntas complejas, contexto conversacional

Para el A/B test:

```python
# Correr ambas estrategias para las 20 queries del eval set
results_passthrough = []
results_synthesis = []

for query in eval_set:
    # Forzar passthrough
    resp_pt = await pipeline(query, force_response_type="passthrough")
    # Forzar synthesis
    resp_synth = await pipeline(query, force_response_type="synthesis")

    # LLM-as-judge evalua ambas
    score_pt = await judge(query, resp_pt)
    score_synth = await judge(query, resp_synth)

    results_passthrough.append(score_pt)
    results_synthesis.append(score_synth)

# Comparar
avg_pt = mean([r.overall for r in results_passthrough])
avg_synth = mean([r.overall for r in results_synthesis])
```

### Junior MLE #3

No entiendo por que no simplemente usamos synthesis siempre. Si el LLM es bueno entendiendo contexto, dejarlo trabajar.

### Grandmaster Codeforces #5

Porque synthesis agrega 8-10 segundos de latencia. Con 10 dias para las elecciones y picos de 5000-10000 queries/dia, eso son miles de dolares en tokens y usuarios esperando. La pregunta no es "cual es mejor en calidad" -- es "cual es el punto optimo de calidad/latencia".

Formalizando:

```
Score compuesto = quality_score * w_quality - latency_penalty * w_latency

donde:
  quality_score = (relevance + completeness + conciseness + intent_match) / 20  # normalizado 0-1
  latency_penalty = max(0, (latency_ms - 2000) / 10000)  # penaliza >2s, max penalty a 12s
  w_quality = 0.7
  w_latency = 0.3
```

Si passthrough da quality=0.6 con latency=200ms y synthesis da quality=0.9 con latency=10000ms:

```
passthrough: 0.6 * 0.7 - 0 * 0.3     = 0.42
synthesis:   0.9 * 0.7 - 0.8 * 0.3   = 0.39
```

Passthrough gana por la penalizacion de latencia. PERO si filtramos passthrough por seccion y quality sube a 0.8:

```
passthrough_filtrado: 0.8 * 0.7 - 0 * 0.3 = 0.56  <-- GANADOR
```

La respuesta es **passthrough inteligente con filtro de seccion**, no passthrough crudo ni synthesis completo.

### Delivery Lead

Excelente analisis. Pero hay un caso que no estamos considerando: **queries de seguimiento en una conversacion**. El usuario pregunta "Quien es Keiko?", recibe el perfil, y luego pregunta "Y su patrimonio?". El passthrough no tiene contexto de la conversacion anterior.

En este caso:
- Passthrough: devuelve perfil completo de Keiko otra vez (duplicado, mala UX)
- Synthesis: entiende el contexto, responde solo la seccion de patrimonio

Necesitamos medir **calidad en contexto conversacional**, no solo queries aisladas.

### Senior MLE #3 (Evaluacion)

Buen punto. Propongo expandir el eval set con 5 **sesiones multi-turn**:

| Sesion | Turn 1 | Turn 2 | Turn 3 |
|--------|--------|--------|--------|
| S1 | "Quien es Keiko?" | "Y su patrimonio?" | "Comparala con Lopez Aliaga" |
| S2 | "Candidatos de Lima" | "Cual tiene mas experiencia?" | "Dime mas de ese" |
| S3 | "Hola" | "Que candidatos hay?" | "Quien tiene sentencias?" |
| S4 | "Lopez Aliaga patrimonio" | "Y su educacion?" | "Tiene antecedentes?" |
| S5 | "Comparame Keiko y Antauro" | "Quien tiene mas patrimonio de los dos?" | "Y en educacion?" |

La evaluacion multi-turn requiere que el juez vea la conversacion completa:

```python
MULTI_TURN_JUDGE_PROMPT = """
## Conversacion completa
{conversation_history}

## Ultima respuesta del chatbot
{last_response}

## Evalua la ultima respuesta considerando el contexto de la conversacion:
1. RELEVANCE: Responde lo que se pregunto en el contexto de la conversacion?
2. CONTEXT_AWARENESS: Usa correctamente la informacion de turnos anteriores?
3. REDUNDANCY: Evita repetir informacion ya proporcionada?
4. CONCISENESS: Longitud apropiada para un turno de seguimiento?
"""
```

---

## Ciclo 4 -- Implementacion Practica en 10 Dias

### AI Tech Lead

Basta de teoria. Tenemos 10 dias. Que hacemos HOY?

Propongo un plan concreto de 3 niveles:

**Nivel 1 -- HOY (2 horas)**
- Agregar logging estructurado al pipeline (`ResponseMetrics`)
- Crear eval set de 20 queries como fixture JSON
- Correr eval set manualmente, registrar resultados como baseline
- Archivo: `gateway/src/agent/metrics.py` + `gateway/tests/fixtures/eval_set.json`

**Nivel 2 -- MANANA (3 horas)**
- Script de evaluacion batch: corre eval set, ejecuta LLM-as-judge, genera reporte
- Archivo: `gateway/scripts/eval_quality.py`
- Calibrar LLM-as-judge contra evaluacion humana (las 20 queries)

**Nivel 3 -- DIA 3-4 (4 horas)**
- A/B passthrough vs synthesis vs passthrough-filtrado para eval set
- Dashboard simple (puede ser un script que imprime tabla en terminal)
- Alertas basicas: si quality_score promedio cae bajo 3.0, log warning

**POST-ELECCIONES (despues del 12 abril)**
- BigQuery para analytics
- Dashboard web real
- Evaluacion multi-turn automatizada
- A/B testing en produccion con traffic splitting

### Grandmaster Codeforces #1

El plan del AI Tech Lead es correcto pero le falta el detalle de DONDE loggear. No podemos usar PostgreSQL de produccion. Propuestas:

| Opcion | Pros | Contras | Veredicto |
|--------|------|---------|-----------|
| JSONL en disco | Simple, sin deps | Se pierde en redeploy | Para eval local OK |
| Redis stream | Ya tenemos Redis | Memoria limitada, se pierde | No |
| PostgreSQL schema separado | Persistente, queryable | Overhead en prod DB | No por ahora |
| Cloud Logging structured | Persistente, queryable, gratis | Requiere GCP setup | Mejor opcion produccion |
| SQLite file en volume mount | Persistente, simple, queryable | No escala | OK para 10 dias |

Para los 10 dias: **JSONL para eval local, Cloud Logging structured para produccion.**

Cloud Logging ya esta configurado en Cloud Run. Solo necesitamos emitir JSON a stdout con campos estructurados:

```python
import json
import sys

def log_metric(metric: ResponseMetrics):
    # Cloud Run captura stdout como Cloud Logging entries
    # Campos en "jsonPayload" son queryables
    entry = {
        "severity": "INFO",
        "message": "response_metric",
        **asdict(metric)
    }
    print(json.dumps(entry, default=str), file=sys.stdout, flush=True)
```

Luego en Cloud Logging podemos hacer:

```
resource.type="cloud_run_revision"
jsonPayload.message="response_metric"
jsonPayload.query_type="perfil_individual"
jsonPayload.latency_total_ms>5000
```

Cero costo adicional. Cero infraestructura nueva.

### Senior MLE #4

De acuerdo con Cloud Logging. Pero para la evaluacion con LLM-as-judge, necesitamos poder LEER las metricas. Cloud Logging tiene la API de Logging, pero es lenta y compleja. Propongo:

1. En produccion: loggear a stdout (Cloud Logging)
2. Script de evaluacion: `gcloud logging read` para extraer N queries del dia
3. Pipe al LLM-as-judge
4. Output a un archivo de reporte

```bash
# scripts/eval_quality.sh
gcloud logging read \
  'resource.type="cloud_run_revision" AND jsonPayload.message="response_metric"' \
  --project=infovoto-prod \
  --limit=100 \
  --format=json \
  > /tmp/daily_metrics.json

python gateway/scripts/eval_quality.py /tmp/daily_metrics.json
```

### Junior MLE #1

Y en local? No tenemos Cloud Logging. Necesitamos poder evaluar sin deploy.

### Senior MLE #1

En local usamos el eval set directamente. No necesitamos loggear para evaluar -- el script de evaluacion corre las 20 queries contra el gateway local y evalua:

```python
# gateway/scripts/eval_quality.py
import httpx
import json

EVAL_SET = json.load(open("tests/fixtures/eval_set.json"))
GATEWAY_URL = "http://localhost:2080"

async def run_eval():
    results = []
    for item in EVAL_SET:
        # Ejecutar query
        resp = await httpx.AsyncClient().post(
            f"{GATEWAY_URL}/api/chat",
            json={"message": item["query"], "session_id": f"eval_{item['id']}"}
        )
        response_text = resp.json()["response"]
        latency_ms = resp.elapsed.total_seconds() * 1000

        # LLM-as-judge
        score = await judge_response(item["query"], response_text, item["expected_criteria"])

        results.append({
            "query": item["query"],
            "query_type": item["query_type"],
            "response": response_text[:200],
            "latency_ms": latency_ms,
            **score
        })

    # Imprimir reporte
    print_eval_report(results)
```

### Grandmaster Codeforces #2

El script de evaluacion debe ser **determinista y reproducible**. Propongo:

1. Session IDs fijos por query (`eval_001`, `eval_002`, etc.)
2. Limpiar cache de Redis antes de cada run (para medir latencia real)
3. Correr 3 veces y promediar (LLM tiene varianza)
4. Output en formato CSV para facil comparacion temporal

```
run_id,timestamp,query_id,query_type,relevance,completeness,conciseness,intent_match,overall,latency_ms
baseline_001,2026-04-02T10:00:00,q01,perfil_individual,4,5,3,5,4.25,2100
baseline_001,2026-04-02T10:00:00,q02,lista_region,5,4,4,5,4.50,1800
...
```

Asi podemos hacer `diff baseline_001.csv optimization_001.csv` y ver exactamente que mejoro y que empeoro.

### Stakeholder

Quiero entender las metricas desde la perspectiva del usuario final. El usuario peruano promedio que va a usar InfoVoto:

1. **No sabe que hay un LLM detras.** Espera respuestas como de Google: rapidas y directas.
2. **Tiene poca paciencia.** Si tarda mas de 5 segundos, cierra la pagina.
3. **Hace preguntas ambiguas.** "Keiko" sin mas contexto. "El de Arequipa". "Ese que robo".
4. **Quiere comparar.** "Quien es mejor?" (que no podemos responder con datos, pero si con comparativas objetivas).
5. **Busca confirmacion de sus prejuicios.** "Es verdad que Keiko es corrupta?" (debemos ser neutrales).

Las metricas deben capturar estos patrones. Propongo agregar al eval set queries "del mundo real":

| Query | Tipo | Dificultad |
|-------|------|------------|
| "keiko" | ambigua_minima | Alta -- debe asumir que quiere perfil |
| "el de renovacion popular" | referencia_indirecta | Alta -- debe resolver "Lopez Aliaga" |
| "quien va a ganar?" | prediccion | Media -- debe declinar con tacto |
| "son todos corruptos?" | opinion_negativa | Media -- debe ser neutral |
| "a quien debo votar?" | recomendacion | Media -- debe declinar y ofrecer herramientas |

Estas queries "dificiles" nos dicen mas sobre la calidad real del sistema que las queries faciles.

### Delivery Lead

Completamente de acuerdo con el Stakeholder. Pero cuidado con expandir demasiado el eval set. 20 queries ya es bastante para evaluar manualmente. Propongo:

- **Core eval set**: 20 queries (cobertura de tipos)
- **Edge cases**: 10 queries adicionales (las dificiles del Stakeholder)
- **Total**: 30 queries

Y priorizamos el core para el baseline de hoy.

---

## Ciclo 5 -- Convergencia y Decisiones Finales

### AI Tech Lead (Sintesis)

Consolidando todo lo discutido. Estas son las decisiones:

**1. Metricas Online (por request)**

```python
@dataclass
class ResponseMetrics:
    session_id: str
    message_index: int
    query_text: str              # se trunca a 500 chars
    query_type: str
    response_type: str           # passthrough | passthrough_filtered | synthesis | cached | error
    tool_called: str | None
    tool_args_hash: str | None
    latency_total_ms: int
    latency_router_ms: int
    latency_mcp_ms: int
    latency_synth_ms: int
    tokens_in: int | None
    tokens_out: int | None
    cache_hit: bool
    timestamp: datetime
```

Implementacion: loggear a stdout como JSON estructurado (Cloud Logging lo captura automaticamente).

**2. Metricas de Calidad (offline)**

| Dimension | Peso | Evaluador |
|-----------|------|-----------|
| Relevance | 0.30 | LLM-as-judge |
| Completeness | 0.25 | LLM-as-judge |
| Conciseness | 0.20 | LLM-as-judge |
| Intent Match | 0.25 | LLM-as-judge |

Score compuesto: `sum(dimension * peso)` normalizado a 0-5.

**3. Score Compuesto con Latencia**

```
final_score = quality_score * 0.7 - latency_penalty * 0.3
latency_penalty = max(0, (latency_ms - 2000) / 10000)
```

**4. Evaluacion Offline**

- Eval set: 20 core + 10 edge cases = 30 queries
- LLM-as-judge: Gemini 2.5 Flash (diferente del modelo de generacion)
- Calibracion: correlacion con evaluacion humana debe ser > 0.7
- Frecuencia: diaria en produccion (sample 100), manual pre/post cambios

**5. A/B Testing**

Comparar 3 estrategias en el eval set:
- (A) Passthrough completo
- (B) Passthrough con filtro de seccion
- (C) Synthesis LLM

Decision basada en score compuesto (calidad + latencia).

**6. Metricas Proxy de UX**

| Metrica | Como Medir | Threshold |
|---------|------------|-----------|
| Abandonment rate | Sesiones con 1 mensaje / total sesiones | < 30% |
| Follow-up rate | Sesiones con 2+ mensajes / total | > 50% |
| Avg session length | Mensajes por sesion | > 2.5 |
| Repeat query rate | Queries identicas (hash) en misma sesion | < 10% |

Repeat query rate es clave: si el usuario repite la misma pregunta, probablemente no entendio la respuesta o no le gusto.

### Senior MLE #5

Falta algo: **alertas**. De nada sirve medir si nadie mira los dashboards. Propongo thresholds minimos:

| Alerta | Condicion | Accion |
|--------|-----------|--------|
| Quality drop | Avg quality < 3.0 en ultimas 100 queries | Log WARNING + Slack (futuro) |
| Latency spike | p95 latency > 8000ms | Log WARNING |
| High abandonment | Abandonment > 50% en ultima hora | Log WARNING |
| High repeat queries | Repeat rate > 20% | Log WARNING -- posible bug de comprension |
| Tool error rate | Tool errors > 10% | Log ERROR |

Por ahora, log WARNING es suficiente. Post-elecciones, integrar Slack o PagerDuty.

### Grandmaster Codeforces #3

Un ultimo punto tecnico sobre la implementacion del logging. No debe agregar latencia al hot path. Usar `asyncio.create_task` para loggear sin bloquear:

```python
async def process_request(request: ProcessRequest) -> ProcessResponse:
    start = time.monotonic()

    # ... pipeline normal ...

    # Loggear sin bloquear la respuesta
    metrics = ResponseMetrics(
        session_id=request.session_id,
        latency_total_ms=int((time.monotonic() - start) * 1000),
        # ... etc
    )
    asyncio.create_task(_async_log_metric(metrics))

    return response
```

Pero cuidado: si el task falla, no debe afectar la respuesta. Wrap en try/except generico:

```python
async def _async_log_metric(metric: ResponseMetrics):
    try:
        log_metric(metric)
    except Exception:
        logger.warning("Failed to log metric", exc_info=True)
```

### Junior Codeforces #1

Y como vamos a visualizar los resultados del eval set? Un CSV no es muy visual.

### Senior MLE #2

Para los 10 dias, una tabla en terminal es suficiente:

```
============ EVAL REPORT: baseline_001 ============
Date: 2026-04-02 10:00:00
Model: gemini-2.0-flash
Strategy: passthrough + synthesis hybrid

SCORES BY QUERY TYPE:
+---------------------+-----+------+------+-------+--------+----------+
| Type                | N   | Rel  | Comp | Conc  | Intent | Overall  |
+---------------------+-----+------+------+-------+--------+----------+
| perfil_individual   |  5  | 4.2  | 4.0  | 3.1   | 4.5    | 3.95     |
| lista_region        |  3  | 4.8  | 4.5  | 4.2   | 4.8    | 4.58     |
| comparacion         |  2  | 3.5  | 3.0  | 3.5   | 4.0    | 3.50     |
| posicion_tematica   |  2  | 3.8  | 3.2  | 3.8   | 3.5    | 3.58     |
| saludo              |  1  | 5.0  | 5.0  | 5.0   | 5.0    | 5.00     |
| off_topic           |  2  | 4.5  | 4.0  | 4.5   | 4.5    | 4.38     |
| edge_case           |  5  | 2.8  | 2.5  | 3.0   | 2.5    | 2.70     |
+---------------------+-----+------+------+-------+--------+----------+
| GLOBAL              | 20  | 3.94 | 3.60 | 3.73  | 3.97   | 3.81     |
+---------------------+-----+------+------+-------+--------+----------+

LATENCY:
  p50: 2100ms | p95: 8500ms | p99: 12000ms | avg: 3200ms

WORST QUERIES:
  #14 "Keiko vs Keiko" -> overall: 1.5 (intent_match: 1)
  #12 "Quien estudio en el extranjero?" -> overall: 2.0 (completeness: 1)
  #17 "Lopez Aliaga patrimonio" -> overall: 2.5 (conciseness: 2)

COMPARISON WITH PREVIOUS (if available):
  Overall: N/A (first baseline)
```

Esto se imprime en terminal y se guarda como CSV para tracking historico.

### Senior MLE #4

Ultimo punto: el eval set debe estar versionado en git. Asi podemos trackear:

```
gateway/tests/fixtures/
  eval_set.json           # 30 queries con criterios
  eval_results/
    baseline_001.csv      # primer baseline
    optimization_001.csv  # despues de cambios
    ...
```

Y en el README del directorio, documentar como correr la evaluacion.

### Delivery Lead (Cierre)

Resumo las prioridades para el equipo:

**HOY (no negociable):**
1. Crear `ResponseMetrics` dataclass y loggear en el pipeline
2. Crear `eval_set.json` con 20 queries core
3. Correr baseline manual y registrar resultados

**MANANA (alta prioridad):**
4. Script `eval_quality.py` con LLM-as-judge
5. Calibrar juez contra evaluacion humana

**ESTA SEMANA (media prioridad):**
6. A/B passthrough vs synthesis vs passthrough-filtrado
7. Agregar 10 edge cases al eval set
8. Implementar alertas basicas (log WARNING)

**POST-ELECCIONES (baja prioridad):**
9. BigQuery export
10. Dashboard web
11. Evaluacion multi-turn
12. Cloud Monitoring alertas

El feedback del usuario "que me entienda lo que estoy preguntando" se mide directamente con **Intent Match**. Si ese score esta bajo 3.0, tenemos un problema de router/clasificacion. Si esta sobre 4.0, el problema es de otra dimension.

### Junior MLE #2

Una pregunta final: y si el LLM-as-judge y el humano no coinciden en la calibracion? Que hacemos?

### Senior MLE #3

Iteramos el prompt del juez. Las causas comunes de discrepancia son:

1. **El juez es muy generoso**: agregar ejemplos de respuestas malas con scores bajos al prompt (few-shot)
2. **El juez no entiende el dominio**: agregar contexto sobre elecciones peruanas al system prompt
3. **El criterio es ambiguo**: refinar las rubricas de scoring (que significa "3" en relevance?)

Si despues de 3 iteraciones la correlacion sigue bajo 0.7, abandonamos LLM-as-judge y hacemos evaluacion 100% manual para el eval set (20 queries = 30 minutos). Para monitoreo de produccion, usamos solo metricas proxy (abandonment, repeat rate, latency).

### Grandmaster Codeforces #5 (Ultimo)

Un recordatorio matematico. Con 20 queries y 4 dimensiones, tenemos 80 data points. Con 3 runs para promediar, son 240 evaluaciones LLM. Esto es estadisticamente debil para conclusiones fuertes. No pretendamos que es riguroso -- es un **indicador direccional**.

Para tomar decisiones con confianza:
- Si la diferencia entre A y B es > 1.0 puntos en overall: probablemente real
- Si es 0.3-1.0: puede ser ruido, necesita mas queries
- Si es < 0.3: no es distinguible

Esto aplica al A/B testing tambien. No tomar decisiones de arquitectura basadas en diferencias de 0.2 puntos.

### AI Tech Lead (Consenso Final)

Todos de acuerdo? Veo consenso en:

1. Logging estructurado via stdout/Cloud Logging -- sin DB adicional
2. Eval set de 30 queries con LLM-as-judge offline
3. 4 dimensiones: relevance, completeness, conciseness, intent_match
4. Score compuesto con penalizacion de latencia
5. Baseline HOY, comparar despues de cada cambio
6. No meter evaluacion en el hot path
7. Metricas proxy de UX (abandonment, repeat rate)

Ciclo cerrado.

---

## VEREDICTO

**Estado:** APROBADO POR UNANIMIDAD

### Decisiones Finales

| # | Decision | Responsable | Deadline |
|---|----------|-------------|----------|
| 1 | Implementar `ResponseMetrics` dataclass con logging a stdout (JSON estructurado) | Senior MLE #1 | Hoy |
| 2 | Crear `eval_set.json` con 20 queries core + 10 edge cases | Senior MLE #2 + Stakeholder | Hoy |
| 3 | Correr baseline manual y registrar como `baseline_001.csv` | AI Tech Lead | Hoy |
| 4 | Implementar `eval_quality.py` con LLM-as-judge (Gemini 2.5 Flash) | Senior MLE #3 | Manana |
| 5 | Calibrar LLM-as-judge contra evaluacion humana (target: correlacion > 0.7) | Senior MLE #3 + Junior MLE #1 | Manana |
| 6 | A/B testing: passthrough vs passthrough-filtrado vs synthesis | Senior MLE #2 + Grandmaster #4 | Dia 3-4 |
| 7 | Alertas basicas: quality < 3.0, latency p95 > 8s, abandonment > 50% | Senior MLE #1 | Dia 3-4 |

### Metricas de Calidad Adoptadas

| Dimension | Peso | Escala | Threshold Aceptable |
|-----------|------|--------|-------------------|
| Relevance | 0.30 | 0-5 | >= 3.5 |
| Completeness | 0.25 | 0-5 | >= 3.0 |
| Conciseness | 0.20 | 0-5 | >= 3.0 |
| Intent Match | 0.25 | 0-5 | >= 3.5 |
| **Overall** | -- | 0-5 | **>= 3.5** |

### Score Compuesto

```
quality_score = relevance*0.30 + completeness*0.25 + conciseness*0.20 + intent_match*0.25
final_score = quality_score * 0.7 - latency_penalty * 0.3
latency_penalty = max(0, (latency_ms - 2000) / 10000)
```

### Archivos a Crear/Modificar

| Archivo | Accion |
|---------|--------|
| `gateway/src/agent/metrics.py` | CREAR -- ResponseMetrics dataclass + log_metric() |
| `gateway/src/agent/core.py` | MODIFICAR -- agregar logging de metricas al pipeline |
| `gateway/tests/fixtures/eval_set.json` | CREAR -- 30 queries con criterios esperados |
| `gateway/scripts/eval_quality.py` | CREAR -- script de evaluacion batch con LLM-as-judge |

### Rechazado / Diferido

| Item | Razon |
|------|-------|
| PostgreSQL para metricas | Sobreingenieria para 10 dias, Cloud Logging es suficiente |
| Dashboard web | Post-elecciones, terminal table es suficiente por ahora |
| A/B testing en produccion con traffic splitting | Demasiado complejo, eval set offline es suficiente |
| Evaluacion multi-turn automatizada | Post-elecciones, el eval set multi-turn es manual por ahora |
| BigQuery export | Post-elecciones |

### Proximo Debate

Debate 20: Resultados del baseline y plan de accion basado en scores reales.
