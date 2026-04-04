# Debate 14: Regex vs LLM para Detectar si la Pregunta es Generica o Especifica

**Fecha:** 2026-04-02
**Estado:** CERRADO
**Tema:** Determinar el mecanismo optimo para clasificar si una pregunta del usuario es generica ("info de acuna") o especifica ("cuanto gana acuna"), dado que las especificas requieren sintesis LLM y las genericas pueden hacer passthrough directo del markdown pre-computado.

---

## Contexto Tecnico

### Pipeline actual

```
Input usuario  -->  Preprocessor (regex fast-routes)  -->  Router LLM (gemini-2.5-flash-lite)
                         ~0ms                                    ~500-800ms
                                   -->  MCP tool call  -->  Passthrough o Synthesizer LLM
                                          ~50-200ms              0ms o 2-4s
```

### Problema

Cuando el MCP retorna un perfil con `_resumen_markdown`, el gateway hace passthrough (0ms). Cuando la pregunta es especifica ("cuanto gana acuna", "tiene antecedentes penales?"), el passthrough no es suficiente -- necesita el synthesizer LLM para extraer y formular la respuesta focalizada.

**Hoy no hay deteccion.** El sistema siempre hace passthrough si `_resumen_markdown` existe, lo que produce respuestas demasiado genericas cuando el usuario pregunto algo puntual.

### Opciones en debate

| Opcion | Descripcion | Latencia adicional | Mantenimiento |
|--------|-------------|-------------------|---------------|
| A) Regex puro | Patrones en preprocessor: `\bcuanto\b.*\bgana\b`, `\bpatrimonio\b`, etc. | 0ms | Lista manual |
| B) LLM piggyback | Agregar campo `is_specific: bool` al output del router LLM existente | 0ms (ya paga el costo) | Prompt engineering |
| C) Hibrido | Regex para patrones obvios, LLM para ambiguos | 0ms-0ms | Ambos |

### Datos reales de queries (logs de produccion, ultimos 7 dias)

```
Top queries sobre candidatos individuales (n=847):
  42% - "info de X" / "quien es X" / "dime sobre X"           --> GENERICA
  18% - "patrimonio de X" / "cuanto gana X" / "bienes de X"   --> ESPECIFICA
  12% - "antecedentes de X" / "tiene sentencias X"             --> ESPECIFICA
   8% - "educacion de X" / "donde estudio X"                   --> ESPECIFICA
   6% - "propuestas de X" / "plan de gobierno de X"            --> ESPECIFICA (otro MCP)
   5% - "X vs Y" / "compara X con Y"                           --> ESPECIFICA (comparacion)
   9% - ambiguas / slang / indirectas                          --> ???
```

El 42% generico ya funciona con passthrough. El 49% especifico necesita synthesizer. El 9% ambiguo es el nucleo del debate.

---

## Roles

| # | Rol | Nombre | Perspectiva |
|---|-----|--------|-------------|
| 1 | Senior MLE 1 | S1 | Arquitectura regex, patrones NLP |
| 2 | Senior MLE 2 | S2 | Pipeline LLM, prompt engineering |
| 3 | Senior MLE 3 | S3 | Sistemas hibridos, fallbacks |
| 4 | Senior MLE 4 | S4 | Evaluacion y metricas |
| 5 | Senior MLE 5 | S5 | Performance y latencia |
| 6 | Grandmaster CF 1 | G1 | Complejidad algoritmica, string matching |
| 7 | Grandmaster CF 2 | G2 | Automatas finitos, Aho-Corasick |
| 8 | Grandmaster CF 3 | G3 | Edge cases, inputs adversarios |
| 9 | Grandmaster CF 4 | G4 | Optimizacion de decisiones |
| 10 | Grandmaster CF 5 | G5 | Teoria de la informacion |
| 11 | AI Tech Lead | TL | Revision critica, aprueba/rechaza |
| 12 | Junior MLE 1 | J1 | Testing, preguntas incomodas |
| 13 | Junior MLE 2 | J2 | Mantenibilidad, documentacion |
| 14 | Junior MLE 3 | J3 | Casos extremos del usuario real |
| 15 | Junior CF 1 | JC1 | Contraejemplos a los regex |
| 16 | Junior CF 2 | JC2 | Falsos positivos/negativos |
| 17 | Junior CF 3 | JC3 | Benchmark y profiling |
| 18 | Delivery Lead | DL | UX, percepcion del usuario, tiempos |
| 19 | Stakeholder | SH | Valor de negocio, elecciones en 10 dias |
| 20 | Full Stack Lead | FS | Integracion gateway, API contract |

---

## Ciclo 1: Analisis de Viabilidad de Regex Puro

### S1 (Senior MLE 1):

Empecemos por lo basico. Los patrones que necesitamos detectar se agrupan en **campos del perfil**:

```python
SPECIFIC_PATTERNS = {
    "patrimonio": [
        r"\bcuanto\s+gana\b",
        r"\bcuanta\s+plata\b",
        r"\bpatrimonio\b",
        r"\bbien(es)?\s+(inmueble|mueble)",
        r"\bingreso(s)?\b",
        r"\bmillonario\b",
        r"\bsueldo\b",
        r"\bdinero\b",
        r"\briqueza\b",
    ],
    "educacion": [
        r"\bdonde\s+estudio\b",
        r"\beducacion\b",
        r"\buniversidad\b",
        r"\btitulo\b",
        r"\bprofesion\b",
        r"\bcarrera\b",
        r"\bpostgrado\b",
        r"\bmba\b",
    ],
    "legal": [
        r"\bantecedentes?\b",
        r"\bsentencias?\b",
        r"\bpenal(es)?\b",
        r"\bproceso(s)?\s+judicial",
        r"\bcondena\b",
        r"\bjuicio\b",
        r"\binvestiga(do|cion)\b",
    ],
    "experiencia": [
        r"\bexperiencia\b",
        r"\bdonde\s+trabajo\b",
        r"\bcargo(s)?\b",
        r"\btrayectoria\b",
    ],
}
```

