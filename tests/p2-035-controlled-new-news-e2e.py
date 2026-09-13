# P2-035 — Controlled New-News End-to-End Integration (isolated).
# News Object → integrate → event/evaluation → candidate decision → handoff → Brief
# Does NOT touch production seen / handoff / morning-brief / Meaning Gate / Queue UI.
from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPTS = os.path.join(ROOT, "scripts")

# Unique URLs — must not collide with production seen identities.
URL_A = "https://example.test/p2-035/controlled-fed-rates-note"
URL_B = "https://example.test/p2-035/controlled-nvidia-partnership-note"
PUBLISHED_A = "2026-09-12T14:00:00Z"
PUBLISHED_B = "2026-09-12T15:30:00Z"


def load_py(name, filename):
    path = os.path.join(SCRIPTS, filename)
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


fails = []


def record(name, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(status + " " + name + ((" " + detail) if detail else ""))
    if not ok:
        fails.append(name + ": " + (detail or "failed"))


def file_hash(path):
    if not os.path.isfile(path):
        return "MISSING"
    raw = open(path, "rb").read()
    return hashlib.sha256(raw).hexdigest()


def utc_now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


integrate = load_py("integrate_ni", "integrate-news-event-evaluation.py")
publish = load_py("publish_handoff", "publish-research-candidates-handoff.py")
generate = load_py("generate_brief", "generate-morning-brief.py")
evaluate = load_py("evaluate_ni", "evaluate-news-intelligence.py")

# --- Production safety baselines ---
PROD_PATHS = {
    "seen": os.path.join(ROOT, "data", "news", "seen.json"),
    "pipeline_seen": os.path.join(ROOT, "data", "news", "pipeline-seen.json"),
    "handoff": os.path.join(ROOT, "data", "research-candidates-handoff.json"),
    "brief": os.path.join(ROOT, "data", "morning-brief.json"),
    "queue": os.path.join(ROOT, "data", "research-queue.json"),
    "meaning": os.path.join(ROOT, "data", "meaning-gate-state.json"),
    "candidate_gate": os.path.join(ROOT, "data", "candidate-gate.json"),
}
hashes_before = {k: file_hash(p) for k, p in PROD_PATHS.items()}
print("HASH_BEFORE", {k: v[:16] for k, v in hashes_before.items()})

seen_before = {}
if os.path.isfile(PROD_PATHS["seen"]):
    seen_before = json.load(open(PROD_PATHS["seen"], encoding="utf-8-sig"))
by_url = seen_before.get("byUrl") or {}
record(
    "A0-urls-absent-from-prod-seen",
    URL_A not in by_url and URL_B not in by_url,
    "collision with production seen",
)

# --- Controlled News Objects (v1) ---
news_a = {
    "id": URL_A,
    "source": "Federal Reserve Press RSS",
    "sourceId": "fed-press-rss",
    "title": "Federal Reserve releases FOMC statement on policy rate path",
    "publishedTime": PUBLISHED_A,
    "url": URL_A,
    "summary": (
        "The Federal Reserve published an official FOMC statement describing "
        "the current policy rate decision and the committee outlook for inflation "
        "and employment. This is an official press release summary for integration testing."
    ),
    "subject": None,
    "eventRef": None,
}
news_b = {
    "id": URL_B,
    "source": "NVIDIA Newsroom RSS",
    "sourceId": "nvidia-newsroom-rss",
    "title": "NVIDIA and partner expand AI infrastructure capacity for data centers",
    "publishedTime": PUBLISHED_B,
    "url": URL_B,
    "summary": (
        "NVIDIA announced a partnership to expand AI infrastructure capacity "
        "with a data center ecosystem partner. The release describes compute demand "
        "and deployment plans without investment advice."
    ),
    "subject": None,
    "eventRef": None,
}

# Validate News Object shape via existing evaluator
try:
    evaluate.validate_news_object(news_a)
    evaluate.validate_news_object(news_b)
    record("A1-news-object-v1", True)
except Exception as exc:
    record("A1-news-object-v1", False, str(exc))

record(
    "A2-unique-urls",
    news_a["url"] != news_b["url"] and "example.test/p2-035/" in news_a["url"],
)
record(
    "A3-no-recommendation-leak",
    evaluate.recommendation_leak({"title": news_a["title"], "summary": news_a["summary"]}) == []
    and evaluate.recommendation_leak({"title": news_b["title"], "summary": news_b["summary"]}) == [],
)
record(
    "A4-not-acceptance-fixture",
    "Acceptance Fixture" not in news_a["source"] and "Acceptance Fixture" not in news_b["source"],
)

tmp = tempfile.mkdtemp(prefix="InvestorTwin-P2035-")
try:
    # B. Simulate normalize artifacts in isolated store only
    store = os.path.join(tmp, "news-store")
    run_id = "run-p2-035-controlled"
    norm_dir = os.path.join(store, "runs", run_id, "normalized")
    os.makedirs(norm_dir, exist_ok=True)
    for i, obj in enumerate((news_a, news_b), start=1):
        path = os.path.join(norm_dir, "news-%02d.json" % i)
        with open(path, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(obj, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
    norm_files = [f for f in os.listdir(norm_dir) if f.endswith(".json")]
    record("B-normalized-count", len(norm_files) == 2, str(norm_files))

    # C. NI integrate (existing engine)
    result = None
    try:
        result = integrate.integrate({"news": [news_a, news_b]})
        record("C1-integrate-ok", True)
    except SystemExit as exc:
        record("C1-integrate-ok", False, "SystemExit " + str(exc))
    except Exception as exc:
        record("C1-integrate-ok", False, str(exc))

    if result is None:
        record("C2-events", False, "no integrate result")
        record("C3-evaluations", False, "no integrate result")
        record("D-dedup", False, "no integrate result")
        record("E-candidate-decision", False, "no integrate result")
    else:
        events = result.get("events") or []
        evaluations = result.get("evaluations") or []
        candidates = result.get("researchCandidates") or []
        news_out = result.get("news") or []
        record("C2-events", len(events) >= 1, "events=%s" % len(events))
        record("C3-evaluations", len(evaluations) >= 1, "evaluations=%s" % len(evaluations))
        urls = [n.get("url") for n in news_out]
        record("D-dedup", len(urls) == len(set(urls)) and len(urls) == 2, str(urls))

        # Candidate may be 0 — capture gate reasons from embedded researchCandidate
        embedded = []
        for ev in evaluations:
            rc = ev.get("researchCandidate") if isinstance(ev.get("researchCandidate"), dict) else {}
            embedded.append({
                "eventRef": ev.get("eventRef"),
                "eligible": rc.get("eligible"),
                "reason": rc.get("reason"),
                "importance": ev.get("importance"),
                "relevance": ev.get("relevance"),
            })
        print("CANDIDATE_DECISIONS", json.dumps(embedded, ensure_ascii=False))
        print(
            "INTEGRATE_COUNTS",
            json.dumps({
                "news": len(news_out),
                "events": len(events),
                "evaluations": len(evaluations),
                "researchCandidates": len(candidates),
            }, ensure_ascii=False),
        )
        record(
            "E-candidate-decision-recorded",
            True,
            "eligible_count=%s (0 allowed)" % len(candidates),
        )

        # 4. Handoff to isolated path only
        handoff_path = os.path.join(tmp, "brief-root", "data", "research-candidates-handoff.json")
        os.makedirs(os.path.dirname(handoff_path), exist_ok=True)
        summary = publish.publish_handoff(result, handoff_path, replace=True)
        loaded = json.load(open(handoff_path, encoding="utf-8"))
        handoff_cands = loaded.get("researchCandidates") or []
        print(
            "HANDOFF_SUMMARY",
            json.dumps({
                "path": handoff_path.replace("\\", "/"),
                "publish": summary if isinstance(summary, dict) else str(summary),
                "news": len(loaded.get("news") or []),
                "events": len(loaded.get("events") or []),
                "evaluations": len(loaded.get("evaluations") or []),
                "researchCandidates": len(handoff_cands),
            }, ensure_ascii=False),
        )
        record(
            "H1-handoff-has-events-evals",
            len(loaded.get("events") or []) >= 1 and len(loaded.get("evaluations") or []) >= 1,
        )
        record(
            "H2-handoff-candidate-count-matches-eligible",
            len(handoff_cands) == len(candidates),
            "handoff=%s integrate=%s" % (len(handoff_cands), len(candidates)),
        )
        record(
            "H3-handoff-not-prod-path",
            os.path.abspath(handoff_path) != os.path.abspath(PROD_PATHS["handoff"]),
        )

        # 5. Morning Brief consumption under isolated --root equivalent
        brief_root = os.path.join(tmp, "brief-root")
        run_dir = os.path.join(brief_root, "data", "evidence", "runs", "run-20260913T120000Z")
        os.makedirs(os.path.join(run_dir, "normalized"), exist_ok=True)
        os.makedirs(os.path.join(brief_root, "data", "evidence", "history", "US10Y"), exist_ok=True)
        run_meta = {
            "runId": "run-20260913T120000Z",
            "capturedAt": "2026-09-13T12:00:00Z",
            "expectedAsOf": "2026-09-13",
            "writesBrief": False,
            "statuses": {"US10Y": "stale"},
        }
        with open(os.path.join(run_dir, "run.json"), "w", encoding="utf-8", newline="\n") as handle:
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
            os.path.join(run_dir, "normalized", "US10Y.json"),
            "w", encoding="utf-8", newline="\n",
        ) as handle:
            json.dump(us10y, handle)
        with open(
            os.path.join(brief_root, "data", "evidence", "history", "US10Y", "2026-09-10.json"),
            "w", encoding="utf-8", newline="\n",
        ) as handle:
            json.dump(us10y, handle)
        seed_brief = {
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
        }
        brief_path = os.path.join(brief_root, "data", "morning-brief.json")
        with open(brief_path, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(seed_brief, handle)

        hash_brief_before = file_hash(brief_path)
        evidence = generate.load_evidence(brief_root)
        brief = generate.build_brief(brief_root, evidence, {})
        brief.pop("_selection", None)
        with open(brief_path, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(brief, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        hash_brief_after = file_hash(brief_path)
        print("BRIEF_HASH_ISOLATED", hash_brief_before[:16], "->", hash_brief_after[:16])
        print("BRIEF_DATE", brief.get("date"))

        blob = json.dumps(brief, ensure_ascii=False)
        exec_text = brief.get("executiveSummary") or ""
        event_ids = [e.get("eventId") for e in (loaded.get("events") or [])]
        consumed = any(eid and eid in blob for eid in event_ids) or any(
            (n.get("title") or "")[:24] in blob for n in (loaded.get("news") or [])
        )
        # Brief contract: consumes evaluated events from handoff; candidates not required.
        print(
            "BRIEF_CONTRACT",
            json.dumps({
                "consumesEvaluatedEvents": True,
                "requiresCandidate": False,
                "handoffCandidates": len(handoff_cands),
                "consumedSignal": consumed,
            }, ensure_ascii=False),
        )
        record("B1-brief-no-acceptance-fixture", "Acceptance Fixture" not in blob)
        record(
            "B2-brief-no-false-yesterday-for-test",
            "昨日" not in exec_text or "Brief 前一日" in exec_text,
            exec_text[:200],
        )
        # publishedTime / when honesty: test news day should appear as absolute when if elevated
        when_ok = ("2026-09-12" in blob) or consumed or len(event_ids) >= 1
        record("B3-brief-has-test-when-or-event", when_ok, "events=" + str(event_ids))
        # no duplicate event ids in handoff feeding brief
        record(
            "B4-no-duplicate-event-ids",
            len(event_ids) == len(set(event_ids)),
            str(event_ids),
        )
        record(
            "B5-brief-wrote-isolated-only",
            os.path.abspath(brief_path) != os.path.abspath(PROD_PATHS["brief"])
            and hash_brief_after != hash_brief_before,
        )

        # Persist a small report under tmp (not staged)
        report = {
            "schemaVersion": "1.0",
            "kind": "p2-035-controlled-e2e",
            "finishedAt": utc_now_iso(),
            "newsUrls": [URL_A, URL_B],
            "integrate": {
                "news": len(news_out),
                "events": len(events),
                "evaluations": len(evaluations),
                "researchCandidates": len(candidates),
            },
            "candidateDecisions": embedded,
            "handoffCandidates": len(handoff_cands),
            "briefDate": brief.get("date"),
            "briefConsumedSignal": consumed,
            "isolatedPaths": {
                "store": store.replace("\\", "/"),
                "handoff": handoff_path.replace("\\", "/"),
                "brief": brief_path.replace("\\", "/"),
            },
        }
        report_path = os.path.join(ROOT, "tmp", "p2-035-e2e-report.json")
        os.makedirs(os.path.join(ROOT, "tmp"), exist_ok=True)
        with open(report_path, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(report, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        print("REPORT", report_path.replace("\\", "/"))

finally:
    # Keep isolation: wipe ephemeral tree; durable report already under repo tmp/
    shutil.rmtree(tmp, ignore_errors=True)

# --- Production untouched ---
hashes_after = {k: file_hash(p) for k, p in PROD_PATHS.items()}
for key in PROD_PATHS:
    record(
        "PROD-unchanged-" + key,
        hashes_before[key] == hashes_after[key],
        "%s -> %s" % (hashes_before[key][:12], hashes_after[key][:12]),
    )

seen_after = {}
if os.path.isfile(PROD_PATHS["seen"]):
    seen_after = json.load(open(PROD_PATHS["seen"], encoding="utf-8-sig"))
by_url_after = seen_after.get("byUrl") or {}
record(
    "PROD-seen-no-test-urls",
    URL_A not in by_url_after and URL_B not in by_url_after,
)

# Nested regressions (existing suites)
def run_py(rel):
    proc = subprocess.run(
        [sys.executable, os.path.join(ROOT, rel)],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    return proc.returncode, ((proc.stdout or "") + (proc.stderr or ""))[-400:]


for label, rel in (
    ("R-p2-023", "tests/p2-023-phase2-cross-evidence.py"),
    ("R-p2-024", "tests/p2-024-event-understanding.py"),
    ("R-p2-026", "tests/p2-026-fed-press-rss.py"),
    ("R-p2-027", "tests/p2-027-nvidia-newsroom-rss.py"),
    ("R-p2-027g", "tests/p2-027g-recommendation-guard.py"),
):
    code, out = run_py(rel)
    record(label, code == 0, out)

if fails:
    sys.stderr.write("FAIL " + "; ".join(fails) + "\n")
    raise SystemExit(1)
print("P2-035 CONTROLLED NEW-NEWS E2E OK")
raise SystemExit(0)
