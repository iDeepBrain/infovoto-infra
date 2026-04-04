# Debate 32: ¿Se necesitan cambios en el Frontend Web?

**Rol:** Full Stack Lead
**Input:** Debates 20-31 (consenso) + exploración completa de infovoto-web + feedback stakeholders
**Fecha:** 2026-04-03

---

## Contexto

Los 11 debates anteriores llegaron a consenso sobre fixes en el gateway (system.py + preprocessor.py). La pregunta ahora es: **¿el frontend web necesita cambios para que estos fixes tengan el impacto deseado?**

El frontend es Next.js 14 con chat en `/app/chat/page.tsx` (~1000 líneas). Usa un renderizador de markdown custom, CandidateCards, VotiSprite animado, y un sistema de welcome screen con preguntas sugeridas.

## Análisis: ¿Qué parte del frontend interactúa con cada fix?

### Fix 1: Greeting/Discovery Detector (gateway)

**¿Requiere cambio web?** NO

**Razón:** El frontend ya tiene welcome screen con preguntas sugeridas cuando `messages.length === 0`. Si el usuario escribe "recién me entero de esta app a ver qué tal", el gateway devuelve un mensaje de bienvenida como texto. El renderizador de markdown lo muestra correctamente (bold, listas, etc.).

**Pero hay un matiz:** Si el usuario llega con `?q=` pre-filled desde landing page, el welcome screen se salta. Si ese query pre-filled es algo como "a ver qué tal", el gateway ahora lo detectaría como greeting. Esto está bien — el gateway responde con bienvenida y el frontend la muestra.

**Veredicto:** ✅ No requiere cambio web.

---

### Fix 2: Router Prompt Disambiguation (gateway)

**¿Requiere cambio web?** NO

**Razón:** El router corregido devuelve mejor contenido, pero el formato de la respuesta no cambia. El frontend renderiza markdown que viene del gateway. Si el gateway devuelve educación en vez de antecedentes, el markdown se renderiza igual.

**Veredicto:** ✅ No requiere cambio web.

---

### Fix 3: Ampliar _NICKNAMES (gateway)

**¿Requiere cambio web?** NO

**Razón:** Entity resolution es 100% backend. El frontend envía el texto del usuario tal cual.

**Veredicto:** ✅ No requiere cambio web.

---

### Fix 4: "Nunca digas ya te lo dije" (gateway)

**¿Requiere cambio web?** NO

**Razón:** Es cambio de prompt, la respuesta del gateway ya no dirá "ya te di la información".

**Veredicto:** ✅ No requiere cambio web.

---

### Fix 5: Fallback Messages (gateway)

**¿Requiere cambio web?** POSIBLEMENTE

**El fallback mejorado incluye:**
```
No cuento con datos de financiamiento de campaña.

Lo que sí puedo decirte:
- **Patrimonio declarado** de los candidatos
- **Antecedentes** (incluyendo investigaciones por financiamiento)
- **Propuestas** de gobierno

¿Te interesa alguno de estos?
```

**Pregunta:** ¿Las opciones "Patrimonio declarado", "Antecedentes", "Propuestas" deberían ser **botones clickeables** en vez de solo texto?

**Estado actual del frontend:** No hay sistema de quick replies/botones sugeridos dentro de mensajes. Solo existen las 4 preguntas sugeridas en el welcome screen (empty state). Una vez iniciada la conversación, no hay chips/botones.

**¿Se beneficiaría?** SÍ, pero es una **mejora de UX, no un requisito**. El texto con lista funciona, pero botones clickeables reducirían fricción.

**Veredicto:** 🔄 No es bloqueante pero sería una mejora útil (P5).

---

### Problema identificado por stakeholders: Lista de 36 candidatos

**Diego (D25):** "La lista de 36 es GIGANTE"
**Doña Carmen (D26):** "En mi celular chiquito no se ve"

**Estado actual del frontend:**
- `CandidateCard` se renderiza inline dentro del mensaje
- 36 cards = ~36 × 80px = ~2880px de altura en el chat
- No hay paginación, virtualización, ni colapso
- En Redmi con pantalla de 6" → el usuario scrollea MUCHO

**¿Requiere cambio web?** SÍ, pero es P5 (nice to have, no este sprint).

**Opciones futuras:**
1. **Mostrar top 10 + "Ver más"**: El gateway ya devuelve `hay_mas` flag + `siguiente_inicio`. El frontend podría mostrar 10 cards y un botón "Ver más candidatos".
2. **Lista colapsable**: Mostrar nombres en lista compacta, expandir a card on click.
3. **Scroll horizontal**: Cards en carrusel horizontal (como stories de Instagram).

**Veredicto:** P5 — no en este sprint. La mejora está en el gateway (el prompt puede instruir al LLM a mostrar top 10 primero).

---

### Problema identificado: Renderizado de tablas Markdown

**El gateway a veces devuelve tablas markdown** para comparaciones. El renderizador custom del frontend (`renderMarkdown()` en `page.tsx:55-99`) **NO soporta tablas**.

**Impacto:** Si el synthesizer genera una tabla comparativa (ej: "compara keiko y acuña"), la tabla se muestra como texto plano con pipes `|`. Esto fue detectado por el judge (formato_visual=4.64 global, el score más bajo).

