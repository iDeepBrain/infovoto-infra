#!/usr/bin/env python3
"""E2E test: 100 debate queries through gateway /api/chat.

Sends each query to the gateway as a real user would, collects responses,
and saves raw results for LLM-judge evaluation.
"""

import json
import sys
import time
from pathlib import Path
import requests

GATEWAY_URL = "http://localhost:2080"
QUERIES_FILE = Path("../infovoto-scraper/data/processed/debates/test_queries_100.json")
OUTPUT_FILE = Path("../infovoto-scraper/data/processed/debates/eval_results_e2e.json")

HEADERS = {
    "Content-Type": "application/json",
    "X-Test-User-Id": "eval-debates-e2e",
}


def send_chat(message: str, timeout: int = 30) -> dict:
    """Send a message to the gateway and return the response."""
    resp = requests.post(
        f"{GATEWAY_URL}/api/chat",
        json={"message": message},
        headers=HEADERS,
        timeout=timeout,
    )
    resp.raise_for_status()
    return resp.json()


def run_all():
    with open(QUERIES_FILE) as f:
        data = json.load(f)

    queries = data["queries"]
    print(f"\n{'='*70}")
    print(f"  GATEWAY E2E TEST — {len(queries)} queries")
    print(f"  Target: {GATEWAY_URL}/api/chat")
    print(f"{'='*70}\n")

    results = []
    cat_stats = {}
    errors = 0
    t0 = time.time()

    for i, q in enumerate(queries):
        qid = q["id"]
        cat = q["categoria"]
        pregunta = q["pregunta"]

        cat_stats.setdefault(cat, {"total": 0, "ok": 0, "error": 0, "latencies": []})
        cat_stats[cat]["total"] += 1

        try:
            t1 = time.time()
            resp = send_chat(pregunta)
            latency_ms = (time.time() - t1) * 1000

            reply = resp.get("reply", "")
            sources = resp.get("sources", [])
            cached = resp.get("cached", False)

            cat_stats[cat]["ok"] += 1
            cat_stats[cat]["latencies"].append(latency_ms)

            # Quick heuristic checks
            flags = []
            reply_lower = reply.lower()

            # Check if reply is too short (likely error)
            if len(reply) < 20:
                flags.append("reply_too_short")

            # Check if debate tool was used (sources mention debates)
            has_debate_source = any("debate" in str(s).lower() for s in (sources or []))

            # For categories that should use debate tools
            if cat in ("A", "B", "D", "E") and not has_debate_source and not cached:
                flags.append("no_debate_source")

            # Imparcialidad check
            if cat == "F":
                bad_words = ["ganó", "ganador", "mejor candidato", "peor candidato", "deberías votar"]
                if any(w in reply_lower for w in bad_words):
                    flags.append("parcialidad_detectada")

            status = "OK" if not flags else f"WARN({','.join(flags)})"
            symbol = "✓" if not flags else "⚠"

            print(f"  [{symbol}] {qid} (cat {cat}) {latency_ms:5.0f}ms: {pregunta[:55]}...")
            if flags:
                print(f"         flags: {flags}")
                print(f"         reply: {reply[:120]}...")

            results.append({
                "id": qid,
                "categoria": cat,
                "pregunta": pregunta,
                "reply": reply,
                "sources": sources,
                "cached": cached,
                "latency_ms": round(latency_ms),
                "flags": flags,
                "status": status,
            })

        except Exception as e:
            errors += 1
            cat_stats[cat]["error"] += 1
            print(f"  [✗] {qid} (cat {cat}): ERROR — {e}")
            results.append({
                "id": qid,
                "categoria": cat,
                "pregunta": pregunta,
                "reply": None,
                "error": str(e),
                "status": "ERROR",
            })

        # Small delay to avoid rate limiting
        if (i + 1) % 10 == 0:
            elapsed = time.time() - t0
            print(f"\n  --- Progress: {i+1}/{len(queries)} ({elapsed:.0f}s elapsed) ---\n")

    elapsed = time.time() - t0

    # Summary
    print(f"\n{'='*70}")
    print(f"  RESULTS SUMMARY ({elapsed:.0f}s total)")
    print(f"{'='*70}\n")

    total_ok = sum(s["ok"] for s in cat_stats.values())
    total_err = sum(s["error"] for s in cat_stats.values())
    total_flagged = sum(1 for r in results if r.get("flags"))

    for cat in sorted(cat_stats):
        s = cat_stats[cat]
        avg_lat = sum(s["latencies"]) / len(s["latencies"]) if s["latencies"] else 0
        flagged = sum(1 for r in results if r["categoria"] == cat and r.get("flags"))
        print(f"  Cat {cat}: {s['ok']}/{s['total']} ok, {flagged} flagged, avg {avg_lat:.0f}ms")

    print(f"\n  Total: {total_ok}/{len(queries)} ok, {total_flagged} flagged, {total_err} errors")
    print(f"  Avg latency: {sum(sum(s['latencies']) for s in cat_stats.values()) / max(total_ok, 1):.0f}ms")

    # Save results
    output = {
        "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S"),
        "total_queries": len(queries),
        "total_ok": total_ok,
        "total_errors": total_err,
        "total_flagged": total_flagged,
        "elapsed_seconds": round(elapsed),
        "per_category": {
            cat: {
                "total": s["total"],
                "ok": s["ok"],
                "errors": s["error"],
                "avg_latency_ms": round(sum(s["latencies"]) / len(s["latencies"])) if s["latencies"] else 0,
            }
            for cat, s in cat_stats.items()
        },
        "results": results,
    }
    OUTPUT_FILE.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_FILE.write_text(json.dumps(output, ensure_ascii=False, indent=2))
    print(f"\n  Results saved to: {OUTPUT_FILE}")
    print()


if __name__ == "__main__":
    # Health check
    try:
        h = requests.get(f"{GATEWAY_URL}/health", timeout=5).json()
        print(f"Gateway: {h['status']}, MCPs: {len(h['mcps_connected'])}")
    except Exception as e:
        print(f"Gateway not available: {e}")
        sys.exit(1)

    run_all()
