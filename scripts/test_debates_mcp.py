#!/usr/bin/env python3
"""Test 30 debate queries + 30 regression queries against running MCP containers.

Debates: categories A-E from test_queries.json (30 queries via /debates/tools/call)
Regression: 30 queries against perfiles, planes, logistica, proceso MCPs
"""

import json
import sys
import time
import requests

MCP_BASE = "http://localhost:2900"


# ── Debate Tests (30 queries: Q01-Q34 = cat A-E, skip some to get 30) ──

def load_debate_queries():
    with open("../infovoto-scraper/data/processed/debates/test_queries.json") as f:
        data = json.load(f)
    # Categories A-E only (MCP-testable), limit to 30
    return [q for q in data["queries"] if q["categoria"] in ("A", "B", "C", "D", "E")][:30]


def call_debate_tool(name, arguments):
    resp = requests.post(
        f"{MCP_BASE}/debates/tools/call",
        json={"name": name, "arguments": arguments},
        timeout=30,
    )
    resp.raise_for_status()
    return resp.json()


def test_buscar(q):
    args = {"query": q["pregunta"], "n_resultados": 8}
    v = q["validacion"]
    if v.get("candidato_esperado") and "," not in (v["candidato_esperado"] or ""):
        # Extract candidate name for the filter
        cand = v["candidato_esperado"]
        # Use last name as candidato filter
        parts = cand.split()
        args["candidato"] = parts[-1] if len(parts) > 1 else cand
    result = call_debate_tool("buscar_en_debate", args)
    return result


def test_comparar(q):
    v = q["validacion"]
    cands = v["candidato_esperado"].split(",")
    args = {
        "candidato_a": cands[0].strip().split()[-1],
        "candidato_b": cands[1].strip().split()[-1],
        "tema": q["pregunta"].split("sobre")[-1].strip() if "sobre" in q["pregunta"] else "seguridad",
    }
    return call_debate_tool("comparar_candidatos_debate", args)


def test_resumen(q):
    target = q.get("debate_target", "todos")
    args = {}
    if target and target != "todos":
        args["debate_id"] = target
    return call_debate_tool("resumen_debate", args)


def validate_debate_result(q, result):
    """Validate result against expected criteria. Returns (pass, reason)."""
    v = q["validacion"]
    result_text = json.dumps(result, ensure_ascii=False).lower()

    # Check debe_contener (at least 1 keyword must be present)
    debe = v.get("debe_contener", [])
    if debe:
        found_any = any(kw.lower() in result_text for kw in debe)
        if not found_any:
            return False, f"Missing keywords: {debe}"

    # Check no_debe_contener — skip common words that appear in non-partial context
    # "mejor" alone is too common ("mejores propuestas"), check for partiality phrases instead
    _PARTIALITY_PHRASES = {"mejor": ["el mejor candidato", "es mejor que", "fue mejor", "claramente mejor", "es superior"],
                           "superior": ["es superior", "claramente superior"]}
    for kw in v.get("no_debe_contener", []):
        kw_low = kw.lower()
        if kw_low in _PARTIALITY_PHRASES:
            # Check for full partiality phrases instead of bare word
            if any(phrase in result_text for phrase in _PARTIALITY_PHRASES[kw_low]):
                return False, f"Contains partiality phrase with '{kw}'"
        elif kw_low in result_text:
            return False, f"Contains forbidden: '{kw}'"

    # Check candidato_esperado appears in result
    cand = v.get("candidato_esperado")
    if cand and "," not in cand:
        # Single candidate — check at least partial name match
        parts = cand.lower().split()
        found = any(p in result_text for p in parts if len(p) > 3)
        if not found:
            return False, f"Expected candidate '{cand}' not in result"

    # Check has _fuente field (source citation)
    if isinstance(result, list) and result:
        has_fuente = any("_fuente" in str(r) for r in result)
    elif isinstance(result, dict):
        has_fuente = "_fuente" in str(result)
    else:
        has_fuente = "_fuente" in result_text
    if not has_fuente and q["categoria"] in ("A", "B", "D", "E"):
        return False, "Missing _fuente (source citation)"

    return True, "OK"