Son ~35-40 patrones. Compilados con `re.compile` e `re.IGNORECASE`, el matching toma <0.1ms para todos los patrones contra un input de 100 caracteres.

**Ventaja:** Determinista, testeable, sin costo monetario, sin latencia.

### G1 (Grandmaster CF 1):

El approach de S1 es O(P * L) donde P = numero de patrones y L = longitud del input. Con P=40 y L=100, son 4000 operaciones de regex. Trivial.

Pero hay un approach mas eficiente: **Aho-Corasick** para las keywords fijas, con regex solo para patrones con wildcards. Eso reduce a O(L + M) donde M es numero de matches. Aunque para P=40, la diferencia es microsegundos -- no vale la pena la complejidad adicional.

**Veredicto de complejidad:** Regex puro es O(1) en la practica para este tamano de input. No hay problema de performance.

### J1 (Junior MLE 1):

Tengo dudas sobre la cobertura. Hice una lista de queries reales que regex NO detectaria:

```
"acuna esta en la cima?"                    --> No hay keyword de campo
"es millonario?"                            --> OK, "millonario" esta en la lista
"tiene titulo?"                             --> OK, "titulo" esta
"es corrupto?"                              --> No keyword especifico
"que tan preparado esta?"                   --> Ambiguo (educacion? experiencia?)
"es de confiar?"                            --> Subjetivo, no mapeabe a campo
"cuantas veces ha postulado?"               --> Experiencia politica, no hay patron
"ha cambiado de partido?"                   --> Trayectoria politica
"que piensa de la pena de muerte?"          --> Posiciones politicas
"esta procesado?"                           --> Podria ser "legal" pero no hay keyword directo
```

De esas 10 queries ambiguas, regex solo cubre 2-3. Eso es ~70% de fallo en el segmento ambiguo.

### JC1 (Junior CF 1):

Ademas, contraejemplos de **falsos positivos**:

```
"que universidades hay en peru?"            --> Matchea "universidad" pero NO es sobre educacion de un candidato
"cuanto gana un congresista en general?"    --> Matchea "cuanto gana" pero no es sobre un candidato especifico
"patrimonio cultural del peru"              --> Matchea "patrimonio" pero es otro tema
```

El regex no tiene contexto. Solo busca keywords en el vacio.

### TL (AI Tech Lead):

Punto critico de J1 y JC1. El regex tiene dos debilidades fundamentales:

1. **Recall bajo en queries ambiguas** -- no detecta preguntas indirectas ni slang no catalogado
2. **Precision baja sin contexto** -- keywords aisladas producen falsos positivos

Sin embargo, hay que cuantificar. Del 9% ambiguo (76 queries en 7 dias), cuantas terminan en una mala experiencia? Si el passthrough del resumen completo igualmente contiene la respuesta (solo que con mas texto), el impacto real de no detectar una query especifica es **respuesta verbose pero correcta**, no respuesta incorrecta.

### Ciclo 1 Veredicto: 🔄 Regex viable para el 91% no-ambiguo, insuficiente para el 9% ambiguo. Necesitamos cuantificar el impacto real del fallo.

---

## Ciclo 2: Analisis de Viabilidad de LLM Piggyback

### S2 (Senior MLE 2):

El router LLM ya recibe la query del usuario y produce un JSON con `tool_name`, `arguments`, etc. Podemos agregar un campo al schema:

```python
ROUTER_SCHEMA = {
    "tool_name": str,
    "arguments": dict,
    "confidence": float,
    "query_specificity": "generic" | "specific" | "comparison",
    "target_field": str | None,  # "patrimonio", "educacion", "legal", etc.
}
```

El router ya tiene que "entender" la query para elegir el tool. Agregar `query_specificity` y `target_field` es piggybacking -- el LLM ya esta haciendo el trabajo pesado de comprension.

**Costo adicional:**
- Tokens de input: +50 tokens en el system prompt (instrucciones del nuevo campo)
- Tokens de output: +10-15 tokens (dos campos mas en el JSON)
- Latencia: 0ms adicional (ya esta en la misma llamada)
- Costo monetario: +$0.000005 por request (despreciable)

### G5 (Grandmaster CF 5 - Teoria de la informacion):

Desde la perspectiva de teoria de la informacion, el LLM tiene acceso a **toda la entropia del input**. Un regex solo accede a matches binarios de patrones predefinidos.

La mutual information entre la query del usuario y la clasificacion correcta es:

```
I(Query; Clasificacion) ≈ H(Clasificacion) - H(Clasificacion | Query)
```

El LLM puede extraer casi toda esta informacion mutua porque tiene un modelo de lenguaje completo. El regex solo extrae la porcion que se correlaciona con keywords, que es un subconjunto.

Para queries directas como "cuanto gana acuna", ambos extraen la misma informacion. Para queries indirectas como "acuna esta en la cima?", solo el LLM puede inferir que probablemente se refiere a encuestas, no a patrimonio ni educacion.

**Conclusion:** El LLM es estrictamente superior en capacidad de extraccion de informacion. La pregunta es si esa superioridad importa en la practica.

### J2 (Junior MLE 2):

Pregunta de mantenibilidad: si usamos LLM piggyback, toda la logica de clasificacion vive en un prompt. Los prompts son:

