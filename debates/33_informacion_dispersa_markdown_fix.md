# Debate 33: Información Dispersa — ¿Qué fix se necesita realmente?

**Rol:** Full Stack Lead + UX Researcher + Delivery Lead (debate conjunto)
**Input:** Debates 20-32 + análisis de las 261 respuestas reales + código del renderizador
**Fecha:** 2026-04-03

---

## El diagnóstico real (datos, no intuición)

Analicé las 261 respuestas del eval para entender qué markdown usa el gateway y qué puede renderizar el frontend.

### Qué markdown USA el gateway

| Feature | Respuestas que lo usan | % |
|---------|----------------------|---|
| `**bold**` | 212 / 261 | 81% |
| Listas `- item` | 166 / 261 | 64% |
| Separadores `---` | 126 / 261 | 48% |
| Tablas `| col |` | 0 / 261 | **0%** |
| Headers `# Título` | 0 / 261 | **0%** |

### Qué markdown RENDERIZA el frontend

| Feature | Soporte | Estado |
|---------|---------|--------|
| `**bold**` | ✅ Sí | Funciona |
| `*italic*` | ✅ Sí | Funciona |
| Listas `-`, `*`, `•`, `1.` | ✅ Sí | Funciona |
| Links `[text](url)` | ✅ Sí | Funciona |
| Separadores `---` | ✅ Sí | Funciona |
| Tablas | ❌ No | No implementado |
| Headers `#` | ❌ No | No implementado |
| Code blocks | ❌ No | No implementado |

### Conclusión sorprendente

**El frontend ya renderiza TODO lo que el gateway envía.** No hay tablas ni headers en ninguna de las 261 respuestas. El gap de tablas/headers en el renderizador es irrelevante AHORA porque el gateway no las genera.

**Entonces, ¿por qué el judge da `formato_visual` bajo (4.64 promedio)?**

## El problema real: NO es el renderizador, es el CONTENIDO

Las 9 respuestas con `formato_visual ≤ 3` revelan el patrón:

### Patrón 1: "Muro de texto sin estructura" (fmt=1, 3 queries)

```
"qué propone lopez aliaga para la seguridad" → fmt=1

¡Claro! Te cuento sobre la visión del plan de gobierno de
Rafael López Aliaga (Renovación Popular):

Su visión es impulsar el Buen Gobierno de manera eficiente,
moderna y transparente, con una gestión que ayude a
revalorarnos como ciudadanos de primera...
```

**Problema:** Párrafo continuo sin bold, sin listas, sin estructura. El LLM synthesizer no formateó la respuesta. No es culpa del frontend — el markdown nunca se generó.

### Patrón 2: "Respuesta genérica sin formato" (fmt=1, 2 queries)

```
"quién defiende más a los trabajadores" → fmt=1

¡Hola! No encontré información sobre qué candidato defiende
más a los trabajadores. Sin embargo, puedo mostrarte las
propuestas de los candidatos sobre derechos humanos...
```

**Problema:** El fallback es un párrafo plano. Debería usar lista con alternativas. De nuevo, es el gateway/prompt, no el frontend.

### Patrón 3: "Comparaciones que DEBERÍAN ser tabla" (fmt=4-5 pero verbose)

```
"compara a keiko y acuña" → fmt=5 pero 2152 chars

**Keiko Fujimori (Fuerza Popular):**
*   **Educación:** Es bachiller de Boston University...
*   **Experiencia:** Ha sido Presidenta...
*   **Patrimonio:** Declara un ingreso total de S/ 271,853...

**César Acuña (Alianza para el Progreso):**
*   **Educación:** Tiene un doctorado de la Universidad Complutense...
*   **Experiencia:** Ha sido Asesor en la Universidad...
*   **Patrimonio:** Declara un ingreso total de S/ 9,836,766...
```

**Problema:** Para comparar 2 candidatos, el formato ideal es una TABLA donde ves columna a columna. El formato actual (lista por candidato) obliga al usuario a scrollear arriba y abajo para comparar el mismo campo.

Pero: el gateway NO genera tablas (0 de 261). Y el frontend NO renderiza tablas. **Ambos necesitan fix** para este caso.

## ¿Dónde está la "información dispersa"?

La dispersión ocurre en 3 niveles:

### Nivel 1: El passthrough del perfil completo

Cuando el gateway hace passthrough, devuelve TODA la info del candidato:
```
Nombre + Cargo + Partido
Formación (3-4 items)
Experiencia (3-4 items)
Patrimonio
Situación legal (3-7 items)
Posiciones políticas (8 items)
Fuentes
```

