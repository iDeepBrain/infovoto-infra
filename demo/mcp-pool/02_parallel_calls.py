"""POOL-03: Parallel Connections — 50 concurrent calls con pool de 10.

Requiere fake server corriendo:
    uvicorn fake_mcp_server:app --port 9001

Uso:
    python 02_parallel_calls.py
    python 02_parallel_calls.py --pool-size 5 --calls 100 --delay 0.1
"""

import argparse
import asyncio
import statistics
import time

import httpx


class SimplePool:
    """Pool mínimo para experimentar — sin resilience, solo queue + HTTP."""

    def __init__(self, url: str, pool_size: int):
        self.url = url
        self.pool_size = pool_size
        self._queue: asyncio.Queue[httpx.AsyncClient] = asyncio.Queue(maxsize=pool_size)
        self.stats = {"calls": 0, "errors": 0, "acquire_waits": 0}

    async def start(self):
        for _ in range(self.pool_size):
            client = httpx.AsyncClient(
                base_url=self.url,
                timeout=httpx.Timeout(connect=2.0, read=5.0, write=5.0, pool=5.0),
                limits=httpx.Limits(max_connections=1, max_keepalive_connections=1),
            )
            await self._queue.put(client)

    async def call_tool(self, name: str, args: dict, delay: float = 0.05) -> dict:
        t_acquire = time.perf_counter()
        try:
            client = await asyncio.wait_for(self._queue.get(), timeout=2.0)
        except asyncio.TimeoutError:
            self.stats["acquire_waits"] += 1
            raise RuntimeError("Pool exhausted")
        acquire_ms = (time.perf_counter() - t_acquire) * 1000

        try:
            t_call = time.perf_counter()
            resp = await client.post(
                f"/tools/call?delay={delay}",
                json={"name": name, "arguments": args},
            )
            call_ms = (time.perf_counter() - t_call) * 1000
            resp.raise_for_status()
            self.stats["calls"] += 1
            return {"acquire_ms": acquire_ms, "call_ms": call_ms, "total_ms": acquire_ms + call_ms}
        except Exception as e:
            self.stats["errors"] += 1
            return {"error": str(e), "acquire_ms": acquire_ms}
        finally:
            await self._queue.put(client)

    async def close(self):
        while not self._queue.empty():
            client = await self._queue.get()
            await client.aclose()


async def run_benchmark(url: str, pool_size: int, num_calls: int, delay: float):
    pool = SimplePool(url, pool_size)
    await pool.start()

    async def single_call(call_id: int):
        return await pool.call_tool("fake_tool_a", {"query": f"call-{call_id}"}, delay=delay)

    print(f"\nLanzando {num_calls} calls concurrentes (pool_size={pool_size}, delay={delay}s)...")
    t0 = time.perf_counter()
    results = await asyncio.gather(*[single_call(i) for i in range(num_calls)])
    total_s = time.perf_counter() - t0

    # Analyze
    acquire_times = [r["acquire_ms"] for r in results if "acquire_ms" in r and "error" not in r]
    call_times = [r["call_ms"] for r in results if "call_ms" in r]
    total_times = [r["total_ms"] for r in results if "total_ms" in r]
    errors = [r for r in results if "error" in r]

    def percentiles(data, label):
        if not data:
            return
        s = sorted(data)
        n = len(s)
        print(f"  {label}: p50={s[n//2]:.1f}ms  p95={s[int(n*0.95)]:.1f}ms  p99={s[int(n*0.99)]:.1f}ms  max={s[-1]:.1f}ms")

    print(f"\n--- Resultados: {num_calls} calls, pool={pool_size} ---")
    print(f"  Completados: {len(total_times)}/{num_calls}")
    print(f"  Errores: {len(errors)}")
    print(f"  Tiempo total: {total_s:.2f}s")
    print(f"  Throughput: {len(total_times)/total_s:.1f} calls/sec")
    percentiles(acquire_times, "Acquire")
    percentiles(call_times, "HTTP call")
    percentiles(total_times, "Total (acquire+call)")
    print(f"  Pool stats: {pool.stats}")

    await pool.close()
    return total_s


async def main():
    parser = argparse.ArgumentParser(description="POOL-03: Parallel calls benchmark")
    parser.add_argument("--url", default="http://localhost:9001", help="Fake MCP URL")
    parser.add_argument("--pool-size", type=int, default=10)
    parser.add_argument("--calls", type=int, default=50)
    parser.add_argument("--delay", type=float, default=0.05, help="Simulated tool latency (seconds)")
    parser.add_argument("--compare", action="store_true", help="Run with pool_size 5, 10, 20")
    args = parser.parse_args()

    print("=" * 70)
    print("POOL-03: Parallel Connections Benchmark")
    print("=" * 70)

    if args.compare:
        print(f"\n--- Comparación: {args.calls} calls, delay={args.delay}s ---")
        print(f"{'pool_size':>10} {'time_s':>10} {'throughput':>12}")
        print("-" * 35)
        for ps in [5, 10, 20]:
            t = await run_benchmark(args.url, ps, args.calls, args.delay)
            tps = args.calls / t
            print(f"{ps:>10} {t:>10.2f} {tps:>12.1f}")
    else:
        await run_benchmark(args.url, args.pool_size, args.calls, args.delay)


if __name__ == "__main__":
    asyncio.run(main())
