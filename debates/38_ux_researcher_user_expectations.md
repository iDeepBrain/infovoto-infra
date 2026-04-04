# Debate 38: ¿Qué Espera el Usuario Peruano?

**Rol:** UX Researcher
**Input:** Debates 34-37 + eval sessions + queries fallidas
**Fecha:** 2026-04-03

---

## Perfil del usuario objetivo

InfoVoto atiende a votantes peruanos de 18-65 años, diversidad socioeconómica, muchos votando por primera vez o desinformados. Contexto: Elecciones generales 2026, Perú.

### Segmentos clave

| Segmento | % estimado | Comportamiento | Expectativa |
|----------|-----------|---------------|-------------|
| Joven urbano (18-25) | ~30% | Compara rápido, usa apodos, typos | Respuesta corta, datos concretos |
| Adulto informado (25-45) | ~35% | Preguntas específicas, sabe de candidatos | Datos verificables con fuentes |
| Adulto desinformado (35-55) | ~25% | Preguntas básicas, desconfía de la tecnología | Explicación clara, tono cercano |
| Adulto mayor (55+) | ~10% | Preguntas simples, vocabulario formal | Paciencia, respuesta directa |

## Análisis de las sesiones del eval

### Patrón 1: "Pregunta simple, respuesta ausente"

**Queries representativas**:
- "educación de keiko" → Score 3.0: "No encontré esa información específica"
- "aborto keiko" → Score 3.1: Respuesta genérica sin posición
- "antecedentes penales hay?" → Score 2.8: "No encontré esa info"

**Qué espera el usuario**: Una respuesta directa. "Keiko estudió Administración en Boston University." Punto. No quiere excusas técnicas.

**Impacto emocional**: "No encontré esa info" en un chatbot electoral genera **desconfianza**. El usuario piensa: "Si no sabe dónde estudió Keiko, ¿para qué sirve?" Y se va. Primera impresión arruinada.

**Cómo el RAG ayuda**: El perfil vectorizado tiene la educación. La búsqueda semántica la encuentra aunque el router falle. El usuario obtiene respuesta → confía → sigue preguntando.

### Patrón 2: "Comparación esperada, respuesta individual"

**Queries representativas**:
- "keiko vs acuña propuestas" → Score 3.4
- "menos antecedentes" → Score 3.8
- "mejor plan de seguridad" → Score 3.8

**Qué espera el usuario**: Una tabla o lista comparativa. Lado a lado. No un párrafo de texto.

**Cómo el RAG ayuda parcialmente**: Si el RAG inyecta perfiles de ambos candidatos, el synthesizer tiene datos para comparar. Pero la calidad de la comparación depende del prompting del synthesizer, no solo de los datos.

### Patrón 3: "Follow-up natural, contexto perdido"

**Queries representativas** (en sesión):
```
Usuario: "quién es keiko"      → Score 5.0 (responde bien)
Usuario: "y la china?"          → Score 3.5-4.0 (pierde contexto)
Usuario: "cuánto tiene?"        → Score 3.5 (no sabe que "tiene" = patrimonio)
```

**Qué espera el usuario**: Que el bot "recuerde" que estamos hablando de Keiko y que "cuánto tiene" = patrimonio. Como una conversación con un amigo.

**Cómo el RAG ayuda**: Si "cuánto tiene" llega al RAG con entity context `candidate=Keiko`, el RAG devuelve su patrimonio. El synthesizer tiene datos incluso si el router no entiende el follow-up.

### Patrón 4: "Pregunta amplia, espera resumen"

**Queries representativas**:
- "alguno está investigado?" → Score 1.0 (timeout)
- "quién tiene más antecedentes?" → Score ~3.5

**Qué espera el usuario**: Un resumen tipo: "Sí, varios candidatos tienen investigaciones abiertas: Keiko (Caso Cócteles), Acuña (plagio de tesis)..." — una respuesta panorámica.

**El reto**: Estas queries necesitan agregar datos de MÚLTIPLES candidatos. El RAG con top_k=3 solo devuelve 3 perfiles.

**Propuesta UX**: Para queries amplias ("alguno", "quién tiene", "cuántos"), el RAG debería devolver top_k=5 y el synthesizer debería listar. El preprocessor puede detectar queries de tipo "comparación amplia" y aumentar el top_k.

## Expectativas de respuesta por tipo de query

### Tipo 1: Dato puntual
```
"educación de keiko" → "Keiko Fujimori estudió Administración de Empresas en Boston University (2001)"
```
- **Formato**: 1-2 oraciones
- **Tono**: Informativo, directo
- **Fuente**: "(Declaración Jurada JNE)"
- **RAG impact**: ALTO — dato exacto en el perfil vectorizado

### Tipo 2: Posición política
```
"aborto keiko" → "Keiko Fujimori se ha declarado EN CONTRA del aborto (Decide.pe)"
```
- **Formato**: 1 oración + fuente
- **Tono**: Neutral, sin juicio
- **RAG impact**: ALTO — match directo