Son ~1200-1500 chars. Para "info de keiko" está bien. Para "cuánto gana keiko" es disperso — el usuario tiene que encontrar la línea de patrimonio entre todo lo demás.

**Fix:** Ya implementado — passthrough inteligente (is_specific_query → synthesis focalizada). Funciona al 95%.

### Nivel 2: Las comparaciones son listas paralelas en vez de tablas

Para comparar keiko vs acuña, lo ideal es:

```
| Aspecto | Keiko Fujimori | César Acuña |
|---------|---------------|-------------|
| Educación | Boston University | U. Complutense Madrid |
| Patrimonio | S/ 271,853 | S/ 9,836,766 |
| Antecedentes | 6 registros | 7 registros |
```

Pero el gateway genera listas separadas por candidato. El usuario debe ir y venir mentalmente.

**Fix necesario:**
1. **Gateway:** Instruir al synthesizer a generar tablas markdown para comparaciones
2. **Frontend:** Agregar soporte de tabla al renderizador

### Nivel 3: Los fallback son párrafos planos

Cuando el bot no tiene data, responde en prosa sin estructura:

```
No encontré información sobre X. Sin embargo, puedo mostrarte
las propuestas de los candidatos sobre derechos humanos,
informalidad y pensiones públicas. ¿Te interesa?
```

Debería ser:

```
No encontré información sobre X.

Te puedo ayudar con:
- **Propuestas** de cada candidato sobre empleo
- **Posiciones políticas** sobre derechos laborales
- **Patrimonio declarado** de los candidatos

¿Qué te interesa?
```

**Fix:** Solo gateway (prompt). El frontend ya renderiza listas con bold.

## Plan de fixes por nivel

### Nivel 1: Passthrough inteligente
**Estado:** ✅ YA IMPLEMENTADO. is_specific_query funciona.

### Nivel 2: Tablas para comparaciones — REQUIERE CAMBIO EN AMBOS

**Gateway (`system.py`):**
Agregar instrucción al synthesizer:
```
### Formato de comparaciones
- Cuando el usuario pida comparar 2 o más candidatos, usa una TABLA markdown:
  | Aspecto | Candidato A | Candidato B |
  |---------|------------|------------|
  | Educación | ... | ... |
  | Patrimonio | ... | ... |
- La tabla permite comparar campo por campo, que es lo que el usuario necesita.
- Si la comparación tiene más de 5 filas, prioriza los aspectos más relevantes.
```

**Frontend (`app/chat/page.tsx`):**
Agregar parsing de tablas al `renderMarkdown()`:

```typescript
// Detectar tablas: líneas con | separadores
if (line.trim().startsWith('|') && line.trim().endsWith('|')) {
  // Acumular filas de tabla
  tableRows.push(line.trim());
  continue;
}
// Al terminar la tabla, renderizar como <table>
```

**Estimación:** ~40 líneas en `renderMarkdown()` + ~60 tokens en system prompt.

### Nivel 3: Fallbacks estructurados — SOLO GATEWAY

**Ya cubierto por debate 30** (Delivery Lead). Solo cambio de prompt para que los fallbacks usen listas con bold en vez de prosa plana.

## ¿Qué pasa si NO hacemos el fix de tablas?

Las comparaciones siguen funcionando con listas paralelas. Score actual de comparaciones: **4.5-5.0/5**. No es un problema grave — es una mejora de UX.

Pero el judge puntúa `formato_visual = 4.64` como la dimensión más baja. Si queremos subir eso, las tablas en comparaciones son el fix más impactante.

## Debate: ¿Vale la pena agregar tablas?

### A favor (UX Researcher)

- Las comparaciones son el **caso de uso más valioso** — el usuario quiere decidir entre candidatos
- Una tabla de 5 filas × 3 columnas dice más que 30 líneas de lista
- Doña Carmen (D26): "En mi celular chiquito no se ve" — una tabla compacta ayuda
- Diego (D25): implícitamente quiere info rápida y visual

### En contra (Backend Architect)

- Score de comparaciones ya es 4.5-5.0, no es urgente
- Agregar tabla al renderizador custom es propenso a bugs (colspan, overflow en mobile, etc.)
- Podríamos migrar a `react-markdown` en vez de renderizador custom, pero es un refactor grande
- Las tablas en mobile se ven mal si son anchas (horizontal scroll)

### Solución pragmática (Delivery Lead)

**No necesitamos tablas HTML perfectas.** Para VOTI, una "tabla" es siempre:
- 3 columnas máximo (Aspecto | Candidato A | Candidato B)
- 5-8 filas (Educación, Patrimonio, Experiencia, Legal, Posiciones)
- Texto corto por celda

