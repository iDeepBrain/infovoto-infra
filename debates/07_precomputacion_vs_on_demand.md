# Debate 07: Pre-computacion vs On-Demand -- Que calcular de antemano?

> **Pregunta central:** Dado que la data electoral es cuasi-estatica (JNE actualiza semanalmente), que vale la pena pre-computar al momento del scraping vs calcular on-demand en cada request?

**Fecha:** 2026-04-02
**Contexto:** Chatbot electoral Peru 2026. 36 candidatos presidenciales, ~1500 candidatos totales (congresistas, regionales, etc). Data de JNE cuasi-estatica. Actual: todo on-demand, 30 preguntas warmed at startup (5-10 min). Gemini 2.0 Flash pricing: ~$0.10/1M input tokens, ~$0.40/1M output tokens.

---

## Opciones en Mesa

| Opcion | Descripcion | Cuando se computa |
|--------|-------------|-------------------|
| **A) Status quo** | Todo on-demand + warmup de 30 preguntas al startup | Request time |
| **B) Pre-compute perfiles markdown** | Generar resumen markdown de cada candidato durante scraping | Scrape time |
| **C) Pre-compute comparaciones pairwise** | C(36,2)=630 comparaciones entre presidenciales | Scrape time |
| **D) Pre-compute busquedas tematicas** | Top 10-15 temas (seguridad, educacion, salud...) pre-computados | Scrape time |
| **E) Hibrido selectivo** | Pre-computar B + D, on-demand para C y long-tail | Scrape/Request time |

## Numeros Clave

| Metrica | Valor |
|---------|-------|
| Candidatos presidenciales | 36 |
| Candidatos totales | ~1500 |
| Comparaciones pairwise (presidenciales) | C(36,2) = 630 |
| Comparaciones pairwise (todos) | C(1500,2) = 1,124,250 |
| Temas principales | 10-15 |
| Frecuencia de actualizacion JNE | Semanal |
| Warmup actual | 30 queries, 5-10 min secuencial |
| Gemini 2.0 Flash input | $0.10 / 1M tokens |
| Gemini 2.0 Flash output | $0.40 / 1M tokens |
| Tokens promedio por perfil (input) | ~2,000 (data cruda candidato) |
| Tokens promedio por perfil (output) | ~800 (markdown generado) |
| Tokens promedio por comparacion (input) | ~4,000 (2 candidatos) |
| Tokens promedio por comparacion (output) | ~1,200 (tabla comparativa) |

---

## Ciclo 1 -- Analisis de Costos Crudos

### Codeforces Grandmaster

Hagamos las cuentas exactas antes de opinar. Esto es pura aritmetica.

**Opcion B: Perfiles markdown (36 presidenciales)**
- Input: 36 candidatos x 2,000 tokens = 72,000 tokens -> 72K / 1M x $0.10 = $0.0072
- Output: 36 candidatos x 800 tokens = 28,800 tokens -> 28.8K / 1M x $0.40 = $0.01152
- **Total por batch: $0.019** (menos de 2 centavos)
- Semanal: $0.019 x 4 = $0.076/mes

**Opcion B extendida: Perfiles markdown (1500 todos)**
- Input: 1500 x 2,000 = 3M tokens -> $0.30
- Output: 1500 x 800 = 1.2M tokens -> $0.48
- **Total por batch: $0.78**
- Semanal: $0.78 x 4 = $3.12/mes

**Opcion C: Comparaciones pairwise (36 presidenciales)**
- Input: 630 x 4,000 = 2.52M tokens -> $0.252
- Output: 630 x 1,200 = 756K tokens -> $0.3024
- **Total por batch: $0.554**
- Semanal: $0.554 x 4 = $2.22/mes

**Opcion C extendida: Comparaciones pairwise (1500 todos)**
- 1,124,250 comparaciones x 4,000 input = 4.497B tokens -> $449.70
- 1,124,250 comparaciones x 1,200 output = 1.349B tokens -> $539.70
- **Total por batch: $989.40** -- DESCARTADO inmediatamente
- Ni siquiera calcular mensual

**Opcion D: Busquedas tematicas (15 temas x 36 candidatos)**
- Input: 15 x 36 x 2,000 = 1.08M tokens -> $0.108
- Output: 15 x 36 x 600 = 324K tokens -> $0.1296
- **Total por batch: $0.238**
- Semanal: $0.238 x 4 = $0.95/mes

**Opcion E: Hibrido (B + D para presidenciales)**
- $0.019 + $0.238 = **$0.257 por batch**
- Semanal: $1.03/mes

### Senior AI Engineer

Los costos de pre-computacion son irrisorios para los 36 presidenciales. Menos de $1/mes para perfiles + temas. Pero ojo: el costo real no es solo el LLM call. Es:

1. **Almacenamiento**: Donde guardar ~36 markdowns + 15 tablas tematicas
2. **Invalidacion**: Como detectar que JNE actualizo y hay que regenerar
3. **Complejidad del pipeline**: Agregar un paso post-scraping que llame a Gemini
4. **Staleness risk**: Si el scraper falla, los pre-computados quedan desactualizados

El costo monetario es despreciable. El costo de complejidad es el debate real.

### Senior MLE

Concuerdo con el analisis de costos. Para ponerlo en perspectiva: si 100 usuarios al dia hacen la misma pregunta "quien es Keiko", y cada query on-demand cuesta ~$0.0012 (2K input + 800 output), eso son $0.12/dia = $3.60/mes para UNA sola pregunta repetida. Pre-computar el perfil cuesta $0.0005 una vez. El ROI es obvio para queries de alta frecuencia.

Pero las comparaciones pairwise de todos los candidatos son imposibles. 1.1M comparaciones a $989/batch. Ni Google regala eso.

### Junior MLE

Pregunta basica: si ya tenemos el cache de 24h (debate 03) con hit rate estimado del 70-80% post-mejoras, cual es el beneficio incremental de pre-computar? Si el primer usuario del dia hace la query y queda cacheada para todos los demas... no estamos resolviendo el mismo problema dos veces?

### Junior Full Stack

Desde el frontend, me importa la latencia del primer request. Si un usuario abre la app y pregunta "comparame keiko con antauro", espera la respuesta en <3 segundos. Si es on-demand, son 10-20 segundos. Si esta pre-computado, es un lookup de <100ms. Esa diferencia se siente brutal en UX.

### AI Tech Lead

El Junior MLE hace un punto valido. La pre-computacion y el cache resuelven el mismo problema (evitar LLM calls redundantes) pero en momentos distintos:

| Aspecto | Cache | Pre-computacion |
|---------|-------|-----------------|
| Cuando computa | Primer request | Scrape time |
| Cold start | Primer usuario espera 10-20s | Nadie espera |
| Staleness | TTL-based, autorenovable | Atado al ciclo de scraping |
| Cobertura | Solo queries que alguien hizo | Todas las queries predefinidas |
| Complejidad | Ya implementado | Nuevo pipeline |

No son mutuamente excluyentes. La pre-computacion alimenta el cache.

### Full Stack Lead

Pensando en el patron enterprise "compute at write time, serve at read time": es exactamente lo que hacen los CDNs, los SSG (Static Site Generation), y cualquier sistema de busqueda serio. Elasticsearch no ejecuta queries complejas en real-time -- pre-indexa.

Pero InfoVoto no es un motor de busqueda. Es un chatbot conversacional. El valor esta en la conversacion natural, no en servir documentos estaticos. Si pre-computamos todo, estamos construyendo una Wikipedia, no un chatbot.

### Delivery Lead

Desde UX, dos escenarios:

**Dia normal (50-100 usuarios/dia):** El cache resuelve casi todo despues del primer usuario. La pre-computacion ahorra 10s al primer usuario del dia. Valor marginal.