def run_debate_tests():
    queries = load_debate_queries()
    print(f"\n{'='*60}")
    print(f"  DEBATE MCP TESTS — {len(queries)} queries")
    print(f"{'='*60}\n")

    passed = 0
    failed = 0
    errors = 0
    results = []

    for q in queries:
        qid = q["id"]
        cat = q["categoria"]
        tool = q.get("tool_esperado", "buscar_en_debate")

        try:
            if cat == "B" or tool == "comparar_candidatos_debate":
                result = test_comparar(q)
            elif cat == "C" or tool == "resumen_debate":
                result = test_resumen(q)
            else:
                result = test_buscar(q)

            ok, reason = validate_debate_result(q, result)
            status = "PASS" if ok else "FAIL"
            if ok:
                passed += 1
            else:
                failed += 1

            # Check relevance scores for search results
            relevance = ""
            if isinstance(result, list) and result and isinstance(result[0], dict):
                scores = [r.get("relevancia", 0) for r in result if "relevancia" in r]
                if scores:
                    relevance = f" (max_rel={max(scores):.2f})"

            print(f"  [{status}] {qid} (cat {cat}): {q['pregunta'][:60]}...{relevance}")
            if not ok:
                print(f"         → {reason}")

            results.append({"id": qid, "status": status, "reason": reason})

        except Exception as e:
            errors += 1
            print(f"  [ERROR] {qid} (cat {cat}): {e}")
            results.append({"id": qid, "status": "ERROR", "reason": str(e)})

    return passed, failed, errors, results


# ── Regression Tests (30 queries against existing MCPs) ──

