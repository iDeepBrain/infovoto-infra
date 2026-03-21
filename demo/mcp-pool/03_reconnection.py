"""POOL-04: Reconnection Under Load — matar servidor y verificar recuperación.

Requiere:
    Terminal 1: uvicorn fake_mcp_server:app --port 9001
    Terminal 2: python 03_reconnection.py

El script te pide que mates el server manualmente (Ctrl+C) y lo reinicies.
Mide cuántas calls fallan y cuántas se recuperan con reconexión automática.

Uso:
    python 03_reconnection.py
    python 03_reconnection.py --auto  # mata y reinicia automáticamente con subprocess
"""

import argparse
import asyncio
import signal
import subprocess
import sys
import time

import httpx


class ResilientPoolDemo:
    """Pool con reconexión — versión simplificada para experimentar."""

    def __init__(self, url: str, pool_size: int = 5):
        self.url = url
        self.pool_size = pool_size
        self._queue: asyncio.Queue[httpx.AsyncClient] = asyncio.Queue(maxsize=pool_size)
        self.stats = {"calls": 0, "errors": 0, "reconnects": 0, "reconnect_failures": 0}

    async def start(self):
        for _ in range(self.pool_size):
            client = self._make_client()
            await self._queue.put(client)
        print(f"Pool started: {self.pool_size} connections to {self.url}")

    def _make_client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            base_url=self.url,
            timeout=httpx.Timeout(connect=2.0, read=2.0, write=2.0, pool=2.0),
            limits=httpx.Limits(max_connections=1, max_keepalive_connections=1),
        )

    async def call_tool(self, name: str, args: dict) -> dict:
        client = await asyncio.wait_for(self._queue.get(), timeout=1.0)
        try:
            # Attempt 1
            resp = await client.post("/tools/call", json={"name": name, "arguments": args})
            resp.raise_for_status()
            self.stats["calls"] += 1
            return resp.json().get("result", resp.json())
        except Exception as e1:
            self.stats["errors"] += 1
            # Reconnect
            try:
                await client.aclose()
            except Exception:
                pass
            client = self._make_client()
            self.stats["reconnects"] += 1

            # Attempt 2
            try:
                resp = await client.post("/tools/call", json={"name": name, "arguments": args})
                resp.raise_for_status()
                self.stats["calls"] += 1
                return resp.json().get("result", resp.json())
            except Exception as e2:
                self.stats["reconnect_failures"] += 1
                return {"error": f"attempt1: {e1}, attempt2: {e2}"}
        finally:
            await self._queue.put(client)

    async def close(self):
        while not self._queue.empty():
            client = await self._queue.get()
            await client.aclose()


async def continuous_calls(pool: ResilientPoolDemo, duration_s: float, interval_s: float = 0.2):
    """Hace calls continuas durante duration_s segundos."""
    results = []
    t_start = time.monotonic()
    call_id = 0

    while time.monotonic() - t_start < duration_s:
        call_id += 1
        t0 = time.monotonic()
        result = await pool.call_tool("fake_tool_a", {"query": f"call-{call_id}"})
        elapsed_ms = (time.monotonic() - t0) * 1000
        ok = "error" not in result
        status = "OK" if ok else "FAIL"
        results.append({"id": call_id, "ok": ok, "ms": elapsed_ms, "t": time.monotonic() - t_start})
        print(f"  [{status}] call-{call_id}: {elapsed_ms:.0f}ms (t={results[-1]['t']:.1f}s)")
        await asyncio.sleep(interval_s)

    return results