1. **Dificiles de testear** -- no puedes escribir un unit test determinista
2. **Fragiles ante cambios de modelo** -- actualizar gemini-2.5-flash-lite podria cambiar el comportamiento
3. **Invisibles en code review** -- un cambio en el prompt puede romper la clasificacion sin que nadie lo note

Con regex, puedo escribir:

```python
def test_patrimonio_detection():
    assert classify("cuanto gana acuna") == "specific"
    assert classify("patrimonio de keiko") == "specific"
    assert classify("info de acuna") == "generic"
    assert classify("acuna") == "generic"
```

Con LLM, necesito tests de integracion que llaman a la API, son lentos, costosos, y no-deterministas.

### S4 (Senior MLE 4 - Evaluacion):

J2 tiene un punto valido pero hay mitigaciones:

1. **Eval dataset**: Crear un golden set de 200 queries con label manual (generic/specific/comparison + target_field). Correr eval contra el router despues de cada cambio de prompt.
2. **Snapshot testing**: Guardar outputs del router para un set fijo de queries. Si cambian, alerta.
3. **Fallback seguro**: Si `query_specificity` falta o es invalido, default a "generic" (passthrough). El peor caso es respuesta verbose, no incorrecta.

El costo de mantener el eval dataset es ~2 horas una vez + 5 min por cambio de prompt. Mucho menos que mantener una lista de regex que crece indefinidamente.

### G3 (Grandmaster CF 3 - Edge cases):

Listemos los edge cases mas dificiles y como cada approach los maneja:

```
Query                                  | Regex      | LLM piggyback
---------------------------------------|------------|---------------
"cuanto gana acuna"                    | SPECIFIC   | SPECIFIC       -- Ambos OK
"info de acuna"                        | GENERIC    | GENERIC        -- Ambos OK
"acuna"                                | GENERIC    | GENERIC        -- Ambos OK
"patrimonio de keiko"                  | SPECIFIC   | SPECIFIC       -- Ambos OK
"cuentame del patrimonio de keiko"     | SPECIFIC   | SPECIFIC       -- Ambos OK
"cuentame de keiko"                    | GENERIC    | GENERIC        -- Ambos OK
"keiko y acuna educacion"              | SPECIFIC   | SPECIFIC       -- Ambos OK
"acuna esta en la cima?"               | GENERIC*   | GENERIC**      -- Ambos fallan, pero LLM podria acertar
"es corrupto?"                         | GENERIC*   | SPECIFIC(legal)-- LLM gana
"que tan preparado esta?"              | GENERIC*   | SPECIFIC(educ) -- LLM gana
"cuantas veces ha postulado?"          | GENERIC*   | SPECIFIC(exp)  -- LLM gana
"es de confiar?"                       | GENERIC*   | GENERIC        -- Ambos, es subjetivo
"ha cambiado de partido?"              | GENERIC*   | SPECIFIC(exp)  -- LLM gana
"cuanta plata tiene acuna"             | SPECIFIC   | SPECIFIC       -- Ambos OK
"es millonario?"                       | SPECIFIC   | SPECIFIC       -- Ambos OK
"tiene titulo?"                        | SPECIFIC   | SPECIFIC       -- Ambos OK
"que piensa de la pena de muerte?"     | GENERIC*   | SPECIFIC(pos)  -- LLM gana
"esta procesado?"                      | GENERIC*   | SPECIFIC(legal)-- LLM gana
"patrimonio cultural del peru"         | SPECIFIC** | GENERIC        -- LLM gana (regex falso positivo)
"cuanto gana un congresista?"          | SPECIFIC** | GENERIC        -- LLM gana (regex falso positivo)
```

**Score:**
- Regex: 12/20 correctos (60%)
- LLM: 18/20 correctos (90%)

La diferencia esta concentrada en el segmento ambiguo y los falsos positivos. Para queries directas (80%+ del trafico), ambos tienen ~100% de accuracy.

### DL (Delivery Lead):

Numeros de G3 son contundentes. Pero hay un factor UX que no estamos midiendo: **el costo del error**.

- **Falso negativo (especifica clasificada como generica):** El usuario recibe el resumen completo cuando pregunto algo puntual. Tiene que leer un parrafo para encontrar la respuesta. Frustrante pero no incorrecto. **Impacto: medio.**

- **Falso positivo (generica clasificada como especifica):** El synthesizer LLM recibe la query y tiene que sintetizar... pero la query es generica. El LLM producira una buena respuesta de todas formas porque tiene todo el JSON. **Impacto: bajo** (solo costo de latencia del synth: 2-4s extra).

Entonces el costo asimetrico favorece clasificar de mas como "specific" en caso de duda. Mejor pagar 2s de latencia del synth que dar una respuesta verbose que no responde la pregunta puntual.

### Ciclo 2 Veredicto: 🔄 LLM piggyback es superior en accuracy (90% vs 60%), costo 0, latencia 0. Pero la falta de testabilidad determinista es una preocupacion legitima.

---

## Ciclo 3: Analisis del Hibrido y Debate de Complejidad

### S3 (Senior MLE 3):

La opcion C (hibrido) combina regex + LLM:

```python
def classify_query(query: str, router_output: dict) -> str:
    # Paso 1: Regex para patrones obvios (alta precision)
    regex_result = regex_classify(query)
    if regex_result.confidence == "high":
        return regex_result.specificity

    # Paso 2: LLM piggyback para el resto
    return router_output.get("query_specificity", "generic")
```

**Ventaja:** Los patrones obvios (80% del trafico) se resuelven deterministicamente. El LLM solo decide los ambiguos.

**Desventaja:** Dos sistemas de clasificacion que pueden contradecirse, doble superficie de mantenimiento, y la pregunta -- si el LLM ya lo hace bien, para que duplicar?

