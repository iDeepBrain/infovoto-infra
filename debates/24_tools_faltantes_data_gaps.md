# Debate 24: Tools Faltantes y Data Gaps en los MCPs

**Rol:** Data Engineer
**Input:** Debates 20-23 (NLP, UX, QA, Prompt Engineer) + MCPs actuales
**Fecha:** 2026-04-03

---

## Contexto

El Prompt Engineer (debate 23) propuso mejorar el router prompt, pero pregunta: ¿los tools existentes pueden responder las queries que fallan? El QA Lead (debate 22) identificó 3 queries donde "no existe tool/data":

| Score | Query | Lo que falta |
|-------|-------|-------------|
| 3.4 | "cuánto ha gastado cada candidato en su campaña" | No hay MCP de gasto de campaña |
| 3.6 | "quién financia a keiko" | No hay MCP de financiamiento de campaña |
| 3.4 | "cuáles son los partidos principales" | No hay tool que agrupe por partido |

Además, 2 queries de routing fallido dependen de que los tools existentes funcionen correctamente:

| Query | Tool que debería usarse | ¿Funciona? |
|-------|------------------------|-------------|
| "qué estudió lopez aliaga" | `buscar_candidato_por_nombre` → educación en perfil | ✅ SÍ, educación está en el perfil |
| "qué propone lopez aliaga para la seguridad" | `buscar_propuesta_tema(tema="seguridad")` | ❓ NECESITA VERIFICAR |

## Inventario de MCPs actuales

Los 5 MCPs conectados (según health endpoint):

| MCP | Tools | Datos |
|-----|-------|-------|
| **infovoto-perfiles** | `buscar_candidato_por_nombre`, `buscar_candidato_por_dni`, `listar_candidatos_region` | DJHV: educación, experiencia, patrimonio, posiciones (Decide.pe), situación legal resumida |
| **infovoto-planes-gobierno** | `buscar_propuesta_tema`, `buscar_vision_mision` | Ejes temáticos del plan de gobierno (texto largo) |
| **infovoto-logistica** | `buscar_mesa_votacion`, `info_proceso_electoral` | Mesas, horarios, multas, DNI |
| **infovoto-proceso-electoral** | `verificar_antecedentes` | VotaBienPerú: antecedentes penales, judiciales, fiscales |
| **infovoto-debates** | (sin calls registradas) | Posiciones en debates |

## Análisis de data gaps

### Gap 1: Gasto de campaña

**Query:** "cuánto ha gastado cada candidato en su campaña"