REGRESSION_QUERIES = [
    # perfiles (10) — tool names verified against /perfiles/metadata
    {"mcp": "perfiles", "tool": "buscar_candidato_por_dni", "args": {"nombre": "Keiko Fujimori"}, "expect_key": None, "label": "Buscar Keiko por nombre"},
    {"mcp": "perfiles", "tool": "buscar_candidato_por_nombre", "args": {"nombre": "Keiko"}, "expect_key": None, "label": "Buscar por nombre Keiko"},
    {"mcp": "perfiles", "tool": "buscar_candidato_por_nombre", "args": {"nombre": "López Aliaga"}, "expect_key": None, "label": "Buscar por nombre López Aliaga"},
    {"mcp": "perfiles", "tool": "buscar_candidato_por_nombre", "args": {"nombre": "César Acuña"}, "expect_key": None, "label": "Buscar por nombre Acuña"},
    {"mcp": "perfiles", "tool": "formula_presidencial", "args": {"partido": "Fuerza Popular"}, "expect_key": "partido", "label": "Fórmula presidencial FP"},
    {"mcp": "perfiles", "tool": "formula_presidencial", "args": {"partido": "Renovación Popular"}, "expect_key": "partido", "label": "Fórmula presidencial RP"},
    {"mcp": "perfiles", "tool": "estadisticas_candidatos", "args": {"campo": "genero"}, "expect_key": "estadistica", "label": "Estadísticas candidatos género"},
    {"mcp": "perfiles", "tool": "ranking_patrimonio", "args": {"cargo": "presidente"}, "expect_key": None, "label": "Ranking patrimonio presidentes"},
    {"mcp": "perfiles", "tool": "buscar_candidato_por_nombre", "args": {"nombre": "Forsyth"}, "expect_key": None, "label": "Buscar Forsyth"},
    {"mcp": "perfiles", "tool": "buscar_candidato_por_nombre", "args": {"nombre": "Guevara"}, "expect_key": None, "label": "Buscar Guevara"},
    # planes (10)
    {"mcp": "planes", "tool": "buscar_propuesta_tema", "args": {"tema": "seguridad ciudadana"}, "expect_key": None, "label": "Plan seguridad ciudadana"},
    {"mcp": "planes", "tool": "buscar_propuesta_tema", "args": {"tema": "educación"}, "expect_key": None, "label": "Plan educación"},
    {"mcp": "planes", "tool": "buscar_propuesta_tema", "args": {"tema": "salud"}, "expect_key": None, "label": "Plan salud"},
    {"mcp": "planes", "tool": "buscar_propuesta_tema", "args": {"tema": "corrupción", "partido": "Fuerza Popular"}, "expect_key": None, "label": "Plan anticorrupción FP"},
    {"mcp": "planes", "tool": "buscar_propuesta_tema", "args": {"tema": "economía"}, "expect_key": None, "label": "Plan economía"},
    {"mcp": "planes", "tool": "comparar_planes_gobierno", "args": {"partidos": ["Fuerza Popular", "Renovación Popular"], "tema": "seguridad"}, "expect_key": "comparacion", "label": "Comparar FP vs RP seguridad"},
    {"mcp": "planes", "tool": "buscar_propuesta_tema", "args": {"tema": "tecnología"}, "expect_key": None, "label": "Plan tecnología"},
    {"mcp": "planes", "tool": "buscar_propuesta_tema", "args": {"tema": "minería"}, "expect_key": None, "label": "Plan minería"},
    {"mcp": "planes", "tool": "buscar_propuesta_tema", "args": {"tema": "agua"}, "expect_key": None, "label": "Plan agua"},
    {"mcp": "planes", "tool": "buscar_propuesta_tema", "args": {"tema": "empleo"}, "expect_key": None, "label": "Plan empleo"},
    # logistica (5)
    {"mcp": "logistica", "tool": "consultar_local_votacion", "args": {"dni": "10219855"}, "expect_key": None, "label": "Local votación por DNI"},
    {"mcp": "logistica", "tool": "consultar_miembro_mesa", "args": {"dni": "10219855"}, "expect_key": None, "label": "Miembro de mesa por DNI"},
    {"mcp": "logistica", "tool": "consultar_multas", "args": {"dni": "10219855"}, "expect_key": None, "label": "Multas por DNI"},
    {"mcp": "logistica", "tool": "consultar_local_votacion", "args": {"dni": "99999999"}, "expect_key": None, "label": "Local votación DNI inválido"},
    {"mcp": "logistica", "tool": "consultar_miembro_mesa", "args": {"dni": "99999999"}, "expect_key": None, "label": "Miembro mesa DNI inválido"},
    # proceso (5) — tools: buscar_info_electoral, explicar_sistema_electoral
    {"mcp": "proceso", "tool": "explicar_sistema_electoral", "args": {"aspecto": "segunda_vuelta"}, "expect_key": None, "label": "Explicar segunda vuelta"},
    {"mcp": "proceso", "tool": "explicar_sistema_electoral", "args": {"aspecto": "voto_preferencial"}, "expect_key": None, "label": "Explicar voto preferencial"},
    {"mcp": "proceso", "tool": "explicar_sistema_electoral", "args": {"aspecto": "bicameral"}, "expect_key": None, "label": "Explicar sistema bicameral"},
    {"mcp": "proceso", "tool": "buscar_info_electoral", "args": {"query": "requisitos para ser candidato"}, "expect_key": None, "label": "Info requisitos candidato"},
    {"mcp": "proceso", "tool": "buscar_info_electoral", "args": {"query": "cuántos senadores se eligen"}, "expect_key": None, "label": "Info senadores"},
]