**Dia de elecciones (10K-50K usuarios/hora):** El cache se llena en los primeros minutos. Pero esos primeros minutos con miles de usuarios concurrentes haciendo cold-start queries podrian tumbar el sistema. La pre-computacion garantiza que las top 50 queries ya estan resueltas antes del tsunami.

El dia de elecciones es el unico dia que importa. Y justamente ese dia, la pre-computacion brilla.

### Staff Engineer

Desde operaciones: agregar un paso post-scraping que llame a Gemini 630 veces (pairwise presidenciales) introduce un punto de fallo. Si el scraper termina pero Gemini esta down, que hacemos? El scraper debe ser independiente del LLM. Separar responsabilidades.

Propongo: el scraping y la pre-computacion son dos jobs diferentes. El scraper llena la DB. Un segundo job (que llamemos `precompute`) lee la DB y genera los markdowns. Si `precompute` falla, tenemos la data cruda intacta y el on-demand sigue funcionando.

### Product Manager

Las metricas que me importan:
1. **Time-to-first-answer** para queries populares
2. **Costo por usuario activo** al dia
3. **Complejidad de mantenimiento** (somos un equipo chico)

Pre-computar perfiles es no-brainer. Pre-computar 630 comparaciones... depende de cuantas se piden realmente. Si solo 20 pares son populares (keiko-antauro, keiko-lopez, etc.), pre-computar 630 es desperdiciar 610 llamadas. Mejor pre-computar solo los top 20 pares mas probables.

**Veredicto Ciclo 1:** 🔄 Necesita refinamiento. Los costos son claros. La estrategia optima no.

---

## Ciclo 2 -- Analisis de Frecuencia de Queries

### Codeforces Grandmaster

Modelemos la distribucion de queries para decidir que pre-computar. En elecciones, las queries siguen una distribucion Zipf: pocos candidatos concentran la mayoria de consultas.

**Distribucion estimada (basada en encuestas + Google Trends Peru):**

| Rango | Candidatos | % de queries | Acumulado |
|-------|-----------|-------------|-----------|
| Top 5 | Keiko, Antauro, Lopez Aliaga, Castillo, Mendoza | ~60% | 60% |
| Top 10 | + Forsyth, Acuna, De Soto, Urresti, Fujimori (hijo) | ~25% | 85% |
| Top 20 | + 10 mas | ~10% | 95% |
| Resto 16 | Candidatos menores | ~5% | 100% |

Para comparaciones, la distribucion es aun mas concentrada:

| Tipo de comparacion | Estimado | Cantidad |
|---------------------|----------|----------|
| Top 5 vs Top 5 | C(5,2) = 10 pares | ~50% de comparaciones |
| Top 10 vs Top 10 | C(10,2) = 45 pares | ~80% |
| Top 20 vs cualquiera | ~190 pares | ~95% |
| Long tail | ~440 pares | ~5% |

Conclusion matematica: pre-computar los 45 pares del top 10 cubre el 80% de comparaciones pedidas.

### Senior AI Engineer

Esto cambia completamente la economia. En vez de 630 comparaciones, hacemos 45. Veamos:

**45 comparaciones pairwise:**
- Input: 45 x 4,000 = 180K tokens -> $0.018
- Output: 45 x 1,200 = 54K tokens -> $0.0216
- **Total: $0.04 por batch** (4 centavos)
- Semanal: $0.16/mes

Es ridiculo lo barato. Menos que un chicle.

**Plan hibrido refinado:**
- 36 perfiles presidenciales: $0.019
- 45 comparaciones top-10: $0.04
- 15 temas x top-10: $0.054
- **Total batch: $0.113** (11 centavos)
- **Mensual: $0.45**

### Senior MLE

Ahora comparemos con el costo on-demand. Supongamos dia de elecciones, 30K usuarios, cada uno hace 5 queries promedio = 150K queries/dia.

**On-demand sin cache ni pre-computacion:**
- 150K queries x $0.0012 promedio = **$180/dia**

**On-demand con cache (hit rate 80% post debate-03):**
- 30K queries unicas x $0.0012 = **$36/dia**

**Pre-computacion + cache:**
- ~200 queries pre-computadas (perfiles + comparaciones + temas) cubren ~70% del trafico
- 150K x 30% miss rate x $0.0012 = **$54/dia** (peor caso, si el cache no atrapa nada mas)
- Realista: cache atrapa otro 20% del long-tail -> 150K x 10% x $0.0012 = **$18/dia**

El saving real es de $36/dia a $18/dia en dia de elecciones. $18 de ahorro. Suena poco, pero son $0.45 de pre-computacion que ahorran $18. ROI = 40x.

### Junior MLE

Espera, estoy confundido con algo. Si la pre-computacion genera un markdown o respuesta pre-armada, eso se guarda como que? Como un cache entry en Redis? Como un archivo en la DB? Como se sirve al usuario?

### AI Tech Lead

Excelente pregunta. Propongo que la pre-computacion genere **cache entries en Redis**, exactamente en el mismo formato que el cache on-demand. Es decir:

```
# Perfil pre-computado
cache:tool:buscar_candidato:{sha256("nombre=Keiko Fujimori")} -> markdown

# Comparacion pre-computada
cache:tool:comparar_candidatos:{sha256("a=Keiko Fujimori&b=Antauro Humala")} -> markdown

# Busqueda tematica pre-computada
cache:tool:buscar_por_tema:{sha256("tema=seguridad")} -> markdown
```

El gateway ni se entera si la respuesta fue pre-computada o cacheada on-demand. Misma interfaz, misma key, mismo TTL. La unica diferencia es que las pre-computadas estan ahi antes del primer usuario.

### Full Stack Lead

Me gusta la transparencia de ese approach. El frontend no cambia nada. El gateway no cambia nada. Solo se agrega un job de pre-poblacion de Redis. Pero hay un detalle: el TTL.

Si el cache tiene TTL=24h y el pre-compute corre post-scraping (semanal), los pre-computados expiran en 24h y vuelven a ser on-demand hasta el proximo scraping. Necesitamos:

1. TTL del pre-computado = 7 dias (alineado con frecuencia de scraping), o
2. Un cron diario que re-pueble el cache, o
3. TTL=24h pero con refresh automatico: cuando expira, si hay version pre-computada en DB, se restaura sin llamar al LLM

### Delivery Lead

La opcion 3 es over-engineering. La opcion 1 es la mas simple: TTL=7d para pre-computados, TTL=24h para on-demand. Cuando el scraper actualiza, se regeneran los pre-computados y se sobreescriben en Redis con TTL=7d fresco.

### Staff Engineer

Cuidado con TTL=7d. Si un candidato renuncia o hay un escandalo, la data pre-computada tarda hasta 7 dias en actualizarse. Necesitamos un mecanismo de invalidacion manual: `make invalidate-cache candidato=keiko` que borre las keys afectadas y force regeneracion.

### Product Manager

Me gusta la direccion. Resumo la propuesta emergente:

1. Pre-computar ~200 respuestas (36 perfiles + 45 comparaciones + temas)
2. Guardar en Redis como cache entries con TTL=7d
3. Gateway transparente -- no sabe si es pre-computado o on-demand
4. Invalidacion manual para emergencias
5. Costo: $0.45/mes

**Veredicto Ciclo 2:** 🔄 Necesita detalles de implementacion. La estrategia esta convergiendo.

---

## Ciclo 3 -- Arquitectura del Pipeline de Pre-computacion

### Codeforces Grandmaster

Formalizemos el pipeline. Tenemos dos jobs:

```
Job 1: scraper (existente)
  Input: JNE website
  Output: PostgreSQL tables (candidatos, planes, hojas_vida, etc)
  Frecuencia: Semanal o manual

Job 2: precompute (nuevo)
  Input: PostgreSQL tables
  Output: Redis cache entries
  Frecuencia: Post-scraping + cron diario de refresh
  Dependencia: Job 1 debe haber corrido al menos 1 vez
```

El DAG es simple: `scraper -> precompute -> (cache listo)`.

La complejidad algoritmica del precompute:
- Leer 36 candidatos de DB: O(36) queries
- Generar 36 perfiles: O(36) LLM calls (paralelizables)
- Generar 45 comparaciones: O(45) LLM calls (paralelizables)
- Generar 15 x 10 temas: O(150) LLM calls (paralelizables)
- Total: ~231 LLM calls, paralelizables con asyncio.gather con semaforo

Con un semaforo de 10 llamadas concurrentes y ~2s por call:
- 231 calls / 10 concurrentes x 2s = **~46 segundos**

Contra los 5-10 minutos del warmup actual secuencial de solo 30 queries.

### Senior AI Engineer

El paralelismo es clave. Actualmente el warmup es secuencial (30 queries x 10-20s = 5-10 min). El precompute con semaforo de 10 concurrentes termina en <1 minuto para 231 queries.

Pero hay un detalle: rate limits de Gemini. La API de Gemini 2.0 Flash tiene:

| Tier | RPM (Requests Per Minute) | TPM (Tokens Per Minute) |
|------|---------------------------|-------------------------|
| Free | 15 | 1M |
| Pay-as-you-go | 1,000 | 4M |
| Scale | 4,000 | 4M |

Con pay-as-you-go (1000 RPM), 231 requests caben en <15 segundos si los lanzamos todos. Pero para ser buenos ciudadanos, semaforo de 50 y delay de 100ms entre batches. Total: ~10 segundos.

### Senior MLE

Propongo esta estructura en `infovoto-scraper`:

```
infovoto-scraper/
├── src/
│   ├── scrapers/           # existente
│   ├── precompute/         # NUEVO
│   │   ├── __init__.py
│   │   ├── runner.py       # orquestador: lee DB, llama generadores, escribe Redis
│   │   ├── profiles.py     # genera markdown de perfiles
│   │   ├── comparisons.py  # genera comparaciones pairwise
│   │   ├── themes.py       # genera busquedas tematicas
│   │   └── config.py       # TOP_N_CANDIDATES, TOP_THEMES, SEMAPHORE_LIMIT
│   └── ...
```

O alternativamente, como un script standalone en `infovoto-infra/scripts/precompute/` que conecta a la DB y Redis directamente. Asi no acoplamos el scraper al LLM.

### Junior MLE

Me preocupa el testing. Como testeo que los perfiles pre-computados son correctos? Necesito:

1. Un test que verifique que el formato markdown es consistente
2. Un test que compare el pre-computado vs el on-demand para el mismo candidato
3. Un test de integracion que verifique que las keys de Redis coinciden con las que el gateway busca

Si las keys no coinciden, pre-computamos para nada.

### AI Tech Lead

El punto del Junior MLE es critico. La key de cache debe ser **identica** a la que el gateway genera on-demand. Si el gateway usa `cache:tool:buscar_candidato:{sha256("nombre=Keiko Fujimori")}` y el precompute usa `cache:tool:buscar_candidato:{sha256("nombre=keiko fujimori")}` (lowercase), cache miss garantizado.

**Solucion:** Extraer la logica de generacion de cache keys a un modulo compartido. O mejor: documentar el contrato exacto de las keys y que ambos lados lo implementen identico. Dado que son repos separados, yo prefiero un test de contrato.

```python
# test_cache_contract.py
def test_profile_cache_key_matches_gateway():
    """El precompute y el gateway deben generar la misma key para el mismo candidato."""
    gateway_key = gateway_cache_key("buscar_candidato", {"nombre": "Keiko Fujimori"})
    precompute_key = precompute_cache_key("buscar_candidato", {"nombre": "Keiko Fujimori"})
    assert gateway_key == precompute_key
```

### Full Stack Lead

Desde el frontend: no hay cambios. Cero. El frontend llama al gateway, el gateway revisa cache, encuentra el pre-computado, responde. Transparente. Me gusta.

Lo unico que necesito es que la respuesta pre-computada tenga el mismo formato JSON que la respuesta on-demand. Si el on-demand devuelve `{"response": "...", "sources": [...]}`, el pre-computado debe tener la misma estructura.

### Delivery Lead

Pensando en el dia de elecciones:

**Timeline propuesto:**
- D-7: Ultimo scraping antes de elecciones
- D-7: Precompute corre inmediatamente despues
- D-1: Verificacion manual de que las top 20 queries responden correctamente
- D-0 (madrugada): Re-run precompute para refrescar TTLs
- D-0: Redis tiene todo listo. Cero cold-start para el 80% de queries.

Sin pre-computacion:
- D-0 06:00: Primer usuario pregunta "quien es keiko" -> 15s de espera
- D-0 06:00: Segundo usuario pregunta lo mismo -> cache hit, 50ms
- D-0 06:01: Usuario pregunta "comparame keiko con antauro" -> 20s de espera
- ...y asi para cada query unica

Con pre-computacion:
- D-0 06:00: Primer usuario -> 50ms. Todos los usuarios -> 50ms. Desde el minuto cero.

### Staff Engineer

Me gusta el approach pero agrego una restriccion operacional: el precompute job **no debe correr en Cloud Run**. Debe correr local o en Cloud Build como un Job. Razones:

1. Cloud Run tiene timeout de 5 min (configurable hasta 60 min, pero no ideal para batch)
2. Si el precompute falla a mitad, no queremos reintentos automaticos del load balancer
3. Es un job batch, no un servicio. Usar Cloud Run Jobs o simplemente `make precompute` desde local

### Product Manager

Veo un riesgo de scope creep. Estamos pasando de "pre-computar 36 perfiles" a un pipeline complejo con jobs, tests de contrato, invalidacion manual, y timeline de dia-D. Pregunto: cual es el MVP?

**MVP:** Un script Python que lee los 36 candidatos presidenciales de la DB, genera 36 perfiles con Gemini, y los mete en Redis. Un `make precompute` y listo. Sin comparaciones, sin temas, sin cron. Solo perfiles.

**V2:** Agregar comparaciones top-10 y temas.
**V3:** Automatizar post-scraping y agregar invalidacion.

**Veredicto Ciclo 3:** 🔄 La arquitectura esta clara pero el scope necesita acotarse. MVP primero.

---

## Ciclo 4 -- Staleness y Consistencia de Datos

### Codeforces Grandmaster

El problema de staleness es un clasico de sistemas distribuidos. Tenemos tres fuentes de verdad:

```
JNE website (source of truth)
    |
    v [scraping, lag = 0-7 dias]
PostgreSQL (DB)
    |
    v [precompute, lag = 0-7 dias adicionales]
Redis (cache pre-computado)
    |
    v [TTL, lag = 0-7 dias adicionales]
Usuario final
```

**Peor caso de staleness:** JNE actualiza el lunes, scraper corre el domingo siguiente, precompute corre post-scraping, TTL de 7 dias. El usuario ve data de hasta **14 dias de retraso** en el peor caso.

**Mejor caso:** JNE actualiza, scraper detecta cambio inmediatamente (webhook o polling diario), precompute regenera, Redis actualizado. Lag: minutos.

Para data electoral que cambia semanalmente, 14 dias de peor caso es... aceptable? Depende del tipo de cambio.

### Senior AI Engineer

Categoricemos los tipos de cambios y su criticidad:

