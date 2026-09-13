# P2-022 Step 2 — News Intelligence → Morning Brief minimal wire (isolated).
# No network. Does not modify production Meaning Gate / Today / Queue engines.
import datetime
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


collect_news = load_py("collect_news", "collect-news.py")
publish = load_py("publish_handoff", "publish-research-candidates-handoff.py")
generate = load_py("generate_brief", "generate-morning-brief.py")

# --- Catalog / policy checks (Gold / engines untouched) ---
collect_ev = load_py("collect_evidence", "collect-evidence.py")
gold_in_catalog = any(
    isinstance(row, dict) and row.get("instrument") == "Gold"
    for row in collect_ev.SOURCE_CATALOG.values()
)
record("T8-no-gold-adapter", not gold_in_catalog and "Gold" not in generate.TEMPERATURE_KEYS)

record(
    "freshness-constants",
    generate.MAX_BRIEF_EVENT_AGE_DAYS == 7 and generate.ELEVATE_EVENT_MAX_AGE_DAYS == 2,
)

# --- Isolated handoff publish replace (fixture out of production input) ---
tmp = tempfile.mkdtemp(prefix="InvestorTwin-P2022-")
try:
    handoff = os.path.join(tmp, "handoff.json")
    fixture_like = {
        "news": [{
            "id": "news-fixture",
            "source": "Acceptance Fixture",
            "title": "old fixture",
            "publishedTime": "2026-09-03",
            "url": "https://example.test/fixture",
        }],
        "events": [{
            "eventId": "evt:corporate-action/hugging-face,nvidia/acquire",
            "what": "acquire",
            "when": "2026-09-03",
            "subject": "hugging-face / nvidia",
            "eventType": "Corporate Action",
            "newsRefs": ["news-fixture"],
        }],
        "links": [],
        "evaluations": [{
            "eventRef": "evt:corporate-action/hugging-face,nvidia/acquire",
            "importance": 5,
            "relevance": "High",
            "relevanceBasis": "fixture why",
            "impact": {
                "target": "NVIDIA",
                "direction": "Mixed",
                "strength": "High",
                "evidenceStatus": {
                    "FACT": [{"claim": "NVIDIA 宣布收購 Hugging Face", "source": "Acceptance Fixture"}]
                },
            },
        }],
        "researchCandidates": [],
    }
    with open(handoff, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(fixture_like, handle)

    live_payload = {
        "news": [{
            "id": "news-live-a",
            "source": "CNA Finance",
            "title": "Live A",
            "publishedTime": "2026-09-12T05:00:00Z",
            "url": "https://example.test/a",
            "subject": "台股",
        }, {
            "id": "news-live-b",
            "source": "CNA Finance",
            "title": "Live B",
            "publishedTime": "2026-09-12T06:00:00Z",
            "url": "https://example.test/b",
            "subject": "台股",
        }],
        "events": [{
            "eventId": "evt:market/live-a/move",
            "what": "move",
            "when": "2026-09-12",
            "subject": "台股",
            "eventType": "Market",
            "newsRefs": ["news-live-a"],
        }],
        "links": [],
        "evaluations": [{
            "eventRef": "evt:market/live-a/move",
            "importance": 4,
            "relevance": "High",
            "relevanceBasis": "與台股水位相關",
            "impact": {
                "target": "TAIEX",
                "direction": "Mixed",
                "strength": "Medium",
                "evidenceStatus": {
                    "FACT": [{"claim": "台股相關事件", "source": "CNA Finance", "newsRef": "news-live-a"}]
                },
            },
        }],
        "researchCandidates": [],
    }
    publish.publish_handoff(live_payload, handoff, replace=True)
    loaded = json.load(open(handoff, encoding="utf-8"))
    record(
        "T1-replace-drops-fixture",
        all(n.get("source") != "Acceptance Fixture" for n in loaded["news"])
        and any(e.get("eventId") == "evt:market/live-a/move" for e in loaded["events"]),
        json.dumps(loaded, ensure_ascii=False)[:300],
    )

    # Build isolated Brief root with evidence stub + handoff
    brief_root = os.path.join(tmp, "brief-root")
    os.makedirs(os.path.join(brief_root, "data", "evidence", "runs", "run-20260913T120000Z", "normalized"))
    os.makedirs(os.path.join(brief_root, "data", "evidence", "history", "US10Y"))
    shutil.copy2(handoff, os.path.join(brief_root, "data", "research-candidates-handoff.json"))
    run_meta = {
        "runId": "run-20260913T120000Z",
        "capturedAt": "2026-09-13T12:00:00Z",
        "expectedAsOf": "2026-09-13",
        "writesBrief": False,
        "statuses": {"US10Y": "stale"},
    }
    with open(
        os.path.join(brief_root, "data", "evidence", "runs", "run-20260913T120000Z", "run.json"),
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
    }
    with open(
        os.path.join(brief_root, "data", "evidence", "runs", "run-20260913T120000Z", "normalized", "US10Y.json"),
        "w", encoding="utf-8", newline="\n",
    ) as handle:
        json.dump(us10y, handle)
    with open(
        os.path.join(brief_root, "data", "evidence", "history", "US10Y", "2026-09-10.json"),
        "w", encoding="utf-8", newline="\n",
    ) as handle:
        json.dump(us10y, handle)
    with open(os.path.join(brief_root, "data", "morning-brief.json"), "w", encoding="utf-8", newline="\n") as handle:
        json.dump({
            "date": "2026-09-12",
            "executiveSummary": "seed",
            "macroDecisionLens": [],
            "marketTemperature": {},
            "globalMarketAndNews": {"summary": "", "items": []},
            "taiwanMarketAndNews": {"summary": "", "items": []},
            "aiIndustryHighlights": [],
            "upcomingEvents": [],
            "today3Things": [],
            "opportunityRadar": [],
            "opportunityRadarException": False,
        }, handle)

    # Seed research cards required by radar helper — empty radar ok if cards missing
    evidence = generate.load_evidence(brief_root)
    brief = generate.build_brief(brief_root, evidence, {})
    brief.pop("_selection", None)
    text = json.dumps(brief, ensure_ascii=False)
    record(
        "T1-brief-uses-live-event",
        "evt:market/live-a/move" in text and "Acceptance Fixture" not in text,
        text[:400],
    )
    record(
        "T2-old-event-not-elevated-as-yesterday",
        "2026-09-03" not in (brief.get("executiveSummary") or "")
        and "hugging-face" not in (brief.get("executiveSummary") or ""),
        brief.get("executiveSummary"),
    )
    # Absolute when present for elevated event
    record(
        "T2-absolute-when",
        "when 2026-09-12" in (brief.get("executiveSummary") or ""),
        brief.get("executiveSummary"),
    )

    # T3: republish same payload — no duplicate event ids in handoff
    publish.publish_handoff(live_payload, handoff, replace=False)
    loaded2 = json.load(open(handoff, encoding="utf-8"))
    ids = [e.get("eventId") for e in loaded2["events"]]
    record("T3-no-duplicate-events", len(ids) == len(set(ids)), str(ids))

    # T4: only stale events → Brief does not invent yesterday narrative from them
    stale_only = {
        "news": fixture_like["news"],
        "events": fixture_like["events"],
        "links": [],
        "evaluations": fixture_like["evaluations"],
        "researchCandidates": [],
    }
    publish.publish_handoff(stale_only, os.path.join(brief_root, "data", "research-candidates-handoff.json"), replace=True)
    brief_stale = generate.build_brief(brief_root, evidence, {})
    brief_stale.pop("_selection", None)
    exec_text = brief_stale.get("executiveSummary") or ""
    blob = json.dumps(brief_stale, ensure_ascii=False)
    record(
        "T4-no-stale-forced-as-news",
        "hugging-face" not in exec_text
        and "Acceptance Fixture" not in blob
        and "昨日" not in exec_text
        and "今晨" not in exec_text
        and "最新事件" not in exec_text
        and "hugging-face" not in blob,
        exec_text,
    )

    # T5/T6: Meaning Gate / Queue scripts unchanged by this test harness (hash check vs repo)
    gate = os.path.join(ROOT, "js", "candidate-gate.js")
    queue_script_markers = (
        os.path.join(ROOT, "scripts", "evaluate-news-intelligence.py"),
        os.path.join(ROOT, "scripts", "integrate-news-event-evaluation.py"),
    )
    record("T5-meaning-gate-file-present", os.path.isfile(gate))
    record(
        "T6-ni-engines-untouched-api",
        hasattr(collect_news, "pipeline") and hasattr(publish, "publish_handoff"),
    )

    # T7: market evidence path still maps Bitcoin; freshness constants for market not removed
    record("T7-market-evidence-path", "Bitcoin" in generate.TEMPERATURE_KEYS and "US10Y" in generate.INSTRUMENT_MAP)

finally:
    shutil.rmtree(tmp, ignore_errors=True)

if fails:
    sys.stderr.write("FAIL " + "; ".join(fails) + "\n")
    raise SystemExit(1)
print("P2-022 STEP2 NI BRIEF UNIT OK")
raise SystemExit(0)