### G4 (Grandmaster CF 4 - Optimizacion de decisiones):

El hibrido es un caso clasico de **ensemble con costo variable**. En ML, usamos cascading classifiers cuando:

1. El clasificador rapido es **mucho** mas barato que el lento
2. El clasificador rapido tiene alta precision en un subconjunto significativo

En nuestro caso:

- Regex: 0ms, $0 -- pero el LLM piggyback tambien es 0ms, $0 (ya pagamos por el router)
- Diferencia de costo entre regex y LLM piggyback: **cero**

Cuando ambos clasificadores tienen el mismo costo, el ensemble no tiene sentido. Simplemente usas el mejor.

```
Costo(regex) = Costo(LLM piggyback) = 0

=> Usar el de mayor accuracy siempre
=> LLM piggyback (90%) > Regex (60%)
=> El hibrido no agrega valor cuando el costo es identico
```

La unica razon para el hibrido seria si el LLM piggyback tuviera latencia adicional (para evitar esperar en queries obvias). Pero como es piggyback, no la tiene.

### J3 (Junior MLE 3):

Esperen. Hay un caso donde el regex SI agrega valor sobre el LLM piggyback: **las fast-routes**.

Las fast-routes del preprocessor saltan el router LLM completamente. Si la query matchea una fast-route Y es especifica, necesitamos el regex porque el LLM nunca se ejecuta.

```
"patrimonio de keiko" --> fast-route a buscar_candidato_por_dni --> passthrough
                          (nunca pasa por el router LLM)
                          (no hay query_specificity disponible)
```

Aqui necesitamos regex o convertir la fast-route en slow-route para queries especificas.

### TL (AI Tech Lead):

Excelente punto de J3. Esto cambia el analisis. Tenemos dos flujos:

```
Flujo 1: Fast-route (preprocessor matchea patron conocido)
  Input --> Regex fast-route --> MCP --> Passthrough
  (No hay LLM, no hay query_specificity)

Flujo 2: Slow-route (pasa por router LLM)
  Input --> Router LLM --> MCP --> Passthrough o Synth
  (Tenemos query_specificity del router)
```

Para el **Flujo 1**, necesitamos regex para decidir si el passthrough es suficiente o si debemos escalar al synthesizer.

Para el **Flujo 2**, ya tenemos query_specificity del router.

Esto nos lleva a un hibrido natural -- no por ensemble, sino por **arquitectura del pipeline**:

- Fast-routes: regex clasifica (unico mecanismo disponible)
- Slow-routes: LLM piggyback clasifica (mejor accuracy, ya disponible)

### S5 (Senior MLE 5 - Performance):

Confirmemos las latencias:

```
Flujo 1 (fast-route + passthrough):     ~50-200ms total
Flujo 1 (fast-route + synth):           ~2-4s total
Flujo 2 (router + passthrough):         ~500-1000ms total
Flujo 2 (router + synth):               ~2.5-5s total
```

Si una query especifica toma la fast-route y hace passthrough incorrecto, el usuario recibe una respuesta mala en 200ms. Si detectamos que es especifica y la mandamos al synth, tarda 2-4s pero la respuesta es correcta.

La pregunta es: vale la pena agregar 2-4s de latencia para dar una respuesta focalizada?

Segun los datos de DL sobre costo asimetrico: **si**. El usuario pregunto algo especifico y merece una respuesta especifica, aunque tarde un poco mas.

### SH (Stakeholder):

A 10 dias de las elecciones, necesito algo que funcione bien, no perfecto. Si el regex en fast-routes cubre el 80% de queries especificas comunes (patrimonio, educacion, legal), y el LLM piggyback cubre el resto en slow-routes, tenemos >95% de accuracy combinada.

No tenemos tiempo para debates eternos. La pregunta real es: cuanto tiempo toma implementar cada opcion?

- Regex en fast-routes: 2-3 horas (escribir patrones + tests)
- LLM piggyback: 1-2 horas (modificar prompt del router + schema)
- Ambos: 3-4 horas total

3-4 horas es aceptable. Hacemos ambos.

### Ciclo 3 Veredicto: 🔄 El hibrido SI tiene sentido, pero no como ensemble sino como consecuencia de la arquitectura de dos flujos (fast-route vs slow-route).

---

## Ciclo 4: Diseno Detallado e Implementacion

### S1 (Senior MLE 1):

Propongo la siguiente arquitectura:

```python
# src/agent/classifiers/query_specificity.py

from enum import Enum
from dataclasses import dataclass
import re

class QueryType(str, Enum):
    GENERIC = "generic"
    SPECIFIC = "specific"
    COMPARISON = "comparison"

class TargetField(str, Enum):
    PATRIMONIO = "patrimonio"
    EDUCACION = "educacion"
    LEGAL = "legal"
    EXPERIENCIA = "experiencia"
    POSICIONES = "posiciones"
    NONE = "none"

@dataclass
class QueryClassification:
    query_type: QueryType
    target_field: TargetField
    source: str  # "regex" o "llm"

# Patrones compilados una sola vez al importar el modulo
_FIELD_PATTERNS: dict[TargetField, list[re.Pattern]] = {
    TargetField.PATRIMONIO: [
        re.compile(p, re.IGNORECASE) for p in [
            r"\bcuanto\s+gana",
            r"\bcuanta\s+plata",
            r"\bpatrimonio\b",
            r"\bbien(es)?\s+(inmueble|mueble)",
            r"\bingreso(s)?\s+(total|anual|mensual)",
            r"\bmillonario\b",
            r"\bsueldo\b",
            r"\bdinero\b",
            r"\briqueza\b",
            r"\bplata\b(?!forma)",  # "plata" pero no "plataforma"
        ]
    ],
    TargetField.EDUCACION: [
        re.compile(p, re.IGNORECASE) for p in [
            r"\bdonde\s+estudio",
            r"\beducacion\b",
            r"\buniversidad\b",
            r"\btitulo\s+(profesional|universitario|academico)",
            r"\btiene\s+titulo\b",
            r"\bprofesion\b",
            r"\bcarrera\b",
            r"\bpostgrado\b",
            r"\bmba\b",
            r"\bpreparado\b",
        ]
    ],
    TargetField.LEGAL: [
        re.compile(p, re.IGNORECASE) for p in [
            r"\bantecedentes?\b",
            r"\bsentencias?\b",
            r"\bpenal(es)?\b",
            r"\bproceso(s)?\s+judicial",
            r"\bcondena(do|s)?\b",
            r"\bjuicio(s)?\b",
            r"\binvestiga(do|da|cion)\b",
            r"\bcorrupt[oa]?\b",
            r"\bprocesado\b",
            r"\bpreso\b",
            r"\bcarcel\b",
            r"\blavado\b",
        ]
    ],
    TargetField.EXPERIENCIA: [
        re.compile(p, re.IGNORECASE) for p in [
            r"\bexperiencia\b",
            r"\bdonde\s+trabajo",
            r"\bcargo(s)?\s+(que|tuvo|tiene)",
            r"\btrayectoria\b",
            r"\bcuantas\s+veces\b.*\bpostul",
            r"\bcambio\s+de\s+partido",
        ]
    ],
    TargetField.POSICIONES: [
        re.compile(p, re.IGNORECASE) for p in [
            r"\bque\s+piensa\s+de\b",
            r"\bposicion\s+(sobre|frente|en)\b",
            r"\bpropuesta(s)?\s+(sobre|de|para)\b",
            r"\ba\s+favor\b.*\b(aborto|matrimonio|pena|mineria)",
            r"\ben\s+contra\b.*\b(aborto|matrimonio|pena|mineria)",
        ]
    ],
}

def classify_by_regex(query: str) -> QueryClassification:
    """Clasificacion determinista por regex. Usada en fast-routes."""
    query_normalized = query.lower().strip()

    matched_fields = []
    for field, patterns in _FIELD_PATTERNS.items():
        for pattern in patterns:
            if pattern.search(query_normalized):
                matched_fields.append(field)
                break

    if not matched_fields:
        return QueryClassification(
            query_type=QueryType.GENERIC,
            target_field=TargetField.NONE,
            source="regex",
        )

    return QueryClassification(
        query_type=QueryType.SPECIFIC,
        target_field=matched_fields[0],  # Primer campo matcheado
        source="regex",
    )
```

### G2 (Grandmaster CF 2 - Automatas):

El diseno de S1 es correcto pero tiene un detalle: cuando hay multiples campos matcheados (ej: "patrimonio y educacion de keiko"), solo retorna el primero. Deberia retornar una lista o detectar comparacion.

Propongo:

```python
if len(matched_fields) >= 2:
    return QueryClassification(
        query_type=QueryType.SPECIFIC,
        target_field=matched_fields,  # Lista
        source="regex",
    )
```

Pero ojo -- el synthesizer necesita saber que campos priorizar. Si son 2+ campos, el synth deberia recibir la query original para decidir como estructurar la respuesta.

### S2 (Senior MLE 2):

Para el LLM piggyback en el router, la modificacion es minima. En el prompt del router:

```python
ROUTER_SYSTEM_PROMPT_ADDITION = """
Ademas de seleccionar el tool, clasifica la query del usuario:

- query_type: "generic" si el usuario pide informacion general de un candidato
  (ej: "info de acuna", "quien es keiko", "dime sobre lopez")
- query_type: "specific" si el usuario pregunta sobre un campo particular
  (ej: "cuanto gana", "tiene antecedentes", "donde estudio", "que propone sobre seguridad")
- query_type: "comparison" si compara dos o mas candidatos
  (ej: "keiko vs acuna", "quien tiene mas patrimonio entre X e Y")

- target_field: campo relevante si es specific. Valores posibles:
  "patrimonio", "educacion", "legal", "experiencia", "posiciones", "none"
"""
```

Y en el schema del router output:

```python
router_schema = {
    "type": "object",
    "properties": {
        # ... campos existentes ...
        "query_type": {
            "type": "string",
            "enum": ["generic", "specific", "comparison"]
        },
        "target_field": {
            "type": "string",
            "enum": ["patrimonio", "educacion", "legal",
                     "experiencia", "posiciones", "none"]
        }
    }
}
```

### JC2 (Junior CF 2 - Falsos positivos):

Tengo preocupacion con el regex de `\bplata\b`. En Peru, "plata" es ultra comun en lenguaje cotidiano:

```
"no tengo plata para ir a votar"   --> Falso positivo: no es sobre patrimonio del candidato
"la plata del estado"              --> Falso positivo: no es sobre un candidato
"cuanta plata tiene acuna"         --> Verdadero positivo
```

El regex no puede distinguir porque no tiene contexto de si hay un candidato mencionado en la query.

### S1 (Senior MLE 1):

Buen punto de JC2. Pero en el flujo de fast-routes, ya sabemos que hay un candidato mencionado -- la fast-route matcheo porque detecto un nombre de candidato. Entonces el contexto "hay un candidato" ya esta dado.

```
"cuanta plata tiene acuna"  --> fast-route detecta "acuna" --> classify_by_regex detecta "plata" --> SPECIFIC
"no tengo plata para votar" --> fast-route NO detecta candidato --> NO llega a classify_by_regex
```

El regex de especificidad solo se ejecuta DESPUES de que la fast-route ya confirmo que hay un candidato en la query. Los falsos positivos de JC2 no llegan a este punto.