| Tipo de cambio | Frecuencia | Criticidad de retraso | Ejemplo |
|----------------|------------|----------------------|---------|
| Nuevo candidato inscrito | Rara | Alta (debe aparecer) | Candidato se inscribe |
| Candidato renuncia/excluido | Rara | Critica (no debe aparecer como activo) | JNE excluye a candidato |
| Actualizacion de plan de gobierno | Mensual | Media | Candidato sube plan actualizado |
| Cambio de datos personales | Rara | Baja | Correccion de fecha de nacimiento |
| Sentencia judicial nueva | Irregular | Alta | Noticia de condena |

Para cambios criticos (exclusion de candidato), 14 dias de retraso es inaceptable. Necesitamos invalidacion manual.

### Senior MLE

Propongo un sistema de versionado simple:

```python
# En PostgreSQL
class CandidatoVersion:
    candidato_id: int
    version: int          # incrementa en cada scraping
    updated_at: datetime

# En Redis, la key incluye la version
cache_key = f"precompute:perfil:{candidato_id}:v{version}"
```

Cuando el scraper actualiza un candidato, incrementa la version. El gateway, al buscar en cache, primero consulta la version actual en DB (una query rapida de <1ms) y busca la key con esa version. Si no existe (porque el precompute no ha corrido para la nueva version), hace on-demand y cachea.

Esto elimina completamente el problema de staleness: el cache pre-computado solo se sirve si es de la version actual.

### Junior MLE

Eso agrega una query a PostgreSQL en cada request para verificar la version. Si tenemos 150K queries/dia el dia de elecciones, son 150K queries adicionales a la DB. Es viable?

### AI Tech Lead

150K queries de `SELECT version FROM candidato_version WHERE id = ?` en PostgreSQL es absolutamente trivial. Es una tabla de 36 rows (presidenciales) con un indice primary key. Cada query tarda <0.5ms. 150K x 0.5ms = 75 segundos de tiempo total de DB en un dia. Irrelevante.

Pero hay un approach mas simple: cachear la version en Redis con TTL corto.

```python
# Redis
"precompute:version:36" -> "7"        # TTL = 5 min
"precompute:perfil:36:v7" -> "..."     # TTL = 7d
```

El gateway lee la version de Redis (microsegundos), luego lee el perfil con esa version. Si la version cambio, cache miss -> on-demand. Cero queries a PostgreSQL en hot path.

### Full Stack Lead

Me parece que estamos sobreingenieriando el versionado. La data cambia semanalmente. Los cambios criticos (exclusion de candidato) son eventos rarisimos que se manejan con invalidacion manual (`make invalidate candidato=X`).

Para el 99.9% del tiempo: TTL=7d, refresh semanal post-scraping. Para el 0.1% de emergencias: un comando manual que borra las keys afectadas.

Simple > elegante.

### Delivery Lead

Concuerdo con el Full Stack Lead. Somos un equipo chico. El versionado automatico es lindo pero agrega complejidad que no necesitamos para un evento de un dia (elecciones).

**Protocolo de emergencia simple:**
1. Detectar cambio critico (manualmente, via monitoreo de noticias)
2. `make invalidate-candidate nombre="X"` -- borra todas las cache keys relacionadas
3. El proximo request regenera on-demand
4. Opcionalmente, `make precompute --candidate="X"` para regenerar solo ese candidato

### Staff Engineer

De acuerdo con keep-it-simple. Pero agrego: necesitamos logging de cuando se generaron los pre-computados.

```python
# Al guardar en Redis, agregar metadata
{
    "content": "## Keiko Fujimori\n...",
    "generated_at": "2026-03-30T03:00:00Z",
    "source_version": "scrape_2026-03-30",
    "model": "gemini-2.0-flash"
}
```

Asi, si algo se ve mal, podemos diagnosticar: "este perfil se genero hace 5 dias con data del scraping del 30 de marzo".

### Product Manager

El versionado automatico queda para V3. El MVP es:

1. Pre-computar perfiles con TTL=7d
2. `make invalidate-candidate` para emergencias
3. Metadata de generacion en cada entry

**Veredicto Ciclo 4:** ✅ Aprobado. Staleness manejado con TTL semanal + invalidacion manual.

---

## Ciclo 5 -- Storage y Costos de Infraestructura

### Codeforces Grandmaster

Calculemos el storage exacto en Redis:

**Perfil markdown promedio:** ~2,000 caracteres = ~2 KB
**Comparacion pairwise:** ~3,000 caracteres = ~3 KB
**Busqueda tematica:** ~4,000 caracteres = ~4 KB (lista de 10 candidatos)
**Metadata por entry:** ~200 bytes

**MVP (36 perfiles):**
- 36 x 2.2 KB = **79.2 KB**

**V2 (+ 45 comparaciones + 15 temas):**
- 36 perfiles x 2.2 KB = 79.2 KB
- 45 comparaciones x 3.2 KB = 144 KB
- 15 temas x 4.2 KB = 63 KB
- **Total: 286.2 KB**

**V2 extendido con 1500 candidatos (solo perfiles):**
- 1500 x 2.2 KB = **3.3 MB**

Para contexto: Redis en Upstash (tier gratis) tiene 256 MB. Usariamos el 0.11% del espacio con V2. Incluso los 1500 candidatos usan solo el 1.3%.

### Senior AI Engineer

El storage es un no-issue absoluto. Pero hay otro costo: las conexiones a Redis.

Upstash free tier:
- 10,000 commands/dia
- 256 MB storage
- 1 DB

Upstash pay-as-you-go:
- $0.2/100K commands
- 1 GB storage
- $0.05/100K commands read, $0.2/100K commands write

El dia de elecciones con 150K queries:
- 150K reads x $0.05/100K = $0.075
- Pre-computacion 231 writes = despreciable
- **Total Redis dia-D: ~$0.10**

On-demand cache writes (30K cache misses): 30K x $0.2/100K = $0.06

**Redis total dia-D: ~$0.16**

### Senior MLE

Para el Cloud Run, el costo relevante es la latencia. Un cache hit en Redis (Upstash, region us-central1) tiene latencia de ~5-10ms. Un LLM call tiene latencia de 2-15 segundos.

Impacto en Cloud Run billing:
- Cache hit: request dura 100ms -> billed 100ms de vCPU
- Cache miss: request dura 10s -> billed 10s de vCPU

Cloud Run pricing: $0.00002400/vCPU-second

- Cache hit: 0.1s x $0.000024 = $0.0000024
- Cache miss: 10s x $0.000024 = $0.000240

Un cache miss cuesta **100x mas** en Cloud Run que un cache hit. Con 150K queries y 80% hit rate:
- 120K hits x $0.0000024 = $0.29
- 30K misses x $0.000240 = $7.20
- **Total Cloud Run dia-D: $7.49**

Con pre-computacion subiendo hit rate a 90%:
- 135K hits x $0.0000024 = $0.32
- 15K misses x $0.000240 = $3.60
- **Total Cloud Run dia-D: $3.92**

**Ahorro en Cloud Run: $3.57** (casi 50% de reduccion).

### Junior MLE

Entonces el ahorro total del dia de elecciones:

| Concepto | Sin pre-computacion | Con pre-computacion | Ahorro |
|----------|--------------------|--------------------|--------|
| Gemini API | $36.00 | $18.00 | $18.00 |
| Cloud Run | $7.49 | $3.92 | $3.57 |
| Redis | $0.16 | $0.16 | $0.00 |
| Pre-computacion (Gemini) | $0.00 | $0.11 | -$0.11 |
| **Total** | **$43.65** | **$22.19** | **$21.46** |

Ahorramos $21.46 en el dia mas caro. El costo mensual de pre-computacion es $0.45. ROI anualizado: absurdo.

### Junior Full Stack

Y el ahorro en UX es incalculable. 50ms vs 10 segundos para las queries mas populares. Eso es la diferencia entre "esta app es instantanea" y "esta app es lenta".

### AI Tech Lead

