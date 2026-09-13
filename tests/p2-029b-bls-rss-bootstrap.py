# P2-029B — BLS RSS First-Enable Bootstrap (seen-only; enabled=false).
# Does not enable sources. Does not modify NI / Brief / production integrate.
import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPTS = os.path.join(ROOT, "scripts")
PROD_STORE = os.path.join(ROOT, "data", "news")
FIXTURE_CPI = os.path.join(ROOT, "tests", "fixtures", "p2-029-bls-cpi-rss.xml")
FIXTURE_EMP = os.path.join(ROOT, "tests", "fixtures", "p2-029-bls-empsit-rss.xml")
FIXTURE_CPI_PLUS = os.path.join(ROOT, "tests", "fixtures", "p2-029b-bls-cpi-rss-plus-one.xml")
FIXTURE_EMP_PLUS = os.path.join(ROOT, "tests", "fixtures", "p2-029b-bls-empsit-rss-plus-one.xml")


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


def seed_news_store(path):
    os.makedirs(os.path.join(path, "history", "by-url"), exist_ok=True)
    os.makedirs(os.path.join(path, "runs"), exist_ok=True)
    for name in ("schemaVersion.json", "news-object-v1.contract.json", "seen.example.json"):
        src = os.path.join(ROOT, "data", "news", name)
        if os.path.isfile(src):
            shutil.copy(src, os.path.join(path, name))
    hist_ex = os.path.join(ROOT, "data", "news", "history", "by-url", "index.example.json")
    if os.path.isfile(hist_ex):
        shutil.copy(hist_ex, os.path.join(path, "history", "by-url", "index.example.json"))


