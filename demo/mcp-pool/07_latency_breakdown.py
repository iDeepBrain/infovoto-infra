"""POOL-08: End-to-End Latency Breakdown — medir cada capa del stack.

Instrumenta: acquire → HTTP connect → HTTP response → parse → release.

Requiere:
    uvicorn fake_mcp_server:app --port 9001

Uso:
    python 07_latency_breakdown.py
    python 07_latency_breakdown.py --calls 200 --delay 0.1
"""

import argparse
import asyncio
import statistics
import time

import httpx


class InstrumentedPool:
    """Pool que mide cada fase del ciclo acquire → call → release."""

    def __init__(self, url: str, pool_size: int = 10):
        self.url = url
        self.pool_size = pool_size
        self._queue: asyncio.Queue[httpx.AsyncClient] = asyncio.Queue(maxsize=pool_size)

    async def start(self):
        for _ in range(self.pool_size):
            client = httpx.AsyncClient(
                base_url=self.url,
                timeout=httpx.Timeout(connect=2.0, read=5.0, write=5.0, pool=5.0),
                limits=httpx.Limits(max_connections=1, max_keepalive_connections=1),
            )
            await self._queue.put(client)

    async def call_instrumented(self, name: str, args: dict, delay: float) -> dict:
        """Returns timing breakdown in microseconds."""
        # 1. Acquire
        t0 = time.perf_counter_ns()
        client = await self._queue.get()
        t_acquired = time.perf_counter_ns()

        try:
            # 2. HTTP call
            resp = await client.post(
                f"/tools/call?delay={delay}",
                json={"name": name, "arguments": args},
            )
            t_response = time.perf_counter_ns()

            # 3. Parse
            resp.raise_for_status()
            data = resp.json()
            t_parsed = time.perf_counter_ns()

            return {
                "acquire_us": (t_acquired - t0) / 1000,
                "http_us": (t_response - t_acquired) / 1000,
                "parse_us": (t_parsed - t_response) / 1000,
                "total_us": (t_parsed - t0) / 1000,
                "ok": True,
            }
        except Exception as e:
            return {"error": str(e), "ok": False}
        finally:
            # 4. Release
            await self._queue.put(client)

    async def close(self):
        while not self._queue.empty():
            client = await self._queue.get()
            await client.aclose()


def print_percentiles(data: list[float], label: str):
    if not data:
        print(f"  {label:>12}: no data")
        return
    s = sorted(data)
    n = len(s)
    avg = statistics.mean(s)
    print(
        f"  {label:>12}: "
        f"avg={avg:>8.0f}μs  "
        f"p50={s[n//2]:>8.0f}μs  "
        f"p95={s[int(n*0.95)]:>8.0f}μs  "
        f"p99={s[int(n*0.99)]:>8.0f}μs  "
        f"max={s[-1]:>8.0f}μs"
    )


async def main():
    parser = argparse.ArgumentParser(description="POOL-08: Latency breakdown")
    parser.add_argument("--url", default="http://localhost:9001")
    parser.add_argument("--pool-size", type=int, default=10)
    parser.add_argument("--calls", type=int, default=100)
    parser.add_argument("--delay", type=float, default=0.05, help="Simulated tool latency (s)")
    parser.add_argument("--sequential", action="store_true", help="Run calls sequentially (no contention)")
    args = parser.parse_args()

    print("=" * 70)
    print("POOL-08: End-to-End Latency Breakdown")
    print("=" * 70)

    pool = InstrumentedPool(args.url, pool_size=args.pool_size)
    await pool.start()

    # Warmup
    print("\nWarmup (5 calls)...")
    for i in range(5):
        await pool.call_instrumented("fake_tool_a", {"query": "warmup"}, delay=0.01)

    # Benchmark
    mode = "sequential" if args.sequential else "parallel"
    print(f"\nBenchmark: {args.calls} calls, pool={args.pool_size}, delay={args.delay}s, mode={mode}")

    if args.sequential:
        results = []
        for i in range(args.calls):
            r = await pool.call_instrumented("fake_tool_a", {"query": f"q{i}"}, delay=args.delay)
            results.append(r)
    else:
        results = await asyncio.gather(
            *[pool.call_instrumented("fake_tool_a", {"query": f"q{i}"}, delay=args.delay) for i in range(args.calls)]
        )

    ok_results = [r for r in results if r.get("ok")]
    errors = len(results) - len(ok_results)

    print(f"\nResults: {len(ok_results)}/{len(results)} OK, {errors} errors\n")

    if ok_results:
        acquire = [r["acquire_us"] for r in ok_results]
        http = [r["http_us"] for r in ok_results]
        parse = [r["parse_us"] for r in ok_results]
        total = [r["total_us"] for r in ok_results]

        print("--- Breakdown por fase ---")
        print_percentiles(acquire, "acquire")
        print_percentiles(http, "HTTP call")
        print_percentiles(parse, "parse")
        print_percentiles(total, "TOTAL")

        # Proportions
        avg_total = statistics.mean(total)
        avg_acquire = statistics.mean(acquire)
        avg_http = statistics.mean(http)
        avg_parse = statistics.mean(parse)

        print(f"\n--- Proporción del tiempo (avg) ---")
        print(f"  acquire: {avg_acquire/avg_total*100:>5.1f}%  ({avg_acquire:.0f}μs)")
        print(f"  HTTP:    {avg_http/avg_total*100:>5.1f}%  ({avg_http:.0f}μs)")
        print(f"  parse:   {avg_parse/avg_total*100:>5.1f}%  ({avg_parse:.0f}μs)")
        print(f"  TOTAL:   100.0%  ({avg_total:.0f}μs = {avg_total/1000:.1f}ms)")

        # Compare sequential vs parallel recommendation
        if not args.sequential:
            print(f"\n--- Nota ---")
            print(f"  acquire p99 con contención: {sorted(acquire)[int(len(acquire)*0.99)]:.0f}μs")
            print(f"  Corre con --sequential para ver acquire sin contención")
            print(f"  Si acquire p99 >> 10μs en parallel, hay contención de pool")

    await pool.close()


if __name__ == "__main__":
    asyncio.run(main())