Los numeros hablan. Pre-computar perfiles y comparaciones top es puro beneficio. El unico costo real es la complejidad del script, que es un one-time effort de quizas 4-8 horas de desarrollo.

### Full Stack Lead

Nada que agregar desde frontend. Storage es irrelevante, latencia mejora, costos bajan.

### Delivery Lead

Me convence. El ahorro de $21 en el dia de elecciones paga un ano entero de pre-computacion mensual ($5.40/ano). Y la mejora de UX no tiene precio.

### Staff Engineer

Un detalle operacional: monitorear el tamano de Redis. Agregar una alerta si supera el 50% del tier. No porque los pre-computados sean grandes, sino porque si alguien mete data basura en el cache, queremos detectarlo antes de que Upstash empiece a cobrar overages.

### Product Manager

Numeros solidos. Aprobado.

**Veredicto Ciclo 5:** ✅ Aprobado. Storage y costos totalmente viables. ROI claro.

---

## Ciclo 6 -- Formato de los Pre-computados

### Codeforces Grandmaster

Hay una decision de diseño que nadie ha mencionado: que formato tienen los pre-computados?

**Opcion 1: Markdown plano**
```
## Keiko Fujimori
**Partido:** Fuerza Popular
**Edad:** 51 años
...
```
Pro: Simple, legible. Contra: El chatbot normalmente genera respuestas conversacionales, no fichas tecnicas.

**Opcion 2: Respuesta conversacional pre-generada**
```
Keiko Fujimori es la candidata de Fuerza Popular. Tiene 51 años y...
```
Pro: Suena natural. Contra: No se adapta al contexto de la conversacion. Si el usuario pregunto "que experiencia tiene keiko?" y servimos un perfil generico, se siente robótico.

**Opcion 3: Datos estructurados + generacion on-demand del texto**
```json
{
  "nombre": "Keiko Fujimori",
  "partido": "Fuerza Popular",
  "edad": 51,
  "experiencia": ["Congresista 2006-2011", ...],
  "propuestas_clave": ["...", "..."]
}
```
Pro: El LLM puede usar estos datos para generar una respuesta contextual sin llamar al MCP. Contra: Sigue necesitando un LLM call para formatear la respuesta.

### Senior AI Engineer

La opcion 3 es la mas inteligente pero contradice el objetivo de eliminar LLM calls. Propongo **Opcion 4: Pre-computar a nivel de cache de tool response, no de respuesta final.**

Actualmente el flujo es:
```
Query -> Router LLM -> Tool call -> MCP response -> Synthesis LLM -> Respuesta
```

Los pasos caros son:
1. Router LLM: ~500ms, barato (poco output)
2. MCP response: ~200ms, gratis (DB query)
3. Synthesis LLM: ~2-10s, caro (genera respuesta larga)

Si pre-computamos la **respuesta del Synthesis LLM para la tool response del MCP**, eliminamos el paso 3 para cache hits. Pero el Router LLM sigue corriendo para entender la query.

Alternativa mas agresiva: pre-computar la **respuesta completa** para queries canonicas. "Quien es Keiko Fujimori" -> respuesta pre-armada. Esto elimina los 3 pasos.

### Senior MLE

Propongo un approach dual:

**Nivel 1: Cache de MCP responses (datos crudos)**
- Key: `cache:mcp:{tool}:{args_hash}`
- Value: La respuesta cruda del MCP (JSON de datos del candidato)
- Esto evita la llamada al MCP pero el LLM de sintesis sigue corriendo
- Ahorro: ~200ms por hit, pero el LLM de sintesis sigue costando

**Nivel 2: Cache de respuestas finales (pre-computadas)**
- Key: `cache:response:{query_hash}`
- Value: La respuesta conversacional final
- Esto evita TODO el pipeline
- Ahorro: 2-15s por hit

El Nivel 1 es el mismo cache de tool+args del debate 03. El Nivel 2 es la pre-computacion real.

Para el Nivel 2, necesitamos queries canonicas. Ejemplo:
- "Quien es {candidato}?" -> 36 perfiles
- "Comparame {A} con {B}" -> 45 comparaciones
- "Que proponen sobre {tema}?" -> 15 temas

### Junior MLE

Pero el Nivel 2 tiene un problema: la respuesta pre-computada suena generica. Si el usuario dice "que onda con keiko" (informal) y servimos una respuesta formal pre-computada, hay una desconexion de tono.

### AI Tech Lead

El tono es un problema real pero menor. Opciones:

1. **Ignorar:** El 95% de usuarios quiere la info, no el tono. Una respuesta bien escrita sirve para todos.
2. **Tone wrapper:** El pre-computado tiene los datos. Un LLM call barato (solo reescritura, sin tool calls) ajusta el tono en 200ms. Sigue siendo 10x mas rapido que el pipeline completo.
3. **Multiples versiones:** Pre-computar version formal e informal. Duplica el storage (de 286KB a 572KB -- irrelevante).

Recomiendo opcion 1 para MVP. Si los usuarios se quejan del tono, pasamos a opcion 2.

### Full Stack Lead

Desde UX: una respuesta instantanea con tono ligeramente formal es infinitamente mejor que una respuesta perfectamente informal que tarda 10 segundos. Los usuarios no se van a quejar del tono. Se van a quejar de la lentitud.

### Delivery Lead

Absolutamente de acuerdo. La velocidad ES la UX en un chatbot. Tono perfecto pero lento = mala UX. Tono generico pero instantaneo = buena UX.

### Staff Engineer

Para el formato de almacenamiento, propongo:

```json
{
  "content": "## Keiko Fujimori\nKeiko Sofía Fujimori Higuchi es la candidata...",
  "metadata": {
    "generated_at": "2026-03-30T03:00:00Z",
    "generator": "precompute_v1",
    "model": "gemini-2.0-flash",
    "source_query": "Quien es Keiko Fujimori?",
    "candidato_ids": [12],
    "type": "profile"
  }
}
```

El `content` es lo que se devuelve al usuario. El `metadata` es para debugging y monitoreo.

### Product Manager

Formato resuelto: respuesta completa pre-computada, tono neutral-informativo, metadata para debug. MVP sin ajuste de tono.

**Veredicto Ciclo 6:** ✅ Aprobado. Opcion 4 (respuesta completa para queries canonicas) con tono neutral.

---

## Ciclo 7 -- Que NO Pre-computar

### Codeforces Grandmaster

Tan importante como decidir que pre-computar es decidir que dejar on-demand. Analicemos queries por factibilidad de pre-computacion:

| Tipo de query | Ejemplo | Pre-computable? | Razon |
|---------------|---------|-----------------|-------|
| Perfil basico | "Quien es Keiko?" | SI | Finito (36), alta frecuencia |
| Comparacion top-10 | "Keiko vs Antauro" | SI | C(10,2)=45, alta frecuencia |
| Tema popular | "Propuestas de seguridad" | SI | 15 temas, alta frecuencia |
| Comparacion long-tail | "Candidato X vs Y" | NO | 630 pares, baja frecuencia individual |
| Query de logistica | "Donde voto?" | SI parcial | Depende de la ubicacion del usuario |
| Query de fiscalizacion | "Tiene sentencias?" | SI | Dato factico, 36 candidatos |
| Seguimiento conversacional | "Y que mas propone?" | NO | Depende del contexto previo |
| Opinion/analisis | "Quien va a ganar?" | NO | No es data factica |
| Congresistas | "Quien es X de Arequipa?" | NO (V1) | 1500 candidatos, baja frecuencia individual |
| Preguntas meta | "Que puedes hacer?" | SI | 1 respuesta estatica |

### Senior AI Engineer

La lista de "NO" revela algo importante: las queries dependientes de contexto (seguimiento conversacional) son inherentemente on-demand. No puedes pre-computar "y que mas propone?" porque depende de quien es "el/ella" en la conversacion.

