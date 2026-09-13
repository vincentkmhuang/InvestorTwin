# P2-026 — Federal Reserve Press RSS Collect (isolated).
# Does not enable production Fed source. Does not modify NI / Brief engines.
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPTS = os.path.join(ROOT, "scripts")
FIXTURE = os.path.join(ROOT, "tests", "fixtures", "p2-026-fed-press-rss.xml")
FIXTURE_PLUS = os.path.join(ROOT, "tests", "fixtures", "p2-026-fed-press-rss-plus-one.xml")


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


adapter = load_py("fed_rss", "collect-fed-press-rss.py")
bootstrap = load_py("fed_boot", "bootstrap-fed-press-seen.py")
contract = load_py("news_contract", "news-object-contract.py")
collect_news = load_py("collect_news", "collect-news.py")

# T1 parse
with open(FIXTURE, encoding="utf-8") as handle:
    xml_text = handle.read()
items = adapter.parse_rss_items(xml_text)
record("T1-rss-parse", len(items) == 2 and items[0].get("title") and items[0].get("link"), str(items[:1]))

# T2 / T3 / T4 / T5 / T6 via normalize
tmp = tempfile.mkdtemp(prefix="InvestorTwin-P2026-")
try:
    store = os.path.join(tmp, "store-a")
    seed_store(store)
    run1 = adapter.collect(fixture_path=FIXTURE, store_root=store)
    record("T-fixture-collect", run1.get("status") == "ok" and count_or(run1.get("normalizedCount")) == 2, str(run1))
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
        "T5-url-fed-official",
        all(str(row.get("url") or "").startswith("https://www.federalreserve.gov/") for row in news_rows),
        str([row.get("url") for row in news_rows]),
    )
    record(
        "T6-publishedTime",
        all(str(row.get("publishedTime") or "").endswith("Z") for row in news_rows),
        str([row.get("publishedTime") for row in news_rows]),
    )

    # T7 / T8 dedup second run
    run2 = adapter.collect(fixture_path=FIXTURE, store_root=store)
    record(
        "T7-dedup",
        count_or(run2.get("normalizedCount")) == 0 and count_or(run2.get("skippedSeenCount")) == 2,
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
        and count_or(boot1.get("seededCount")) == 2
        and count_or(boot1.get("fetchedCount")) == 2,
        str(boot1),
    )
    # After bootstrap, collect same feed → all skipped, 0 normalized
    after = adapter.collect(fixture_path=FIXTURE, store_root=store_b)
    record(
        "T9b-post-bootstrap-collect-skip",
        count_or(after.get("normalizedCount")) == 0 and count_or(after.get("skippedSeenCount")) == 2,
        str(after),
    )
    # Incremental plus-one
    inc = adapter.collect(fixture_path=FIXTURE_PLUS, store_root=store_b)
    record(
        "T9c-incremental-one",
        count_or(inc.get("normalizedCount")) == 1 and count_or(inc.get("skippedSeenCount")) == 2,
        str(inc),
    )

    # Registry still disabled
    sources = json.load(open(os.path.join(ROOT, "data", "news", "sources.json"), encoding="utf-8"))
    fed_row = next((row for row in sources.get("sources") or [] if row.get("sourceId") == "fed-press-rss"), None)
    record(
        "T-registry-disabled",
        fed_row is not None and fed_row.get("enabled") is False
        and fed_row.get("official") is True
        and "press_all.xml" in str(fed_row.get("url") or fed_row.get("feedUrl") or ""),
        str(fed_row),
    )
    record("T14-no-engine-duplication", "fed-press-rss" in collect_news.ADAPTER_BY_SOURCE)

finally:
    shutil.rmtree(tmp, ignore_errors=True)

# T10 live RSS smoke (tmp store only)
live_tmp = tempfile.mkdtemp(prefix="InvestorTwin-P2026-live-")
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
    except Exception as exc:
        record("T10-live-rss-smoke-bootstrap", False, str(exc))
        record("T10b-live-recollect-skip", False, "skipped due to live bootstrap failure")
finally:
    shutil.rmtree(live_tmp, ignore_errors=True)


def run_py(path):
    proc = subprocess.run([sys.executable, path], cwd=ROOT, capture_output=True, text=True)
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


# T11 News Collect regression: dispatch registry loads; enabled sources exclude Fed
enabled = [
    row for row in json.load(open(os.path.join(ROOT, "data", "news", "sources.json"), encoding="utf-8")).get("sources") or []
    if row.get("enabled") is True
]
record("T11-news-collect-regression", all(row.get("sourceId") != "fed-press-rss" for row in enabled) and len(enabled) >= 1)

code12, out12 = run_py(os.path.join(ROOT, "tests", "p2-024-event-understanding.py"))
record("T12-ni-regression", code12 == 0, out12[-400:])

code13, out13 = run_py(os.path.join(ROOT, "tests", "p2-023-phase2-cross-evidence.py"))
record("T13-morning-brief-regression", code13 == 0, out13[-400:])

if fails:
    sys.stderr.write("FAIL " + "; ".join(fails) + "\n")
    raise SystemExit(1)
print("P2-026 FED PRESS RSS COLLECT UNIT OK")
raise SystemExit(0)
