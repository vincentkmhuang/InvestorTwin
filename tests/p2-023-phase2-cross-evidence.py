# P2-023 Phase 2 — Cross-Evidence Interpretation (isolated).
# No network. Does not modify News Collect / NI / Meaning Gate / Today / Queue / Gold.
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPTS = os.path.join(ROOT, "scripts")


def load_py(name, filename):
    path = os.path.join(SCRIPTS, filename)
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


fails = []


def record(name, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(status + " " + name + ((" " + detail) if (detail and not ok) else ""))
    if not ok:
        fails.append(name + ": " + (detail or "failed"))


generate = load_py("generate_brief", "generate-morning-brief.py")


def make_item(instrument, value, unit, as_of, change, source="test"):
    return {
        "instrument": instrument,
        "latest": True,
        "row": {
            "instrument": instrument,
            "value": value,
            "unit": unit,
            "asOf": as_of,
            "asOfKind": "close",
            "sourceId": source,
            "status": "ok",
            "changeDoD": change,
        },
        "researchId": None,
        "theme": "macro",
        "sections": ["globalMarketAndNews", "marketTemperature"],
    }


def by_id_from_items(items):
    return {item["instrument"]: item for item in items}


def write_run(root, expected_as_of, rows, handoff=None, previous_ai=None):
    run_id = "run-20260913T160000Z"
    run_dir = os.path.join(root, "data", "evidence", "runs", run_id)
    os.makedirs(os.path.join(run_dir, "normalized"), exist_ok=True)
    os.makedirs(os.path.join(root, "data", "evidence", "history"), exist_ok=True)
    os.makedirs(os.path.join(root, "research", "hbm"), exist_ok=True)
    with open(os.path.join(run_dir, "run.json"), "w", encoding="utf-8", newline="\n") as handle:
        json.dump({
            "runId": run_id,
            "capturedAt": "2026-09-13T16:00:00Z",
            "expectedAsOf": expected_as_of,
            "writesBrief": False,
            "statuses": {row["instrument"]: "ok" for row in rows},
        }, handle)
    for row in rows:
        with open(
            os.path.join(run_dir, "normalized", row["instrument"] + ".json"),
            "w", encoding="utf-8", newline="\n",
        ) as handle:
            json.dump(row, handle)
        hist = os.path.join(root, "data", "evidence", "history", row["instrument"])
        os.makedirs(hist, exist_ok=True)
        with open(
            os.path.join(hist, row["asOf"] + ".json"),
            "w", encoding="utf-8", newline="\n",
        ) as handle:
            json.dump(row, handle)
    with open(os.path.join(root, "research", "hbm", "card.json"), "w", encoding="utf-8", newline="\n") as handle:
        json.dump({"id": "hbm", "title": "HBM"}, handle)
    if handoff is not None:
        with open(
            os.path.join(root, "data", "research-candidates-handoff.json"),
            "w", encoding="utf-8", newline="\n",
        ) as handle:
            json.dump(handoff, handle)
    prev = {
        "date": "2026-09-12",
        "executiveSummary": "seed",
        "macroDecisionLens": [],
        "marketTemperature": {},
        "globalMarketAndNews": {"summary": "", "items": []},
        "taiwanMarketAndNews": {"summary": "", "items": []},
        "aiIndustryHighlights": previous_ai or [],
        "upcomingEvents": [],
        "today3Things": [],
        "opportunityRadar": [],
        "opportunityRadarException": False,
    }
    with open(os.path.join(root, "data", "morning-brief.json"), "w", encoding="utf-8", newline="\n") as handle:
        json.dump(prev, handle)
    return prev


FULL_ROWS = [
    {"instrument": "US10Y", "value": 4.2, "unit": "percent", "asOf": "2026-09-10",
     "asOfKind": "close", "sourceId": "fred-dgs10", "status": "ok", "changeDoD": 0.05},
    {"instrument": "US30Y", "value": 4.8, "unit": "percent", "asOf": "2026-09-10",
     "asOfKind": "close", "sourceId": "fred-dgs30", "status": "ok", "changeDoD": 0.04},
    {"instrument": "Nasdaq", "value": 22000.0, "unit": "index", "asOf": "2026-09-11",
     "asOfKind": "close", "sourceId": "fred-nasdaq", "status": "ok", "changeDoD": 1.2},
    {"instrument": "SPX", "value": 6500.0, "unit": "index", "asOf": "2026-09-11",
     "asOfKind": "close", "sourceId": "fred-sp500", "status": "ok", "changeDoD": 0.8},
    {"instrument": "SOX", "value": 5800.0, "unit": "index", "asOf": "2026-09-11",
     "asOfKind": "close", "sourceId": "us-index-sox", "status": "ok", "changeDoD": 1.5},
    {"instrument": "TAIEX", "value": 25000.0, "unit": "index", "asOf": "2026-09-11",
     "asOfKind": "close", "sourceId": "twse-taiex", "status": "ok", "changeDoD": 0.9},
    {"instrument": "WTI", "value": 72.0, "unit": "USD", "asOf": "2026-09-11",
     "asOfKind": "close", "sourceId": "fred-wti", "status": "ok", "changeDoD": -0.4},
    {"instrument": "Brent", "value": 75.0, "unit": "USD", "asOf": "2026-09-11",
     "asOfKind": "close", "sourceId": "fred-brent", "status": "ok", "changeDoD": -0.3},
    {"instrument": "VIX", "value": 14.5, "unit": "index", "asOf": "2026-09-11",
     "asOfKind": "close", "sourceId": "fred-vix", "status": "ok", "changeDoD": -0.2},
    {"instrument": "Bitcoin", "value": 115000.0, "unit": "USD", "asOf": "2026-09-12",
     "asOfKind": "close", "sourceId": "fred-btc", "status": "ok", "changeDoD": 2.1},
    {"instrument": "TW_FOREIGN_NET", "value": -50.0, "unit": "TWD_hundred_million",
     "asOf": "2026-09-11", "asOfKind": "close", "sourceId": "twse-institutional",
     "status": "ok", "changeDoD": -10.0},
]


def live_handoff(when="2026-09-12"):
    return {
        "news": [{
            "id": "news-live",
            "source": "CNA Finance RSS",
            "title": "輝達供應鏈動態",
            "publishedTime": when + "T00:30:01Z",
            "url": "https://example.test/nvidia",
            "subject": "nvidia",
        }],
        "events": [{
            "eventId": "evt:other/nvidia/other",
            "what": "other",
            "when": when,
            "subject": "nvidia",
            "eventType": "Other",
            "newsRefs": ["news-live"],
        }],
        "links": [],
        "evaluations": [{
            "eventRef": "evt:other/nvidia/other",
            "importance": 4,
            "relevance": "High",
            "relevanceBasis": "與 NVIDIA／AI 基礎設施研究方向相關。",
            "impact": {
                "target": "nvidia",
                "direction": "Mixed",
                "strength": "Medium",
                "evidenceStatus": {
                    "FACT": [{"claim": "輝達供應鏈動態見報", "source": "CNA Finance RSS"}]
                },
            },
        }],
        "researchCandidates": [],
    }


tmp = tempfile.mkdtemp(prefix="InvestorTwin-P2023P2-")
try:
    # --- Unit: relationship builders ---
    items = [
        make_item("US10Y", 4.2, "percent", "2026-09-10", 0.05),
        make_item("US30Y", 4.8, "percent", "2026-09-10", 0.04),
        make_item("Nasdaq", 22000, "index", "2026-09-11", 1.2),
        make_item("SPX", 6500, "index", "2026-09-11", 0.8),
        make_item("SOX", 5800, "index", "2026-09-11", 1.5),
        make_item("TAIEX", 25000, "index", "2026-09-11", 0.9),
        make_item("WTI", 72, "USD", "2026-09-11", -0.4),
        make_item("Brent", 75, "USD", "2026-09-11", -0.3),
        make_item("VIX", 14.5, "index", "2026-09-11", -0.2),
        make_item("Bitcoin", 115000, "USD", "2026-09-12", 2.1),
    ]
    mapping = by_id_from_items(items)
    relationships = generate.build_cross_relationships(mapping)
    by_name = {row["id"]: row for row in relationships}

    record("T1-rates-equity", by_name["rates_equity"]["ok"] and "美債利率×美股／半導體" in by_name["rates_equity"]["text"])
    record("T2-sox-rates", by_name["sox_rates"]["ok"] and "半導體／Nasdaq×美債利率" in by_name["sox_rates"]["text"])
    record("T3-taiex-sox", by_name["taiwan_sox"]["ok"] and "台股×SOX" in by_name["taiwan_sox"]["text"])
    record("T4-oil-rates", by_name["oil_rates"]["ok"] and "油價×美債利率" in by_name["oil_rates"]["text"])
    record("T5-vix-equity", by_name["vix_equity"]["ok"] and "VIX×美股" in by_name["vix_equity"]["text"])
    record("T6-btc-risk", by_name["btc_risk"]["ok"] and "Bitcoin×風險偏好" in by_name["btc_risk"]["text"])

    sample = by_name["rates_equity"]["text"]
    record(
        "T7-fact-inference-unknown",
        "FACT｜" in sample and "INFERENCE｜" in sample and "UNKNOWN｜" in sample,
        sample[:300],
    )
    forbidden = []
    for row in relationships:
        text = row.get("text") or ""
        if "所以" in text and "上升，所以" in text.replace(" ", ""):
            forbidden.append(row["id"])
        if "因此導致" in text or "造成下跌" in text or "造成上漲" in text:
            forbidden.append(row["id"])
    # Soft: inference must deny causation when dirs diverge/converge
    record(
        "T8-no-unproven-causation",
        all("不足以證明因果" in (by_name[k]["text"] if by_name[k]["ok"] else "")
            or "因果未證" in (by_name[k]["text"] if by_name[k]["ok"] else "")
            or "非因果" in (by_name[k]["text"] if by_name[k]["ok"] else "")
            for k in ("rates_equity", "sox_rates", "oil_rates", "vix_equity"))
        and not forbidden,
        str(forbidden),
    )

    missing = generate.interpret_cross_relationship(
        "rates_equity", [], [make_item("Nasdaq", 1, "index", "2026-09-11", 1)],
        "美債利率", "美股／半導體",
    )
    record("T9-insufficient-unknown", (not missing["ok"]) and missing["text"].startswith("UNKNOWN｜"))

    # Executive: do not pad to 3
    one_rel = [by_name["rates_equity"]]
    summary, blocks = generate.build_executive_summary(
        [], elevate_packets=[], brief_date="2026-09-13", relationships=one_rel
    )
    record(
        "T10-exec-no-pad",
        len(blocks) == 1 and summary.count("\n") == 0,
        f"blocks={len(blocks)} summary_lines={summary.count(chr(10))+1}",
    )

    # Full brief build: old event must not be "latest"
    root = os.path.join(tmp, "root")
    os.makedirs(root, exist_ok=True)
    old_handoff = live_handoff(when="2026-09-03")
    prev = write_run(root, "2026-09-13", FULL_ROWS, handoff=old_handoff, previous_ai=[
        {"title": "08/26 NVIDIA 舊故事不應再出現", "researchId": "hbm"}
    ])
    evidence = generate.load_evidence(root)
    brief = generate.build_brief(root, evidence, prev)
    brief.pop("_selection", None)
    blob = json.dumps(brief, ensure_ascii=False)
    exec_text = brief.get("executiveSummary") or ""
    # Age 10 > MAX 7 → event excluded entirely from elevate / packets
    packets = generate.collect_evaluated_events(root, "2026-09-13")
    record(
        "T11-old-event-not-latest",
        packets == [] or all(int(p.get("ageDays") or 0) > generate.ELEVATE_EVENT_MAX_AGE_DAYS for p in packets),
        str([(p.get("eventId"), p.get("ageDays"), p.get("when")) for p in packets]),
    )
    record(
        "T11b-old-when-not-yesterday",
        "昨天" not in exec_text and "昨日" not in exec_text,
        exec_text[:200],
    )

    # Fresh event + relationships in sections
    root2 = os.path.join(tmp, "root2")
    os.makedirs(root2, exist_ok=True)
    prev2 = write_run(root2, "2026-09-13", FULL_ROWS, handoff=live_handoff("2026-09-12"))
    evidence2 = generate.load_evidence(root2)
    brief2 = generate.build_brief(root2, evidence2, prev2)
    brief2.pop("_selection", None)
    exec2 = brief2.get("executiveSummary") or ""
    global_s = (brief2.get("globalMarketAndNews") or {}).get("summary") or ""
    taiwan_s = (brief2.get("taiwanMarketAndNews") or {}).get("summary") or ""
    lens = brief2.get("macroDecisionLens") or []
    lens_blob = " ".join(str(x) for x in lens)
    today = brief2.get("today3Things") or []

    record(
        "cross-in-global",
        ("美債利率×美股" in global_s or "VIX×美股" in global_s or "油價×美債" in global_s)
        and "FACT｜" in global_s and "INFERENCE｜" in global_s,
        global_s[:250],
    )
    record(
        "cross-in-taiwan",
        "台股×SOX" in taiwan_s and "FACT｜" in taiwan_s and "INFERENCE｜" in taiwan_s,
        taiwan_s[:250],
    )
    record(
        "macro-constraint",
        "constraint" in lens_blob.lower() or "Constraint" in lens_blob or "約束" in lens_blob,
        lens_blob[:250],
    )
    record(
        "macro-regime-unknown",
        "regime" in lens_blob.lower() and "UNKNOWN｜" in lens_blob,
        lens_blob[:250],
    )
    record(
        "today-reuses-exec",
        len(today) >= 1 and any(
            (t.get("text") or "")[:40] in exec2 for t in today
        ),
        str([ (t.get("text") or "")[:60] for t in today ]),
    )
    record(
        "exec-has-labels",
        "FACT｜" in exec2 and "INFERENCE｜" in exec2 and "UNKNOWN｜" in exec2,
        exec2[:300],
    )

finally:
    shutil.rmtree(tmp, ignore_errors=True)


# T12 / T13 regressions
def run_py(path):
    proc = subprocess.run(
        [sys.executable, path],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


code12, out12 = run_py(os.path.join(ROOT, "tests", "p2-022-step2-ni-brief.py"))
record("T12-p2-022-step2-regression", code12 == 0, out12[-400:])

code13, out13 = run_py(os.path.join(ROOT, "tests", "p2-023-brief-interpretation.py"))
record("T13-p2-023-phase1-regression", code13 == 0, out13[-400:])

if fails:
    sys.stderr.write("FAIL " + "; ".join(fails) + "\n")
    raise SystemExit(1)
print("P2-023 PHASE2 CROSS-EVIDENCE UNIT OK")
raise SystemExit(0)
