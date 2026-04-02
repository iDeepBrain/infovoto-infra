# 06 — Debate: Streaming vs Batch Response

**Tema central:** Implementar streaming (SSE/WebSocket/chunked) para mejorar UX de chat, o mantener batch JSON y optimizar latencia con templates.

**Contexto actual:**
- `POST /api/chat` retorna JSON completo despues de 10-13s de procesamiento
- Ya existe `POST /api/chat/stream` (stub que procesa batch y emite 1 solo evento SSE)
- Frontend (`infovoto-web`) usa `sendMessage()` batch; `sendMessageStream()` existe pero no se usa
- `LLMPort.generate()` retorna `LLMResponse` completa (no hay `generate_stream`)
- Gemini SDK soporta `generate_content_stream()` nativo
- Pipeline: router LLM (800ms) + MCP tools (1-3s) + synthesizer LLM (2-5s) + output filter
- Proxy Next.js: Browser -> `/api/chat` route -> Gateway `/api/chat` (API key server-side)
- Response incluye metadata estructurada: `reply`, `sources`, `candidates`, `warnings`

---

## Participantes

| # | Rol | Enfoque |
|---|-----|---------|
| 1 | Codeforces Grandmaster | Complejidad algortimica, correctitud, edge cases, concurrencia |
| 2 | Senior AI Engineer | LLM streaming, prompt engineering, model APIs, RAG |
| 3 | Senior MLE | Arquitectura hexagonal, clean code, patrones ML en produccion |
| 4 | Junior MLE | Testing, preguntas incomodas, edge cases |
| 5 | Junior Full Stack | DX, onboarding, documentacion, complejidad frontend |
| 6 | AI Tech Lead | Arquitectura de sistema, decision final tecnica |
| 7 | Full Stack Lead | API design, frontend patterns, UX real |
| 8 | Delivery Lead | Plazos, riesgo, usuario final, UX percibida |
| 9 | Staff Engineer | Infraestructura, Cloud Run, proxies, buffering |
| 10 | Product Manager | ROI, metricas de negocio, competencia, prioridades |

---

## Arquitectura Actual (Batch)

```
Browser                Next.js Proxy              Gateway                    Gemini
  |                        |                         |                         |
  |-- POST /api/chat ----->|                         |                         |
  |                        |-- POST /api/chat ------>|                         |
  |                        |   (+ X-API-Key)         |                         |
  |                        |                         |-- Router LLM (800ms) -->|
  |                        |                         |<-- tool selection ------|
  |                        |                         |                         |
  |                        |                         |-- MCP calls (1-3s) ---->|
  |                        |                         |   (perfiles/planes/etc) |
  |                        |                         |                         |
  |                        |                         |-- Synth LLM (2-5s) ---->|
  |                        |                         |<-- full response -------|
  |                        |                         |                         |
  |                        |                         |-- output_filter ------->|
  |                        |<-- JSON {reply,sources} |                         |
  |<-- JSON response ------|                         |                         |
  |                        |                         |                         |
  TOTAL: 10-13s spinner                              |                         |
```

## Arquitectura Propuesta (SSE Streaming)

```
Browser                Next.js Proxy              Gateway                    Gemini
  |                        |                         |                         |
  |-- POST /api/chat ----->|                         |                         |
  |   (Accept: text/       |-- POST /api/chat/stream>|                         |
  |    event-stream)       |   (SSE passthrough)     |                         |
  |                        |                         |-- Router LLM (800ms) -->|
  |                        |                         |<-- tool selection ------|
  |                        |                         |                         |
  |                        |<-- SSE: {type:"status", |                         |
  |<-- "Buscando info..." -|    msg:"Buscando..."}   |                         |
  |                        |                         |-- MCP calls (1-3s) ---->|
  |                        |                         |                         |
  |                        |<-- SSE: {type:"status", |                         |
  |<-- "Generando resp.." -|    msg:"Analizando..."}  |                         |
  |                        |                         |-- Synth LLM stream ---->|
  |                        |                         |<-- token token token ---|
  |                        |<-- SSE: {type:"token",  |                         |
  |<-- "Keiko Fuj"---------|    content:"Keiko Fuj"} |                         |
  |<-- "imori es can"------|<-- SSE: token ----------|                         |
  |<-- "didata por..."-----|<-- SSE: token ----------|                         |
  |                        |                         |                         |
  |                        |<-- SSE: {type:"sources"}|                         |
  |<-- [render sources] ---|<-- SSE: {type:"done"}   |                         |
  |                        |                         |                         |
  TTFB: ~2s (status)       |                         |                         |
  TTFT: ~5s (first token)  |                         |                         |
```

## Comparacion de Protocolos

```
+------------------+----------------+----------------+----------------+
| Criterio         | SSE            | WebSocket      | Chunked JSON   |
+------------------+----------------+----------------+----------------+
| Direccion        | Server -> Client| Bidireccional | Server -> Client|
| Protocolo        | HTTP/1.1+      | WS (upgrade)  | HTTP/1.1+      |
| Reconexion auto  | Si (nativo)    | Manual         | No             |
| Proxy compatible | Si (con headers)| Problematico  | Si             |
| Cloud Run compat | Si             | Si (timeout)   | Si             |
| Auth por request | Si (POST)      | En handshake   | Si (POST)      |
| Tipos de evento  | Si (event:)    | Manual         | Manual         |
| Browser support  | fetch+reader   | WebSocket API  | fetch+reader   |
| Next.js proxy    | StreamingResp  | No trivial     | StreamingResp  |
| Complejidad impl | Media          | Alta           | Baja           |
| Metadata typed   | Si (JSON lines)| Si (frames)   | Si (JSON lines)|
+------------------+----------------+----------------+----------------+
```

---

## Ciclo 1: Viabilidad Tecnica del Streaming en el Pipeline Actual

> **Codeforces Grandmaster:** El pipeline actual es secuencial: `router -> MCP -> synth -> filter`. El streaming solo beneficia la fase `synth` (generacion de texto), que toma 2-5s de los 10-13s totales. Las fases router y MCP son inherentemente batch: necesitas la respuesta completa del router para saber que tools llamar, y necesitas los datos MCP completos para pasarlos al synthesizer. La reduccion de latencia percibida es: de 10-13s de spinner a ~5s de spinner + 5-8s de texto apareciendo. Mejora real del TTFB: de 10-13s a ~5s. Mejora del TTFT (first token): de 10-13s a ~5-8s. No trivial, pero no magico.

> **Senior AI Engineer:** El punto clave que nadie menciona: Gemini `generate_content_stream()` retorna chunks que pueden contener tool calls parciales. El manejo de tool calls en streaming es significativamente mas complejo que en batch. En el pipeline 2-pass, el router LLM SI puede streamear (retorna JSON con tool selection), pero necesitamos el JSON completo para parsearlo. El synth LLM es el unico que genuinamente se beneficia de streaming porque genera texto libre. Propongo: streaming solo en la fase synth, batch para router y MCP.

> **Senior MLE:** Desde la arquitectura hexagonal, necesitamos un nuevo metodo en `LLMPort`:

```python
class LLMPort(Protocol):
    async def generate(self, ...) -> LLMResponse: ...
    async def generate_stream(self, ...) -> AsyncGenerator[str, None]: ...
```

Cada adapter (Gemini, Claude, OpenAI) debe implementar `generate_stream`. El `GeminiAdapter` usaria `generate_content_stream()`, `ClaudeAdapter` usaria `client.messages.stream()`, `OpenAIAdapter` usaria `stream=True`. El patron es limpio, pero son 3 adapters nuevos de testear.

