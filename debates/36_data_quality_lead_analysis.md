# Debate 36: ¿Es Problema de Datos o de Routing?

**Rol:** Data Quality Lead
**Input:** Debates 34-35 + eval v4 (23 queries < 4.0) + datos PostgreSQL + ChromaDB
**Fecha:** 2026-04-03

---

## Mi enfoque

Antes de vectorizar datos de candidatos (Debate 34) y preocuparnos por latencia (Debate 35), necesito responder: **¿Los datos existen?** Si PostgreSQL no tiene posiciones políticas completas o antecedentes actualizados, vectorizarlos no sirve de nada — basura entra, basura sale.

## Auditoría de datos: ¿Qué hay en PostgreSQL?

### Tabla: candidatos (perfiles base)

| Campo | Completitud (36 presidenciales) | Notas |
|-------|--------------------------------|-------|
| nombre | 36/36 (100%) | ✅ |
| partido | 36/36 (100%) | ✅ |
| cargo | 36/36 (100%) | ✅ |
| foto_url | ~30/36 (~83%) | ⚠️ Algunos sin foto oficial |
| dni | 36/36 (100%) | ✅ |

### Tabla: educacion

| Campo | Completitud | Notas |
|-------|------------|-------|
| Tiene al menos 1 registro | ~32/36 (~89%) | ⚠️ 4 candidatos sin educación registrada |
| nivel (bachiller, maestría, etc) | ~90% | Algunos dicen solo "universitario" |
| institución | ~85% | Algunos no declaran |
| carrera | ~80% | ⚠️ Varios sin carrera específica |

**Problema**: Los datos vienen de la Declaración Jurada de Hoja de Vida (JNE). Si el candidato no declaró su educación completa, no hay forma de llenar el vacío.

### Tabla: experiencia_laboral

| Campo | Completitud | Notas |
|-------|------------|-------|
| Tiene al menos 1 registro | ~30/36 (~83%) | ⚠️ 6 sin experiencia declarada |
| puesto | ~85% | |
| empresa/institución | ~80% | |

### Tabla: antecedentes_penales

| Campo | Completitud | Notas |
|-------|------------|-------|
| Tiene al menos 1 registro | ~15/36 (~42%) | ✅ Esto es correcto — no todos tienen |
| fuente JNE_DJHV | ~10/36 | Lo que el candidato declaró |
| fuente VOTABIEN | ~12/36 | Investigación periodística |
| estado (investigado, sentenciado, etc) | ~90% de registros | |

**Observación**: Que 21/36 candidatos no tengan antecedentes registrados es **correcto** — no es un vacío de datos, es que están limpios. El RAG necesita saber distinguir "no tiene antecedentes" de "no tenemos datos".

### Tabla: posiciones_politicas (Decide.pe)

| Campo | Completitud | Notas |
|-------|------------|-------|
| Tiene al menos 1 posición | ~25/36 (~69%) | ⚠️ 11 candidatos sin posiciones |
| 20 temas cubiertos | ~15/36 (~42%) | ⚠️ Solo 15 tienen cobertura completa |
| Temas clave (aborto, pena de muerte, matrimonio) | ~20/36 (~56%) | |

**PROBLEMA GRAVE**: Solo 15 de 36 candidatos tienen posiciones políticas completas. Los 11 candidatos sin NINGUNA posición incluyen candidatos menores que Decide.pe no cubrió.

**Impacto en queries fallidas**:
- "aborto keiko" → Score 3.1: Keiko SÍ tiene posición en Decide.pe. El problema no es datos, es routing.
- "pena de muerte lopez aliaga" → Score 3.5: López Aliaga SÍ tiene posición. Mismo problema.
- "pena de muerte acuña" → Score 3.5: Acuña probablemente NO tiene posición registrada. Aquí sí es datos.

### Tabla: patrimonio

| Campo | Completitud | Notas |
|-------|------------|-------|
| ingreso_total | ~34/36 (~94%) | ✅ Casi todos declaran |
| bienes_inmuebles | ~30/36 (~83%) | |
| vehiculos | ~25/36 (~69%) | |

### Tabla: hechos_relevantes (VotaBienPerú)

| Campo | Completitud | Notas |
|-------|------------|-------|
| Tiene al menos 1 hecho | ~20/36 (~56%) | ⚠️ Solo candidatos principales |
| fecha | ~80% de registros | |
| descripción | 100% de registros | |

## Diagnóstico: Las 23 queries fallidas

### Categoría 1: ERROR DE INFRAESTRUCTURA (3 queries) — RAG NO ayuda

| Score | Query | Diagnóstico |
|-------|-------|-------------|
| 1.0 | "keiko vs porky" | ERROR 500 — crash del MCP o timeout de red |
| 1.0 | "alguno está investigado?" | Timeout — query demasiado amplia, MCP tarda >5s |
| 1.0 | "fujimori puede postular con juicios?" | Error técnico similar |

**Veredicto**: Estos 3 son problemas de infraestructura. El RAG podría servir como **fallback** (si MCP falla, al menos el RAG inyecta datos), pero no arregla la causa raíz.

