# Debate 40: "Quiero comparar rápido y me da mucho texto"

**Rol:** Joven de 20 años, Trujillo — Stakeholder
**Input:** Debates 34-39 + experiencia como usuario
**Fecha:** 2026-04-03

---

## Quién soy

Soy Diego, 20 años, estudio Ingeniería de Sistemas en la UNT (Trujillo). Es mi segunda elección presidencial — la primera voté en blanco porque no sabía nada. Ahora quiero votar informado pero no tengo tiempo para leer planes de gobierno de 200 páginas. Un pata del grupo de la u compartió el link del bot. Lo probé en el micro camino a clases.

## Mi experiencia

### Lo bueno

Le pregunté "keiko vs acuña" y me respondió algo comparativo. Piola. También le pregunté "quién es porky" y supo que era López Aliaga. Eso está bacán, entiende jerga.

### Lo malo

Le pregunté "pena de muerte lopez aliaga" y no me dio su posición directa. Bro, solo quiero saber: ¿a favor o en contra? No me des un discurso. Dame un SÍ/NO con fuente y ya.

Después le pregunté "alguno está investigado?" y se colgó. Timeout. En serio, ¿timeout en 2026? Eso me da paja. Si tarda más de 3 segundos ya cambié de pestaña.

Y lo peor: le pregunté "y la marihuana?" (después de haber hablado de posiciones políticas) y no entendió. Me dijo algo genérico. Bro, es obvia la pregunta: ¿keiko está a favor de legalizar la marihuana o no?

### Comparaciones: mi caso de uso principal

Yo lo que más quiero es **comparar candidatos**. No me importa la vida de cada uno por separado — quiero ver las diferencias. Tipo:

```
Yo: "compara keiko, acuña y lopez aliaga"

Bot ideal:
| Tema | Keiko | Acuña | López Aliaga |
|------|-------|-------|-------------|
| Pena de muerte | En contra | Sin posición | A favor |
| Aborto | En contra | Sin posición | En contra |
| Patrimonio | S/ 271K | S/ 1.2M | S/ 5.3M |
| Antecedentes | Caso Cócteles | Plagio tesis | Investigado |
| Educación | Boston U. | U. Complutense | U. del Pacífico |
```

Eso. Tabla limpia. Sin párrafos. En el celular se ve perfecto si es tabla HTML.

## Mis opiniones sobre el RAG

### Me parece bien

Si el bot tiene TODA la data de los candidatos siempre disponible, puede hacer comparaciones al toque. No tiene que ir a buscar candidato por candidato a una base de datos (que a veces falla). Ya tiene todo en memoria. Eso haría las comparaciones más rápidas y completas.

### Me preocupa la velocidad

Si agregar el RAG hace que el bot tarde más, no vale. Mi umbral de tolerancia:
- **<2 segundos**: Perfecto, se siente instantáneo
- **2-4 segundos**: Aceptable, pero ya estoy mirando otra cosa
- **>4 segundos**: Me fui. Abro Google.

Según el Debate 35, el RAG agrega ~100ms. Eso es imperceptible. OK.

### Lo que quiero ver mejorado

**1. Posiciones políticas como tabla**

Pregunta: "posiciones de keiko"
```
| Tema | Posición |
|------|----------|
| Pena de muerte | En contra |
| Aborto | En contra |
| Matrimonio igualitario | En contra |
| Minería | A favor |
| Marihuana | Sin posición registrada |
```

NO quiero un párrafo de 10 líneas explicando cada posición. Tabla o nada.

**2. Patrimonio como números**

Pregunta: "cuánto tiene keiko"
```
💰 Patrimonio declarado (JNE):
- Ingreso total: S/ 271,853
- Propiedades: 2
- Vehículos: 1
```

**3. Antecedentes como lista**

Pregunta: "antecedentes de acuña"
```
⚖️ Antecedentes:
- Plagio de tesis doctoral (SENTENCIADO) — U. Complutense
- Compra de votos 2016 (ARCHIVADO) — JNE
```

**4. Respuesta rápida a preguntas de sí/no**

Pregunta: "keiko está a favor del aborto?"
```
No. Keiko Fujimori se ha declarado EN CONTRA del aborto (Decide.pe).
```

UNA oración. No tres párrafos.

## Sobre los datos faltantes

La señora Carmen (Debate 39) dice que no le digan "Decide.pe" porque no sabe qué es. Yo sí sé qué es. Pero entiendo su punto.

**Mi propuesta**: Que el bot diga la fuente pero sin jerga. En vez de "(Decide.pe, score 0.8)" decir "(según encuesta Decide.pe 2025)". Simple.

Para los candidatos sin posiciones: "Sin posición registrada" es suficiente. No me des un párrafo explicando por qué no hay datos. Yo entiendo que no todos los candidatos se pronuncian.

## El tema de la marihuana y otros temas polémicos

El eval tiene una query "y de la marihuana?" con score 3.0. Esto fue un follow-up donde el bot debería haber entendido que estamos hablando de posiciones políticas de Keiko.

**El RAG resuelve esto**: Si el perfil vectorizado de Keiko tiene "Marihuana/Legalización: SIN POSICIÓN REGISTRADA", el RAG inyecta eso y el synthesizer puede responder: "No encontramos una posición de Keiko sobre la legalización de la marihuana en las fuentes consultadas."

Eso es mejor que "No encontré esa info", que es lo que respondió.

## Top 5 mejoras que quiero

1. **Tabla para comparaciones** — siempre, automáticamente
2. **Respuestas de 1-3 oraciones** para datos puntuales
3. **Posiciones políticas completas** sin depender del routing
4. **Timeout < 4s** — si se pasa, dame lo que tienes y dime "cargando más..."
5. **Follow-ups inteligentes** — que recuerde de quién hablamos

## Veredicto

✅ **Aprobado — el RAG me da exactamente lo que necesito.**

Como usuario que quiere comparar rápido, el RAG paralelo me beneficia directamente:
- Comparaciones completas sin esperar múltiples MCP calls
- Posiciones políticas siempre disponibles
- Patrimonio y antecedentes sin depender del routing

La señora Carmen tiene razón en que no hay que abrumar con datos. Pero la solución no es dar menos datos — es **formatearlos mejor**: tablas, bullets, números concretos.

**Lo que NO quiero**:
- Párrafos largos
- "No encontré esa info"
- Timeouts de más de 4 segundos
- Fuentes incomprensibles

Si el bot me da tablas comparativas con datos reales en menos de 3 segundos, les hago propaganda en el grupo de la u. Somos 200.