> **Junior MLE:** Pregunta: si el output_filter necesita el texto completo para detectar sesgo (ej: compara longitud de respuesta entre candidatos), no puede filtrar token por token. Eso significa que o (a) acumulamos todo y filtramos al final (perdiendo ventaja de streaming), o (b) aplicamos filtro post-hoc y enviamos correccion, o (c) relajamos el filtro en streaming.

> **Junior Full Stack:** El frontend ya tiene `sendMessageStream()` en `lib/api.ts` con parsing de SSE. Pero el proxy Next.js (`/api/chat/route.ts`) solo hace `fetch` + `res.json()`. Para streaming necesito un nuevo route que haga pipe del SSE response. En Next.js 14 App Router, eso es un `ReadableStream` en el `Response`. No es trivial pasar headers de auth y hacer pipe sin bufferear.

> **AI Tech Lead:** La viabilidad tecnica es clara: es posible, pero el esfuerzo no es trivial. Requiere cambios en 4 capas: LLMPort, adapters, agent core, gateway router, proxy Next.js, y frontend. Ademas el output_filter es un blocker no trivial. Calculo: 3-5 dias de un dev senior.

> **Full Stack Lead:** El UX improvement es real. De "10s de nada" a "2s de nada + status updates + tokens apareciendo" es la diferencia entre "esta roto" y "esta pensando". ChatGPT entreno a los usuarios a esperar streaming. Sin streaming, InfoVoto se siente lento aunque sea igual de rapido que GPT.

> **Delivery Lead:** Estamos a 4 meses de elecciones. 3-5 dias de dev es aceptable SI el riesgo es bajo. Pero el riesgo real no es la implementacion: es el testing. Streaming introduce race conditions, desconexiones parciales, timeouts intermedios, retry logic. El testing matrix se multiplica por 3x.

> **Staff Engineer:** Cloud Run tiene un request timeout de 300s (default) y soporta SSE nativamente. Pero hay un gotcha: Cloud Run HTTP/2 multiplexing puede causar que el proxy de Cloud Run bufferee chunks SSE. Necesitamos `X-Accel-Buffering: no` (ya lo tienen en el stub) y verificar que el Cloud Run proxy no agregue buffering adicional. En produccion vi casos donde Cloud Run bufferea los primeros 4KB antes de enviar. Eso mataria el TTFB de status events.

> **Product Manager:** Los numeros: ChatGPT TTFT es ~1s, Perplexity ~0.5s. InfoVoto actual: 10-13s de nada. Eso es inaceptable para 2026 donde los usuarios estan acostumbrados a streaming. El abandonment rate con 10s de wait es ~60% (dato de Google: cada segundo extra = -7% conversions). Pero: si vamos a reducir latencia a 2-3s con templates/cache, el ROI de streaming baja drasticamente.

**Veredicto Ciclo 1:** 🔄 Necesita mas analisis
- Viabilidad tecnica: confirmada
- Esfuerzo: 3-5 dias (sin tests exhaustivos)
- Riesgo: medio (output_filter, Cloud Run buffering, proxy complexity)
- Pregunta abierta: si templates reducen a 2-3s, el streaming sigue siendo necesario?

---

## Ciclo 2: SSE vs WebSocket vs Chunked — Eleccion de Protocolo

> **Codeforces Grandmaster:** La comunicacion es unidireccional (server -> client) durante la generacion. No hay caso de uso para que el cliente envie datos DURANTE el stream. WebSocket es over-engineering: agrega complejidad de connection management, heartbeats, y reconexion manual. SSE sobre POST con `fetch` + `ReadableStream` es la opcion correcta. Complejidad O(n) de implementacion donde n = capas, vs O(n*m) con WebSocket donde m = estados de conexion.

> **Senior AI Engineer:** Confirmo SSE. Los SDKs de todos los LLM providers retornan SSE nativo (OpenAI, Anthropic, Google). El formato `data: {json}\n\n` es estandar. Ademas, SSE permite typed events (`event: token`, `event: sources`, `event: done`), lo cual simplifica el parsing en frontend. WebSocket seria necesario solo si quisieramos que el usuario cancele mid-generation (abort), pero eso se puede hacer con `AbortController` en la request SSE.

> **Senior MLE:** Una consideracion que no vi: SSE con `EventSource` nativo del browser solo soporta GET. Nosotros necesitamos POST (para enviar el body con el mensaje). Eso significa que NO podemos usar `EventSource` nativo — tenemos que usar `fetch` con `ReadableStream`, que es exactamente lo que ya hace `sendMessageStream()` en el frontend. Es mas codigo que `EventSource`, pero ya esta hecho.

> **Junior MLE:** Encontre un edge case: si la conexion se corta a la mitad del stream (usuario cambia de pagina, pierde wifi), el gateway sigue generando tokens que nadie consume. Con batch, el response se descarta en el proxy. Con SSE, el generator sigue corriendo hasta que FastAPI detecta la desconexion. Pregunta: FastAPI detecta desconexiones en `StreamingResponse`? Si no, estamos quemando tokens de Gemini por nada.

> **Junior Full Stack:** Investigue: FastAPI `StreamingResponse` NO detecta client disconnect automaticamente. El generator sigue ejecutando. Para detectar disconnect hay que usar `request.is_disconnected()` dentro del generator, o usar `anyio.create_task_group` con cancel scope. Esto agrega complejidad al generator. Ref: https://github.com/tiangolo/fastapi/discussions/8553

> **AI Tech Lead:** Protocolo elegido: **SSE via POST + fetch ReadableStream**. Razones:
> 1. Unidireccional (no necesitamos WebSocket)
> 2. Auth por request (no hay session management extra)
> 3. Proxy-friendly (HTTP standard, Cloud Run lo soporta)
> 4. Frontend ya tiene el client implementado
> 5. Cancelacion via `AbortController` (client) + `request.is_disconnected()` (server)

> **Full Stack Lead:** Para el proxy Next.js, el patron es:

```typescript
// app/api/chat/stream/route.ts
export async function POST(req: NextRequest) {
  const body = await req.json();
  const res = await fetch(`${GATEWAY_URL}/api/chat/stream`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "X-API-Key": API_KEY },
    body: JSON.stringify({ message: body.message }),
  });
  // Pipe SSE through
  return new Response(res.body, {
    headers: {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      "Connection": "keep-alive",
    },
  });
}
```

Simple pipe sin buffering. Funciona en Next.js 14 App Router con edge runtime.

> **Delivery Lead:** SSE es la opcion de menor riesgo y menor esfuerzo. WebSocket seria 2-3x mas esfuerzo sin beneficio. Chunked JSON es marginalmente mas simple pero pierde typed events. SSE es el estandar de la industria para LLM streaming. Apruebo.

> **Staff Engineer:** Confirmo compatibilidad con Cloud Run. SSE sobre HTTP/1.1 funciona sin problemas. HTTP/2 tambien pero requiere que el cliente no espere trailers (fetch no los espera). Un punto: Cloud Run tiene un idle timeout de 300s. Si el procesamiento total tarda >300s (no deberia), Cloud Run cortara la conexion. Con nuestro pipeline de 10-13s estamos muy lejos del limite.

> **Product Manager:** Bien. SSE. No necesito mas convincing. Lo que me importa es: el protocolo elegido funciona en celulares 3G? Si el RTT es alto, los chunks SSE se entregan en bursts? Eso podria hacer que el streaming se vea "tartamudo" en conexiones lentas.