Esto significa que el pre-compute solo aplica al **primer turno** de una conversacion o a queries autocontenidas. Estimemos que proporcion del trafico es eso:

- Primer turno: ~40% del total de queries (muchos usuarios hacen 1-2 preguntas y se van)
- Queries autocontenidas en turnos siguientes: ~20%
- Queries contextuales: ~40%

Del 60% autocontenible, el pre-compute cubre ~70% (las populares). Asi que el pre-compute cubre **~42% del trafico total**. No esta mal para un script de 11 centavos.

### Senior MLE

Para las queries de logistica ("donde voto"), depende de si el usuario dio su DNI o ubicacion. No es pre-computable en el sentido general. Pero podemos pre-computar las respuestas genericas: "Los locales de votacion se publican en X, puedes consultar con tu DNI en Y".

Para fiscalizacion ("tiene sentencias?"), es 100% pre-computable. Son datos facticos de 36 candidatos. 36 entries mas.

**Inventario final de pre-computados:**

| Tipo | Cantidad | Prioridad |
|------|----------|-----------|
| Perfiles presidenciales | 36 | MVP |
| Fiscalizacion (sentencias, hojas de vida) | 36 | MVP |
| Respuesta meta ("que puedes hacer") | 1 | MVP |
| Comparaciones top-10 pairwise | 45 | V2 |
| Busquedas tematicas (top 15 temas) | 15 | V2 |
| Logistica generica | 5 | V2 |
| Financiamiento de campana | 36 | V3 |

**MVP total: 73 entries.** Contra 231 originales. Mas acotado.

### Junior MLE

Con 73 entries en MVP, el costo se reduce aun mas:

- 73 x 2,800 tokens input promedio = 204K tokens -> $0.020
- 73 x 1,000 tokens output promedio = 73K tokens -> $0.029
- **Total MVP: $0.049** (menos de 5 centavos por batch)

### Junior Full Stack

Una pregunta del front: si servimos una respuesta pre-computada, debemos indicarle al usuario que es pre-computada? Tipo "respuesta rapida" o algun badge?

### AI Tech Lead

No. Absolutamente no. El usuario no debe saber ni importarle si la respuesta es pre-computada o generada on-demand. La magia del sistema es que sea transparente. Agregar un badge genera preguntas innecesarias ("por que esta es rapida y la otra no?") y reduce la confianza ("sera que la pre-computada es menos precisa?").

### Full Stack Lead

De acuerdo. Transparencia total. El frontend nunca sabra la diferencia. Solo vera que algunas respuestas llegan en 50ms y otras en 10s. Podemos agregar un typing indicator uniforme de 500ms para que todas las respuestas "se sientan" como que el bot esta pensando, aunque la pre-computada ya este lista.

### Delivery Lead

El typing indicator de 500ms es un buen detalle de UX. Evita el "uncanny valley" de una respuesta tan rapida que parece pre-grabada. 500ms se siente natural, como si el bot leyera la pregunta.

### Staff Engineer

Backlog de "NO pre-computar" que debe quedar documentado:

1. **Queries contextuales** -- siempre on-demand
2. **Queries con datos del usuario** (DNI, ubicacion) -- siempre on-demand
3. **Queries de opinion/prediccion** -- rechazar, no es el rol del bot
4. **Congresistas** -- on-demand en V1, evaluar pre-computar en V3 si hay demanda
5. **Comparaciones long-tail** -- on-demand, cache 24h

### Product Manager

Excelente. El scope esta bien definido. 73 entries en MVP. Lista clara de que NO tocar.

**Veredicto Ciclo 7:** ✅ Aprobado. Inventario final definido. Scope MVP = 73 entries.

---

## Ciclo 8 -- Implementacion del MVP

### Codeforces Grandmaster

Pseudocodigo del MVP completo:

```python
import asyncio
import hashlib
import json
from datetime import datetime

PRESIDENTIAL_CANDIDATES = [...]  # 36 nombres, from DB query
SEMAPHORE = asyncio.Semaphore(20)

async def generate_profile(candidate: dict, llm_client, redis_client):
    prompt = f"""Genera un perfil informativo del candidato presidencial:
    Nombre: {candidate['nombre']}
    Partido: {candidate['partido']}
    Datos: {json.dumps(candidate['datos'])}

    Formato: markdown, maximo 500 palabras, tono informativo neutral."""

    async with SEMAPHORE:
        response = await llm_client.generate(prompt)

    cache_key = build_cache_key("buscar_candidato", {"nombre": candidate['nombre']})
    entry = {
        "content": response,
        "metadata": {
            "generated_at": datetime.utcnow().isoformat(),
            "generator": "precompute_v1",
            "type": "profile"
        }
    }
    await redis_client.setex(cache_key, 7 * 86400, json.dumps(entry))

async def generate_fiscalizacion(candidate: dict, llm_client, redis_client):
    # Similar pero con datos de sentencias y hojas de vida
    ...

async def run_precompute():
    candidates = await db.fetch_presidential_candidates()

    tasks = []
    for c in candidates:
        tasks.append(generate_profile(c, llm, redis))
        tasks.append(generate_fiscalizacion(c, llm, redis))

    # +1 para query meta
    tasks.append(generate_meta_response(llm, redis))

    results = await asyncio.gather(*tasks, return_exceptions=True)

    success = sum(1 for r in results if not isinstance(r, Exception))
    failed = sum(1 for r in results if isinstance(r, Exception))

    print(f"Pre-computacion completada: {success} exitosos, {failed} fallidos")
    for i, r in enumerate(results):
        if isinstance(r, Exception):
            print(f"  Error en task {i}: {r}")
```

Complejidad: O(n) donde n = candidatos. Paralelismo limitado por semaforo. Tiempo estimado: <30 segundos.

### Senior AI Engineer

La funcion `build_cache_key` es la pieza mas critica. Debe generar **exactamente** la misma key que el gateway usa cuando un usuario hace la query on-demand. Esto significa que necesitamos entender como el gateway resuelve queries a tool calls.

En el gateway actual:
1. Usuario dice "quien es keiko"
2. Router LLM mapea a `buscar_candidato(nombre="Keiko Fujimori")` (preprocessor resuelve "keiko" -> "Keiko Fujimori")
3. Cache check: `cache:tool:buscar_candidato:{sha256(json.dumps({"nombre": "Keiko Fujimori"}, sort_keys=True))}`

El precompute debe usar **exactamente** el mismo `sha256(json.dumps({"nombre": "Keiko Fujimori"}, sort_keys=True))`. Esto es fragil. Si alguien cambia el formato del JSON dump en el gateway (ej: agrega espacios), todas las pre-computaciones se invalidan.

**Solucion robusta:** Extraer `build_cache_key` a una funcion utilidad documentada y testeada. En el MVP, duplicar la logica y agregar un test de contrato.

### Senior MLE

Para el lugar del codigo, propongo:

```
infovoto-infra/
├── scripts/
│   └── precompute/
│       ├── run.py              # entry point: python scripts/precompute/run.py
│       ├── generators.py       # generate_profile, generate_fiscalizacion, generate_meta
│       ├── cache_keys.py       # build_cache_key (duplicado del gateway, con test)
│       └── config.py           # TOP_N, temas, semaforo, Redis URL
```

En `infovoto-infra` porque es un script operacional, no parte de un servicio. Se corre con `make precompute`.

### Junior MLE

Tests que necesitamos:

```python
# test_precompute.py

def test_cache_key_format():
    """La key generada debe coincidir con el formato del gateway."""
    key = build_cache_key("buscar_candidato", {"nombre": "Keiko Fujimori"})
    assert key.startswith("cache:tool:buscar_candidato:")
    assert len(key.split(":")[-1]) == 64  # sha256 hex

def test_all_candidates_covered():
    """Todos los 36 presidenciales deben tener perfil generado."""
    candidates = fetch_presidential_candidates()
    assert len(candidates) == 36

def test_profile_not_empty():
    """Ningun perfil generado debe estar vacio."""
    for profile in generated_profiles:
        assert len(profile["content"]) > 100

def test_idempotent():
    """Correr precompute dos veces produce el mismo resultado."""
    run_precompute()
    keys_v1 = get_all_precompute_keys()
    run_precompute()
    keys_v2 = get_all_precompute_keys()
    assert keys_v1 == keys_v2
```

### AI Tech Lead

El test de idempotencia es interesante pero no trivial: las respuestas del LLM no son deterministicas. El contenido sera distinto pero las keys seran iguales. El test debe verificar **keys**, no **contenido**.

Apruebo la ubicacion en `infovoto-infra/scripts/precompute/`. El Makefile target:

```makefile
precompute:
	python scripts/precompute/run.py
```

### Full Stack Lead

Sin impacto en frontend. Aprobado.

### Delivery Lead

El `make precompute` debe tener output claro:

```
$ make precompute
[INFO] Conectando a PostgreSQL...
[INFO] Conectando a Redis...
[INFO] Cargando 36 candidatos presidenciales...
[INFO] Generando 36 perfiles...
[INFO] Generando 36 fichas de fiscalizacion...
[INFO] Generando 1 respuesta meta...
[INFO] Completado: 73/73 exitosos, 0 fallidos
[INFO] Tiempo total: 28s
[INFO] Costo estimado: $0.049
[INFO] Entries en Redis: 73 (TTL: 7 dias)
```

### Staff Engineer

Agregar flag `--dry-run` que muestre que haria sin ejecutar. Y `--force` que regenere todo incluso si ya existe en Redis (para forzar actualizacion).

```bash
make precompute              # solo genera lo que falta
make precompute-force        # regenera todo
make precompute-dry          # muestra plan sin ejecutar
```

### Product Manager

Implementacion clara, scope acotado, buena DX con dry-run y logging. Aprobado.

**Veredicto Ciclo 8:** ✅ Aprobado. MVP = script en infovoto-infra/scripts/precompute/, 73 entries, make target.

---

## Ciclo 9 -- Riesgos y Mitigaciones

### Codeforces Grandmaster

Enumeremos todos los failure modes:

| # | Riesgo | Probabilidad | Impacto | Mitigacion |
|---|--------|-------------|---------|-----------|
| 1 | Gemini API down durante precompute | Baja | Bajo (on-demand sigue funcionando) | Retry con backoff. Si falla, log y continuar. |
| 2 | Redis lleno | Muy baja (usamos 0.1% del espacio) | Alto (cache roto) | Alerta al 50% de capacidad |
| 3 | Cache key mismatch entre precompute y gateway | Media | Alto (pre-computados nunca se sirven) | Test de contrato obligatorio |
| 4 | Data stale post-cambio critico | Baja | Alto (info incorrecta al usuario) | `make invalidate-candidate` |
| 5 | Precompute genera respuesta incorrecta | Baja | Medio (info erronea temporal) | Review manual de samples post-precompute |
| 6 | Prompt del precompute diverge del prompt del gateway | Media | Medio (respuestas inconsistentes) | Documentar prompts, review periodico |
| 7 | Rate limit de Gemini durante precompute | Baja (231 calls << 1000 RPM) | Bajo (retry resuelve) | Semaforo + exponential backoff |
| 8 | DB no tiene data actualizada cuando corre precompute | Media | Medio (genera con data vieja) | Verificar `updated_at` antes de generar |

### Senior AI Engineer

El riesgo #3 (cache key mismatch) es el mas insidioso porque es silencioso. No da error, simplemente los pre-computados nunca se sirven y nadie se da cuenta. El sistema funciona "correctamente" pero 100% on-demand.

**Mitigacion reforzada:** Despues de cada precompute, verificar que al menos 5 queries representativas hacen cache hit. Un "smoke test" automatico.

```python
async def verify_precompute():
    test_queries = [
        "Quien es Keiko Fujimori",
        "Dime sobre Antauro Humala",
        "Informacion de Lopez Aliaga",
    ]
    hits = 0
    for q in test_queries:
        response = await gateway.process(q)
        if response.from_cache:
            hits += 1

    if hits < len(test_queries) * 0.8:
        raise Alert("Pre-computados no estan sirviendo. Posible key mismatch.")
```

### Senior MLE

El riesgo #6 (divergencia de prompts) es real a largo plazo. El gateway evoluciona su prompt de sintesis independientemente del precompute. En 3 meses, el tono/formato del precompute puede ser muy distinto del on-demand.

**Mitigacion:** El precompute debe usar el **mismo prompt** que el gateway para la fase de sintesis. Idealmente importado del mismo modulo. Dado que son repos separados, al menos documentar el prompt en un lugar comun.

### Junior MLE

Para el riesgo #5, propongo un check automatico post-precompute que verifique:

1. Ningun perfil menciona a un candidato equivocado (buscar nombre en el contenido)
2. Ningun perfil esta truncado (min 200 caracteres)
3. Ningun perfil contiene "no tengo informacion" o "no puedo responder"
4. Todos los perfiles estan en español

Son validaciones simples pero atrapan los errores mas comunes del LLM.

### AI Tech Lead

Agrego un riesgo que nadie menciono:

**Riesgo #9: El precompute se convierte en tech debt.**

Si el precompute tiene su propia logica de generacion de respuestas, separada del gateway, terminamos manteniendo dos pipelines paralelos. Cada cambio en el gateway requiere un cambio en el precompute. Esto escala mal.

**Mitigacion:** En V2, el precompute debe llamar al gateway directamente (HTTP POST a /api/chat con queries canonicas) en vez de tener su propio pipeline. Asi, el precompute es solo un "warmup inteligente" que precarga el cache del gateway.

### Full Stack Lead

El riesgo #9 es el mas importante a largo plazo. Concuerdo: el precompute debe ser un wrapper alrededor del gateway, no un pipeline paralelo. MVP puede ser pipeline propio por simplicidad, pero V2 debe refactorear a llamar al gateway.

### Delivery Lead

Riesgo adicional desde el lado de usuarios:

**Riesgo #10: Los pre-computados no cubren la query real.**

Precomputamos "Quien es Keiko Fujimori?" pero el usuario pregunta "keiko tiene antecedentes?". Son queries diferentes que llaman a tools diferentes. La pre-computacion tiene un techo natural de cobertura (~42% segun estimacion del ciclo 7).

Mitigacion: No prometer cobertura total. Aceptar que el 58% sera on-demand + cache. Optimizar el on-demand en paralelo (debate 03 de cache inteligente).

### Staff Engineer

Tabla final de riesgos con acciones concretas:

| Riesgo | Accion | Responsable | Cuando |
|--------|--------|-------------|--------|
| Key mismatch | Test de contrato + smoke test | Dev | Pre-merge |
| Data stale | make invalidate-candidate | Ops | Manual, cuando se detecte |
| Pipeline diverge | Refactorear a llamar gateway en V2 | Dev | Post-MVP |
| Respuesta incorrecta | Validaciones automaticas post-precompute | Dev | Cada ejecucion |
| Rate limit | Semaforo + backoff | Dev | Implementacion |

### Product Manager

Riesgos bien mapeados. Ninguno es blocker para el MVP. Los mitigamos progresivamente.

**Veredicto Ciclo 9:** ✅ Aprobado. Riesgos aceptables con mitigaciones claras.

---

## Ciclo 10 -- Plan Final de Ejecucion

### Codeforces Grandmaster

