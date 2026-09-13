# P2-023 — Morning Brief evidence-based interpretation (isolated).
import importlib.util
import json
import os
import shutil
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
collect_ev = load_py("collect_evidence", "collect-evidence.py")

record(
    "T10-gold-unknown",
    "Gold" not in generate.TEMPERATURE_KEYS
    and not any(
        isinstance(row, dict) and row.get("instrument") == "Gold"
        for row in collect_ev.SOURCE_CATALOG.values()
    ),
)
record("T7-meaning-gate-untouched", os.path.isfile(os.path.join(ROOT, "js", "candidate-gate.js")))
record("T8-queue-file-present", os.path.isfile(os.path.join(ROOT, "data", "research-queue.json")))
record("T9-market-evidence-path", "Bitcoin" in generate.TEMPERATURE_KEYS and "US10Y" in generate.INSTRUMENT_MAP)

tmp = tempfile.mkdtemp(prefix="InvestorTwin-P2023-")
try:
    root = os.path.join(tmp, "root")
    os.makedirs(os.path.join(root, "data", "evidence", "runs", "run-20260913T150000Z", "normalized"))
    os.makedirs(os.path.join(root, "data", "evidence", "history", "US10Y"))
    os.makedirs(os.path.join(root, "research", "hbm"), exist_ok=True)

    run_meta = {
        "runId": "run-20260913T150000Z",
        "capturedAt": "2026-09-13T15:00:00Z",
        "expectedAsOf": "2026-09-13",
        "writesBrief": False,
        "statuses": {"US10Y": "stale", "SOX": "stale"},
    }
    with open(
        os.path.join(root, "data", "evidence", "runs", "run-20260913T150000Z", "run.json"),
        "w", encoding="utf-8", newline="\n",
    ) as handle:
        json.dump(run_meta, handle)

    us10y = {
        "instrument": "US10Y",
        "value": 4.95,
        "unit": "percent",
        "asOf": "2026-09-10",
        "asOfKind": "close",
        "sourceId": "fred-dgs10",
        "status": "stale",
        "changeDoD": 0.12,
    }
    sox = {
        "instrument": "SOX",
        "value": 11824.0,
        "unit": "index",
        "asOf": "2026-09-11",
        "asOfKind": "close",
        "sourceId": "us-index-sox",
        "status": "stale",
        "changeDoD": -1.5,
    }
    for row in (us10y, sox):
        with open(
            os.path.join(
                root, "data", "evidence", "runs", "run-20260913T150000Z", "normalized",
                row["instrument"] + ".json",
            ),
            "w", encoding="utf-8", newline="\n",
        ) as handle:
            json.dump(row, handle)
    with open(
        os.path.join(root, "data", "evidence", "history", "US10Y", "2026-09-10.json"),
        "w", encoding="utf-8", newline="\n",
    ) as handle:
        json.dump(us10y, handle)

    with open(os.path.join(root, "research", "hbm", "card.json"), "w", encoding="utf-8", newline="\n") as handle:
        json.dump({"id": "hbm", "title": "HBM"}, handle)

    handoff = {
        "news": [{
            "id": "news-live",
            "source": "CNA Finance RSS",
            "title": "輝達供應鏈動態",
            "publishedTime": "2026-09-12T00:30:01Z",
            "url": "https://example.test/nvidia",
            "subject": "nvidia",
        }],
        "events": [{
            "eventId": "evt:other/nvidia/other",
            "what": "other",
            "when": "2026-09-12",
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
                "target": "NVIDIA / AI infrastructure",
                "direction": "Mixed",
                "strength": "Medium",
                "evidenceStatus": {
                    "FACT": [{"claim": "輝達供應鏈動態見報", "source": "CNA Finance RSS"}]
                },
            },
        }],
        "researchCandidates": [],
    }
    with open(
        os.path.join(root, "data", "research-candidates-handoff.json"),
        "w", encoding="utf-8", newline="\n",
    ) as handle:
        json.dump(handoff, handle)

    with open(os.path.join(root, "data", "morning-brief.json"), "w", encoding="utf-8", newline="\n") as handle:
        json.dump({
            "date": "2026-09-12",
            "executiveSummary": "seed",
            "macroDecisionLens": [],
            "marketTemperature": {},
            "globalMarketAndNews": {"summary": "", "items": []},
            "taiwanMarketAndNews": {"summary": "", "items": []},
            "aiIndustryHighlights": [
                {"title": "08/26 NVIDIA 舊故事不應再出現", "researchId": "hbm"}
            ],
            "upcomingEvents": [],
            "today3Things": [],
            "opportunityRadar": [],
            "opportunityRadarException": False,
        }, handle)

    evidence = generate.load_evidence(root)
    brief = generate.build_brief(root, evidence, json.load(open(
        os.path.join(root, "data", "morning-brief.json"), encoding="utf-8"
    )))
    brief.pop("_selection", None)
    exec_text = brief.get("executiveSummary") or ""
    blob = json.dumps(brief, ensure_ascii=False)

    record("T1-evidence-interpretation", "FACT｜US10Y=" in exec_text and "INFERENCE｜" in exec_text, exec_text[:400])
    record("T2-event-interpretation", "evt:other/nvidia/other" in exec_text and "FACT｜" in exec_text, exec_text[:400])
    record(
        "T3-no-false-yesterday",
        "2026-09-03" not in blob
        and "昨天" not in exec_text
        and "昨日" not in exec_text
        and "when 2026-09-12" in exec_text,
        exec_text[:400],
    )
    record(
        "T4-labels-present",
        "FACT｜" in exec_text and "INFERENCE｜" in exec_text and "UNKNOWN｜" in exec_text,
        exec_text[:400],
    )
    record(
        "T-no-stale-ai-story",
        "08/26 NVIDIA" not in blob,
        str(brief.get("aiIndustryHighlights")),
    )

    # T5: empty selected market themes + no elevate → UNKNOWN executive
    empty_summary, _ = generate.build_executive_summary([], elevate_packets=[], brief_date="2026-09-13")
    record("T5-unknown-when-insufficient", empty_summary.startswith("UNKNOWN｜"), empty_summary)

    # T6: Low relevance event filtered out of collect_evaluated_events
    low_root = os.path.join(tmp, "low")
    shutil.copytree(root, low_root)
    low_handoff = {
        "news": handoff["news"],
        "events": handoff["events"],
        "links": [],
        "evaluations": [{
            "eventRef": "evt:other/nvidia/other",
            "importance": 5,
            "relevance": "Low",
            "relevanceBasis": "普通消息",
            "impact": {"target": "x", "direction": "Unclear", "strength": "Low"},
        }],
        "researchCandidates": [],
    }
    with open(
        os.path.join(low_root, "data", "research-candidates-handoff.json"),
        "w", encoding="utf-8", newline="\n",
    ) as handle:
        json.dump(low_handoff, handle)
    packets = generate.collect_evaluated_events(low_root, "2026-09-13")
    record("T6-low-relevance-excluded", packets == [], str(packets))

    # Old event age > 7 should not elevate as yesterday
    record(
        "T3b-relative-note",
        "距 Brief 10 日" in generate.when_relative_note("2026-09-03", "2026-09-13")
        and "昨天" not in generate.when_relative_note("2026-09-03", "2026-09-13"),
    )

finally:
    shutil.rmtree(tmp, ignore_errors=True)

if fails:
    sys.stderr.write("FAIL " + "; ".join(fails) + "\n")
    raise SystemExit(1)
print("P2-023 BRIEF INTERPRETATION UNIT OK")
raise SystemExit(0)