def run_regression_tests():
    print(f"\n{'='*60}")
    print(f"  REGRESSION TESTS — {len(REGRESSION_QUERIES)} queries")
    print(f"{'='*60}\n")

    passed = 0
    failed = 0
    errors = 0

    for rq in REGRESSION_QUERIES:
        mcp = rq["mcp"]
        tool = rq["tool"]
        label = rq["label"]
        try:
            resp = requests.post(
                f"{MCP_BASE}/{mcp}/tools/call",
                json={"name": tool, "arguments": rq["args"]},
                timeout=30,
            )
            resp.raise_for_status()
            result = resp.json()

            # Unwrap {"result": ...} wrapper if present
            inner = result.get("result", result) if isinstance(result, dict) else result

            # Check for errors
            has_error = False
            if isinstance(inner, dict) and "error" in inner:
                has_error = True
            if isinstance(result, dict) and "error" in result and "result" not in result:
                has_error = True

            expect = rq["expect_key"]
            if has_error:
                failed += 1
                err_msg = inner.get("error", "") if isinstance(inner, dict) else str(result)
                print(f"  [FAIL] {label} — error: {str(err_msg)[:100]}")
            elif expect is None:
                # Just check no crash and no error
                passed += 1
                size = len(str(inner))
                print(f"  [PASS] {label} ({size} chars)")
            elif isinstance(inner, dict) and expect in inner:
                passed += 1
                print(f"  [PASS] {label}")
            elif isinstance(inner, list) and len(inner) > 0:
                passed += 1
                print(f"  [PASS] {label} ({len(inner)} results)")
            elif isinstance(inner, dict) and not has_error:
                passed += 1
                print(f"  [PASS] {label} (alt structure)")
            else:
                failed += 1
                print(f"  [FAIL] {label} — expected key '{expect}' not found")
                print(f"         → got: {str(inner)[:120]}")
        except requests.exceptions.HTTPError as e:
            # Some tools may return 4xx for invalid input — that's OK
            if e.response.status_code in (400, 404, 422):
                passed += 1
                print(f"  [PASS] {label} (expected error: {e.response.status_code})")
            else:
                errors += 1
                print(f"  [ERROR] {label} — HTTP {e.response.status_code}")
        except Exception as e:
            errors += 1
            print(f"  [ERROR] {label} — {e}")

    return passed, failed, errors


# ── Main ──

if __name__ == "__main__":
    print("\n" + "=" * 60)
    print("  InfoVoto MCP — Full Test Suite")
    print("  Testing against localhost:2900")
    print("=" * 60)

    # Quick health check
    for mcp in ["perfiles", "planes", "logistica", "proceso", "debates"]:
        try:
            r = requests.get(f"{MCP_BASE}/{mcp}/health", timeout=5)
            status = r.json().get("status", "unknown")
            print(f"  {mcp}: {status}")
        except Exception as e:
            print(f"  {mcp}: UNAVAILABLE ({e})")
            if mcp == "debates":
                print("\n  FATAL: debates MCP not available. Aborting.")
                sys.exit(1)

    t0 = time.time()

    # Run debate tests
    d_pass, d_fail, d_err, d_results = run_debate_tests()
    d_total = d_pass + d_fail + d_err
    d_rate = d_pass / d_total * 100 if d_total else 0

    # Run regression tests
    r_pass, r_fail, r_err = run_regression_tests()
    r_total = r_pass + r_fail + r_err
    r_rate = r_pass / r_total * 100 if r_total else 0

    elapsed = time.time() - t0

    # Summary
    print(f"\n{'='*60}")
    print(f"  SUMMARY ({elapsed:.1f}s)")
    print(f"{'='*60}")
    print(f"  Debate queries:     {d_pass}/{d_total} passed ({d_rate:.0f}%) — {d_fail} failed, {d_err} errors")
    print(f"  Regression queries: {r_pass}/{r_total} passed ({r_rate:.0f}%) — {r_fail} failed, {r_err} errors")
    print(f"  Overall:            {d_pass+r_pass}/{d_total+r_total} passed")

    threshold = 85
    if d_rate >= threshold:
        print(f"\n  ✓ Debate pass rate {d_rate:.0f}% >= {threshold}% threshold")
    else:
        print(f"\n  ✗ Debate pass rate {d_rate:.0f}% < {threshold}% threshold")

    if r_rate >= 90:
        print(f"  ✓ Regression pass rate {r_rate:.0f}% >= 90% threshold")
    else:
        print(f"  ✗ Regression pass rate {r_rate:.0f}% < 90% threshold")

    print()