**Veredicto Ciclo 2:** ✅ Aprobado
- Protocolo: **SSE via POST + fetch ReadableStream**
- No WebSocket (over-engineering)
- No chunked JSON puro (pierde typed events)
- Pendiente: disconnect detection en el generator

---

## Ciclo 3: Manejo de Metadata en Streaming (sources, candidates, warnings)

> **Codeforces Grandmaster:** El problema de metadata en streaming es un problema de ordenamiento. En batch, todo llega junto. En streaming, hay dependencias: `candidates` se puede determinar despues del router (antes del synth), `sources` se conoce despues de MCP calls, pero `warnings` del output_filter necesitan el texto completo. Propongo un protocolo de eventos con orden definido:

```
1. {type: "status", phase: "routing"}
2. {type: "candidates", data: [...]}         <- despues del router
3. {type: "status", phase: "fetching_data"}
4. {type: "sources", data: [...]}            <- despues de MCP
5. {type: "status", phase: "generating"}
6. {type: "token", content: "Keiko"}         <- stream de synth
7. {type: "token", content: " Fujimori"}
8. ...
9. {type: "warnings", data: [...]}           <- post output_filter
10. {type: "done", session_id: "xxx"}
```

> **Senior AI Engineer:** El orden propuesto es bueno pero hay un detalle: los candidates no siempre salen del router. A veces el router decide "buscar_candidato(nombre=keiko)" y los candidates se extraen del resultado MCP. Asi que candidates deberian ir despues de MCP, no despues del router. Propongo:

```
status:routing -> status:fetching -> sources + candidates -> status:generating -> tokens -> warnings -> done
```

> **Senior MLE:** El problema real es que `process_message()` en `core.py` es un metodo monolitico que hace todo el pipeline internamente. Para emitir eventos intermedios necesitamos refactorizarlo en pasos:

```python
async def process_message_stream(self, req: ProcessRequest) -> AsyncGenerator[StreamEvent, None]:
    # Step 1: Route
    yield StreamEvent(type="status", phase="routing")
    route_result = await self._route(req)

    # Step 2: Execute tools
    yield StreamEvent(type="status", phase="fetching")
    mcp_results = await self._execute_tools(route_result)
    yield StreamEvent(type="sources", data=mcp_results.sources)
    yield StreamEvent(type="candidates", data=mcp_results.candidates)

    # Step 3: Synthesize (streaming)
    yield StreamEvent(type="status", phase="generating")
    async for chunk in self._synthesize_stream(mcp_results):
        yield StreamEvent(type="token", content=chunk)

    # Step 4: Post-process
    warnings = self._apply_output_filter(accumulated_text)
    if warnings:
        yield StreamEvent(type="warnings", data=warnings)

    yield StreamEvent(type="done", session_id=req.session_id)
```

Esto es un refactor significativo del core. El metodo actual `process_message()` seguiria existiendo (para batch) y `process_message_stream()` seria nuevo.

> **Junior MLE:** El output_filter es el problema. El filtro actual en `output_filter.py` busca patrones como "vota por X", mide longitud de respuesta por candidato en comparaciones, y verifica neutralidad. Todo esto requiere el texto completo. Si streameamos tokens y LUEGO el filtro detecta un problema, que hacemos? Enviar un evento de correccion? Reemplazar el texto? El usuario ya leyo tokens que podrian ser sesgados.

> **Junior Full Stack:** Desde el frontend, recibir metadata en orden definido simplifica mucho el rendering:

```typescript
// Pseudo-code del handler
for await (const event of sendMessageStream(message)) {
  switch (event.type) {
    case "status":   setStatus(event.phase); break;
    case "candidates": setCandidates(event.data); break;
    case "sources":  setSources(event.data); break;
    case "token":    appendToReply(event.content); break;
    case "warnings": setWarnings(event.data); break;
    case "done":     setLoading(false); break;
    case "error":    setError(event.message); break;
  }
}
```

Es limpio. Pero necesito mostrar candidates/sources ANTES del texto. El UI actual muestra sources al final. Con streaming, deberia mostrar candidates arriba del texto que va apareciendo.

> **AI Tech Lead:** El output_filter tiene dos opciones viables:
> 1. **Post-stream correction:** Streamear tokens, acumular, filtrar al final, enviar warning si hay problemas. El usuario ve el texto y luego ve un warning. Aceptable para V1.
> 2. **Pre-filter en synth prompt:** Mover las reglas de neutralidad al system prompt del synthesizer (que ya tiene reglas de neutralidad). Confiar mas en el prompt y menos en el filtro post-hoc. El filtro post-hoc queda como safety net con el warning.

Recomiendo opcion 1 para V1. Es mas simple y el riesgo de sesgo en una respuesta individual es bajo (las reglas ya estan en el prompt).

> **Full Stack Lead:** El protocolo de eventos necesita un schema formal. Propongo:

```typescript
type StreamEvent =
  | { type: "status"; phase: "routing" | "fetching" | "generating" }
  | { type: "candidates"; data: CandidateCard[] }
  | { type: "sources"; data: SourceMetadata[] }
  | { type: "token"; content: string }
  | { type: "warnings"; data: Warning[] }
  | { type: "done"; session_id?: string }
  | { type: "error"; message: string }
```

Esto se documenta como contrato y se testea con tipos.

> **Delivery Lead:** La metadata en streaming es el aspecto mas complejo. Pero es solucionable. El output_filter post-stream con warning es pragmatico. La alternativa (no streamear por el filtro) mata todo el beneficio.

> **Staff Engineer:** Un punto sobre el tamano de los eventos SSE: los candidates y sources pueden ser objetos grandes (foto_url, multiples sources). En un evento SSE, todo va en una linea `data:`. No hay limite de tamano en SSE, pero un evento de 10KB en una sola linea es feo. Propongo: si candidates tiene imagenes, enviar solo los datos esenciales (nombre, partido) y que el frontend resuelva las URLs.

> **Product Manager:** Quiero que el usuario vea ALGO util en los primeros 2 segundos. Los status events ("Buscando informacion de Keiko...") cumplen eso. Luego candidates aparecen con nombre y partido. Luego el texto fluye. El usuario nunca mira una pantalla muerta. Eso es lo que necesito.

**Veredicto Ciclo 3:** ✅ Aprobado con condiciones
- Protocolo de eventos: aprobado (7 tipos)
- Output filter: post-stream con warning (V1)
- Refactor de `process_message()`: necesario, crear `process_message_stream()` nuevo
- Candidates/sources ANTES de tokens en el stream
- Schema formal como contrato frontend-backend

---

## Ciclo 4: Impacto en LLMPort y Adapters (Hexagonal)

> **Codeforces Grandmaster:** Agregar `generate_stream` a `LLMPort` es una extension del protocolo, no una modificacion. El metodo `generate()` existente sigue intacto. Los adapters que no implementen `generate_stream` pueden hacer fallback a `generate()` + yield completo. La interfaz es:

```python
class LLMPort(Protocol):
    async def generate(self, ...) -> LLMResponse: ...

    async def generate_stream(
        self,
        messages: list[dict],
        tools: list[ToolSpec],
        system_prompt: str,
        temperature: float = 0.3,
        max_tokens: int = 1024,
    ) -> AsyncGenerator[str, None]:
        """Yield text chunks as they are generated."""
        ...
```

Complejidad: O(1) por adapter. Total: 3 adapters * O(1) = O(3). Razonable.

> **Senior AI Engineer:** Implementacion por adapter:

**GeminiAdapter:**
```python
async def generate_stream(self, ...):
    response = await self.client.aio.models.generate_content_stream(
        model=self.model, contents=contents, config=config
    )
    async for chunk in response:
        if chunk.text:
            yield chunk.text
```