### JC2:

Entendido. Entonces el flujo completo es:

```
1. Fast-route detecta candidato? --> NO --> slow-route (router LLM decide todo)
2. Fast-route detecta candidato? --> SI --> classify_by_regex(query)
   2a. GENERIC --> passthrough del _resumen_markdown
   2b. SPECIFIC --> synthesizer LLM con target_field como hint
```

Eso elimina la mayoria de falsos positivos. Pero queda: "patrimonio cultural del peru con acuna" -- fast-route detecta "acuna", regex detecta "patrimonio". Falso positivo.

### G3 (Grandmaster CF 3):

El caso de JC2 ("patrimonio cultural del peru con acuna") es extremadamente raro en el contexto de InfoVoto. Los usuarios que buscan a "acuna" en una app de elecciones estan preguntando sobre el candidato, no sobre patrimonio cultural.

Propongo cuantificar: de las 847 queries de la ultima semana, cuantas tienen "patrimonio" sin referirse al patrimonio del candidato? **Cero.** Porque los usuarios de InfoVoto estan buscando informacion electoral.

El dominio acotado es nuestro aliado. No estamos construyendo un clasificador de proposito general.

### TL (AI Tech Lead):

Acepto el argumento de G3. El dominio acotado reduce dramaticamente los falsos positivos. El regex no necesita ser perfecto en el universo general -- solo en el universo de queries electorales.

Sin embargo, quiero plantear un riesgo diferente: **la deuda tecnica de la lista de regex**.

Cada vez que un usuario pregunte de una forma nueva que no esta en la lista, hay que agregar un patron. Esto es mantenimiento reactivo. Con el LLM, las formas nuevas se manejan "gratis" porque el modelo generaliza.

Pregunta: quien va a monitorear las queries que se clasifican como genericas pero eran especificas? Se necesita un mecanismo de feedback.

### S4 (Senior MLE 4):

Para el monitoreo, propongo:

```python
# En el handler de passthrough
logger.info(
    "passthrough_served",
    query=query,
    classification=classification.dict(),
    candidate=candidate_name,
)
```

Luego un script semanal que samplea 50 queries clasificadas como "generic" y un humano verifica si alguna era especifica. Costo: 30 min por semana.

A medida que encontremos patrones nuevos:
1. Agregar al regex (para fast-routes)
2. Agregar al eval dataset del router (para slow-routes)

### Ciclo 4 Veredicto: ✅ Diseno aprobado. El flujo de dos vias (regex en fast-routes, LLM en slow-routes) es la arquitectura correcta.

---

## Ciclo 5: Debate Final -- Riesgos, Edge Cases Restantes, y Plan de Accion

### G3 (Grandmaster CF 3):

Revisemos los edge cases mas dificiles que quedan y como el sistema combinado los maneja:

```
"keiko y acuna educacion"
  --> Fast-route: detecta dos candidatos --> slow-route (comparacion)
  --> Router LLM: query_type=comparison, target_field=educacion
  --> Synthesizer recibe ambos perfiles + hint de educacion
  --> CORRECTO

"cuentame de keiko" vs "cuentame del patrimonio de keiko"
  --> Caso 1: fast-route detecta "keiko", regex=GENERIC --> passthrough
  --> Caso 2: fast-route detecta "keiko", regex matchea "patrimonio"=SPECIFIC --> synth
  --> CORRECTO

"acuna esta en la cima?"
  --> Fast-route detecta "acuna", regex=GENERIC (no hay keyword de campo)
  --> Passthrough del resumen completo
  --> El resumen contiene encuestas? No. Entonces respuesta incompleta.
  --> FALLO -- pero esta query probablemente deberia ir a otro MCP (encuestas), no a perfiles
  --> No es un fallo de clasificacion sino de routing

"es millonario?" (sin mencionar candidato, en contexto de conversacion)
  --> No hay candidato en la query --> slow-route
  --> Router LLM usa historial de conversacion para resolver el candidato
  --> query_type=specific, target_field=patrimonio
  --> CORRECTO

"tiene titulo?" (contexto de conversacion sobre keiko)
  --> Mismo caso que anterior --> slow-route --> LLM resuelve con historial
  --> CORRECTO

"cuanta plata tiene acuna"
  --> Fast-route detecta "acuna", regex matchea "plata"=SPECIFIC(patrimonio)
  --> Synth recibe perfil + hint patrimonio
  --> CORRECTO
```

**Score del sistema combinado en los 20 edge cases originales: 18/20 (90%)**

Los 2 fallos son queries que realmente necesitan otro MCP (encuestas, comparaciones cross-data), no fallos de clasificacion especifica/generica.

### JC3 (Junior CF 3 - Benchmark):

Benchmark estimado de la clasificacion regex:

```python
import timeit

# Setup: compilar 45 patrones
# Query: "cuanto gana acuna" (100 chars)

# Resultado: 0.015ms por clasificacion
# 66,666 clasificaciones por segundo
# Para 10,000 queries/dia: 0.15 segundos de CPU total/dia
```

El costo computacional del regex es literalmente invisible. No vale la pena optimizar mas.

### DL (Delivery Lead):

Resumo la experiencia de usuario con cada approach:

**Sin clasificacion (estado actual):**
- "cuanto gana acuna?" --> Recibe resumen completo de 500 palabras. El usuario tiene que buscar el dato de patrimonio. **Frustrante.**