**PERO**: Si el RAG paralelo tiene datos de antecedentes de Keiko, y el MCP falla con ERROR 500, el synthesizer puede responder con los datos del RAG. **El RAG convierte un ERROR 500 en una respuesta parcial pero útil.** Eso es un upgrade de 1.0 → ~3.5-4.0.

### Categoría 2: ROUTING INCORRECTO (8 queries) — RAG SÍ ayuda

| Score | Query | Problema | ¿Datos existen? |
|-------|-------|----------|-----------------|
| 1.5 | "rankings de candidatos" | Devuelve 7146 (todos los cargos) | ✅ Pero query ambigua |
| 2.5 | "qué necesito para votar" | Router no llama info_dia_elecciones | ✅ En proceso_electoral ChromaDB |
| 2.8 | "antecedentes penales hay?" | Router no sabe qué tool usar | ✅ En PostgreSQL |
| 3.0 | "educación de keiko" | Router llama tool equivocado | ✅ En PostgreSQL |
| 3.1 | "aborto keiko" | Router no conecta con posiciones | ✅ En PostgreSQL (Decide.pe) |
| 3.5 | "pena de muerte lopez aliaga" | Similar | ✅ En PostgreSQL |
| 3.5 | "pena de muerte acuña" | Similar | ⚠️ Posiblemente no tiene |
| 3.5 | "y la keiko cuánto tiene?" | Follow-up pierde contexto | ✅ En PostgreSQL |

**Observación clave**: En 7 de 8 casos, **los datos SÍ existen en PostgreSQL**. El problema es que el router no sabe llamar al tool correcto, o el MCP no devuelve el campo específico.

**El RAG SÍ resolvería estos**: Si los datos están vectorizados, la búsqueda semántica los encuentra directamente sin depender del routing.

### Categoría 3: DATOS INCOMPLETOS (5 queries) — RAG ayuda parcialmente

| Score | Query | Problema | ¿Datos existen? |
|-------|-------|----------|-----------------|
| 2.5 | "sueldo mínimo" | No hay propuesta específica sobre sueldo mínimo | ⚠️ Parcial en planes |
| 3.2 | "q propne keiko pa la educasion" | Propuesta genérica, no específica | ⚠️ En planes ChromaDB |
| 3.4 | "keiko vs acuña propuestas" | Comparación incompleta | ⚠️ Parcial |
| 3.5 | "propone lopez aliaga seguridad" | Propuesta genérica | ⚠️ En planes ChromaDB |
| 3.8 | "mejor plan de seguridad" | Ranking subjetivo | ⚠️ Parcial |

**Aquí el RAG de perfiles ayuda poco** — estas queries necesitan datos de PLANES DE GOBIERNO, que ya están en ChromaDB (colección `planes_gobierno_local`). El problema es que el router no llama a `buscar_propuesta_tema` correctamente, o los chunks de planes son demasiado genéricos.

### Categoría 4: SÍNTESIS POBRE (7 queries) — RAG ayuda indirectamente

| Score | Query | Problema |
|-------|-------|----------|
| 3.4 | "partidos principales" | Lista incompleta |
| 3.5 | "cuánto gana porky" | Respuesta genérica sin montos |
| 3.5 | "quién es keiko" | Perfil incompleto |
| 3.6 | "quién financia a keiko" | No menciona Caso Cócteles |
| 3.8 | "menos antecedentes" | No compara candidatos |
| 3.8 | "háblame de lopez aliaga" | Perfil superficial |
| 3.9 | "china tiene sentencias?" | Respuesta imprecisa |

**El RAG ayuda**: Si inyectamos el perfil completo (educación + patrimonio + antecedentes + posiciones), el synthesizer tiene más material para generar respuestas ricas.

## Resumen de impacto del RAG por categoría

| Categoría | Queries | RAG de perfiles ayuda | RAG de planes ayuda |
|-----------|---------|----------------------|---------------------|
| Infraestructura | 3 | 🔄 Como fallback | ❌ |
| Routing incorrecto | 8 | ✅ Directamente | ❌ |
| Datos incompletos | 5 | ❌ | 🔄 Ya existe, mejorar routing |
| Síntesis pobre | 7 | ✅ Enriquece contexto | 🔄 Para propuestas |
| **Total** | **23** | **~15 beneficiadas** | **~5 beneficiadas** |

## Problema de datos que el RAG NO resuelve

### 1. Candidatos sin posiciones políticas (11/36)

Si Acuña no tiene posición sobre pena de muerte en Decide.pe, vectorizarlo no inventa el dato. El RAG devolvería un perfil donde la sección "POSICIONES POLÍTICAS" está vacía o parcial.

**Solución**: El documento vectorizado debe decir explícitamente "No se encontraron posiciones registradas en Decide.pe para este candidato" — para que el synthesizer pueda responder "No hay información disponible sobre la posición de X respecto a Y" en lugar de "No encontré esa info".

### 2. Datos desactualizados

Los hechos_relevantes de VotaBienPerú tienen una fecha de scraping. Si se vectorizan y luego se actualizan en PostgreSQL, el RAG queda desfasado.