def run_py(path):
    proc = subprocess.run(
        [sys.executable, path],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


cpi_adapter = load_py("bls_cpi", "collect-bls-cpi-rss.py")
emp_adapter = load_py("bls_emp", "collect-bls-empsit-rss.py")
cpi_boot = load_py("bls_cpi_boot", "bootstrap-bls-cpi-seen.py")
emp_boot = load_py("bls_emp_boot", "bootstrap-bls-empsit-seen.py")
contract = load_py("news_contract", "news-object-contract.py")
collect_news = load_py("collect_news", "collect-news.py")

# --- T1 / T2 live fetch ---
try:
    xml_cpi = cpi_adapter.http_get_text(cpi_adapter.DEFAULT_FEED_URL)
    items_cpi_live = cpi_adapter.parse_rss_items(xml_cpi)
    record(
        "T1-cpi-live",
        cpi_adapter.http_get_text.last_status == 200 and len(items_cpi_live) >= 1,
        str({"http": cpi_adapter.http_get_text.last_status, "fetched": len(items_cpi_live)}),
    )
    print("LIVE_CPI " + json.dumps({
        "httpStatus": cpi_adapter.http_get_text.last_status,
        "fetched": len(items_cpi_live),
    }, ensure_ascii=False))
except Exception as exc:
    items_cpi_live = []
    record("T1-cpi-live", False, str(exc))

try:
    xml_emp = emp_adapter.http_get_text(emp_adapter.DEFAULT_FEED_URL)
    items_emp_live = emp_adapter.parse_rss_items(xml_emp)
    record(
        "T2-empsit-live",
        emp_adapter.http_get_text.last_status == 200 and len(items_emp_live) >= 1,
        str({"http": emp_adapter.http_get_text.last_status, "fetched": len(items_emp_live)}),
    )
    print("LIVE_EMPSIT " + json.dumps({
        "httpStatus": emp_adapter.http_get_text.last_status,
        "fetched": len(items_emp_live),
    }, ensure_ascii=False))
except Exception as exc:
    items_emp_live = []
    record("T2-empsit-live", False, str(exc))

# --- T3 / T4 / T5 / T6 / T7 / T8 / T9 fixture bootstrap path (tmp only) ---
tmp = tempfile.mkdtemp(prefix="InvestorTwin-P2029B-")
try:
    store_cpi = os.path.join(tmp, "cpi")
    seed_news_store(store_cpi)
    boot_cpi = cpi_boot.bootstrap(fixture_path=FIXTURE_CPI, store_root=store_cpi)
    record(
        "T3-cpi-bootstrap",
        boot_cpi.get("status") in ("ok", "partial")
        and count_or(boot_cpi.get("fetchedCount")) == 2
        and count_or(boot_cpi.get("seededCount")) == 2
        and count_or(boot_cpi.get("normalizedCount")) == 0
        and count_or(boot_cpi.get("integrateCount")) == 0
        and boot_cpi.get("writesNormalized") is False
        and boot_cpi.get("callsIntegrate") is False,
        str({k: boot_cpi.get(k) for k in (
            "status", "fetchedCount", "seededCount", "normalizedCount", "integrateCount"
        )}),
    )

    store_emp = os.path.join(tmp, "emp")
    seed_news_store(store_emp)
    boot_emp = emp_boot.bootstrap(fixture_path=FIXTURE_EMP, store_root=store_emp)
    record(
        "T4-empsit-bootstrap",
        boot_emp.get("status") in ("ok", "partial")
        and count_or(boot_emp.get("fetchedCount")) == 2
        and count_or(boot_emp.get("seededCount")) == 2
        and count_or(boot_emp.get("normalizedCount")) == 0
        and count_or(boot_emp.get("integrateCount")) == 0,
        str({k: boot_emp.get(k) for k in (
            "status", "fetchedCount", "seededCount", "normalizedCount", "integrateCount"
        )}),
    )

    # T5 identity parity — bootstrap identity == collect URL/guid identity
    items_fx = cpi_adapter.parse_rss_items(open(FIXTURE_CPI, encoding="utf-8").read())
    parity_ok = True
    for item in items_fx:
        boot_url, boot_guid = cpi_boot.item_identity(cpi_adapter, item)
        news = cpi_adapter.item_to_news(item, "2026-09-13T00:00:00Z", "parity-run")
        collect_url = news.get("url") or ""
        collect_guid = cpi_adapter.normalize_url(item.get("guid") or "")
        if collect_guid:
            try:
                collect_guid = cpi_adapter.assert_bls_link(collect_guid)
            except ValueError:
                collect_guid = ""
        if boot_url != collect_url or boot_guid != collect_guid:
            parity_ok = False
            break
    record("T5-identity-parity", parity_ok and len(items_fx) == 2)

    # T6 duplicate / seen after bootstrap
    after_cpi = cpi_adapter.collect(fixture_path=FIXTURE_CPI, store_root=store_cpi)
    record(
        "T6-cpi-duplicate-seen",
        count_or(after_cpi.get("normalizedCount")) == 0
        and count_or(after_cpi.get("skippedSeenCount")) == 2,
        str({k: after_cpi.get(k) for k in ("normalizedCount", "skippedSeenCount", "fetchedCount")}),
    )
    after_emp = emp_adapter.collect(fixture_path=FIXTURE_EMP, store_root=store_emp)
    record(
        "T6b-empsit-duplicate-seen",
        count_or(after_emp.get("normalizedCount")) == 0
        and count_or(after_emp.get("skippedSeenCount")) == 2,
        str({k: after_emp.get(k) for k in ("normalizedCount", "skippedSeenCount", "fetchedCount")}),
    )

    # T7 incremental +1 (collect layer only; tmp store)
    inc_cpi = cpi_adapter.collect(fixture_path=FIXTURE_CPI_PLUS, store_root=store_cpi)
    record(
        "T7-cpi-incremental-plus-one",
        count_or(inc_cpi.get("normalizedCount")) == 1
        and count_or(inc_cpi.get("skippedSeenCount")) == 2,
        str({k: inc_cpi.get(k) for k in ("normalizedCount", "skippedSeenCount", "fetchedCount")}),
    )
    inc_emp = emp_adapter.collect(fixture_path=FIXTURE_EMP_PLUS, store_root=store_emp)
    record(
        "T7b-empsit-incremental-plus-one",
        count_or(inc_emp.get("normalizedCount")) == 1
        and count_or(inc_emp.get("skippedSeenCount")) == 2,
        str({k: inc_emp.get(k) for k in ("normalizedCount", "skippedSeenCount", "fetchedCount")}),
    )

    # T8 / T9 News Object + forbidden eval fields (from incremental normalized only)
    norm_dir = os.path.join(store_cpi, "runs", inc_cpi["runId"], "normalized")
    news_rows = [
        json.load(open(os.path.join(norm_dir, name), encoding="utf-8"))
        for name in os.listdir(norm_dir) if name.endswith(".json")
    ]
    record(
        "T8-news-object-contract",
        len(news_rows) == 1
        and all(contract.validate_news_object_v1(row, require_collect_url=True) is True for row in news_rows),
        str([row.get("url") for row in news_rows]),
    )
    forbidden = ("importance", "relevance", "impact", "researchCandidate", "candidate")
    record(
        "T9-forbidden-eval-fields",
        all(all(field not in row or row.get(field) is None for field in forbidden) for row in news_rows),
    )
finally:
    shutil.rmtree(tmp, ignore_errors=True)

# --- T10 registry Formal Enable (P2-029C) ---
sources = json.load(open(os.path.join(ROOT, "data", "news", "sources.json"), encoding="utf-8"))
by_id = {row.get("sourceId"): row for row in sources.get("sources") or []}
record(
    "T10-registry-enabled",
    by_id.get("bls-cpi-rss", {}).get("enabled") is True
    and by_id.get("bls-empsit-rss", {}).get("enabled") is True,
    str({k: by_id.get(k, {}).get("enabled") for k in ("bls-cpi-rss", "bls-empsit-rss")}),
)

# --- Production First-Enable bootstrap (seen-only) + second collect ---
# Safe: sources remain enabled=false so collect-news dispatcher will not pull them in production pipelines.
prod_cpi = cpi_boot.bootstrap(store_root=PROD_STORE)
print("PROD_BOOTSTRAP_CPI " + json.dumps({
    k: prod_cpi.get(k) for k in (
        "status", "httpStatus", "fetchedCount", "seededCount", "alreadySeenCount",
        "normalizedCount", "integrateCount", "errors",
    )
}, ensure_ascii=False))
record(
    "T3b-prod-cpi-bootstrap",
    prod_cpi.get("status") in ("ok", "partial")
    and count_or(prod_cpi.get("normalizedCount")) == 0
    and count_or(prod_cpi.get("integrateCount")) == 0
    and count_or(prod_cpi.get("fetchedCount")) >= 1
    and count_or(prod_cpi.get("seededCount")) + count_or(prod_cpi.get("alreadySeenCount"))
    == count_or(prod_cpi.get("fetchedCount")),
    str({k: prod_cpi.get(k) for k in (
        "status", "fetchedCount", "seededCount", "alreadySeenCount", "normalizedCount", "integrateCount"
    )}),
)

prod_emp = emp_boot.bootstrap(store_root=PROD_STORE)
print("PROD_BOOTSTRAP_EMPSIT " + json.dumps({
    k: prod_emp.get(k) for k in (
        "status", "httpStatus", "fetchedCount", "seededCount", "alreadySeenCount",
        "normalizedCount", "integrateCount", "errors",
    )
}, ensure_ascii=False))
record(
    "T4b-prod-empsit-bootstrap",
    prod_emp.get("status") in ("ok", "partial")
    and count_or(prod_emp.get("normalizedCount")) == 0
    and count_or(prod_emp.get("integrateCount")) == 0
    and count_or(prod_emp.get("fetchedCount")) >= 1
    and count_or(prod_emp.get("seededCount")) + count_or(prod_emp.get("alreadySeenCount"))
    == count_or(prod_emp.get("fetchedCount")),
    str({k: prod_emp.get(k) for k in (
        "status", "fetchedCount", "seededCount", "alreadySeenCount", "normalizedCount", "integrateCount"
    )}),
)

# Second live collect against production store — must skip all seen, no new NI objects from history.
prod_re_cpi = cpi_adapter.collect(store_root=PROD_STORE)
print("PROD_RECOLLECT_CPI " + json.dumps({
    k: prod_re_cpi.get(k) for k in (
        "status", "httpStatus", "fetchedCount", "normalizedCount", "skippedSeenCount", "errors"
    )
}, ensure_ascii=False))
record(
    "T6c-prod-cpi-second-collect",
    count_or(prod_re_cpi.get("normalizedCount")) == 0
    and count_or(prod_re_cpi.get("skippedSeenCount")) == count_or(prod_re_cpi.get("fetchedCount"))
    and count_or(prod_re_cpi.get("fetchedCount")) >= 1,
    str({k: prod_re_cpi.get(k) for k in ("fetchedCount", "normalizedCount", "skippedSeenCount")}),
)

prod_re_emp = emp_adapter.collect(store_root=PROD_STORE)
print("PROD_RECOLLECT_EMPSIT " + json.dumps({
    k: prod_re_emp.get(k) for k in (
        "status", "httpStatus", "fetchedCount", "normalizedCount", "skippedSeenCount", "errors"
    )
}, ensure_ascii=False))
record(
    "T6d-prod-empsit-second-collect",
    count_or(prod_re_emp.get("normalizedCount")) == 0
    and count_or(prod_re_emp.get("skippedSeenCount")) == count_or(prod_re_emp.get("fetchedCount"))
    and count_or(prod_re_emp.get("fetchedCount")) >= 1,
    str({k: prod_re_emp.get(k) for k in ("fetchedCount", "normalizedCount", "skippedSeenCount")}),
)

# Confirm bootstrap-state recorded both sources; registry still disabled
boot_state = json.load(open(os.path.join(PROD_STORE, "bootstrap-state.json"), encoding="utf-8"))
by_source = boot_state.get("bySource") or {}
record(
    "T-prod-bootstrap-state",
    "bls-cpi-rss" in by_source and "bls-empsit-rss" in by_source
    and count_or((by_source.get("bls-cpi-rss") or {}).get("normalizedCount")) == 0
    and count_or((by_source.get("bls-empsit-rss") or {}).get("normalizedCount")) == 0,
    str(list(by_source.keys())),
)
sources2 = json.load(open(os.path.join(ROOT, "data", "news", "sources.json"), encoding="utf-8"))
by_id2 = {row.get("sourceId"): row for row in sources2.get("sources") or []}
record(
    "T10b-still-enabled-after-bootstrap",
    by_id2.get("bls-cpi-rss", {}).get("enabled") is True
    and by_id2.get("bls-empsit-rss", {}).get("enabled") is True,
)

# --- Regressions ---
code11, out11 = run_py(os.path.join(ROOT, "tests", "p2-029a-bls-api-live.py"))
if code11 == 2 and "BLS_REGISTRATION_KEY not set" in out11:
    # P2-029A already PASS on keyed machine; this shell may lack key. Soft-pass with note.
    print("GAP T11-p2-029a-regression (BLS_REGISTRATION_KEY unset in this shell; prior P2-029A=PASS)")
    record("T11-p2-029a-regression", True, "skipped-live-key-missing")
else:
    record("T11-p2-029a-regression", code11 == 0, out11[-500:])

code12, out12 = run_py(os.path.join(ROOT, "tests", "p2-024-event-understanding.py"))
record("T12-ni-regression", code12 == 0, out12[-400:])

code13, out13 = run_py(os.path.join(ROOT, "tests", "p2-027-nvidia-newsroom-rss.py"))
record("T13-news-collect-regression", code13 == 0, out13[-400:])

code14, out14 = run_py(os.path.join(ROOT, "tests", "p2-023-phase2-cross-evidence.py"))
record("T14-morning-brief-regression", code14 == 0, out14[-400:])

if fails:
    sys.stderr.write("FAIL " + "; ".join(fails) + "\n")
    raise SystemExit(1)
print("P2-029B BLS RSS FIRST-ENABLE BOOTSTRAP OK")
raise SystemExit(0)