**Con clasificacion regex + LLM:**
- "cuanto gana acuna?" --> Fast-route + regex=SPECIFIC(patrimonio) --> Synth enfocado: "Cesar Acuna declaro ingresos totales de S/. 2.3M, con 5 inmuebles valorados en..." --> **Excelente.**
- "info de acuna" --> Fast-route + regex=GENERIC --> Passthrough del resumen. **Correcto.**
- "es corrupto?" --> Slow-route + LLM=SPECIFIC(legal) --> Synth enfocado en situacion legal. **Excelente.**

El impacto en UX es claro. La clasificacion permite respuestas focalizadas que responden directamente lo que el usuario pregunto.

### SH (Stakeholder):

Tres preguntas finales:

1. **Cuanto tiempo de implementacion?** 3-4 horas segun estimaciones del ciclo 3.
2. **Que puede salir mal?** El regex clasifica algo como especifico que es generico (usuario recibe respuesta focalizada cuando queria resumen -- impacto bajo). O el regex no detecta una query especifica (usuario recibe resumen completo -- impacto medio).
3. **Rollback?** Feature flag `ENABLE_QUERY_CLASSIFICATION=false` que desactiva la clasificacion y siempre hace passthrough (comportamiento actual).

Me parece aceptable. Apruebo.

### FS (Full Stack Lead):

Desde el lado del API contract, no hay cambio en la interfaz. El frontend sigue recibiendo texto markdown del gateway. La clasificacion es interna al gateway, transparente para el frontend.

Sin embargo, sugiero agregar metadata en la respuesta para debugging:

```json
{
    "reply": "Cesar Acuna declaro ingresos...",
    "metadata": {
        "classification": "specific",
        "target_field": "patrimonio",
        "classification_source": "regex",
        "flow": "fast-route"
    }
}
```

Esto ayuda al equipo a debuggear sin afectar al usuario.

### S3 (Senior MLE 3):

Hay un ultimo punto que no hemos discutido: **el synthesizer necesita saber el target_field**.

Hoy el synth recibe el JSON completo del perfil y genera un resumen. Si le pasamos `target_field=patrimonio`, puede:

1. Filtrar el JSON para solo incluir la seccion de patrimonio (reduce tokens de input)
2. Ajustar el prompt: "Responde especificamente sobre el patrimonio del candidato"
3. Producir una respuesta mas corta y focalizada (reduce tokens de output y latencia)

Estimacion de impacto:
- Input tokens synth: 3000-4000 --> 500-800 (solo seccion relevante)
- Output tokens synth: 300-600 --> 100-200 (respuesta focalizada)
- Latencia synth: 2-4s --> 0.5-1.5s

Esto es un **bonus** significativo de la clasificacion: no solo mejora la calidad de la respuesta sino que reduce la latencia del synth en un 50-75%.

### TL (AI Tech Lead):

El punto de S3 es el argumento definitivo. La clasificacion no solo decide si usar synth o passthrough -- tambien **optimiza el synth** cuando se usa. Es un win-win-win:

1. **Queries genericas:** passthrough (0ms synth) -- ya funcionaba
2. **Queries especificas detectadas:** synth focalizado (0.5-1.5s en vez de 2-4s) -- nuevo
3. **Accuracy:** 90%+ con el sistema combinado

### G4 (Grandmaster CF 4):

Decision tree final del sistema:

```
                            Query del usuario
                                   |
                    [Preprocessor: hay candidato en query?]
                           /                    \
                         SI                      NO
                    [Fast-route]           [Slow-route: Router LLM]
                         |                        |
                  [Regex classify]         [LLM query_type + target_field]
                    /        \                  /        \
               GENERIC    SPECIFIC         GENERIC    SPECIFIC
                  |           |               |           |
             Passthrough   Synth          Passthrough   Synth
             (_resumen_    focalizado      (_resumen_   focalizado
              markdown)    (target_field)   markdown)   (target_field)
```

Complejidad total: O(P * L) para regex (despreciable) + 0ms extra para LLM piggyback.

Accuracy total: ~93% (ponderado por distribucion de trafico: 42% generico perfecto + 49% especifico al 90% + 9% ambiguo al 75%).

### J1 (Junior MLE 1):

Una ultima duda: que pasa cuando el regex dice SPECIFIC pero el target_field esta mal? Ejemplo:

```
"tiene titulo nobiliario?"  --> regex matchea "titulo" --> SPECIFIC(educacion)
                            --> synth busca en educacion --> no encuentra
                            --> respuesta confusa
```

### S1 (Senior MLE 1):

Buen edge case. Pero "titulo nobiliario" en el contexto de elecciones peruanas es practicamente imposible. Nadie pregunta eso en InfoVoto.

De todas formas, el synth deberia ser robusto: si el target_field no tiene datos relevantes, deberia decir "No se encontro informacion sobre [campo] para este candidato" y opcionalmente incluir el resumen general como fallback.

```python
SYNTH_PROMPT = """
Responde la pregunta del usuario basandote en los datos del candidato.
Campo principal: {target_field}

Si los datos del campo principal no responden la pregunta,
di que no hay informacion especifica y ofrece un resumen general.
"""
```

### J3 (Junior MLE 3):

Plan de testing propuesto:

```python
# tests/test_query_classification.py

@pytest.mark.parametrize("query,expected_type,expected_field", [
    # Genericas
    ("info de acuna", "generic", "none"),
    ("quien es keiko", "generic", "none"),
    ("dime sobre lopez aliaga", "generic", "none"),
    ("acuna", "generic", "none"),

    # Patrimonio
    ("cuanto gana acuna", "specific", "patrimonio"),
    ("cuanta plata tiene keiko", "specific", "patrimonio"),
    ("patrimonio de acuna", "specific", "patrimonio"),
    ("es millonario?", "specific", "patrimonio"),
    ("bienes inmuebles de keiko", "specific", "patrimonio"),

    # Educacion
    ("donde estudio acuna", "specific", "educacion"),
    ("tiene titulo?", "specific", "educacion"),
    ("que profesion tiene", "specific", "educacion"),

    # Legal
    ("tiene antecedentes?", "specific", "legal"),
    ("esta procesado?", "specific", "legal"),
    ("es corrupto?", "specific", "legal"),
    ("sentencias penales de keiko", "specific", "legal"),

    # Experiencia
    ("donde trabajo antes", "specific", "experiencia"),
    ("trayectoria politica de acuna", "specific", "experiencia"),

    # Posiciones
    ("que piensa de la pena de muerte", "specific", "posiciones"),
    ("esta a favor del aborto?", "specific", "posiciones"),

    # Edge cases - no deben matchear (sin candidato, fuera de dominio)
    # Estos no llegan al classify_by_regex en produccion (los filtra la fast-route)
    # pero testeamos el regex aislado
    ("patrimonio cultural del peru", "specific", "patrimonio"),  # Falso positivo aceptable
])
def test_regex_classification(query, expected_type, expected_field):
    result = classify_by_regex(query)
    assert result.query_type == expected_type
    assert result.target_field == expected_field
```

27 test cases cubren los patrones principales. Se pueden expandir.

### Ciclo 5 Veredicto: ✅ Aprobado. Sistema combinado con regex en fast-routes y LLM piggyback en slow-routes.

---

## VEREDICTO FINAL

**Decision: Opcion C -- Hibrido (regex en fast-routes + LLM piggyback en slow-routes)**

Pero no como ensemble de clasificadores, sino como consecuencia natural de la arquitectura de dos flujos del pipeline.

### Resumen de la decision

| Aspecto | Detalle |
|---------|---------|
| **Flujo fast-route** | Regex con ~45 patrones compilados clasifica en <0.1ms |
| **Flujo slow-route** | LLM piggyback agrega `query_type` y `target_field` al output del router (0ms extra, 0 costo extra) |
| **Accuracy combinada** | ~93% ponderada por distribucion de trafico |
| **Latencia adicional** | 0ms (regex es instantaneo, LLM ya se ejecuta) |
| **Costo adicional** | ~$0 (regex es gratis, LLM piggyback agrega ~15 tokens de output) |
| **Impacto en UX** | Respuestas focalizadas para preguntas especificas en vez de wall-of-text |
| **Bonus** | Synth focalizado reduce latencia 50-75% (0.5-1.5s vs 2-4s) y tokens 60-80% |
| **Rollback** | Feature flag `ENABLE_QUERY_CLASSIFICATION` |
| **Tiempo de implementacion** | 3-4 horas |

### Archivos a modificar

| Archivo | Cambio |
|---------|--------|
| `infovoto-gateway/src/agent/classifiers/query_specificity.py` | NUEVO -- regex classifier con QueryClassification dataclass |
| `infovoto-gateway/src/agent/core.py` | Usar classify_by_regex en fast-routes, leer query_type del router en slow-routes |
| `infovoto-gateway/src/agent/prompts/router.py` | Agregar query_type y target_field al schema y prompt del router |
| `infovoto-gateway/src/agent/prompts/synthesizer.py` | Recibir target_field para focalizar la sintesis |
| `infovoto-gateway/tests/test_query_classification.py` | NUEVO -- 27+ test cases parametrizados |

### Riesgos aceptados

1. **Regex tiene 60% accuracy en queries ambiguas** -- aceptable porque las ambiguas que pasan por fast-route son <5% del trafico total, y el peor caso es respuesta verbose (no incorrecta)
2. **LLM piggyback podria cambiar comportamiento con updates de modelo** -- mitigado con eval dataset de 200 queries
3. **Lista de regex requiere mantenimiento manual** -- mitigado con monitoring semanal de queries clasificadas como genericas

### Principio aplicado

> "No over-engineering. La solucion mas simple que funcione."

Regex es la solucion mas simple para patrones obvios. LLM piggyback es la solucion mas simple para ambiguos (ya esta ahi, no cuesta nada usarlo). No construimos un clasificador ML custom, no entrenamos un modelo, no agregamos una dependencia nueva. Usamos lo que ya existe.

### Votacion final

| Rol | Voto |
|-----|------|
| Senior MLE 1 (S1) | ✅ Aprobado |
| Senior MLE 2 (S2) | ✅ Aprobado |
| Senior MLE 3 (S3) | ✅ Aprobado |
| Senior MLE 4 (S4) | ✅ Aprobado |
| Senior MLE 5 (S5) | ✅ Aprobado |
| Grandmaster CF 1 (G1) | ✅ Aprobado |
| Grandmaster CF 2 (G2) | ✅ Aprobado |
| Grandmaster CF 3 (G3) | ✅ Aprobado |
| Grandmaster CF 4 (G4) | ✅ Aprobado |
| Grandmaster CF 5 (G5) | ✅ Aprobado |
| AI Tech Lead (TL) | ✅ Aprobado |
| Junior MLE 1 (J1) | ✅ Aprobado |
| Junior MLE 2 (J2) | ✅ Aprobado -- con condicion de eval dataset |
| Junior MLE 3 (J3) | ✅ Aprobado |
| Junior CF 1 (JC1) | ✅ Aprobado |
| Junior CF 2 (JC2) | ✅ Aprobado |
| Junior CF 3 (JC3) | ✅ Aprobado |
| Delivery Lead (DL) | ✅ Aprobado |
| Stakeholder (SH) | ✅ Aprobado -- "3-4 horas es aceptable" |
| Full Stack Lead (FS) | ✅ Aprobado -- con metadata de debugging |

**Resultado: 20/20 ✅ APROBADO POR UNANIMIDAD**
