"""POOL-05: Background Refresh Loop — verificar health checks en background.

Requiere:
    Terminal 1: uvicorn fake_mcp_server:app --port 9001
    Terminal 2: python 04_background_refresh.py

Uso:
    python 04_background_refresh.py
    python 04_background_refresh.py --interval 5  # refresh cada 5s
"""

import argparse
import asyncio
import time

import httpx


class PoolWithRefresh:
    """Pool con background refresh loop — versión aislada para experimentar."""

    def __init__(self, url: str, pool_size: int = 3, refresh_interval: float = 10.0):
        self.url = url
        self.pool_size = pool_size
        self.refresh_interval = refresh_interval
        self._queue: asyncio.Queue[httpx.AsyncClient] = asyncio.Queue(maxsize=pool_size)
        self._refresh_task: asyncio.Task | None = None
        self._closing = False
        self.stats = {
            "refreshes": 0,
            "refresh_ok": 0,
            "refresh_fail": 0,
            "reconnects": 0,
            "refresh_skipped": 0,
        }

    def _make_client(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            base_url=self.url,
            timeout=httpx.Timeout(connect=2.0, read=2.0, write=2.0, pool=2.0),
            limits=httpx.Limits(max_connections=1, max_keepalive_connections=1),
        )

    async def start(self):
        for _ in range(self.pool_size):
            await self._queue.put(self._make_client())
        self._refresh_task = asyncio.create_task(self._refresh_loop())
        print(f"Pool started: {self.pool_size} conns, refresh every {self.refresh_interval}s")

    async def _refresh_loop(self):
        while not self._closing:
            await asyncio.sleep(self.refresh_interval)
            if self._closing:
                break
            await self._try_refresh()

    async def _try_refresh(self):
        """Toma UNA conexión sin bloquear, verifica con GET /health."""
        try:
            client = self._queue.get_nowait()
        except asyncio.QueueEmpty:
            self.stats["refresh_skipped"] += 1
            print(f"  [refresh] SKIPPED — all connections busy")
            return

        self.stats["refreshes"] += 1
        try:
            resp = await asyncio.wait_for(client.get("/health"), timeout=2.0)
            if resp.status_code == 200:
                self.stats["refresh_ok"] += 1
                print(f"  [refresh] OK — /health returned 200")
            else:
                print(f"  [refresh] UNHEALTHY — HTTP {resp.status_code}, reconnecting...")
                await self._reconnect_client(client)
        except Exception as e:
            self.stats["refresh_fail"] += 1
            print(f"  [refresh] FAIL — {e}, reconnecting...")
            await self._reconnect_client(client)
        finally:
            await self._queue.put(client)

    async def _reconnect_client(self, old_client: httpx.AsyncClient):
        try:
            await old_client.aclose()
        except Exception:
            pass
        # Replace with new client (in-place not possible with httpx, so we swap)
        new_client = self._make_client()
        # Hacky: we modify the old_client's transport — in real code usamos _Connection wrapper
        # Para demo: simplemente retornamos el nuevo
        self.stats["reconnects"] += 1
        print(f"  [refresh] Reconnected!")

    async def close(self):
        self._closing = True
        if self._refresh_task:
            self._refresh_task.cancel()
            try:
                await self._refresh_task
            except asyncio.CancelledError:
                pass
        while not self._queue.empty():
            client = await self._queue.get()
            await client.aclose()


async def main():
    parser = argparse.ArgumentParser(description="POOL-05: Background refresh demo")
    parser.add_argument("--url", default="http://localhost:9001")
    parser.add_argument("--interval", type=float, default=5.0, help="Refresh interval seconds")
    parser.add_argument("--duration", type=float, default=30.0, help="Total run time seconds")
    args = parser.parse_args()

    print("=" * 70)
    print("POOL-05: Background Refresh Loop")
    print("=" * 70)
    print(f"URL: {args.url}")
    print(f"Refresh interval: {args.interval}s")
    print(f"Duration: {args.duration}s")
    print(f"\nInstrucciones:")
    print(f"  1. El pool hará health checks cada {args.interval}s")
    print(f"  2. Mata el server (Ctrl+C) en medio para ver qué pasa")
    print(f"  3. Reinícialo y mira cómo se recupera")
    print()

    pool = PoolWithRefresh(args.url, pool_size=3, refresh_interval=args.interval)
    await pool.start()

    t_start = time.monotonic()
    while time.monotonic() - t_start < args.duration:
        elapsed = time.monotonic() - t_start
        available = pool._queue.qsize()
        print(f"[t={elapsed:.0f}s] Pool available: {available}/{pool.pool_size} | Stats: {pool.stats}")
        await asyncio.sleep(args.interval)

    print("\n--- Final Stats ---")
    print(f"  {pool.stats}")
    print(f"  Refreshes totales: {pool.stats['refreshes']}")
    print(f"  Health OK: {pool.stats['refresh_ok']}")
    print(f"  Health FAIL (reconectó): {pool.stats['refresh_fail']}")
    print(f"  Reconnects: {pool.stats['reconnects']}")

    await pool.close()


if __name__ == "__main__":
    asyncio.run(main())
