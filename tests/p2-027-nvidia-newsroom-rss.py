# P2-027 — NVIDIA Newsroom RSS Collect (isolated).
# Does not enable production NVIDIA source. Does not modify NI / Brief engines.
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPTS = os.path.join(ROOT, "scripts")
FIXTURE = os.path.join(ROOT, "tests", "fixtures", "p2-027-nvidia-newsroom-rss.xml")
FIXTURE_PLUS = os.path.join(ROOT, "tests", "fixtures", "p2-027-nvidia-newsroom-rss-plus-one.xml")


def load_py(name, filename):
    path = os.path.join(SCRIPTS, filename)
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def count_or(value, default=-1):
    if value is None:
        return default
    try:
        return int(value)
    except (TypeError, ValueError):
        return default


fails = []
live_event_samples = []


def record(name, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(status + " " + name + ((" " + detail) if (detail and not ok) else ""))
    if not ok:
        fails.append(name + ": " + (detail or "failed"))


def seed_store(path):
    os.makedirs(os.path.join(path, "history", "by-url"), exist_ok=True)
    os.makedirs(os.path.join(path, "runs"), exist_ok=True)
    for name in ("schemaVersion.json", "news-object-v1.contract.json", "seen.example.json"):
        src = os.path.join(ROOT, "data", "news", name)
        if os.path.isfile(src):
            shutil.copy(src, os.path.join(path, name))
    hist_ex = os.path.join(ROOT, "data", "news", "history", "by-url", "index.example.json")
    if os.path.isfile(hist_ex):
        shutil.copy(hist_ex, os.path.join(path, "history", "by-url", "index.example.json"))
    boot_ex = os.path.join(ROOT, "data", "news", "bootstrap-state.example.json")
    if os.path.isfile(boot_ex):
        shutil.copy(boot_ex, os.path.join(path, "bootstrap-state.example.json"))


adapter = load_py("nvidia_rss", "collect-nvidia-newsroom-rss.py")
bootstrap = load_py("nvidia_boot", "bootstrap-nvidia-newsroom-seen.py")
contract = load_py("news_contract", "news-object-contract.py")
collect_news = load_py("collect_news", "collect-news.py")
evaluate = load_py("evaluate_ni", "evaluate-news-intelligence.py")

# T1 parse
with open(FIXTURE, encoding="utf-8") as handle:
    xml_text = handle.read()
items = adapter.parse_rss_items(xml_text)
record("T1-rss-parse", len(items) == 4 and items[0].get("title") and items[0].get("link"), str(items[:1]))

# T2 / T3 / T4 / T5 / T6 via normalize
tmp = tempfile.mkdtemp(prefix="InvestorTwin-P2027-")
try:
    store = os.path.join(tmp, "store-a")
    seed_store(store)
    run1 = adapter.collect(fixture_path=FIXTURE, store_root=store)
    record(
        "T-fixture-collect",
        run1.get("status") == "ok" and count_or(run1.get("normalizedCount")) == 4,
        str(run1),
    )
    norm_dir = os.path.join(store, "runs", run1["runId"], "normalized")
    files = [os.path.join(norm_dir, name) for name in os.listdir(norm_dir) if name.endswith(".json")]
    news_rows = [json.load(open(path, encoding="utf-8")) for path in files]
    record("T2-news-object-v1", all(
        contract.validate_news_object_v1(row, require_collect_url=True) is True for row in news_rows
    ))
    required_ok = all(
        row.get("source") and row.get("title") and row.get("publishedTime") and row.get("url")
        and (row.get("summary") or row.get("content"))
        for row in news_rows
    )
    record("T3-required-fields", required_ok, str(news_rows[0] if news_rows else None))
    forbidden = ("importance", "relevance", "impact", "researchCandidate", "candidate")
    record(
        "T4-forbidden-eval-fields",
        all(all(field not in row or row.get(field) is None for field in forbidden) for row in news_rows),
    )
    record(
        "T5-url-nvidia-official",
        all(
            str(row.get("url") or "").startswith("https://blogs.nvidia.com/")
            or str(row.get("url") or "").startswith("https://nvidianews.nvidia.com/")
            for row in news_rows
        ),
        str([row.get("url") for row in news_rows]),
    )
    record(
        "T6-publishedTime",
        all(str(row.get("publishedTime") or "").endswith("Z") for row in news_rows),
        str([row.get("publishedTime") for row in news_rows]),
    )
    record(
        "T-subject-nvidia",
        all(str(row.get("subject") or "").startswith("NVIDIA") for row in news_rows),
        str([row.get("subject") for row in news_rows]),
    )
    record(
        "T-eventRef-null",
        all(row.get("eventRef") is None for row in news_rows),
    )

    # T7 / T8 dedup second run
    run2 = adapter.collect(fixture_path=FIXTURE, store_root=store)
    record(
        "T7-dedup",
        count_or(run2.get("normalizedCount")) == 0 and count_or(run2.get("skippedSeenCount")) == 4,
        str(run2),
    )
    record("T8-second-run-zero-new", count_or(run2.get("normalizedCount")) == 0)

    # T9 bootstrap safety
    store_b = os.path.join(tmp, "store-boot")
    seed_store(store_b)
    boot1 = bootstrap.bootstrap(fixture_path=FIXTURE, store_root=store_b)
    record(
        "T9-bootstrap-safety",
        count_or(boot1.get("normalizedCount")) == 0
        and count_or(boot1.get("integrateCount")) == 0
        and boot1.get("writesNormalized") is False
        and boot1.get("callsIntegrate") is False
        and count_or(boot1.get("seededCount")) == 4
        and count_or(boot1.get("fetchedCount")) == 4,
        str(boot1),
    )
    after = adapter.collect(fixture_path=FIXTURE, store_root=store_b)
    record(
        "T9b-post-bootstrap-collect-skip",
        count_or(after.get("normalizedCount")) == 0 and count_or(after.get("skippedSeenCount")) == 4,
        str(after),
    )
    inc = adapter.collect(fixture_path=FIXTURE_PLUS, store_root=store_b)
    record(
        "T9c-incremental-one",
        count_or(inc.get("normalizedCount")) == 1 and count_or(inc.get("skippedSeenCount")) == 4,
        str(inc),
    )

    # Registry enabled after P2-027E Formal Enable
    sources = json.load(open(os.path.join(ROOT, "data", "news", "sources.json"), encoding="utf-8"))
    nvidia_row = next(
        (row for row in sources.get("sources") or [] if row.get("sourceId") == "nvidia-newsroom-rss"),
        None,
    )
    record(
        "T-registry-enabled",
        nvidia_row is not None
        and nvidia_row.get("enabled") is True
        and nvidia_row.get("official") is True
        and "rss.xml" in str(nvidia_row.get("url") or nvidia_row.get("feedUrl") or ""),
        str(nvidia_row),
    )
    record("T14-no-engine-duplication", "nvidia-newsroom-rss" in collect_news.ADAPTER_BY_SOURCE)

    # Fixture event understanding (not all AI; not all Other)
    typed = []
    for item in items:
        news = adapter.item_to_news(item, "2026-09-01T00:00:00Z", "fixture-run", adapter.load_nvidia_official_module())
        ev = evaluate.event_from({}, news)
        typed.append({
            "title": news.get("title"),
            "subject": news.get("subject"),
            "eventType": ev.get("eventType"),
        })
    types = [row["eventType"] for row in typed]
    record(
        "T11a-event-understanding-variety",
        "Company / Earnings" in types
        and any(t.startswith("AI /") or t == "Company / Product" for t in types)
        and "Company / Partnership" in types
        and "Other" in types
        and not all(t.startswith("AI /") for t in types)
        and not all(t == "Other" for t in types),
        str(typed),
    )
    print("EVENT_UNDERSTANDING_FIXTURE " + json.dumps(typed, ensure_ascii=False))

finally:
    shutil.rmtree(tmp, ignore_errors=True)

# T10 live RSS smoke (tmp store only — never touch production seen)
live_tmp = tempfile.mkdtemp(prefix="InvestorTwin-P2027-live-")
try:
    seed_store(live_tmp)
    try:
        live_boot = bootstrap.bootstrap(store_root=live_tmp)
        live_ok = (
            live_boot.get("status") in ("ok", "partial")
            and count_or(live_boot.get("normalizedCount")) == 0
            and count_or(live_boot.get("integrateCount")) == 0
            and count_or(live_boot.get("fetchedCount")) >= 1
            and count_or(live_boot.get("seededCount")) == count_or(live_boot.get("fetchedCount"))
        )
        record("T10-live-rss-smoke-bootstrap", live_ok, str({
            k: live_boot.get(k) for k in (
                "status", "httpStatus", "fetchedCount", "seededCount",
                "normalizedCount", "integrateCount", "errors",
            )
        }))
        print("LIVE_BOOTSTRAP " + json.dumps({
            k: live_boot.get(k) for k in (
                "status", "httpStatus", "fetchedCount", "seededCount",
                "normalizedCount", "integrateCount",
            )
        }, ensure_ascii=False))
        live_collect = adapter.collect(store_root=live_tmp)
        record(
            "T10b-live-recollect-skip",
            count_or(live_collect.get("normalizedCount")) == 0
            and count_or(live_collect.get("skippedSeenCount")) >= 1
            and (live_collect.get("httpStatus") in (None, 200) or count_or(live_collect.get("httpStatus")) == 200),
            str({
                k: live_collect.get(k) for k in (
                    "status", "httpStatus", "fetchedCount", "normalizedCount", "skippedSeenCount", "errors",
                )
            }),
        )
        print("LIVE_RECOLLECT " + json.dumps({
            k: live_collect.get(k) for k in (
                "status", "httpStatus", "fetchedCount", "normalizedCount", "skippedSeenCount",
            )
        }, ensure_ascii=False))

        # Sample ≥3 live items for event understanding report.
        # Prefer evidence-backed types when present; Other is valid when evidence is thin.
        xml_live = adapter.http_get_text(adapter.DEFAULT_FEED_URL)
        live_items = adapter.parse_rss_items(xml_live)
        nvidia_official = adapter.load_nvidia_official_module()
        classified = []
        for item in live_items:
            news = adapter.item_to_news(item, "2026-09-13T00:00:00Z", "live-sample", nvidia_official)
            if not news.get("url"):
                continue
            ev = evaluate.event_from({}, news)
            classified.append({
                "title": news.get("title"),
                "publishedTime": news.get("publishedTime"),
                "subject": news.get("subject"),
                "eventType": ev.get("eventType"),
                "url": news.get("url"),
            })
        precise = [row for row in classified if row.get("eventType") not in (None, "Other")]
        vague = [row for row in classified if row.get("eventType") == "Other"]
        for row in precise[:2]:
            live_event_samples.append(row)
        for row in vague:
            if len(live_event_samples) >= 3:
                break
            live_event_samples.append(row)
        while len(live_event_samples) < 3 and len(classified) > len(live_event_samples):
            row = classified[len(live_event_samples)]
            if row not in live_event_samples:
                live_event_samples.append(row)
            else:
                break
        # Must not force-all-AI just because subject=NVIDIA; Other remains allowed.
        forced_ai = (
            len(classified) >= 3
            and all(str(row.get("eventType") or "").startswith("AI /") for row in classified)
        )
        record(
            "T11b-live-event-samples",
            len(live_event_samples) >= 3
            and len(precise) >= 1
            and not forced_ai
            and any(
                row.get("subject") in (None, "NVIDIA", "NVIDIA / Hugging Face")
                for row in live_event_samples
            ),
            json.dumps({
                "samples": live_event_samples,
                "preciseCount": len(precise),
                "otherCount": len(vague),
            }, ensure_ascii=False),
        )
        print("LIVE_EVENT_SAMPLES " + json.dumps(live_event_samples, ensure_ascii=False))
        print("LIVE_EVENT_TYPE_COUNTS " + json.dumps({
            "precise": len(precise),
            "other": len(vague),
            "types": sorted({row.get("eventType") for row in classified}),
        }, ensure_ascii=False))
    except Exception as exc:
        record("T10-live-rss-smoke-bootstrap", False, str(exc))
        record("T10b-live-recollect-skip", False, "skipped due to live bootstrap failure")
        record("T11b-live-event-samples", False, str(exc))
finally:
    shutil.rmtree(live_tmp, ignore_errors=True)


def run_py(path):
    proc = subprocess.run([sys.executable, path], cwd=ROOT, capture_output=True, text=True)
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


# Enabled sources must include NVIDIA after P2-027E and Fed after P2-033
enabled = [
    row for row in json.load(open(os.path.join(ROOT, "data", "news", "sources.json"), encoding="utf-8")).get("sources") or []
    if row.get("enabled") is True
]
enabled_ids = {row.get("sourceId") for row in enabled}
record(
    "T-enabled-includes-nvidia",
    "nvidia-newsroom-rss" in enabled_ids and "fed-press-rss" in enabled_ids and len(enabled) >= 1,
)

code11, out11 = run_py(os.path.join(ROOT, "tests", "p2-024-event-understanding.py"))
record("T11-p2-024-event-understanding-regression", code11 == 0, out11[-400:])

code12, out12 = run_py(os.path.join(ROOT, "tests", "p2-023-phase2-cross-evidence.py"))
record("T12-p2-023-morning-brief-regression", code12 == 0, out12[-400:])

code13, out13 = run_py(os.path.join(ROOT, "tests", "p2-026-fed-press-rss.py"))
record("T13-p2-026-fed-regression", code13 == 0, out13[-600:])

# Production seen must not be required to already hold NVIDIA identities for this step
prod_seen_path = os.path.join(ROOT, "data", "news", "seen.json")
prod_seen = {}
if os.path.isfile(prod_seen_path):
    with open(prod_seen_path, encoding="utf-8-sig") as handle:
        prod_seen = json.load(handle)
by_url = prod_seen.get("byUrl") or {}
nvidia_in_prod = [
    url for url in by_url
    if "nvidia.com" in str(url).lower() or "blogs.nvidia.com" in str(url).lower()
]
print("PROD_SEEN_NVIDIA_COUNT " + str(len(nvidia_in_prod)))

if fails:
    sys.stderr.write("FAIL " + "; ".join(fails) + "\n")
    raise SystemExit(1)
print("P2-027 NVIDIA NEWSROOM RSS COLLECT UNIT OK")
raise SystemExit(0)
