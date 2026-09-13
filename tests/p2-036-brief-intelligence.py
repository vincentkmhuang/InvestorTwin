# P2-036 Phase 1 — Morning Brief Intelligence Integration (isolated).
# Does not modify production handoff / brief / seen / Meaning Gate / Queue.
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPTS = os.path.join(ROOT, "scripts")
FIXTURE = os.path.join(ROOT, "tests", "fixtures", "p2-036-handoff-events.json")


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


def file_hash(path):
    if not os.path.isfile(path):
        return "MISSING"
    return hashlib.sha256(open(path, "rb").read()).hexdigest()


generate = load_py("generate_brief_p2036", "generate-morning-brief.py")

PROD = {
    "brief": os.path.join(ROOT, "data", "morning-brief.json"),
    "handoff": os.path.join(ROOT, "data", "research-candidates-handoff.json"),
    "seen": os.path.join(ROOT, "data", "news", "seen.json"),
}
hashes_before = {k: file_hash(p) for k, p in PROD.items()}


def seed_evidence(root, expected_as_of="2026-09-13"):
    run_id = "run-20260913T160000Z"
    run_dir = os.path.join(root, "data", "evidence", "runs", run_id)
    os.makedirs(os.path.join(run_dir, "normalized"), exist_ok=True)
    os.makedirs(os.path.join(root, "data", "evidence", "history", "US10Y"), exist_ok=True)
    os.makedirs(os.path.join(root, "research", "hbm"), exist_ok=True)
    with open(os.path.join(root, "research", "hbm", "card.json"), "w", encoding="utf-8") as handle:
        json.dump({"researchId": "hbm", "title": "HBM"}, handle)
    meta = {
        "runId": run_id,
        "capturedAt": "2026-09-13T16:00:00Z",
        "expectedAsOf": expected_as_of,
        "writesBrief": False,
        "statuses": {"US10Y": "stale", "SOX": "stale", "Nasdaq": "stale", "TAIEX": "stale"},
    }
    with open(os.path.join(run_dir, "run.json"), "w", encoding="utf-8", newline="\n") as handle:
        json.dump(meta, handle)
    rows = [
        {
            "instrument": "US10Y", "value": 4.95, "unit": "percent", "asOf": "2026-09-10",
            "asOfKind": "close", "sourceId": "fred-dgs10", "status": "stale", "changeDoD": 0.12,
        },
        {
            "instrument": "SOX", "value": 11824.0, "unit": "index", "asOf": "2026-09-11",
            "asOfKind": "close", "sourceId": "us-index-sox", "status": "stale", "changeDoD": 209.8,
        },
        {
            "instrument": "Nasdaq", "value": 26333.04, "unit": "index", "asOf": "2026-09-11",
            "asOfKind": "close", "sourceId": "us-index-nasdaq", "status": "stale", "changeDoD": 251.3,
        },
        {
            "instrument": "TAIEX", "value": 46184.85, "unit": "index", "asOf": "2026-09-11",
            "asOfKind": "close", "sourceId": "twse-taiex", "status": "stale", "changeDoD": -146.6,
        },
    ]
    for row in rows:
        with open(
            os.path.join(run_dir, "normalized", row["instrument"] + ".json"),
            "w", encoding="utf-8", newline="\n",
        ) as handle:
            json.dump(row, handle)
        hist = os.path.join(root, "data", "evidence", "history", row["instrument"])
        os.makedirs(hist, exist_ok=True)
        with open(os.path.join(hist, row["asOf"] + ".json"), "w", encoding="utf-8", newline="\n") as handle:
            json.dump(row, handle)