**Fuente potencial:** ONPE CLARIDAD (https://claridad.onpe.gob.pe) publica ingresos y gastos de campaña.

**Estado actual:** NO tenemos este dato en ningún MCP. El scraper (`infovoto-scraper`) no scrapea CLARIDAD.

**¿Vale la pena crear un MCP?**
- CLARIDAD es fuente oficial y pública
- Los datos son interesantes para el votante
- PERO: el scraper requiere desarrollo, los datos cambian frecuentemente
- **Decisión: NO es prioridad para este sprint.** El fix correcto es un fallback message honesto: "No tengo datos de gasto de campaña. Consulta claridad.onpe.gob.pe"

### Gap 2: Financiamiento de campaña

**Query:** "quién financia a keiko"

Mismo caso que Gap 1. ONPE CLARIDAD tiene datos de financiamiento. No los tenemos.

**Pero:** El perfil de Keiko SÍ tiene información relevante en `situación_legal`:
- "Investigación por presunto financiamiento ilícito de campañas" (de VotaBienPerú)

El router debería enviar a `buscar_candidato_por_nombre` y el synthesizer debería extraer la info de situación legal relevante a financiamiento. **No necesitamos un MCP nuevo**, necesitamos mejor routing + synthesis.

### Gap 3: Lista de partidos

**Query:** "cuáles son los partidos principales"

`listar_candidatos_region(cargo="presidente")` devuelve 36 candidatos con su partido. La información de partidos SÍ está ahí, pero:
1. Viene como lista de candidatos, no de partidos
2. El synthesizer debería agrupar por partido
3. Pero en passthrough mode, la lista se devuelve tal cual

**Fix:** No necesitamos tool nuevo. Necesitamos que el synthesizer (o el system prompt) instruya al LLM a agrupar por partido cuando la pregunta es sobre partidos, no candidatos.

### Gap 4: "De quién es [partido]"

**Query:** "alianza para el progreso de quién es"

`listar_candidatos_region(partido="Alianza para el Progreso", cargo="presidente")` devolvería el candidato de ese partido. O `buscar_candidato_por_nombre` con el nombre del partido podría funcionar.

**Fix:** Regla de routing en system prompt (ya propuesto por Prompt Engineer, debate 23).

### Verificación: buscar_propuesta_tema(tema="seguridad")

**Query:** "qué propone lopez aliaga para la seguridad"

Necesito verificar que el MCP de planes de gobierno puede buscar por tema "seguridad". Si el plan de gobierno de Renovación Popular tiene ejes temáticos, y "seguridad" es uno de ellos, debería funcionar.

**Hipótesis de la falla:** El router llama `buscar_propuesta_tema` pero NO pasa `tema="seguridad"`. Devuelve la visión general del plan. El fix es que el router extraiga el tema (debate 23, ya propuesto).

## Resumen: ¿Qué MCPs nuevos necesitamos?

| Gap | MCP nuevo | Decisión |
|-----|-----------|----------|
| Gasto de campaña | `infovoto-financiamiento` (CLARIDAD) | ❌ NO para este sprint. Fallback message. |
| Financiamiento de campaña | Mismo | ❌ NO. Info parcial ya está en perfil (situación legal). |
| Lista de partidos | No necesario | ✅ Synthesizer agrupa candidatos por partido |
| "De quién es [partido]" | No necesario | ✅ Router prompt fix |
| Propuesta por tema | No necesario | ✅ Router debe extraer tema como parámetro |

**Conclusión: NO necesitamos MCPs nuevos.** Todas las fallas se resuelven con:
1. Mejor routing (system prompt) — debate 23
2. Fallback messages para datos no disponibles — debate 22
3. Synthesis inteligente para agrupar por partido

## Propuesta: Fallback inteligente para "no tengo ese dato"

Cuando el usuario pregunte algo que no tenemos (gasto de campaña, financiamiento directo), el bot debe:

```
No cuento con datos de [gasto de campaña / financiamiento] en este momento.

Te sugiero consultar:
- ONPE CLARIDAD: claridad.onpe.gob.pe (financiamiento de campaña)
- Plataforma Electoral JNE: plataformaelectoral.jne.gob.pe

¿Puedo ayudarte con algo más? Tengo info de patrimonio declarado, antecedentes, propuestas y más.
```

Esto requiere que el system prompt tenga una regla:
```
- Si el usuario pregunta sobre gasto de campaña, financiamiento de campaña, o donaciones: informa que no tienes esos datos y sugiere ONPE CLARIDAD (claridad.onpe.gob.pe).
```

## Trade-offs

| Opción | Esfuerzo | Cobertura | Riesgo |
|--------|----------|-----------|--------|
| Crear MCP financiamiento | Alto (2-3 días scraper + MCP) | Alto | Datos cambian frecuentemente |
| Fallback message + routing fix | Bajo (30 min) | Medio | Usuario no obtiene el dato |
| No hacer nada | Zero | Zero | Score sigue bajo |

**Recomendación:** Fallback message ahora, MCP financiamiento en un sprint futuro.

## Veredicto

✅ **Aprobado.** No crear MCPs nuevos en este sprint. Los fixes son:
1. **Router prompt** (debate 23): Resuelve 4 queries de routing
2. **Fallback messages**: Resuelve 2 queries de "no data" con redirect a ONPE CLARIDAD
3. **Synthesis "agrupar por partido"**: Resuelve query de partidos principales

**Pido a los stakeholders (debates 25-26) que validen:** ¿Un peruano de a pie sabe qué es ONPE CLARIDAD? ¿Le molesta que el bot no tenga gasto de campaña?