Es un caso acotado. No necesitamos un parser de tablas genérico ni `react-markdown`. Un parser simplificado de ~40 líneas basta.

## Propuesta final concreta

### Cambio 1: Gateway — instrucción de tablas para comparaciones (~60 tokens)

En `system.py`, agregar:

```
### Formato de respuestas
- Para COMPARACIONES entre candidatos, usa tabla markdown:
  | Aspecto | Candidato A | Candidato B |
  |---------|------------|------------|
  Incluye: educación, experiencia, patrimonio, antecedentes, posiciones clave.
- Para FALLBACKS (no tienes la info), usa lista con bold:
  - **Alternativa 1**
  - **Alternativa 2**
- NUNCA respondas con párrafos largos sin formato. Usa bold, listas o tablas.
```

### Cambio 2: Frontend — renderizado de tablas simples (~40 líneas)

En `page.tsx`, dentro de `renderMarkdown()`:

```typescript
// Table accumulator
let tableRows: string[] = [];

const flushTable = () => {
  if (tableRows.length < 2) { // Need at least header + 1 row
    // Not a real table, render as paragraphs
    tableRows.forEach(row => elements.push(<p key={...}>{formatInline(row)}</p>));
    tableRows = [];
    return;
  }

  const parseRow = (row: string) =>
    row.split('|').filter(c => c.trim()).map(c => c.trim());

  const headers = parseRow(tableRows[0]);
  // Skip separator row (|---|---|)
  const dataStart = tableRows[1]?.includes('---') ? 2 : 1;
  const rows = tableRows.slice(dataStart).map(parseRow);

  elements.push(
    <div key={`table-${elements.length}`} className="overflow-x-auto my-3">
      <table className="w-full text-sm border-collapse">
        <thead>
          <tr className="border-b border-gray-600">
            {headers.map((h, i) => (
              <th key={i} className="text-left py-2 px-3 text-gray-300 font-semibold">
                {formatInline(h)}
              </th>
            ))}
          </tr>
        </thead>
        <tbody>
          {rows.map((row, ri) => (
            <tr key={ri} className="border-b border-gray-700/50">
              {row.map((cell, ci) => (
                <td key={ci} className="py-2 px-3">
                  {formatInline(cell)}
                </td>
              ))}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
  tableRows = [];
};

// In the main loop, before the paragraph fallback:
if (line.trim().startsWith('|') && line.includes('|', 1)) {
  flushList();
  tableRows.push(line.trim());
  continue;
}
if (tableRows.length > 0) {
  flushTable(); // Flush when non-table line appears
}
```

**Mobile:** `overflow-x-auto` permite scroll horizontal si la tabla es ancha. Con 3 columnas y texto corto, cabe en pantalla.

**Estilo:** Hereda el dark theme (`text-gray-300`, `border-gray-600`), consistente con el chat.

## Priorización actualizada

| Fix | Dónde | Prioridad | Esfuerzo |
|-----|-------|-----------|----------|
| Fallbacks estructurados (listas con bold) | Gateway prompt | P2 | ~60 tokens |
| "NUNCA párrafos largos sin formato" | Gateway prompt | P2 | ~20 tokens |
| Instrucción de tablas para comparaciones | Gateway prompt | P3 | ~60 tokens |
| Renderizado de tablas en frontend | Web `page.tsx` | P3 | ~40 líneas |
| Actualizar preguntas sugeridas | Web `page.tsx` | P4 | ~10 líneas |

## Impacto esperado en formato_visual

| Escenario | formato_visual actual | Después del fix |
|-----------|---------------------|-----------------|
| Comparaciones (listas → tablas) | 4-5 | 5 |
| Fallbacks (prosa → lista con bold) | 1-3 | 4-5 |
| Propuestas genéricas (prosa) | 1-3 | 4-5 |
| **Promedio global** | **4.64** | **~4.85** |

## Veredicto

✅ **Aprobado con matiz:**

1. **El problema NO es el renderizador** — el frontend ya soporta todo lo que el gateway envía
2. **El problema es que el gateway no genera suficiente formato** — fallbacks sin estructura, comparaciones sin tabla
3. **El fix principal es en el prompt del gateway** (P2) — instruir al LLM a usar listas y bold siempre
4. **El fix secundario es agregar tablas** (P3) — gateway genera tablas + frontend las renderiza
5. **NO migrar a react-markdown** — el renderizador custom cubre el 99% de lo que necesitamos, y agregar tablas son ~40 líneas

**El 90% del fix de "información dispersa" es cambio de prompt, no de frontend.**