tmp = tempfile.mkdtemp(prefix="InvestorTwin-P2036-")
try:
    root = os.path.join(tmp, "root")
    os.makedirs(os.path.join(root, "data"), exist_ok=True)
    seed_evidence(root)
    shutil.copy2(FIXTURE, os.path.join(root, "data", "research-candidates-handoff.json"))
    with open(os.path.join(root, "data", "morning-brief.json"), "w", encoding="utf-8", newline="\n") as handle:
        json.dump({"date": "2026-09-12", "executiveSummary": "seed", "macroDecisionLens": [],
                   "marketTemperature": {}, "globalMarketAndNews": {"summary": "", "items": []},
                   "taiwanMarketAndNews": {"summary": "", "items": []}, "aiIndustryHighlights": [],
                   "upcomingEvents": [], "today3Things": [], "opportunityRadar": [],
                   "opportunityRadarException": False}, handle)

    evidence = generate.load_evidence(root)
    brief = generate.build_brief(root, evidence, {})
    selection = brief.pop("_selection", {})
    blob = json.dumps(brief, ensure_ascii=False)
    exec_text = brief.get("executiveSummary") or ""
    today = brief.get("today3Things") or []
    global_items = (brief.get("globalMarketAndNews") or {}).get("items") or []
    taiwan_items = (brief.get("taiwanMarketAndNews") or {}).get("items") or []

    # T1 evaluated event enters Brief
    record(
        "T1-evaluated-event-in-brief",
        "evt:ai-server/p2-036-nvidia-cooling" in blob or "evt:ai-server/p2-036-nvidia-cooling" in exec_text,
        exec_text[:240],
    )

    # T2 traceability
    event_items = [i for i in global_items + taiwan_items if i.get("kind") == "event"]
    trace_ok = False
    for item in event_items:
        intel = item.get("intelligence") if isinstance(item.get("intelligence"), dict) else {}
        ev = intel.get("event") if isinstance(intel.get("event"), dict) else {}
        if (
            (item.get("url") or ev.get("url"))
            and (item.get("publishedTime") or ev.get("publishedTime"))
            and (item.get("source") or ev.get("source"))
            and (item.get("newsTitle") or ev.get("title") or item.get("title"))
        ):
            trace_ok = True
            break
    # Also accept exec prose with real url
    if "https://example.test/p2-036/" in blob and "publishedTime" in blob:
        trace_ok = True
    record("T2-event-traceability", trace_ok, str(event_items)[:400])

    # T3 headline is not investment FACT / outcome
    record(
        "T3-headline-not-investment-fact",
        "FACT｜台灣散熱需求已經成長" not in blob
        and (
            "標題本身不是投資結論" in blob
            or "報導標題" in blob
            or "該報導提及" in blob
        ),
        blob[:500],
    )

    # T4 news claim vs business outcome
    record(
        "T4-claim-vs-outcome",
        ("非已驗證" in blob or "尚無營收" in blob or "UNKNOWN｜" in exec_text)
        and "已經造成營收" not in blob,
        exec_text[:400],
    )

    # T5 FACT / INFERENCE / UNKNOWN separation
    record(
        "T5-label-separation",
        "FACT｜" in exec_text and "INFERENCE｜" in exec_text and "UNKNOWN｜" in exec_text,
        exec_text[:300],
    )

    # T6 elevated event in Global or Taiwan section
    elevated_in_section = any(
        i.get("eventRef") == "evt:ai-server/p2-036-nvidia-cooling" for i in event_items
    )
    record("T6-elevated-in-section", elevated_in_section, str([i.get("eventRef") for i in event_items]))

    # T7 section item is compact (not full exec narrative duplicate length)
    compact_ok = True
    for item in event_items:
        title = str(item.get("title") or "")
        if len(title) > 400 and "FACT｜" in title and "INFERENCE｜" in title:
            compact_ok = False
    record("T7-section-not-full-narrative", compact_ok and elevated_in_section, "n=" + str(len(event_items)))

    # T8 stale event not yesterday
    stale_note = generate.when_relative_note("2026-09-03", "2026-09-13")
    record(
        "T8-stale-not-yesterday",
        "昨日" not in stale_note and "昨天" not in stale_note and "Background" in stale_note,
        stale_note,
    )
    # Fresh previous day wording
    prev_note = generate.when_relative_note("2026-09-12", "2026-09-13")
    record(
        "T8b-previous-trading-day",
        "Previous trading day" in prev_note and "昨日" not in prev_note,
        prev_note,
    )

    # T9 0-3 today, no padding — with only one meaningful event+relationships may be 1-3
    record("T9-today-cap", 0 <= len(today) <= 3, "count=" + str(len(today)))
    # Explicit no-pad: build with relationships-only empty elevate should not invent 3
    empty_things = generate.build_today_things([], elevate_packets=[], brief_date="2026-09-13", interpretation_blocks=[])
    record("T9b-no-pad-empty", empty_things == [], str(empty_things))

    # T10 no evidence → no certainty slogans
    record(
        "T10-no-false-certainty",
        "確認估值 regime 已經改變" not in blob
        and "買進" not in blob
        and "賣出" not in blob,
        blob[:200],
    )

    # T11 Market Evidence × Event coexist
    record(
        "T11-evidence-and-event",
        ("SOX" in exec_text or "SOX" in blob)
        and ("evt:ai-server/p2-036-nvidia-cooling" in blob)
        and ("INFERENCE｜" in exec_text),
        exec_text[:300],
    )

    # T12 acceptance fixture blocked
    packets = generate.collect_evaluated_events(root, "2026-09-13")
    record(
        "T12-acceptance-fixture-excluded",
        all(p.get("source", "").strip().lower() != "acceptance fixture" for p in packets)
        and "Acceptance Fixture" not in blob,
        str([p.get("source") for p in packets]),
    )

    # Intelligence block shape when present
    intel_ok = False
    for item in event_items:
        intel = item.get("intelligence")
        if isinstance(intel, dict) and isinstance(intel.get("event"), dict):
            ev = intel["event"]
            intel_ok = bool(ev.get("eventId")) and isinstance(intel.get("evidence"), list)
            break
    for thing in today:
        intel = thing.get("intelligence")
        if isinstance(intel, dict) and isinstance(intel.get("event"), dict):
            intel_ok = True
            record(
                "T-today-has-evidence-ids",
                isinstance(thing.get("evidence"), list) and len(thing.get("evidence") or []) >= 1,
                str(thing.get("evidence")),
            )
            break
    record("T-intelligence-block-shape", intel_ok)

    print("BRIEF_DATE", brief.get("date"))
    print("TODAY_COUNT", len(today))
    print("EVENT_ITEMS", len(event_items))
    print("SELECTION_EVENTS", selection.get("events"))

finally:
    shutil.rmtree(tmp, ignore_errors=True)

# Production untouched
for key, path in PROD.items():
    record("PROD-unchanged-" + key, hashes_before[key] == file_hash(path))

# Nested regressions
def run_py(rel):
    proc = subprocess.run([sys.executable, os.path.join(ROOT, rel)], cwd=ROOT, capture_output=True, text=True)
    return proc.returncode, ((proc.stdout or "") + (proc.stderr or ""))[-350:]


for label, rel in (
    ("R-p2-023", "tests/p2-023-brief-interpretation.py"),
    ("R-p2-023x", "tests/p2-023-phase2-cross-evidence.py"),
    ("R-p2-035", "tests/p2-035-controlled-new-news-e2e.py"),
):
    code, out = run_py(rel)
    record(label, code == 0, out)

if fails:
    sys.stderr.write("FAIL " + "; ".join(fails) + "\n")
    raise SystemExit(1)
print("P2-036 PHASE1 BRIEF INTELLIGENCE OK")
raise SystemExit(0)