**Estado actual:**
```javascript
// renderMarkdown() soporta:
// - Listas (-, *, •, 1.)
// - Bold (**text**)
// - Italic (*text*)
// - Links [text](url)
// - HR (---)
// NO soporta: tablas, code blocks, headers (#)
```

**¿Requiere cambio web?** SÍ, para mejorar formato_visual.

**Fix propuesto:** Agregar parsing de tablas markdown al renderizador custom. O migrar a una librería de markdown (react-markdown). El proyecto ya tiene `@tailwindcss/typography` instalado, que da estilos prose para markdown.

**Estimación:** ~50 líneas para table parsing custom, o ~20 líneas para integrar react-markdown.

**Veredicto:** 🔄 Mejora importante para formato_visual pero no es bloqueante para los 12 queries fallidos. P3.

---

### Problema identificado: Siglas sin explicación

**Diego (D25):** "DJHV-JNE no sé qué es. ¿Es un canal de YouTube?"
**Doña Carmen (D26):** "ONPE CLARIDAD no sé qué es."

**¿Requiere cambio web?** NO — es fix de gateway/prompt.

El gateway debería escribir "Según su Declaración Jurada de Hoja de Vida (DJHV) ante el JNE" en vez de solo "DJHV-JNE". Esto es cambio de system prompt, no de frontend.

**Las fuentes ya se muestran** con badges color-coded en el frontend (oficial=verde, declaración=amber, plan=azul). El componente funciona bien.

**Veredicto:** ✅ No requiere cambio web. Fix en system prompt.

---

### Problema identificado: Onboarding/Welcome Screen

**Estado actual:** El frontend YA tiene welcome screen con:
- Sprite de Voti (108px)
- "¡Hola! Soy VOTI - Te ayudo a votar informado"
- 4 preguntas sugeridas (de 8, shuffled)
- Consent modal (primera visita)

**¿Es suficiente?** SÍ para la web. El welcome screen ya cumple la función que Diego y Carmen piden.

**El problema de "recién me entero de esta app"** solo ocurre cuando:
1. El usuario ignora las preguntas sugeridas
2. Escribe texto libre en vez de clickear una sugerencia
3. El gateway no detecta que es un saludo

**Con el fix del gateway (greeting detector), esto se resuelve sin cambio web.**

**Oportunidad de mejora:** Las 8 preguntas sugeridas podrían actualizarse:

```javascript
// Actuales:
"¿Quiénes postulan a la presidencia en 2026?"
"¿Qué propone Renovación Popular sobre seguridad?"
"¿Cuándo son las elecciones 2026?"
"¿Quién es el candidato con más patrimonio?"
// ...

// Mejoradas (más natural, como peruano de a pie):
"¿Quién es Keiko Fujimori?"
"Compara a Keiko y Acuña"
"¿Cuándo son las elecciones?"
"Antecedentes de López Aliaga"
"¿Qué proponen sobre seguridad?"
"¿Quiénes postulan a presidente?"
"¿Es obligatorio votar?"
"¿Quién tiene más patrimonio?"
```

**Veredicto:** 🔄 Mejora menor — actualizar las preguntas sugeridas. P4.

---

## Resumen: ¿Qué cambios web se necesitan?

| Cambio | Prioridad | Bloqueante | Esfuerzo | Archivo |
|--------|-----------|------------|----------|---------|
| Soporte tablas markdown | P3 | NO | Medio (~50 líneas o react-markdown) | `app/chat/page.tsx` |
| Quick reply buttons en fallbacks | P5 | NO | Alto (~100 líneas nuevo componente) | `app/chat/page.tsx` + nuevo component |
| Actualizar preguntas sugeridas | P4 | NO | Bajo (~10 líneas) | `app/chat/page.tsx` |
| Lista colapsable (36 candidatos) | P5 | NO | Alto (~150 líneas) | `app/components/CandidateCard.tsx` |
| **TOTAL BLOQUEANTE** | **—** | **NINGUNO** | **—** | **—** |

## Conclusión

**Para el sprint actual (fixes de los 12 queries): NO se necesitan cambios en la web.**

Los 5 fixes del consenso (debate 31) son 100% backend:
1. Greeting detector → gateway responde bienvenida → frontend la renderiza OK
2. Router disambiguation → gateway devuelve contenido correcto → frontend lo renderiza OK
3. _NICKNAMES → gateway resuelve entidades → frontend no participa
4. "Nunca ya te lo dije" → gateway no dice eso → frontend no participa
5. Fallback messages → gateway devuelve texto con lista → frontend renderiza markdown OK

**Para un sprint futuro**, las mejoras web recomendadas (en orden):
1. **P3: Tablas markdown** — mejora formato_visual (la dimensión más baja: 4.64/5)
2. **P4: Preguntas sugeridas actualizadas** — mejor onboarding con queries naturales
3. **P5: Quick reply buttons** — reduce fricción en fallbacks
4. **P5: Lista colapsable** — mejor UX para 36 candidatos en mobile

## Veredicto

✅ **Aprobado: NO cambiar la web en este sprint.** El frontend ya soporta todo lo que el gateway va a devolver con los fixes. Las mejoras web son independientes y pueden hacerse después sin bloquear los fixes de calidad.

**Recomendación:** Después de implementar los 5 fixes del gateway y verificar el score, hacer un sprint de UX web con P3 (tablas) como prioridad.