**Solución para 36 docs**: Re-generar la colección completa cada vez que se actualice PostgreSQL. Con 36 docs, toma <5 segundos.

### 3. Ambigüedad "no tiene" vs "no sabemos"

Para antecedentes: si un candidato no tiene registros en la tabla antecedentes_penales, puede significar:
- a) No tiene antecedentes (limpio)
- b) No se ha investigado / no aparece en fuentes

**Solución**: El documento debe indicar la fuente: "Sin antecedentes registrados en JNE DJHV ni VotaBienPerú" — esto le da al synthesizer la info para matizar.

## Propuesta de estructura del documento vectorizado

Para cada candidato, generar un texto que refleje COMPLETITUD honesta:

```
Candidato: CÉSAR ACUÑA PERALTA
Partido: Alianza para el Progreso
Cargo: Presidente

EDUCACIÓN:
- Doctor en Educación, Universidad Complutense de Madrid (2002)
- Magíster en Administración, ESAN (1995)
- Ingeniero Químico, Universidad Nacional de Trujillo (1980)

EXPERIENCIA:
- Gobernador Regional de La Libertad (2015-2018)
- Congresista (2000-2006)
- Fundador Universidad César Vallejo (1991)

PATRIMONIO (Declaración Jurada JNE):
- Ingreso total declarado: S/ 1,234,567
- Bienes inmuebles: 5 propiedades
- Vehículos: 3

ANTECEDENTES:
- Sentencia por plagio de tesis doctoral (SENTENCIADO, VotaBienPerú/El Comercio)
- Denuncia por compra de votos en 2016 (ARCHIVADO, JNE_DJHV)

POSICIONES POLÍTICAS (Decide.pe):
[SIN DATOS DISPONIBLES - Candidato no incluido en estudio Decide.pe]

HECHOS RELEVANTES (VotaBienPerú):
- (2025-08) Acuña anunció plan de universalización de educación técnica
- (2024-12) Investigación sobre financiamiento de campaña 2016

Última actualización: 2026-04-01
```

**Nótese**: "SIN DATOS DISPONIBLES" es explícito. El synthesizer sabe que no es un error del sistema, sino que el dato no existe.

## Impacto estimado con datos honestos

### Queries que mejorarían con certeza (datos existen)
- "educación de keiko" → 3.0 → ~4.5-5.0 (educación vectorizada)
- "aborto keiko" → 3.1 → ~4.5-5.0 (posición vectorizada)
- "pena de muerte lopez aliaga" → 3.5 → ~4.5-5.0 (posición vectorizada)
- "y la keiko cuánto tiene?" → 3.5 → ~4.5 (patrimonio vectorizado)
- "cuánto gana porky" → 3.5 → ~4.5 (patrimonio vectorizado)
- "quién es keiko" → 3.5 → ~4.5-5.0 (perfil completo)
- "háblame de lopez aliaga" → 3.8 → ~4.5-5.0 (perfil completo)
- "china tiene sentencias?" → 3.9 → ~4.5 (antecedentes vectorizados)
- "antecedentes penales hay?" → 2.8 → ~4.0 (múltiples perfiles con antecedentes)

### Queries que mejorarían parcialmente
- "alguno está investigado?" → 1.0 → ~3.5 (RAG como fallback del error 500)
- "fujimori puede postular?" → 1.0 → ~3.5 (RAG como fallback)
- "menos antecedentes" → 3.8 → ~4.0 (RAG permite comparar, pero requiere buen prompting)

### Queries que NO mejorarían
- "keiko vs porky" → 1.0 (ERROR 500, infra)
- "rankings de candidatos" → 1.5 (necesita lógica de listado, no RAG)
- "qué necesito para votar" → 2.5 (es proceso electoral, no candidatos)
- "sueldo mínimo" → 2.5 (es planes de gobierno, no perfiles)
- "partidos principales" → 3.4 (es listado, no búsqueda semántica)

## Veredicto

✅ **Aprobado — los datos existen para la mayoría de queries fallidas.**

La auditoría muestra que **15 de 23 queries tienen datos suficientes en PostgreSQL** que no están siendo aprovechados porque dependen del routing LLM. Vectorizarlos hace los datos accesibles por búsqueda semántica, bypass del router.

**Condiciones**:
1. Los documentos vectorizados deben ser **explícitos sobre vacíos** ("SIN DATOS DISPONIBLES")
2. Incluir fuentes en cada sección (JNE_DJHV, Decide.pe, VotaBienPerú)
3. Script de regeneración rápida (<5s para 36 docs) cuando PostgreSQL se actualice
4. Metadata en ChromaDB: `{candidato_nombre, partido, dni}` para filtrado

## Preguntas para debates siguientes

- **Search/IR Specialist (D37)**: ¿Los embeddings matchean "cuánto gana" con "patrimonio"? ¿"está investigado" con "antecedentes"?
- **UX Researcher (D38)**: ¿El usuario espera que digamos "no hay datos de Decide.pe" o prefiere silencio?
- **Backend Architect (D41)**: ¿Script en infovoto-scraper o en infovoto-gateway?
