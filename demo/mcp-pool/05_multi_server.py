"""POOL-06: Multi-Server Tool Routing — 3 servers, routing O(1).

Requiere 3 fake servers:
    SERVER_NAME=perfiles TOOL_NAMES=buscar_candidato uvicorn fake_mcp_server:app --port 9001
    SERVER_NAME=planes TOOL_NAMES=buscar_propuesta uvicorn fake_mcp_server:app --port 9002
    SERVER_NAME=logistica TOOL_NAMES=consultar_local uvicorn fake_mcp_server:app --port 9003

    # O usa --auto para levantarlos automáticamente
    python 05_multi_server.py --auto

Uso:
    python 05_multi_server.py
    python 05_multi_server.py --auto --calls 100
"""

import argparse
import asyncio
import os
import signal
import subprocess
import sys
import time

import httpx


class MultiPool:
    """Multi-server pool con tool routing O(1) — versión demo."""

    def __init__(self, pool_size_per_server: int = 3):
        self.pool_size = pool_size_per_server
        self._pools: dict[str, asyncio.Queue[httpx.AsyncClient]] = {}  # url → queue
        self._tool_map: dict[str, str] = {}  # tool_name → url
        self._stats_per_server: dict[str, dict] = {}

    async def add_server(self, url: str, tools: list[str]):
        queue: asyncio.Queue[httpx.AsyncClient] = asyncio.Queue(maxsize=self.pool_size)
        for _ in range(self.pool_size):
            client = httpx.AsyncClient(
                base_url=url,
                timeout=httpx.Timeout(connect=2.0, read=2.0, write=2.0, pool=2.0),
                limits=httpx.Limits(max_connections=1, max_keepalive_connections=1),
            )
            await queue.put(client)
        self._pools[url] = queue
        self._stats_per_server[url] = {"calls": 0, "errors": 0}
        for tool in tools:
            self._tool_map[tool] = url
        print(f"  Added {url}: tools={tools}, pool_size={self.pool_size}")

    async def call_tool(self, name: str, args: dict) -> dict:
        url = self._tool_map.get(name)
        if not url:
            return {"error": f"Tool '{name}' not found in any server"}

        queue = self._pools[url]
        client = await asyncio.wait_for(queue.get(), timeout=0.5)
        try:
            t0 = time.perf_counter()
            resp = await client.post("/tools/call", json={"name": name, "arguments": args})
            elapsed_ms = (time.perf_counter() - t0) * 1000
            resp.raise_for_status()
            self._stats_per_server[url]["calls"] += 1
            data = resp.json().get("result", resp.json())
            data["routing_latency_ms"] = round(elapsed_ms, 2)
            return data
        except Exception as e:
            self._stats_per_server[url]["errors"] += 1
            return {"error": str(e)}
        finally:
            await queue.put(client)

    async def call_tools_parallel(self, calls: list[dict]) -> list[dict]:
        return list(await asyncio.gather(
            *[self.call_tool(c["name"], c["args"]) for c in calls]
        ))

    async def close(self):
        for queue in self._pools.values():
            while not queue.empty():
                client = await queue.get()
                await client.aclose()


SERVERS = [
    {"port": 9001, "name": "perfiles", "tools": ["buscar_candidato", "verificar_antecedentes"]},
    {"port": 9002, "name": "planes", "tools": ["buscar_propuesta", "comparar_planes"]},
    {"port": 9003, "name": "logistica", "tools": ["consultar_local", "consultar_multas"]},
]


async def run_tests(multi: MultiPool, num_calls: int):
    print(f"\n--- Test 1: Routing — cada tool va a su server ---")
    all_tools = []
    for s in SERVERS:
        all_tools.extend(s["tools"])

    for tool in all_tools:
        result = await multi.call_tool(tool, {"query": "test"})
        server = result.get("server", "?")
        latency = result.get("routing_latency_ms", "?")
        print(f"  {tool:>25} → server={server}, latency={latency}ms")

    print(f"\n--- Test 2: Parallel dispatch — {num_calls} calls mixtas ---")
    calls = [{"name": all_tools[i % len(all_tools)], "args": {"query": f"q{i}"}} for i in range(num_calls)]

    t0 = time.perf_counter()
    results = await multi.call_tools_parallel(calls)
    total_s = time.perf_counter() - t0

    ok = sum(1 for r in results if "error" not in r)
    errors = num_calls - ok
    print(f"  Completed: {ok}/{num_calls} OK, {errors} errors")
    print(f"  Total time: {total_s:.2f}s ({num_calls/total_s:.0f} calls/sec)")

    print(f"\n--- Stats por server ---")
    for url, stats in multi._stats_per_server.items():
        name = url.split(":")[-1]
        print(f"  :{name} → calls={stats['calls']}, errors={stats['errors']}")


async def run_manual():
    print("\nConectando a servers existentes...")
    multi = MultiPool(pool_size_per_server=3)
    for s in SERVERS:
        url = f"http://localhost:{s['port']}"
        await multi.add_server(url, s["tools"])

    await run_tests(multi, num_calls=30)
    await multi.close()


async def run_auto(num_calls: int):
    procs = []
    demo_dir = str(__import__("pathlib").Path(__file__).parent)

    print("Levantando 3 fake servers...")
    for s in SERVERS:
        env = {
            **os.environ,
            "SERVER_NAME": s["name"],
            "TOOL_NAMES": ",".join(s["tools"]),
        }
        proc = subprocess.Popen(
            [sys.executable, "-m", "uvicorn", "fake_mcp_server:app", "--port", str(s["port"]), "--log-level", "warning"],
            cwd=demo_dir,
            env=env,
        )
        procs.append(proc)

    await asyncio.sleep(1.5)  # Wait for all to start

    multi = MultiPool(pool_size_per_server=3)
    for s in SERVERS:
        await multi.add_server(f"http://localhost:{s['port']}", s["tools"])

    await run_tests(multi, num_calls=num_calls)
    await multi.close()

    print("\nCerrando servers...")
    for proc in procs:
        proc.send_signal(signal.SIGTERM)
        proc.wait(timeout=3)


async def main():
    parser = argparse.ArgumentParser(description="POOL-06: Multi-server routing")
    parser.add_argument("--auto", action="store_true", help="Auto start/stop servers")
    parser.add_argument("--calls", type=int, default=30, help="Number of parallel calls")
    args = parser.parse_args()

    print("=" * 70)
    print("POOL-06: Multi-Server Tool Routing")
    print("=" * 70)

    if args.auto:
        await run_auto(args.calls)
    else:
        await run_manual()


if __name__ == "__main__":
    asyncio.run(main())
