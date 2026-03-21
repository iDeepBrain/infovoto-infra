"""POOL-07: Semaphore vs No Semaphore — benchmark throughput.

Responde: ¿el semaphore limita throughput o lo protege?

Requiere:
    uvicorn fake_mcp_server:app --port 9001

Uso:
    python 06_semaphore_bench.py
    python 06_semaphore_bench.py --calls 200 --delay 0.05
"""

import argparse
import asyncio
import statistics
import time

import httpx


async def run_with_semaphore(url: str, num_calls: int, delay: float, max_parallel: int | None) -> dict:
    """Ejecuta N calls con semaphore opcional."""
    client = httpx.AsyncClient(base_url=url, timeout=httpx.Timeout(10.0))
    semaphore = asyncio.Semaphore(max_parallel) if max_parallel else None
    latencies: list[float] = []
    errors = 0

    async def single_call(call_id: int):
        nonlocal errors

        async def do_call():
            nonlocal errors
            t0 = time.perf_counter()
            try:
                resp = await client.post(
                    f"/tools/call?delay={delay}",
                    json={"name": "fake_tool_a", "arguments": {"query": f"q{call_id}"}},
                )
                resp.raise_for_status()
                latencies.append((time.perf_counter() - t0) * 1000)
            except Exception:
                errors += 1

        if semaphore:
            async with semaphore:
                await do_call()
        else:
            await do_call()

    t0 = time.perf_counter()
    await asyncio.gather(*[single_call(i) for i in range(num_calls)])
    total_s = time.perf_counter() - t0
    await client.aclose()

    if latencies:
        s = sorted(latencies)
        n = len(s)
        return {
            "max_parallel": max_parallel or "unlimited",
            "calls": num_calls,
            "ok": len(latencies),
            "errors": errors,
            "total_s": round(total_s, 2),
            "throughput": round(len(latencies) / total_s, 1),
            "p50_ms": round(s[n // 2], 1),
            "p95_ms": round(s[int(n * 0.95)], 1),
            "p99_ms": round(s[int(n * 0.99)], 1),
        }
    return {"max_parallel": max_parallel, "calls": num_calls, "errors": errors, "total_s": round(total_s, 2)}


async def main():
    parser = argparse.ArgumentParser(description="POOL-07: Semaphore benchmark")
    parser.add_argument("--url", default="http://localhost:9001")
    parser.add_argument("--calls", type=int, default=100)
    parser.add_argument("--delay", type=float, default=0.05, help="Simulated tool latency (s)")
    args = parser.parse_args()

    print("=" * 70)
    print("POOL-07: Semaphore vs No Semaphore")
    print("=" * 70)
    print(f"  URL: {args.url}")
    print(f"  Calls: {args.calls}")
    print(f"  Simulated delay per call: {args.delay}s")

    configs = [5, 10, 20, 50, None]  # None = unlimited
    results = []

    for max_p in configs:
        label = str(max_p) if max_p else "unlimited"
        print(f"\n  Running with max_parallel={label}...")
        result = await run_with_semaphore(args.url, args.calls, args.delay, max_p)
        results.append(result)

    print(f"\n{'='*80}")
    print(f"{'max_parallel':>14} {'ok':>6} {'err':>5} {'total_s':>8} {'tput':>8} {'p50':>8} {'p95':>8} {'p99':>8}")
    print("-" * 80)
    for r in results:
        print(
            f"{str(r['max_parallel']):>14} {r.get('ok', 0):>6} {r.get('errors', 0):>5} "
            f"{r['total_s']:>8} {r.get('throughput', 0):>8} "
            f"{r.get('p50_ms', '-'):>8} {r.get('p95_ms', '-'):>8} {r.get('p99_ms', '-'):>8}"
        )

    print(f"\n--- Conclusión ---")
    print("Si el server aguanta la carga, más parallelism = más throughput.")
    print("El semaphore protege contra overload del server, no del client.")
    print("Para MCP servers internos (mismo docker network): semaphore alto o igual a pool_size.")
    print("Para APIs externas: semaphore bajo para no saturar.")


if __name__ == "__main__":
    asyncio.run(main())