async def run_manual(url: str):
    pool = ResilientPoolDemo(url, pool_size=5)
    await pool.start()

    print("\n--- Fase 1: Calls normales (5s) ---")
    r1 = await continuous_calls(pool, duration_s=5, interval_s=0.3)

    print("\n" + "!" * 50)
    print("AHORA: Mata el server (Ctrl+C en la terminal del server)")
    print("Tienes 5 segundos...")
    print("!" * 50)
    await asyncio.sleep(5)

    print("\n--- Fase 2: Calls con server muerto (5s) ---")
    r2 = await continuous_calls(pool, duration_s=5, interval_s=0.5)

    print("\n" + "!" * 50)
    print("AHORA: Reinicia el server (uvicorn fake_mcp_server:app --port 9001)")
    print("Tienes 5 segundos...")
    print("!" * 50)
    await asyncio.sleep(5)

    print("\n--- Fase 3: Calls después de reinicio (5s) ---")
    r3 = await continuous_calls(pool, duration_s=5, interval_s=0.3)

    # Summary
    all_results = r1 + r2 + r3
    ok_count = sum(1 for r in all_results if r["ok"])
    fail_count = sum(1 for r in all_results if not r["ok"])

    print("\n" + "=" * 50)
    print("RESUMEN")
    print("=" * 50)
    print(f"  Total calls: {len(all_results)}")
    print(f"  OK: {ok_count}  FAIL: {fail_count}")
    print(f"  Pool stats: {pool.stats}")
    print(f"  Reconnects exitosos: {pool.stats['reconnects'] - pool.stats['reconnect_failures']}")

    await pool.close()


async def run_auto(url: str):
    """Versión automática: levanta/mata/reinicia el server con subprocess."""
    pool = ResilientPoolDemo(url, pool_size=5)

    # Start fake server
    print("Levantando fake server...")
    proc = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "fake_mcp_server:app", "--port", "9001", "--log-level", "warning"],
        cwd=str(__import__("pathlib").Path(__file__).parent),
    )
    await asyncio.sleep(1)  # Wait for startup

    await pool.start()

    print("\n--- Fase 1: Calls normales (3s) ---")
    r1 = await continuous_calls(pool, duration_s=3, interval_s=0.2)

    print("\n--- Matando server... ---")
    proc.send_signal(signal.SIGTERM)
    proc.wait(timeout=3)
    await asyncio.sleep(0.5)

    print("\n--- Fase 2: Calls con server muerto (3s) ---")
    r2 = await continuous_calls(pool, duration_s=3, interval_s=0.5)

    print("\n--- Reiniciando server... ---")
    proc = subprocess.Popen(
        [sys.executable, "-m", "uvicorn", "fake_mcp_server:app", "--port", "9001", "--log-level", "warning"],
        cwd=str(__import__("pathlib").Path(__file__).parent),
    )
    await asyncio.sleep(1)

    print("\n--- Fase 3: Calls después de reinicio (3s) ---")
    r3 = await continuous_calls(pool, duration_s=3, interval_s=0.2)

    # Cleanup
    proc.send_signal(signal.SIGTERM)
    proc.wait(timeout=3)

    # Summary
    all_results = r1 + r2 + r3
    ok_count = sum(1 for r in all_results if r["ok"])
    fail_count = sum(1 for r in all_results if not r["ok"])

    print("\n" + "=" * 50)
    print("RESUMEN")
    print("=" * 50)
    print(f"  Total calls: {len(all_results)}")
    print(f"  OK: {ok_count}  FAIL: {fail_count}")
    print(f"  Fase 1 (healthy): {sum(1 for r in r1 if r['ok'])}/{len(r1)} OK")
    print(f"  Fase 2 (dead):    {sum(1 for r in r2 if r['ok'])}/{len(r2)} OK")
    print(f"  Fase 3 (revived): {sum(1 for r in r3 if r['ok'])}/{len(r3)} OK")
    print(f"  Pool stats: {pool.stats}")

    await pool.close()


async def main():
    parser = argparse.ArgumentParser(description="POOL-04: Reconnection under load")
    parser.add_argument("--url", default="http://localhost:9001")
    parser.add_argument("--auto", action="store_true", help="Auto kill/restart server")
    args = parser.parse_args()

    print("=" * 70)
    print("POOL-04: Reconnection Under Load")
    print("=" * 70)

    if args.auto:
        await run_auto(args.url)
    else:
        await run_manual(args.url)


if __name__ == "__main__":
    asyncio.run(main())