### Tipo 3: Comparación
```
"keiko vs acuña" →
| Tema | Keiko | Acuña |
|------|-------|-------|
| Educación | Boston University | U. Complutense Madrid |
| Patrimonio | S/ 271,853 | S/ 1,234,567 |
| Antecedentes | Caso Cócteles | Plagio de tesis |
```
- **Formato**: Tabla comparativa
- **RAG impact**: MEDIO — necesita ambos perfiles, synthesizer debe formatear

### Tipo 4: Perfil completo
```
"háblame de lopez aliaga" → Resumen estructurado con: bio, educación, patrimonio, posiciones, antecedentes
```
- **Formato**: Lista/resumen estructurado
- **RAG impact**: ALTO — perfil completo inyectado

### Tipo 5: Pregunta amplia
```
"alguno está investigado?" → "Sí, X candidatos tienen investigaciones: [lista]"
```
- **Formato**: Lista con bullets
- **RAG impact**: MEDIO-ALTO — necesita top_k mayor

## Análisis UX: ¿RAG mejora o confunde?

### Escenario positivo: RAG inyecta dato correcto

```
Usuario: "educación de keiko"
Router: falla → tools=[]
RAG: inyecta "Keiko — EDUCACIÓN: Bachiller Administración, Boston University"
Synthesizer: "Keiko estudió Administración de Empresas en Boston University"
```

**UX: Excelente.** El usuario obtiene respuesta. No sabe (ni le importa) que vino del RAG en vez del MCP.

### Escenario negativo: RAG inyecta dato irrelevante

```
Usuario: "cuándo son las elecciones"
Router: llama info_dia_elecciones → datos correctos
RAG: inyecta perfil de algún candidato (baja similitud)
Synthesizer: Confundido, mezcla fecha de elecciones con datos del candidato
```

**UX: Malo.** El usuario preguntó algo simple y recibió ruido.

**Mitigación** (D37): Threshold de similitud. Si la query no matchea con perfiles (distancia alta), no inyectar nada.

### Escenario delicado: RAG inyecta dato parcial

```
Usuario: "pena de muerte acuña"
RAG: inyecta perfil de Acuña, pero posiciones dice "[SIN DATOS DISPONIBLES]"
Synthesizer: "No encontramos la posición de Acuña sobre la pena de muerte en las fuentes consultadas (Decide.pe)"
```

**UX: Aceptable.** Es mejor que "No encontré esa info" porque explica POR QUÉ no hay datos. El usuario entiende que es un vacío de fuentes, no del bot.

## Recomendaciones UX para el RAG

### 1. Nunca decir "No encontré esa info"

El RAG debería eliminar esta frase del repertorio del bot. Si no hay datos:
- ❌ "No encontré esa información"
- ✅ "No tenemos registro de la posición de X sobre Y en las fuentes disponibles (JNE, Decide.pe)"

### 2. Fuentes siempre visibles

Cada dato del RAG debe llevar su fuente:
- "Keiko estudió en Boston University *(Declaración Jurada JNE)*"
- "Acuña fue sentenciado por plagio de tesis *(VotaBienPerú)*"

Esto genera confianza. El usuario puede verificar.

### 3. No mezclar RAG + MCP sin contexto

Si el MCP devuelve datos Y el RAG también, el synthesizer debe priorizar MCP (más actualizado) y usar RAG como complemento. No mezclar ambos sin indicar la fuente.

### 4. Queries amplias: ajustar top_k

Para queries tipo "alguno", "quién tiene", "cuántos candidatos" → top_k=5-8 (no 3).

Detección en preprocessor:
```python
BROAD_QUERY_PATTERNS = [
    r"\b(alguno|algún|cuántos|quiénes|todos|ninguno)\b",
    r"\b(más|menos|mejor|peor)\b.*\b(candidato|partido)s?\b",
]
```

### 5. Respuestas de patrimonio: humanizar montos

```
❌ "Ingreso total declarado: S/ 271,853"
✅ "Keiko declaró un ingreso total de S/ 271,853 ante el JNE, con 2 propiedades y 1 vehículo"
```

Esto es trabajo del synthesizer prompt, no del RAG. Pero el RAG le da los datos para hacerlo.

## Veredicto

✅ **Aprobado — el RAG mejora significativamente la experiencia del usuario.**

Los principales beneficios UX:
1. Elimina "No encontré esa info" en ~15 queries
2. Provee datos verificables con fuentes
3. Mantiene conversaciones fluidas (follow-ups)
4. Degrada graciosamente con "SIN DATOS DISPONIBLES" en vez de silencio

**Condiciones UX**:
1. Threshold de similitud para no inyectar ruido
2. Fuentes obligatorias en cada dato
3. Top_k ajustable según tipo de query (puntual=3, amplia=5-8)
4. El synthesizer prompt debe preferir MCP sobre RAG cuando ambos tienen datos

## Preguntas para debates siguientes

- **Señora de 55 (D39)**: ¿Cómo quiere recibir la info? ¿Le molesta que le digan "Decide.pe"?
- **Joven de 20 (D40)**: ¿Quiere ver números o resúmenes? ¿Tabla o bullets?
- **Backend Architect (D41)**: ¿Cómo detectar "query amplia" para ajustar top_k?
