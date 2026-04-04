# Debate 27: Priorización por Impacto al Usuario Real

**Rol:** Product Manager
**Input:** Debates 20-26 (técnicos + stakeholders Diego y Doña Carmen)
**Fecha:** 2026-04-03

---

## Contexto

Tengo input de 4 ingenieros (NLP, UX, QA, Prompt, Data) y 2 stakeholders (joven Lima, señora Chiclayo). Es hora de priorizar combinando perspectiva técnica con la voz del usuario real.

## Lo que dicen los usuarios vs lo que dicen los ingenieros

| Problema | Ingenieros | Diego (18, Lima) | Doña Carmen (50, Chiclayo) |
|----------|-----------|-----------------|---------------------------|
| Bienvenida fallida | P1 (greeting regex) | **"URGENTE"** — casi cierra la app | **"Lo más importante"** — pensó que era propaganda |
| Typos no resueltos | P1 (entity resolution) | "Que me entienda" | "Así hablamos pe" |
| Tool routing incorrecto | P0 (el más grave técnicamente) | No lo mencionó (no lo notó) | "Me respondió otra cosa" |
| No data (gasto campaña) | P2 (fallback message) | "No me importa" | "No me manden a otra página" |
| Lista de 36 candidatos | P3 (mejora UX) | "Mostrar top 5-10" | "En mi celular chiquito no se ve" |
| Partidos principales | Routing fix | No mencionó | **"Yo voto por partido, no persona"** |

## Insights clave de los stakeholders

### 1. La primera impresión lo es TODO

Tanto Diego como Doña Carmen coinciden: si la primera interacción falla, no vuelven. Esto hace que el greeting/bienvenida sea **más urgente que el tool routing**, aunque técnicamente el routing tiene menor score (1.0 vs 3.5).

**Justificación:** Un usuario que escribe "qué estudió lopez aliaga" ya SABE usar la app. Un usuario que escribe "recién me entero de esta app" está DECIDIENDO si la usa. Perder al segundo es peor.

### 2. Los usuarios NO les importa el gasto de campaña

Diego: "El gasto de campaña es para periodistas, no para mí." Doña Carmen: "No me manden a otra página."

**Decisión:** NO crear MCP de financiamiento. Fallback simple: "No tengo esa info. ¿Te puedo ayudar con patrimonio, antecedentes o propuestas?"

### 3. "Que me entienda cuando hablo normal"

Ambos stakeholders frustrados porque la app no entiende jerga natural. Esto valida la propuesta del NLP Engineer (debate 20): ampliar `_NICKNAMES` con apellidos parciales.

### 4. "Respuestas cortas cuando pregunto algo específico"

Doña Carmen: "No me des todo el perfil si solo pregunto el partido." Esto valida el passthrough inteligente ya implementado (is_specific_query → synthesis), PERO para los 4 queries que fallan por routing, el passthrough inteligente no sirve si el router envía al tool equivocado.

## Priorización final (combinada)

### P0: BIENVENIDA + ONBOARDING
**Impacto:** Retención de nuevos usuarios
**Queries afectadas:** 1 (score 3.5) + TODOS los usuarios nuevos
**Fix:** Detector de greeting/discovery (debate 21, Propuesta 3)
**Esfuerzo:** Bajo (~20 líneas en preprocessor.py)
**Por qué P0:** Los ingenieros la pusieron P1, pero los stakeholders la pusieron PRIMERA. Escucho a los usuarios.

### P1: TOOL ROUTING
**Impacto:** Calidad de respuesta para queries específicas
**Queries afectadas:** 4 (scores 1.0, 1.2, 3.2, 3.4)
**Fix:** System prompt con disambiguation rules + few-shot (debate 23)
**Esfuerzo:** Bajo (~350 tokens en system.py)
**Por qué P1:** Las peores scores (1.0 y 1.2) están aquí. Técnicamente es el fix más impactante por score.

### P2: ENTITY RESOLUTION
**Impacto:** Usuarios que escriben con typos o jerga
**Queries afectadas:** 2 (scores 3.4, 3.5) + usuarios como Diego y Carmen
**Fix:** Ampliar _NICKNAMES con apellidos + typo map (debate 20, Propuestas 2+3)
**Esfuerzo:** Bajo (~20 líneas en preprocessor.py)
**Por qué P2:** Afecta a muchos usuarios (los peruanos escriben con typos), pero los scores no son tan bajos.

### P3: "NUNCA DIGAS YA TE LO DIJE"
**Impacto:** Experiencia en sesiones multi-turno
**Queries afectadas:** 1 (score 3.5)
**Fix:** Regla en system prompt (~20 tokens)
**Esfuerzo:** Mínimo
**Por qué P3:** Solo afecta sesiones y es un fix trivial.

### P4: FALLBACK MESSAGES
**Impacto:** Queries sin datos disponibles
**Queries afectadas:** 2 (scores 3.4, 3.6)
**Fix:** Regla en system prompt para redirigir amigablemente
**Esfuerzo:** Mínimo (~50 tokens)
**Por qué P4:** Los usuarios no les importa el gasto de campaña. Solo mejorar el fallback.

### P5: LISTA INTELIGENTE (NICE TO HAVE)
**Impacto:** UX en listas largas
**Queries afectadas:** 1-2 (scores 3.2, 3.4)
**Fix:** Synthesizer que agrupa por partido / muestra top 10
**Esfuerzo:** Medio (requiere cambio en passthrough de listas)
**Por qué P5:** La lista de 36 SÍ funciona, solo es larga. Es mejora de UX, no bug.

## Roadmap sugerido

### Sprint actual (1-2 horas de desarrollo)

| # | Fix | Archivos | Queries resueltas |
|---|-----|----------|------------------|
| 1 | Greeting/discovery detector | `preprocessor.py` | Q8 (3.5) |
| 2 | Router prompt disambiguation | `system.py` | Q1(1.0), Q2(1.2), Q3(3.2), Q6(3.4) |
| 3 | Ampliar _NICKNAMES + apellidos | `preprocessor.py` | Q5(3.4), Q10(3.5) |
| 4 | "Nunca digas ya te lo dije" | `system.py` | Q9(3.5) |
| 5 | Fallback message amigable | `system.py` | Q7(3.4), Q11(3.6) |

**Resultado esperado:** 10 de 12 queries resueltas. Score < 4.0 baja de 12 a ~2.

### Sprint siguiente (nice to have)

| # | Fix | Queries |
|---|-----|---------|
| 6 | Lista inteligente (top 10 + agrupar por partido) | Q4(3.2) |
| 7 | Explicar siglas (DJHV → Declaración Jurada de Hoja de Vida) | UX general |

## Métricas de éxito

| Métrica | Antes | Target |
|---------|-------|--------|
| Score global | 4.79/5 | ≥ 4.85/5 |
| Queries < 4.0 | 12/261 (4.6%) | ≤ 3/261 (1.1%) |
| Score mínimo | 1.0 | ≥ 3.0 |
| Greeting detection | Regex estricto | Cubre saludos naturales |

## Veredicto

✅ **Aprobado.** La priorización es clara: Bienvenida → Routing → Entity → Fallback. Los 2 stakeholders validaron que la bienvenida es lo más urgente. Los ingenieros confirmaron que el routing es el fix de mayor impacto técnico. El sprint cubre 10 de 12 fallas en ~82 líneas de cambio en 2 archivos.

**Pido al Backend Architect (debate 28) que diseñe los cambios mínimos en el pipeline.**
