# Debate 30: Fallback Messages — UX cuando VOTI no tiene la respuesta

**Rol:** Delivery Lead
**Input:** Debates 20-29 (todos) + feedback de Diego (18) y Doña Carmen (50)
**Fecha:** 2026-04-03

---

## Contexto

Los stakeholders fueron claros:
- **Diego (18):** "Si no sabe, que no invente"
- **Doña Carmen (50):** "Si no sabes algo, dime que no sabes. No me des otra cosa. Eso es peor que no responder."
- **Doña Carmen:** "No me manden a otra página"

El Backend Architect (debate 28) propuso reglas de fallback en system prompt. Mi trabajo es diseñar los mensajes exactos que el bot debe dar cuando no tiene datos.

## Escenarios de fallback

### Escenario 1: Gasto de campaña / Financiamiento

**Queries:** "cuánto ha gastado cada candidato en su campaña", "quién financia a keiko"

**Mensaje actual:** Devuelve perfil completo de un candidato (INCORRECTO).

**Mensaje propuesto:**
```
No cuento con datos de financiamiento de campaña en este momento.

Lo que sí puedo decirte:
- Patrimonio declarado de los candidatos
- Antecedentes (incluyendo investigaciones por financiamiento)
- Propuestas de gobierno

¿Te interesa alguno de estos?
```

**Principios:**
1. Decir que NO tiene la info específica
2. Ofrecer lo que SÍ tiene, que sea relevante
3. NO redirigir a páginas externas (Doña Carmen dijo que no)
4. Preguntar qué quiere hacer → mantiene al usuario en la conversación

### Escenario 2: Query específica sin tool disponible

**Queries:** "quién defiende más a los trabajadores"

**Mensaje actual:** "No encontré información sobre qué candidato defiende más a los trabajadores" (score 3.9 — casi OK).

**Mensaje mejorado:**
```
No tengo una comparación directa sobre quién defiende más a los trabajadores.

Pero puedo mostrarte:
- Propuestas de cada candidato sobre empleo y derechos laborales
- Posiciones políticas de los principales candidatos

¿De qué candidato te gustaría ver sus propuestas?
```

**Nota:** Este ya funciona razonablemente (3.9). Solo mejorar el formato visual (agregar lista) y la redirección.

### Escenario 3: "No encontré esa info" genérico

**Query:** "ese lescano de qué partido es pe" (cuando entity falla)

**Mensaje actual:** "No encontré esa info. Prueba con el nombre del candidato o partido."

**Mensaje mejorado:**
```
No encontré resultados para tu búsqueda.

Prueba así:
- Nombre del candidato: "Keiko Fujimori", "César Acuña"
- Nombre del partido: "Fuerza Popular", "APP"
- O pregúntame: "candidatos presidenciales" para ver la lista completa
```

**Principio:** Dar ejemplos concretos de cómo preguntar. Un peruano de a pie no sabe qué formato espera el bot.

### Escenario 4: "Ya te di la información"

**Query:** "kien es keiko" → "Ya te di la información"

**Mensaje correcto:** NUNCA decir "ya te lo dije". Siempre dar la info completa.

Esto ya está cubierto por el fix del system prompt (debate 28, Fix 4).

## Principios de diseño para fallbacks

### 1. Empatía > Precisión técnica

MAL: "No se encontraron resultados para su consulta."
BIEN: "No encontré esa info, pero puedo ayudarte con..."

### 2. Ofrecer alternativas, no muros

MAL: "No tengo datos de financiamiento."
BIEN: "No tengo datos de financiamiento. Lo que sí tengo: patrimonio, antecedentes, propuestas."

### 3. Nunca redirigir a páginas externas como primera opción

MAL: "Consulta ONPE CLARIDAD en claridad.onpe.gob.pe"
BIEN: "No tengo esa info. ¿Te puedo mostrar las propuestas de [candidato] sobre economía?"

### 4. Dar ejemplos de cómo preguntar

MAL: "Prueba con el nombre del candidato."
BIEN: "Prueba: 'Keiko Fujimori', 'César Acuña', o 'candidatos presidenciales'."

### 5. Tono casual, no robótico

MAL: "Lamentamos informar que esta funcionalidad no está disponible."
BIEN: "No tengo esa info, pero pregúntame otra cosa."

## Implementación en system prompt

Agregar a `system.py`:

```
### Cuando NO tienes la información
- Si no tienes los datos que el usuario pide, dilo claramente: "No cuento con esa información."
- SIEMPRE ofrece alternativas relevantes con lo que SÍ tienes. Ejemplo: "No tengo datos de gasto de campaña, pero puedo mostrarte el patrimonio declarado de los candidatos."
- NO redirigir a páginas externas (ONPE, JNE) como primera respuesta. Solo mencionarlas si el usuario insiste.
- Si el usuario escribió algo que no entendiste, da ejemplos de cómo preguntar: "Prueba: 'info de Keiko', 'propuestas de Acuña sobre educación', 'candidatos presidenciales'."
- NUNCA devuelvas un perfil completo de un candidato cuando el usuario preguntó algo que no tienes. Eso confunde más que ayudar.
```

## Métricas de éxito para fallbacks

| Métrica | Cómo medir |
|---------|-----------|
| Comprensión (score judge) | El judge evalúa si la respuesta se alineó con la pregunta |
| Tono amigable | Score de "tono" en evaluación |
| Ofrece alternativas | Manual: ¿la respuesta sugiere qué más puede preguntar? |
| No redirige a externo | Manual: ¿menciona URL externa como primera opción? |

## Ejemplos completos de fallback mejorado

### Ejemplo 1: Gasto de campaña
```
User: cuánto ha gastado cada candidato en su campaña
Bot: No cuento con datos de gasto de campaña en este momento.

Lo que sí puedo decirte:
- **Patrimonio declarado** de los candidatos (cuánto tienen)
- **Antecedentes** (incluyendo investigaciones por financiamiento)
- **Propuestas** de gobierno

¿Te interesa alguno de estos?
```

### Ejemplo 2: Financiamiento
```
User: quién financia a keiko
Bot: No tengo datos específicos sobre quién financia la campaña de Keiko.

Lo que sí sé es que tiene investigaciones relacionadas con financiamiento:
- Investigación por presunto financiamiento ilícito

¿Quieres ver sus antecedentes completos o su patrimonio declarado?
```

### Ejemplo 3: Búsqueda sin resultados
```
User: ese lescano de qué partido es pe
Bot: No encontré resultados.

Prueba con:
- "Lescano" → info del candidato Yonhy Lescano
- "Acción Popular" → candidatos de ese partido
- "candidatos presidenciales" → lista completa

¿Qué te gustaría saber?
```

## Trade-offs

| Aspecto | Antes | Después |
|---------|-------|---------|
| Respuesta a "no data" | Perfil random | Mensaje claro + alternativas |
| Confianza del usuario | Baja (confuso) | Alta (honesto) |
| Tokens del prompt | Base | +~100 tokens |
| Complejidad | Baja | Baja (solo prompt) |

## Veredicto

✅ **Aprobado.** Los fallback messages son el fix más fácil y con alto impacto emocional. Solo es cambio de prompt, ~100 tokens adicionales. Resuelve Q7, Q11, y mejora Q12 (que ya estaba casi bien).

**Pido al AI Tech Lead (debate 31) el consenso final y plan de acción priorizado.**
