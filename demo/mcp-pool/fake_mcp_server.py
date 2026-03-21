"""POOL-01: Fake MCP Server — simula un MCP con latencia configurable.

Uso:
    uvicorn fake_mcp_server:app --port 9001
    uvicorn fake_mcp_server:app --port 9002  # segundo server

    # Test rápido
    curl localhost:9001/health
    curl -X POST localhost:9001/tools/call -H 'Content-Type: application/json' \
         -d '{"name": "fake_tool_a", "arguments": {"query": "test"}}'

    # Con delay
    curl -X POST 'localhost:9001/tools/call?delay=0.5' -H 'Content-Type: application/json' \
         -d '{"name": "fake_tool_a", "arguments": {"query": "test"}}'

Env vars:
    SERVER_NAME   = nombre del server (default: "fake-mcp-1")
    TOOL_NAMES    = tools comma-separated (default: "fake_tool_a,fake_tool_b")
    FAIL_RATE     = probabilidad de error 0.0-1.0 (default: 0.0)
"""

import asyncio
import os
import random
import time

from fastapi import FastAPI, Query, Request

SERVER_NAME = os.getenv("SERVER_NAME", "fake-mcp-1")
TOOL_NAMES = os.getenv("TOOL_NAMES", "fake_tool_a,fake_tool_b").split(",")
FAIL_RATE = float(os.getenv("FAIL_RATE", "0.0"))

app = FastAPI(title=f"Fake MCP: {SERVER_NAME}")

_call_count = 0
_start_time = time.monotonic()


@app.get("/health")
async def health():
    return {"status": "ok", "service": SERVER_NAME, "uptime_s": round(time.monotonic() - _start_time, 1)}


@app.get("/metadata")
async def metadata():
    return {
        "name": SERVER_NAME,
        "version": "1.0.0-fake",
        "tools": [
            {"name": t.strip(), "description": f"Fake tool {t.strip()}", "parameters": ["query"]}
            for t in TOOL_NAMES
        ],
    }


@app.post("/tools/call")
async def tools_call(request: Request, delay: float = Query(default=0.05)):
    global _call_count
    _call_count += 1

    body = await request.json()
    name = body.get("name", "unknown")
    args = body.get("arguments", {})

    # Simular fallo aleatorio
    if random.random() < FAIL_RATE:
        return {"error": f"Simulated failure for {name}", "call_number": _call_count}

    # Simular latencia
    if delay > 0:
        await asyncio.sleep(delay)

    return {
        "result": {
            "tool": name,
            "args": args,
            "server": SERVER_NAME,
            "call_number": _call_count,
            "simulated_delay_ms": round(delay * 1000, 1),
        }
    }


@app.get("/stats")
async def stats():
    return {
        "server": SERVER_NAME,
        "total_calls": _call_count,
        "uptime_s": round(time.monotonic() - _start_time, 1),
        "fail_rate": FAIL_RATE,
    }


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=9001)
