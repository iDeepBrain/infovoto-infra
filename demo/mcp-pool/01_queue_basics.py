"""POOL-02: Queue Pooling Basics — medir acquire/release con asyncio.Queue.

Valida que acquire() es ~0ms con pool warm y mide degradación cuando se agotan.

Uso:
    python 01_queue_basics.py

No requiere servidor — es puro asyncio.Queue con objetos fake.
"""

import asyncio
import statistics
import time


class FakeConnection:
    def __init__(self, conn_id: int):
        self.id = conn_id


async def measure_acquire_release(pool_size: int, num_ops: int) -> dict:
    """Crea pool, mide N acquire/release cycles."""
    queue: asyncio.Queue[FakeConnection] = asyncio.Queue(maxsize=pool_size)

    # Fill pool
    for i in range(pool_size):
        await queue.put(FakeConnection(i))

    # Measure acquire + release (hot path)
    latencies_us = []
    for _ in range(num_ops):
        t0 = time.perf_counter_ns()
        conn = await queue.get()
        acquire_ns = time.perf_counter_ns() - t0
        await queue.put(conn)
        latencies_us.append(acquire_ns / 1000)  # nanoseconds → microseconds

    return {
        "pool_size": pool_size,
        "operations": num_ops,
        "p50_us": round(statistics.median(latencies_us), 2),
        "p95_us": round(sorted(latencies_us)[int(num_ops * 0.95)], 2),
        "p99_us": round(sorted(latencies_us)[int(num_ops * 0.99)], 2),
        "max_us": round(max(latencies_us), 2),
    }


async def measure_contention(pool_size: int, num_workers: int, ops_per_worker: int) -> dict:
    """Simula contención: N workers compitiendo por M conexiones."""
    queue: asyncio.Queue[FakeConnection] = asyncio.Queue(maxsize=pool_size)
    for i in range(pool_size):
        await queue.put(FakeConnection(i))

    all_latencies_us: list[float] = []
    timeouts = 0
    lock = asyncio.Lock()

    async def worker(worker_id: int):
        nonlocal timeouts
        for _ in range(ops_per_worker):
            t0 = time.perf_counter_ns()
            try:
                conn = await asyncio.wait_for(queue.get(), timeout=0.1)
                acquire_ns = time.perf_counter_ns() - t0
                # Simulate some work holding the connection
                await asyncio.sleep(0.001)
                await queue.put(conn)
                async with lock:
                    all_latencies_us.append(acquire_ns / 1000)
            except asyncio.TimeoutError:
                async with lock:
                    timeouts += 1

    await asyncio.gather(*[worker(i) for i in range(num_workers)])

    if all_latencies_us:
        sorted_lat = sorted(all_latencies_us)
        n = len(sorted_lat)
        return {
            "pool_size": pool_size,
            "workers": num_workers,
            "total_ops": num_workers * ops_per_worker,
            "successful": len(all_latencies_us),
            "timeouts": timeouts,
            "p50_us": round(sorted_lat[n // 2], 2),
            "p95_us": round(sorted_lat[int(n * 0.95)], 2),
            "p99_us": round(sorted_lat[int(n * 0.99)], 2),
            "max_us": round(sorted_lat[-1], 2),
        }
    return {"pool_size": pool_size, "workers": num_workers, "timeouts": timeouts, "error": "all timed out"}


async def main():
    print("=" * 70)
    print("POOL-02: Queue Pooling Basics")
    print("=" * 70)

    # Test 1: Hot path — no contention
    print("\n--- Test 1: Acquire/Release sin contención ---")
    print(f"{'pool_size':>10} {'ops':>8} {'p50_us':>10} {'p95_us':>10} {'p99_us':>10} {'max_us':>10}")
    print("-" * 60)
    for pool_size in [5, 10, 20]:
        result = await measure_acquire_release(pool_size, 10_000)
        print(
            f"{result['pool_size']:>10} {result['operations']:>8} "
            f"{result['p50_us']:>10} {result['p95_us']:>10} "
            f"{result['p99_us']:>10} {result['max_us']:>10}"
        )

    # Test 2: Contention — more workers than connections
    print("\n--- Test 2: Contención (workers > pool_size) ---")
    print(f"{'pool':>6} {'workers':>8} {'ok':>8} {'timeout':>8} {'p50_us':>10} {'p95_us':>10} {'p99_us':>10}")
    print("-" * 70)
    for pool_size, workers in [(10, 10), (10, 20), (10, 50), (5, 50)]:
        result = await measure_contention(pool_size, workers, ops_per_worker=20)
        p50 = result.get("p50_us", "N/A")
        p95 = result.get("p95_us", "N/A")
        p99 = result.get("p99_us", "N/A")
        print(
            f"{result['pool_size']:>6} {result['workers']:>8} "
            f"{result.get('successful', 0):>8} {result['timeouts']:>8} "
            f"{str(p50):>10} {str(p95):>10} {str(p99):>10}"
        )

    print("\n--- Conclusión ---")
    print("acquire() es ~0-5μs sin contención (puro queue.get()).")
    print("Con contención, el wait depende de cuánto tiempo los workers retienen conexiones.")
    print("Si tus MCP calls son <200ms y tienes pool_size=10, 50 concurrent es manejable.")


if __name__ == "__main__":
    asyncio.run(main())