Resumen algoritmico de la decision:

**Problema:** Optimizar latencia y costo para un chatbot con data cuasi-estatica.
**Solucion:** Pre-computar respuestas para queries de alta frecuencia al momento del scraping.
**Complejidad:** O(n) donde n = candidatos presidenciales. Tiempo: O(n/semaforo * latencia_LLM).
**Espacio:** O(n * tamano_respuesta) en Redis. Para n=73: 160 KB.
**Costo:** $0.049 por ejecucion. $0.20/mes.

Es una optimizacion trivial en complejidad y costo con impacto significativo en UX y costos operacionales.

### Senior AI Engineer

**Decisiones tecnicas finales:**

1. **Donde vive el codigo:** `infovoto-infra/scripts/precompute/`
2. **Como se ejecuta:** `make precompute`
3. **Que pre-computa (MVP):** 36 perfiles + 36 fiscalizacion + 1 meta = 73 entries
4. **Donde almacena:** Redis, mismas keys que el cache del gateway
5. **TTL:** 7 dias
6. **Modelo:** Gemini 2.0 Flash (mismo que el gateway)
7. **Paralelismo:** asyncio.Semaphore(20)
8. **Validacion:** Checks automaticos post-ejecucion

### Senior MLE

**Roadmap:**

| Fase | Contenido | Entries | Costo/batch | Timeline |
|------|-----------|---------|-------------|----------|
| MVP | Perfiles + fiscalizacion + meta | 73 | $0.049 | Semana 1 |
| V2 | + Comparaciones top-10 + temas | 73+45+15 = 133 | $0.113 | Semana 3 |
| V3 | + Financiamiento + logistica + congresistas top-50 | ~250 | $0.35 | Semana 6 |
| V4 | Refactorear a llamar gateway (eliminar pipeline paralelo) | ~250 | ~$0.35 | Semana 8 |

### Junior MLE

**Tests a escribir:**

1. `test_cache_key_contract` -- keys del precompute == keys del gateway
2. `test_all_candidates_covered` -- 36 presidenciales
3. `test_content_not_empty` -- todas las entries tienen contenido >100 chars
4. `test_content_correct_candidate` -- cada perfil menciona al candidato correcto
5. `test_no_error_responses` -- ningun contenido dice "no puedo"
6. `test_redis_ttl` -- TTL = 7 dias (604800 segundos)
7. `test_idempotent_keys` -- ejecutar 2 veces genera mismas keys

### Junior Full Stack

**Impacto en frontend:** Ninguno. Cero cambios. Solo agregar el typing indicator de 500ms en algun futuro PR para mejorar la percepcion de velocidad.

### AI Tech Lead

**Revision arquitectural final:**

El approach es correcto: "compute at write time, serve at read time" aplicado con pragmatismo. No pre-computamos todo (over-engineering), solo lo de alta frecuencia. No construimos un pipeline complejo, solo un script. No reemplazamos el on-demand, lo complementamos.

La decision de usar Redis como unico storage (sin una tabla adicional en PostgreSQL) es la correcta para MVP. Redis es efimero y eso esta bien: si se pierde, el on-demand sigue funcionando. No hay data critica en los pre-computados.

**Aprobacion arquitectural: SI.**

### Full Stack Lead

Nada que objetar. La solucion es minimalista, efectiva, y no impacta ningun otro componente. Es el tipo de optimizacion que deberia hacerse siempre: bajo costo, alto impacto, bajo riesgo.

### Delivery Lead

**Checklist dia de elecciones:**

```
D-7:  [ ] Ultimo scraping completo verificado
D-7:  [ ] make precompute ejecutado, 73/73 exitosos
D-7:  [ ] Smoke test: top 5 queries responden desde cache
D-3:  [ ] Verificar que Redis tiene las 73 entries (make precompute-status)
D-1:  [ ] Re-run make precompute para refrescar TTLs
D-1:  [ ] Verificar que no hay candidatos excluidos no reflejados
D-0:  [ ] 04:00 AM: make precompute final
D-0:  [ ] 05:00 AM: Smoke test final
D-0:  [ ] 06:00 AM: Apertura. Sistema listo.
```

### Staff Engineer

**Consideraciones operacionales finales:**

1. El script debe funcionar sin Docker (direct connection a Redis/PostgreSQL)
2. Variables de entorno: `REDIS_URL`, `DATABASE_URL`, `GEMINI_API_KEY` desde `.env.secrets`
3. Logging a stdout con timestamps (capturado por `make precompute > logs/precompute.log 2>&1`)
4. Exit code 0 si >90% exitosos, exit code 1 si <90% (para integracion con CI)
5. Agregar `precompute` como step opcional en el Makefile, NO como parte de `make up`

### Product Manager

**Decision final consolidada:**

Lo que SI hacemos:
- Pre-computar 73 entries (perfiles + fiscalizacion + meta) en Redis
- Script en infovoto-infra con make target
- TTL 7 dias, refresh semanal
- Invalidacion manual para emergencias
- Smoke test post-ejecucion

Lo que NO hacemos:
- Pre-computar comparaciones pairwise de todos los candidatos
- Pre-computar congresistas (V3)
- Versionado automatico (V3)
- Pipeline complejo o DAG orchestrator
- Cambios en gateway o frontend

**Costo total:** $0.049/ejecucion, $0.20/mes
**Ahorro estimado dia-D:** $21.46
**Esfuerzo de implementacion:** 4-8 horas
**ROI primer mes:** 40x

**Veredicto Ciclo 10:** ✅ Aprobado unanimemente.

---

## VEREDICTO FINAL

### Decision: IMPLEMENTAR Opcion E (Hibrido Selectivo) con scope MVP

**Que pre-computar:**

| Tipo | Cantidad | Prioridad | Costo/batch |
|------|----------|-----------|-------------|
| Perfiles presidenciales | 36 | MVP | $0.019 |
| Fiscalizacion (sentencias/hojas de vida) | 36 | MVP | $0.019 |
| Respuesta meta (que puedes hacer) | 1 | MVP | $0.001 |
| Comparaciones top-10 pairwise | 45 | V2 | $0.040 |
| Busquedas tematicas (15 temas) | 15 | V2 | $0.034 |
| **TOTAL MVP** | **73** | -- | **$0.049** |
| **TOTAL V2** | **133** | -- | **$0.113** |

**Que NO pre-computar (on-demand + cache):**

- Comparaciones long-tail (C(36,2)-45 = 585 pares)
- Queries contextuales (seguimiento conversacional)
- Queries con datos del usuario (DNI, ubicacion)
- Congresistas y otros cargos (V3)
- Comparaciones de todos los candidatos (C(1500,2) = imposible)

**Numeros clave:**

| Metrica | Valor |
|---------|-------|
| Costo por ejecucion MVP | $0.049 |
| Costo mensual (4 ejecuciones) | $0.20 |
| Storage en Redis | 160 KB (0.06% del tier gratuito) |
| Tiempo de ejecucion | ~30 segundos |
| Cobertura estimada del trafico | ~42% |
| Ahorro dia de elecciones | $21.46 |
| Mejora de latencia (cache hit) | 10s -> 50ms (200x) |
| Esfuerzo de implementacion | 4-8 horas |
| ROI primer mes | 40x |

**Principio guia:** "Compute at write time, serve at read time" -- pero solo para lo que vale la pena. Pre-computar lo popular, cachear lo medio, on-demand lo raro.

**Prioridad de implementacion:**
1. MVP: Script + make target + 73 entries (Semana 1)
2. V2: Comparaciones + temas + smoke test automatico (Semana 3)
3. V3: Congresistas top-50 + invalidacion avanzada (Semana 6)
4. V4: Refactorear precompute para llamar al gateway directamente (Semana 8)