**ClaudeAdapter:**
```python
async def generate_stream(self, ...):
    async with self.client.messages.stream(...) as stream:
        async for text in stream.text_stream:
            yield text
```

**OpenAIAdapter:**
```python
async def generate_stream(self, ...):
    response = await self.client.chat.completions.create(..., stream=True)
    async for chunk in response:
        if chunk.choices[0].delta.content:
            yield chunk.choices[0].delta.content
```

Todos los SDKs soportan streaming nativo. La implementacion es directa.

> **Senior MLE:** El punto critico: `generate_stream` NO debe soportar tool_calls. Los tool calls solo ocurren en la fase router, que es batch. El synth nunca llama tools — solo genera texto. Esto simplifica enormemente la interfaz: `generate_stream` retorna `AsyncGenerator[str, None]`, no chunks mixtos de texto/tool_call.

> **Junior MLE:** Pregunta: si `generate_stream` falla a la mitad (ej: Gemini retorna error en el chunk #15 de 30), que pasa? El frontend ya mostro 14 chunks de texto. Opciones: (a) enviar evento error y el frontend muestra "Error: respuesta incompleta", (b) retry desde cero (pero el usuario ya vio tokens), (c) hacer fallback a batch. Necesitamos definir la estrategia de error mid-stream.

> **Junior Full Stack:** Para el caso de error mid-stream, propongo que el frontend muestre el texto parcial + un banner de error: "La respuesta fue interrumpida. Intenta de nuevo." El usuario ve lo que se genero y puede re-enviar. Es mejor que perder todo.

> **AI Tech Lead:** Estrategia de error:
> 1. Error en router/MCP: enviar evento `error` y cerrar stream. Frontend muestra error normal.
> 2. Error mid-synth: enviar evento `error` despues de los tokens parciales. Frontend muestra texto parcial + banner.
> 3. No hacer retry automatico mid-stream (demasiado complejo para V1).

El fallback a batch no tiene sentido: si el synth falla en streaming, probablemente falla en batch tambien.

> **Full Stack Lead:** Los adapters deben manejar el mapping de errores de cada SDK. Gemini puede lanzar `google.api_core.exceptions.ResourceExhausted`, Claude `anthropic.RateLimitError`, OpenAI `openai.RateLimitError`. Cada adapter debe capturar su error especifico y lanzar un error generico que el generator del gateway pueda convertir en evento SSE de error.

> **Delivery Lead:** Esfuerzo de adapters: 1 dia. Los 3 SDKs soportan streaming. La implementacion es boilerplate. El riesgo esta en el testing, no en la implementacion.

> **Staff Engineer:** Un detalle de infra: el multi-provider failover actual (`CircuitBreaker` + factory) funciona con `generate()`. Para `generate_stream()`, si Gemini falla, el failover a Claude necesita re-crear el stream desde cero. El circuit breaker sigue funcionando igual (se abre/cierra basado en success/failure), pero el retry agrega latencia porque perdemos los tokens ya generados del provider fallido.

> **Product Manager:** Mientras funcione con Gemini (proveedor principal), los edge cases de failover en streaming son P2. Gemini es 99.5%+ uptime. Foco en el happy path primero.

**Veredicto Ciclo 4:** ✅ Aprobado
- `generate_stream` en `LLMPort`: `AsyncGenerator[str, None]` (solo texto, sin tools)
- 3 adapters con implementacion nativa de cada SDK
- Error mid-stream: texto parcial + evento error (no retry)
- Failover en streaming: P2 (V2)

---

## Ciclo 5: Refactor de Agent Core — `process_message_stream()`

> **Codeforces Grandmaster:** El refactor del core es el punto de mayor complejidad. El metodo `process_message()` actual tiene ~200 lineas con cache check, injection check, router, MCP, synth, filter, analytics, token budget. Para streaming necesitamos extraer sub-pasos y hacer yield en los puntos correctos. La complejidad ciclomatica aumenta porque ahora hay dos code paths (batch y stream) que comparten la misma logica de routing y MCP.

Propongo: extraer los pasos a metodos privados y que ambos (`process_message` y `process_message_stream`) los usen:

```
process_message():
    check_injection() -> check_cache() -> _route() -> _execute_tools()
    -> _synthesize() -> _filter() -> _log_analytics() -> return

process_message_stream():
    check_injection() -> check_cache() -> _route() -> yield status
    -> _execute_tools() -> yield sources/candidates
    -> _synthesize_stream() -> yield tokens
    -> _filter(accumulated) -> yield warnings -> yield done
    -> _log_analytics()
```

Los pasos son los mismos, la diferencia es que stream hace yield en los puntos intermedios.

> **Senior AI Engineer:** El cache hit es un caso especial interesante en streaming. Si hay cache hit, la respuesta completa ya esta disponible. Opciones: (a) devolver un stream falso que emite todos los tokens de golpe, (b) simular streaming con delay artificial entre tokens, (c) enviar un evento especial `{type: "cached", data: fullResponse}` y que el frontend lo maneje como batch. Prefiero (c): es honesto y el frontend puede decidir si animar o mostrar de golpe.

> **Senior MLE:** La extraccion a metodos privados es correcta. Pero hay un subtlety: el `_route()` actual maneja fast-routes (regex) Y LLM routing. Los fast-routes no necesitan LLM call y son instantaneos. En streaming, un fast-route resuelve en <100ms, lo cual hace que los status events "routing" aparezcan y desaparezcan tan rapido que son invisibles. Propongo: no emitir status events para fast-routes, ir directo a MCP.

> **Junior MLE:** El testing de `process_message_stream()` es significativamente mas complejo que el de `process_message()`. Necesitamos:
> 1. Tests que consuman el AsyncGenerator completo y verifiquen orden de eventos
> 2. Tests de error mid-stream (mock Gemini que falla en chunk N)
> 3. Tests de disconnect (client drops, generator debe terminar)
> 4. Tests de cache hit en streaming
> 5. Tests de timeout (TimeBudget) en streaming
>
> Eso son ~15-20 tests nuevos solo para el core. Mas los tests de integracion con los adapters reales.

> **Junior Full Stack:** Pregunta inocente: si `process_message_stream()` falla en `_route()` (antes de cualquier token), el stream no tiene que existir. Podemos retornar un error HTTP normal (400/500) en lugar de abrir el stream y emitir un error. Esto simplifica el manejo de errores frontend: si el response code es 200, es un stream valido. Si es 4xx/5xx, es un error normal JSON.

> **AI Tech Lead:** Buena idea del Junior Full Stack. El patron es:

```python
@router.post("/chat/stream")
async def chat_stream(...):
    # Validacion y routing ANTES de abrir el stream
    injection = _check_prompt_injection(body.message)
    if injection:
        raise HTTPException(400, detail=injection)

    # Cache check
    cached = await _check_cache(...)
    if cached:
        # Return batch-like response with cached flag
        return JSONResponse(cached)

    # Si llego aqui, abrimos el stream
    return StreamingResponse(event_generator(), ...)
```

Errores pre-stream son HTTP normales. Errores mid-stream son eventos SSE. Limpio.

> **Full Stack Lead:** Me gusta. El frontend tiene dos code paths:
> 1. `res.headers.get("content-type") === "text/event-stream"` -> consume stream
> 2. `res.headers.get("content-type") === "application/json"` -> cache hit o error

Simple de implementar. Un `if` despues del `fetch`.

> **Delivery Lead:** El refactor del core es el paso mas riesgoso. Tocar `process_message()` para extraer sub-pasos puede romper el flujo batch existente. Propongo: (1) primero extraer sub-pasos sin cambiar el comportamiento de batch (refactor puro), (2) luego agregar `process_message_stream()` que use los mismos sub-pasos. Dos PRs separados.

> **Staff Engineer:** De acuerdo con el Delivery Lead. El refactor del core debe hacerse en pasos:
> - PR1: Extraer `_route()`, `_execute_tools()`, `_synthesize()` como metodos privados. Tests de batch siguen pasando.
> - PR2: Agregar `generate_stream()` a LLMPort + adapters. Tests unitarios de adapters.
> - PR3: Agregar `process_message_stream()` + endpoint SSE funcional. Tests de integracion.
> - PR4: Proxy Next.js + frontend consumption. Tests E2E.

4 PRs, cada uno reviewable y revertible independientemente.

> **Product Manager:** 4 PRs suena a 2 semanas. Es aceptable si empezamos en la semana 2 del sprint. La pregunta es: PR1 (refactor del core) tiene valor de negocio por si solo? Si nos quedamos sin tiempo y solo hacemos PR1+PR2, que ganamos? Nada visible para el usuario. Necesitamos llegar al menos a PR3 para que haya valor.

**Veredicto Ciclo 5:** ✅ Aprobado con plan de ejecucion
- 4 PRs secuenciales, cada uno revertible
- PR1 (refactor core): ~1 dia
- PR2 (LLMPort + adapters): ~1 dia
- PR3 (stream endpoint): ~2 dias
- PR4 (frontend): ~1 dia
- Total: ~5 dias dev + 2-3 dias testing
- Cache hit: retornar JSON normal (no stream falso)
- Errores pre-stream: HTTP normal. Errores mid-stream: SSE event.

---

## Ciclo 6: Frontend — UX de Streaming

> **Codeforces Grandmaster:** El rendering de tokens incrementales tiene un costo de performance. Si el LLM genera 50 tokens/segundo y cada token trigger un `setState` en React, son 50 re-renders/segundo. En un celular de gama media peruano (Redmi 9, Snapdragon 662), eso puede causar jank visible. Solucion: batching de tokens con `requestAnimationFrame` — acumular tokens en un buffer y flush cada 16ms (60fps).

```typescript
const bufferRef = useRef("");
const rafRef = useRef<number>();

function appendToken(token: string) {
  bufferRef.current += token;
  if (!rafRef.current) {
    rafRef.current = requestAnimationFrame(() => {
      setReply(prev => prev + bufferRef.current);
      bufferRef.current = "";
      rafRef.current = undefined;
    });
  }
}
```

> **Senior AI Engineer:** Gemini genera ~30-60 tokens/segundo dependiendo del modelo. Con batching a 60fps, el usuario ve updates cada ~16ms, que es imperceptible. Sin batching, React puede coalesce renders de todas formas (React 18 batching), pero es mejor ser explicito.

> **Senior MLE:** Desde la perspectiva de estado, el frontend necesita manejar un ciclo de vida mas complejo:

```
idle -> loading -> routing -> fetching -> generating -> filtering -> done
                                                                  -> error (desde cualquier estado)
```

Actualmente es `idle -> loading -> done/error`. El nuevo state machine tiene 7 estados. Recomiendo un `useReducer` en lugar de multiples `useState`.

> **Junior MLE:** Test visual: necesitamos verificar que el texto que aparece token-a-token se renderiza correctamente con markdown. Si el reply usa **bold** o listas, un token parcial como `**Kei` rompe el markdown renderer. Opciones: (a) no renderizar markdown hasta `done`, (b) usar un markdown renderer tolerante a texto incompleto, (c) buffer hasta obtener lineas completas antes de renderizar markdown.

> **Junior Full Stack:** Para markdown incremental, `react-markdown` no maneja bien texto parcial. Hay librerias como `marked` que pueden parsear markdown parcial sin crashear. Otra opcion: renderizar el texto como plaintext durante streaming y aplicar markdown solo al hacer `done`. ChatGPT hace esto parcialmente — el markdown se aplica on-the-fly pero con un parser tolerante.

> **AI Tech Lead:** El markdown incremental es un problema real pero solucionable. Propongo para V1: renderizar como plaintext durante streaming, aplicar markdown completo en `done`. Es simple, sin bugs de rendering parcial. Para V2: integrar un parser incremental si el feedback de usuarios lo pide.

> **Full Stack Lead:** Los candidate cards y sources deben aparecer ANTES del texto en streaming. El layout actual es:

```
[user message]
[reply text]
[sources]
```

Con streaming seria:

```
[user message]
[candidate cards]      <- aparecen en fase "fetching" (~2-3s)
[reply text streaming]  <- aparece en fase "generating" (~5s)
[sources footer]        <- aparece con candidates
[warnings banner]       <- aparece en "done"
```

Los candidate cards arriba del texto le dan algo visual al usuario en los primeros 3 segundos. Esto es un cambio de layout.

> **Delivery Lead:** El cambio de layout es riesgoso en UX. Si los candidates aparecen y luego el texto aparece debajo, el scroll se mueve automaticamente. En mobile, eso puede ser confuso. Propongo: mantener el layout actual (cards abajo del texto) pero agregar un skeleton/shimmer mientras se genera. Los cards se llenan cuando llegan y el texto aparece debajo de los cards.

> **Staff Engineer:** Performance del SSE en mobile: el `ReadableStream` API esta soportado en todos los browsers modernos (Chrome 43+, Safari 10.1+, Firefox 65+). En Android 7+ y iOS 10.1+ no hay problema. Peru tiene ~85% Android, mayoria Chrome. Sin concerns de compatibilidad.

> **Product Manager:** Quiero un typing indicator animado (los tres puntos que se mueven) durante las fases "routing" y "fetching". Cuando los tokens empiezan a llegar, el typing indicator desaparece y el texto fluye. Es el patron que usa ChatGPT y Claude. Los usuarios lo entienden intuitivamente.

**Veredicto Ciclo 6:** ✅ Aprobado
- Token batching con `requestAnimationFrame` para performance en mobile
- State machine con `useReducer` (7 estados)
- Markdown: plaintext durante streaming, markdown en `done` (V1)
- Layout: typing indicator -> candidate cards + text streaming -> sources + warnings
- Compatibilidad mobile: sin concerns

---

## Ciclo 7: Cloud Run, Proxies y Buffering

> **Codeforces Grandmaster:** El path completo de un chunk SSE es: Gemini -> GeminiAdapter -> agent core generator -> FastAPI StreamingResponse -> uvicorn -> Cloud Run proxy -> Cloud CDN/Load Balancer -> Internet -> Cloud Run (web) -> Next.js proxy -> Internet -> Browser. Son 8+ hops. Cualquier hop puede bufferear. La latencia de un chunk individual (no el total, sino el tiempo desde que Gemini lo genera hasta que el browser lo recibe) puede ser 50-200ms dependiendo del buffering.

> **Senior AI Engineer:** Los culpables mas comunes de buffering SSE:
> 1. **Uvicorn:** No bufferea por defecto en HTTP/1.1. OK.
> 2. **Cloud Run proxy:** Buffeerea los primeros bytes si el response no tiene `Content-Type: text/event-stream` desde el inicio. Solucion: nuestro `StreamingResponse` ya setea el header.
> 3. **nginx/envoy (Cloud Run internal):** Puede bufferear. `X-Accel-Buffering: no` lo desactiva. Ya lo tenemos.
> 4. **Next.js proxy:** Si usamos `fetch` + pipe, Next.js NO buffeerea el body. OK.
> 5. **Browser:** `ReadableStream.read()` retorna chunks tan pronto como llegan. No buffeerea.

> **Senior MLE:** Un problema especifico de Cloud Run: cuando hay multiple instances con autoscaling, la request se routea a una instancia. Si esa instancia esta cold-starting, el TTFB del SSE incluye el cold start (~2-5s). La solucion es `min-instances: 1` que ya deberiamos tener configurado. Verificar.

> **Junior MLE:** Test que necesitamos: enviar una request SSE desde un ambiente que simule 3G peruano (RTT ~300ms, bandwidth ~1.5Mbps). Verificar que el streaming no se "traba" y que los tokens llegan con fluidez aceptable. Con 50 tokens/s a ~5 chars/token = 250 bytes/s. En 3G eso es nada (1.5Mbps = 187KB/s). Asi que el bandwidth no es problema; el RTT si podria causar bursts.

> **Junior Full Stack:** Cloud Run tiene un timeout de request de 300s (configurable). Nuestro stream maximo es ~15s. Muy lejos del limite. Pero: si configuramos un request timeout menor (ej: 30s) para evitar requests huerfanas, un stream que se cuelga por un bug en el generator sera cortado limpiamente por Cloud Run. Eso es un safety net bueno.

> **AI Tech Lead:** La configuracion de Cloud Run para streaming:

```yaml
# cloudbuild.yaml
- '--timeout=30'              # Request timeout
- '--min-instances=1'         # Avoid cold starts
- '--concurrency=80'          # Max concurrent requests
- '--cpu-throttling=false'    # Keep CPU active during idle
```

`cpu-throttling=false` es importante para streaming: Cloud Run puede throttlear CPU entre chunks si cree que la instancia esta idle. Eso agrega latencia artificial entre chunks.

> **Full Stack Lead:** El proxy Next.js en Cloud Run (infovoto-web) tambien necesita `X-Accel-Buffering: no`. Y el `fetch` interno de Next.js proxy al gateway no debe tener timeout menor que el tiempo total del stream. Actualmente tiene `AbortSignal.timeout(20000)` que es suficiente para 15s de stream.

> **Delivery Lead:** La infraestructura es el area de menor riesgo. Cloud Run soporta SSE nativamente, los headers ya estan configurados, y los timeouts son razonables. El unico action item es verificar `min-instances` y `cpu-throttling` en el deploy actual.

> **Staff Engineer:** Confirmo todo lo anterior. Agrego un punto: en el docker-compose local, el proxy de docker no buffeerea HTTP responses. Pero si usamos `traefik` o `nginx` como reverse proxy local, habria que agregar configuracion anti-buffering. Con docker-compose directo (port mapping) no hay problema.

> **Product Manager:** No tengo concerns de infra. Confio en el equipo tecnico para los detalles de Cloud Run. Mi pregunta es: hay monitoring para detectar si el streaming se degrada? Metricas como TTFB, TTFT, y chunk latency serian utiles para alertar si algo cambia.

**Veredicto Ciclo 7:** ✅ Aprobado
- Cloud Run soporta SSE nativamente
- Headers anti-buffering ya estan en el codigo
- Verificar: `min-instances=1`, `cpu-throttling=false`
- Agregar metricas: TTFB, TTFT, chunk latency (P2)

---

## Ciclo 8: La Pregunta Estrategica — Templates vs Streaming

> **Codeforces Grandmaster:** Si reducimos latencia total de 10-13s a 2-3s con templates/cache, el beneficio marginal de streaming baja drasticamente. Con 2-3s, el usuario ve un spinner por 2-3s y luego la respuesta completa. Es comparable a una busqueda de Google. Nadie se queja de que Google no streamea sus resultados. El ROI de streaming con 2-3s batch es: reducir percepcion de 2-3s a 1s (TTFB con status) + 1-2s de tokens. Marginalmente mejor pero no transformador.

> **Senior AI Engineer:** Los templates son una solucion ortogonal al streaming. Templates reducen el tiempo TOTAL (eliminan LLM calls para queries comunes). Streaming reduce el tiempo PERCIBIDO (mismo tiempo total, pero el usuario ve progreso). En un sistema maduro, quieres ambos:

```
Query comun + cache hit:     0.1s (template, no streaming necesario)
Query comun + cache miss:    2-3s batch (template generado, fast enough)
Query compleja (comparacion): 5-8s total, streaming beneficial
Query de follow-up:          3-5s total, streaming nice-to-have
```

El streaming beneficia mas a las queries complejas que los templates no cubren.

> **Senior MLE:** El analisis costo-beneficio:

```
+-------------------+--------+------------------+------------------+
| Metrica           | Actual | Con Templates    | Templates + SSE  |
+-------------------+--------+------------------+------------------+
| P50 TTFB          | 10s    | 0.1s (cached)    | 0.1s (cached)    |
| P50 TTFB (miss)   | 10s    | 2-3s             | 1-2s (status)    |
| P95 TTFB          | 13s    | 5-8s (complejo)  | 2-3s (status)    |
| P95 Total         | 13s    | 5-8s             | 5-8s             |
| Esfuerzo dev      | 0      | 3-5 dias         | 5-8 dias (+SSE)  |
| Riesgo            | 0      | Bajo             | Medio            |
+-------------------+--------+------------------+------------------+
```

Templates mejoran P50 dramaticamente. SSE mejora P95 percibido. Si el budget es limitado, templates primero.

> **Junior MLE:** Pregunta incomoda: si hacemos templates primero y luego SSE, el refactor del core se hace dos veces. Primero para templates (cache layer), luego para streaming (generator). No seria mejor hacer el refactor una vez, preparando para ambos?

> **Junior Full Stack:** Desde el frontend, el esfuerzo de implementar streaming es el mismo independientemente de si los templates estan o no. Si vamos a hacer streaming eventualmente, el frontend deberia implementarlo ahora. La decision es solo sobre el backend.

> **AI Tech Lead:** La pregunta real es: cual es el ORDEN optimo?

**Opcion A:** Templates primero, SSE despues
- Semana 1-2: Templates + cache -> P50 baja a 0.1s
- Semana 3-4: SSE -> P95 percibido baja
- Riesgo: bajo (cada paso es independiente)

**Opcion B:** SSE primero, templates despues
- Semana 1-2: SSE -> P95 percibido baja, P50 sigue en 10s
- Semana 3-4: Templates -> P50 baja a 0.1s
- Riesgo: medio (SSE mas complejo, si falla perdemos 2 semanas)

**Opcion C:** Ambos en paralelo (2 devs)
- Semana 1-2: Template dev + SSE dev
- Semana 3: Integracion
- Riesgo: alto (merge conflicts en core.py)

Recomiendo **Opcion A**: templates primero. Maximo impacto en P50, menor riesgo.

> **Full Stack Lead:** De acuerdo con Opcion A. Templates le dan a la mayoria de usuarios (60-70% hacen queries comunes) una experiencia instantanea. SSE mejora la experiencia del 30-40% restante con queries complejas. Impacto * probabilidad favorece templates.

> **Delivery Lead:** Opcion A. Sin debate. Templates tienen ROI inmediato y riesgo bajo. SSE es un nice-to-have que podemos implementar despues. Si nos quedamos sin tiempo antes de elecciones, preferimos 70% de queries instantaneas (templates) a 100% de queries con streaming pero 10s (SSE sin templates).

> **Staff Engineer:** Opcion A tambien desde infra. Templates son un cache layer que no cambia la arquitectura. SSE requiere cambios en Cloud Run config, proxy, frontend. Mas superficie de ataque.

> **Product Manager:** Opcion A. Los numeros son claros. Pero quiero que el plan incluya SSE como P1 para despues de templates. No quiero que se convierta en "lo hacemos despues" y nunca se haga. El roadmap debe tener: Sprint 1 = Templates, Sprint 2 = SSE. Con fecha.

**Veredicto Ciclo 8:** ✅ Aprobado
- **Orden: Templates primero (Sprint 1), SSE despues (Sprint 2)**
- Templates: 3-5 dias, impacto en 60-70% de queries
- SSE: 5-8 dias, impacto en queries complejas (P95)
- El refactor del core (PR1) puede hacerse en Sprint 1 como preparacion para ambos

---

## Ciclo 9: Plan de Implementacion Detallado

> **Codeforces Grandmaster:** El plan de 4 PRs del Ciclo 5 es correcto pero necesita dependencias explicitas:

```
PR1: Refactor core (extract _route, _execute_tools, _synthesize)
  |
  +---> PR2: LLMPort.generate_stream + 3 adapters
  |       |
  |       +---> PR3: process_message_stream() + /api/chat/stream real
  |               |
  |               +---> PR4: Next.js proxy + frontend streaming UI
  |
  +---> PR-T1: Template engine (independiente, usa _route y _synthesize)
```

PR1 es el cuello de botella. Sin PR1, ni templates ni streaming pueden avanzar limpiamente. PR2/PR3/PR4 son secuenciales. PR-T1 puede ir en paralelo con PR2.

> **Senior AI Engineer:** Detalle tecnico de PR2 — los tests de cada adapter deben incluir:
> 1. Happy path: stream completo, verificar que todos los tokens se concatenan al texto esperado
> 2. Empty response: stream que termina sin tokens (Gemini retorna 0 tokens a veces con safety filters)
> 3. Rate limit mid-stream: el provider corta con error despues de N tokens
> 4. Timeout: el stream tarda mas de lo esperado (TimeBudget integration)

Mock tests con fixtures pre-grabadas de cada SDK. No hits reales a APIs en CI.

> **Senior MLE:** El contrato de eventos SSE debe documentarse como un file en `docs/contracts/`:

```python
# docs/contracts/sse_events.py
from pydantic import BaseModel
from typing import Literal

class StatusEvent(BaseModel):
    type: Literal["status"]
    phase: Literal["routing", "fetching", "generating"]
    message: str  # Human-readable: "Buscando informacion..."

class TokenEvent(BaseModel):
    type: Literal["token"]
    content: str

class CandidatesEvent(BaseModel):
    type: Literal["candidates"]
    data: list[CandidateCardResponse]

class SourcesEvent(BaseModel):
    type: Literal["sources"]
    data: list[SourceMetadata]

class WarningsEvent(BaseModel):
    type: Literal["warnings"]
    data: list[Warning]

class DoneEvent(BaseModel):
    type: Literal["done"]
    session_id: str | None = None

class ErrorEvent(BaseModel):
    type: Literal["error"]
    message: str
```

Esto sirve de contrato y de documentacion. El frontend puede generar tipos TypeScript desde esto.

> **Junior MLE:** Pregunta de testing E2E: como testeamos el streaming end-to-end sin hacer calls reales a Gemini? Propongo un modo de test donde el agent usa un `MockLLMAdapter` que genera tokens fijos con delay artificial. Asi podemos verificar todo el pipeline (gateway -> proxy -> frontend) sin costos de API.

> **Junior Full Stack:** Para el frontend, propongo un feature flag: `NEXT_PUBLIC_ENABLE_STREAMING=true|false`. Si esta off, usa `sendMessage()` batch. Si esta on, usa `sendMessageStream()`. Esto permite deploy incremental: habilitar streaming para testers primero, luego para todos.

> **AI Tech Lead:** Buen punto del feature flag. Lo agrego al plan:

```
PR1: Refactor core                    [1 dia]
PR2: LLMPort.generate_stream          [1 dia]
PR3: process_message_stream + SSE     [2 dias]
PR4: Next.js proxy stream route       [0.5 dias]
PR5: Frontend streaming UI + flag     [1.5 dias]
---
Total: 6 dias dev + 2-3 dias testing
Feature flag: FEATURE_STREAMING_ENABLED (gateway) + NEXT_PUBLIC_ENABLE_STREAMING (web)
```

> **Full Stack Lead:** Criterios de aceptacion para el streaming completo:
> 1. TTFB (primer evento status) < 2s para queries normales
> 2. TTFT (primer token de texto) < 6s para queries normales
> 3. No jank visible en Redmi 9 / Chrome Android
> 4. Disconnect handling: generator se detiene si el client se desconecta
> 5. Error mid-stream muestra texto parcial + banner de error
> 6. Cache hit retorna JSON normal (no stream)
> 7. Feature flag funciona: off = batch, on = stream

> **Delivery Lead:** 6 dias dev + 3 dias testing = 9 dias = ~2 sprints. Asumiendo Sprint 1 para templates, Sprint 2 para streaming, tenemos entrega en semana 4. Con 4 meses para elecciones (16 semanas), eso nos deja 12 semanas para estabilizar. Aceptable.

> **Staff Engineer:** Monitoring que necesitamos post-deploy:
> - `streaming_ttfb_seconds` (histogram): tiempo hasta primer evento
> - `streaming_ttft_seconds` (histogram): tiempo hasta primer token
> - `streaming_total_seconds` (histogram): tiempo total del stream
> - `streaming_errors_total` (counter): errores mid-stream
> - `streaming_disconnects_total` (counter): client disconnects antes de done

> **Product Manager:** Los criterios de aceptacion son buenos. Agrego uno de negocio: la tasa de abandono (usuario cierra antes de `done`) debe ser menor con streaming que con batch. Medirlo: analytics event en `done` vs analytics event en request start. Si abandonan igual con streaming, el feature no agrego valor y podemos revertir.

**Veredicto Ciclo 9:** ✅ Aprobado
- Plan de 5 PRs con dependencias claras
- Feature flag en gateway y web
- Criterios de aceptacion definidos (7 tecnicas + 1 de negocio)
- Monitoring: 5 metricas nuevas
- Timeline: Sprint 2 (despues de templates)

---

## Ciclo 10: Riesgos, Rollback y Decision Final

> **Codeforces Grandmaster:** Riesgos enumerados por probabilidad * impacto:

| # | Riesgo | Prob | Impacto | Mitigacion |
|---|--------|------|---------|------------|
| 1 | Output filter no puede operar en streaming | Alta | Medio | Post-stream filter + warning (Ciclo 3) |
| 2 | Cloud Run buffeerea chunks | Media | Alto | Headers anti-buffering + test manual |
| 3 | Markdown rendering parcial roto | Media | Bajo | Plaintext durante stream (V1) |
| 4 | Error mid-stream confunde al usuario | Media | Medio | Texto parcial + banner de error |
| 5 | Performance en mobile gama baja | Baja | Medio | Token batching con RAF |
| 6 | Refactor core rompe batch | Baja | Alto | PR1 separado, tests exhaustivos |
| 7 | Next.js proxy buffeerea SSE | Baja | Alto | Test E2E con proxy |

Ningun riesgo es P0-showstopper. Todos tienen mitigacion.

> **Senior AI Engineer:** El rollback es trivial gracias al feature flag. Si streaming causa problemas en produccion:
> 1. Setear `FEATURE_STREAMING_ENABLED=false` en Cloud Run env
> 2. Redeploy (0 codigo, solo config)
> 3. El gateway retorna batch en `/api/chat/stream` (o el frontend usa `/api/chat`)
>
> Tiempo de rollback: <5 minutos.

> **Senior MLE:** El codigo de streaming es adtivo: no modifica el path batch existente. `process_message()` sigue funcionando identico. `process_message_stream()` es un metodo NUEVO. El endpoint `/api/chat` no cambia. El endpoint `/api/chat/stream` ya existe (stub) y se reemplaza. El riesgo de regresion en batch es cercano a cero si el refactor de PR1 tiene tests.

> **Junior MLE:** Lista de tests minimos antes de merge:
> - [ ] Batch `/api/chat` sigue funcionando identico (regresion)
> - [ ] Stream happy path: status -> candidates -> sources -> tokens -> done
> - [ ] Stream con cache hit: retorna JSON
> - [ ] Stream con error pre-routing: retorna HTTP error
> - [ ] Stream con error mid-synth: tokens parciales + error event
> - [ ] Stream disconnect: generator termina en <1s
> - [ ] Frontend feature flag off: usa batch
> - [ ] Frontend feature flag on: consume stream correctamente
> - [ ] Mobile: no jank en Chrome Android

> **Junior Full Stack:** Documentacion necesaria:
> 1. Contrato SSE en `docs/contracts/sse_events.md` (o `.py` tipado)
> 2. README de como testear streaming localmente
> 3. Feature flag documentation en config

> **AI Tech Lead:** Mi evaluacion final:

**A favor de implementar streaming:**
- UX dramaticamente mejor para queries complejas (P95: 5-8s)
- Estandar de la industria (ChatGPT, Claude, Perplexity lo hacen)
- El stub ya existe — el framework esta ahi
- Feature flag permite rollback instantaneo
- Preparacion para WhatsApp progressive responses (futuro)

**En contra:**
- 6+3 dias de esfuerzo con templates como alternativa mas simple
- Complejidad operacional (monitoring, debugging de streams)
- Output filter degradado en streaming

**Mi decision:** Implementar, pero DESPUES de templates. Prioridad P1, no P0.

> **Full Stack Lead:** De acuerdo. El frontend esta preparado (`sendMessageStream()` ya existe). El esfuerzo frontend es ~2 dias. El backend es el cuello de botella. Con el refactor del core (PR1) hecho en Sprint 1 para templates, el camino para SSE en Sprint 2 esta pavimentado.

> **Delivery Lead:** Confirmado. Sprint 1 = templates + refactor core. Sprint 2 = SSE. Si Sprint 2 se complica, el feature flag permite shippear sin streaming y agregarlo despues. El usuario tiene templates desde Sprint 1, que es la mayor mejora.

> **Staff Engineer:** Desde infra, no hay blockers. Cloud Run soporta SSE, los headers estan configurados, el timeout es suficiente. El unico prerequisite es verificar `cpu-throttling` y `min-instances` antes de Sprint 2.

> **Product Manager:** Decision final: **SI, implementar streaming. Prioridad P1. Timeline: Sprint 2 (semanas 3-4). Requisito previo: Templates en Sprint 1.** El streaming es un diferenciador competitivo. InfoVoto sera el primer chatbot electoral peruano con streaming. Eso es marketing gratuito. Pero sin templates primero, estamos optimizando la experiencia del 30% en vez del 70%.

**Veredicto Ciclo 10:** ✅ Aprobado

---

## VEREDICTO FINAL

### Decision

**SI, implementar SSE streaming para `POST /api/chat/stream`.**

### Protocolo

**SSE via POST + fetch ReadableStream** (no WebSocket, no chunked JSON)

### Prioridad

**P1 — Sprint 2 (semanas 3-4), DESPUES de templates en Sprint 1**

### Justificacion

1. UX transformadora para queries complejas (TTFB de 10-13s a 2-3s percibido)
2. Estandar de la industria que los usuarios esperan
3. Infraestructura compatible (Cloud Run, Next.js, SDKs de LLM)
4. Feature flag permite rollback instantaneo
5. El stub de SSE y el client frontend ya existen

### Plan de Ejecucion

```
Sprint 1 (semanas 1-2):
  PR1: Refactor core — extraer _route(), _execute_tools(), _synthesize()
  PR-T1: Template engine + cache (usa metodos extraidos)

Sprint 2 (semanas 3-4):
  PR2: LLMPort.generate_stream() + GeminiAdapter + ClaudeAdapter + OpenAIAdapter
  PR3: agent.process_message_stream() + /api/chat/stream real
  PR4: Next.js proxy /api/chat/stream route
  PR5: Frontend streaming UI + feature flag + useReducer state machine
```

### Protocolo de Eventos SSE

```
{type: "status",     phase: "routing"|"fetching"|"generating", message: str}
{type: "candidates", data: CandidateCard[]}
{type: "sources",    data: SourceMetadata[]}
{type: "token",      content: str}
{type: "warnings",   data: Warning[]}
{type: "done",       session_id?: str}
{type: "error",      message: str}
```

### Criterios de Aceptacion

| # | Criterio | Target |
|---|----------|--------|
| 1 | TTFB (primer status event) | < 2s |
| 2 | TTFT (primer token de texto) | < 6s |
| 3 | No jank en mobile gama media | Redmi 9 / Chrome Android |
| 4 | Disconnect handling | Generator termina en <1s |
| 5 | Error mid-stream | Texto parcial + banner error |
| 6 | Cache hit | Retorna JSON (no stream) |
| 7 | Feature flag off | Comportamiento batch identico |
| 8 | Abandonment rate | Menor con streaming que batch |

### Diagrama Final de Arquitectura

```
                          STREAMING PATH
                          ==============

Browser                 Next.js                Gateway               LLM Provider
   |                      |                      |                       |
   |-- POST /api/chat --->|                      |                       |
   |   {message}          |-- POST /stream ----->|                       |
   |                      |   (+API Key)         |                       |
   |                      |                      |-- _route() ---------->|
   |                      |<-- SSE: status ------|<-- route result ------|
   |<-- "Buscando..." ----|                      |                       |
   |                      |                      |-- _execute_tools() -->|
   |                      |<-- SSE: candidates --|   (MCP calls)        |
   |<-- [cards render] ---|<-- SSE: sources -----|                       |
   |                      |                      |                       |
   |                      |                      |-- _synth_stream() --->|
   |                      |<-- SSE: token -------|<-- chunk chunk chunk -|
   |<-- "Keiko Fu" -------|<-- SSE: token -------|                       |
   |<-- "jimori es" ------|<-- SSE: token -------|                       |
   |<-- " candidata" -----|                      |                       |
   |                      |                      |-- output_filter() --->|
   |                      |<-- SSE: warnings ----|                       |
   |<-- [warning banner] -|<-- SSE: done --------|                       |
   |                      |                      |                       |


                          BATCH PATH (sin cambios)
                          ========================

Browser --- POST /api/chat ---> Next.js --- POST /api/chat ---> Gateway
                                                                   |
                                                         route + MCP + synth + filter
                                                                   |
Browser <-- JSON {reply,sources,candidates,warnings} <-------------|
```

### Riesgos Aceptados

1. Output filter opera post-stream (warning despues de tokens, no bloqueo mid-stream)
2. Markdown se renderiza como plaintext durante streaming (V1)
3. Failover multi-provider en streaming es batch (pierde tokens parciales del provider fallido)

### Condiciones de Rollback

- Feature flag `FEATURE_STREAMING_ENABLED=false` -> rollback sin deploy de codigo
- Si abandonment rate no mejora en 2 semanas post-deploy -> evaluar reversion
- Si errores mid-stream > 5% de requests -> desactivar y debuggear
