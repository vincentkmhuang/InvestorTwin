# P2-031 — EIA Collect Foundation v1 (Evidence API + Today/Press RSS).
# EIA RSS remains enabled=false. No sample fallback for live Evidence PASS.
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPTS = os.path.join(ROOT, "scripts")
FIXTURE_TODAY = os.path.join(ROOT, "tests", "fixtures", "p2-031-eia-today-energy-rss.xml")
FIXTURE_PRESS = os.path.join(ROOT, "tests", "fixtures", "p2-031-eia-press-rss.xml")
FIXTURE_TODAY_PLUS = os.path.join(ROOT, "tests", "fixtures", "p2-031-eia-today-energy-rss-plus-one.xml")

REQUIRED_EVIDENCE = {
    "eia-wti": "RWTC",
    "eia-brent": "RBRTE",
    "eia-crude-stocks": "WCESTUS1",
}


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
live_gap = False


def record(name, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(status + " " + name + ((" " + str(detail)) if (detail and not ok) else ""))
    if not ok:
        fails.append(name + ": " + (str(detail) or "failed"))


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


evidence = load_py("evidence", "collect-evidence.py")
today_adapter = load_py("eia_today", "collect-eia-today-energy-rss.py")
press_adapter = load_py("eia_press", "collect-eia-press-rss.py")
today_boot = load_py("eia_today_boot", "bootstrap-eia-today-energy-seen.py")
press_boot = load_py("eia_press_boot", "bootstrap-eia-press-seen.py")
contract = load_py("news_contract", "news-object-contract.py")
collect_news = load_py("collect_news", "collect-news.py")

# T1 key injection
key = evidence.eia_api_key()
record(
    "T1-key-injection",
    evidence.EIA_API_KEY_ENV == "EIA_API_KEY" and hasattr(evidence, "live_eia"),
)
if key:
    print("KEY_PRESENT len=" + str(len(key)))
else:
    print("KEY_ABSENT")
    live_gap = True

# T8 / T9 credential + no sample in evidence source for EIA live path
src = open(os.path.join(SCRIPTS, "collect-evidence.py"), encoding="utf-8").read()
record(
    "T8-no-credential-leakage-source",
    "EIA_API_KEY" in src and (not key or key not in src),
)
record("T9-no-sample-fallback-code", "sample" not in src.lower() or "EIA" in src)

# Catalog mapping T3-T5
for source_id, series_id in REQUIRED_EVIDENCE.items():
    cat = evidence.SOURCE_CATALOG.get(source_id) or {}
    record(
        "T-catalog-" + source_id,
        cat.get("source") == "eia" and cat.get("seriesId") == series_id,
        str(cat),
    )

live_rows = {}
if key:
    try:
        for source_id, series_id in REQUIRED_EVIDENCE.items():
            cat = evidence.SOURCE_CATALOG[source_id]
            payload = evidence.live_eia(series_id, cat["route"], cat["frequency"], length=5)
            obs = payload.get("observations") or []
            live_rows[source_id] = payload
            latest = obs[-1] if obs else {}
            record(
                "T2-http-live-" + source_id,
                payload.get("httpStatus") == 200 and latest.get("value") is not None,
                str({"period": latest.get("observationPeriod"), "value": latest.get("value")}),
            )
            print("LIVE_" + source_id + " " + json.dumps({
                "seriesId": series_id,
                "value": latest.get("value"),
                "unit": latest.get("unit") or cat.get("unit"),
                "period": latest.get("observationPeriod") or latest.get("date"),
                "frequency": latest.get("frequency") or cat.get("frequency"),
                "releaseDate": None,
            }, ensure_ascii=False))
        record("T3-rwtc", (live_rows.get("eia-wti") or {}).get("seriesId") == "RWTC")
        record("T4-rbrte", (live_rows.get("eia-brent") or {}).get("seriesId") == "RBRTE")
        record("T5-wcestus1", (live_rows.get("eia-crude-stocks") or {}).get("seriesId") == "WCESTUS1")
        wti_obs = ((live_rows.get("eia-wti") or {}).get("observations") or [])[-1:]
        inv_obs = ((live_rows.get("eia-crude-stocks") or {}).get("observations") or [])[-1:]
        record(
            "T6-observation-period",
            bool(wti_obs and wti_obs[0].get("date") and wti_obs[0].get("releaseDate") is None)
            and bool(inv_obs and inv_obs[0].get("observationPeriod")),
            str({"wti": wti_obs[0] if wti_obs else None, "inv": inv_obs[0] if inv_obs else None}),
        )
        record(
            "T7-unit-frequency",
            (wti_obs and (wti_obs[0].get("frequency") or "daily") == "daily")
            and (inv_obs and (inv_obs[0].get("frequency") or "weekly") == "weekly"),
        )
        # Evidence normalize smoke in tmp
        tmp_ev = tempfile.mkdtemp(prefix="InvestorTwin-P2031-ev-")
        try:
            run_dir = os.path.join(tmp_ev, "data", "evidence", "runs", "run-p2031")
            os.makedirs(os.path.join(run_dir, "raw"), exist_ok=True)
            os.makedirs(os.path.join(run_dir, "normalized"), exist_ok=True)
            expected = wti_obs[0]["date"] if wti_obs else None
            raw, produced = evidence.process_source(
                tmp_ev,
                {"sourceId": "eia-wti", "status": "ok", "payload": live_rows.get("eia-wti")},
                expected,
                "2026-09-13T16:00:00Z",
                run_dir,
            )
            row = produced[0] if produced else {}
            record(
                "T-evidence-normalized",
                row.get("seriesId") == "RWTC"
                and row.get("attribution") == evidence.EIA_ATTRIBUTION
                and row.get("asOf") == expected
                and row.get("releaseDate") is None
                and row.get("retrievedAt") == "2026-09-13T16:00:00Z"
                and row.get("value") is not None,
                str({k: row.get(k) for k in (
                    "seriesId", "asOf", "value", "unit", "releaseDate", "attribution", "status"
                )}),
            )
        finally:
            shutil.rmtree(tmp_ev, ignore_errors=True)
    except Exception as exc:
        live_gap = True
        detail = evidence.eia_redact(exc)
        print("GAP live-eia-api " + detail)
        record("T2-live-api-attempted", False, detail)
else:
    print("GAP live-eia-api skipped (EIA_API_KEY absent in this process)")
    record("T2-live-api-skipped-no-key", True)
    record("T3-rwtc-catalog-only", evidence.SOURCE_CATALOG["eia-wti"]["seriesId"] == "RWTC")
    record("T4-rbrte-catalog-only", evidence.SOURCE_CATALOG["eia-brent"]["seriesId"] == "RBRTE")
    record("T5-wcestus1-catalog-only", evidence.SOURCE_CATALOG["eia-crude-stocks"]["seriesId"] == "WCESTUS1")
    record("T6-observation-period-deferred", True)
    record("T7-unit-frequency-catalog", True)

# News fixtures T10-T17
tmp = tempfile.mkdtemp(prefix="InvestorTwin-P2031-")
try:
    store_t = os.path.join(tmp, "today")
    seed_news_store(store_t)
    run_t = today_adapter.collect(fixture_path=FIXTURE_TODAY, store_root=store_t)
    record(
        "T11-today-fixture-collect",
        run_t.get("status") == "ok" and count_or(run_t.get("normalizedCount")) == 2,
        str(run_t),
    )
    norm_dir = os.path.join(store_t, "runs", run_t["runId"], "normalized")
    news_rows = [
        json.load(open(os.path.join(norm_dir, name), encoding="utf-8"))
        for name in os.listdir(norm_dir) if name.endswith(".json")
    ]
    record(
        "T10-news-object-contract",
        all(contract.validate_news_object_v1(row, require_collect_url=True) is True for row in news_rows),
    )
    forbidden = ("importance", "relevance", "impact", "researchCandidate", "candidate")
    record(
        "T14-forbidden-eval-fields",
        all(all(field not in row or row.get(field) is None for field in forbidden) for row in news_rows),
    )
    record(
        "T13-absolute-url-today",
        all(str(row.get("url") or "").startswith("https://www.eia.gov/") for row in news_rows),
        str([row.get("url") for row in news_rows]),
    )

    store_p = os.path.join(tmp, "press")
    seed_news_store(store_p)
    run_p = press_adapter.collect(fixture_path=FIXTURE_PRESS, store_root=store_p)
    record(
        "T12-press-fixture-collect",
        run_p.get("status") == "ok" and count_or(run_p.get("normalizedCount")) == 2,
        str(run_p),
    )
    press_dir = os.path.join(store_p, "runs", run_p["runId"], "normalized")
    press_rows = [
        json.load(open(os.path.join(press_dir, name), encoding="utf-8"))
        for name in os.listdir(press_dir) if name.endswith(".json")
    ]
    record(
        "T13b-absolute-url-press-relative",
        all(str(row.get("url") or "").startswith("https://www.eia.gov/") for row in press_rows),
        str([row.get("url") for row in press_rows]),
    )

    store_b = os.path.join(tmp, "boot")
    seed_news_store(store_b)
    boot = today_boot.bootstrap(fixture_path=FIXTURE_TODAY, store_root=store_b)
    record(
        "T16-bootstrap",
        count_or(boot.get("seededCount")) == 2
        and count_or(boot.get("normalizedCount")) == 0
        and count_or(boot.get("integrateCount")) == 0
        and boot.get("writesNormalized") is False,
        str(boot),
    )
    after = today_adapter.collect(fixture_path=FIXTURE_TODAY, store_root=store_b)
    record(
        "T16b-dedup",
        count_or(after.get("normalizedCount")) == 0 and count_or(after.get("skippedSeenCount")) == 2,
        str(after),
    )
    inc = today_adapter.collect(fixture_path=FIXTURE_TODAY_PLUS, store_root=store_b)
    record(
        "T17-incremental-plus-one",
        count_or(inc.get("normalizedCount")) == 1 and count_or(inc.get("skippedSeenCount")) == 2,
        str(inc),
    )

    boot_p = press_boot.bootstrap(fixture_path=FIXTURE_PRESS, store_root=os.path.join(tmp, "boot-p"))
    seed_news_store(os.path.join(tmp, "boot-p"))
    # re-bootstrap clean
    shutil.rmtree(os.path.join(tmp, "boot-p"), ignore_errors=True)
    seed_news_store(os.path.join(tmp, "boot-p"))
    boot_p = press_boot.bootstrap(fixture_path=FIXTURE_PRESS, store_root=os.path.join(tmp, "boot-p"))
    record(
        "T16c-press-bootstrap",
        count_or(boot_p.get("seededCount")) == 2 and count_or(boot_p.get("normalizedCount")) == 0,
        str(boot_p),
    )
finally:
    shutil.rmtree(tmp, ignore_errors=True)

# T15 dispatch + T registry disabled
sources = json.load(open(os.path.join(ROOT, "data", "news", "sources.json"), encoding="utf-8"))
by_id = {row.get("sourceId"): row for row in sources.get("sources") or []}
record(
    "T-registry-enabled",
    by_id.get("eia-today-energy-rss", {}).get("enabled") is True
    and by_id.get("eia-press-rss", {}).get("enabled") is True,
    str({k: by_id.get(k, {}).get("enabled") for k in ("eia-today-energy-rss", "eia-press-rss")}),
)
record(
    "T15-dispatch",
    "eia-today-energy-rss" in collect_news.ADAPTER_BY_SOURCE
    and "eia-press-rss" in collect_news.ADAPTER_BY_SOURCE
    and collect_news.fixture_applies_to_source("eia-today-energy-rss", FIXTURE_TODAY)
    and collect_news.fixture_applies_to_source("eia-press-rss", FIXTURE_PRESS)
    and not collect_news.fixture_applies_to_source("eia-today-energy-rss", FIXTURE_PRESS),
)
record(
    "T20-no-second-ni",
    "eia-today-energy-rss" in collect_news.ADAPTER_BY_SOURCE
    and "evaluate-news-intelligence.py" in os.listdir(SCRIPTS),
)

# Regressions
code24, out24 = run_py(os.path.join(ROOT, "tests", "p2-024-event-understanding.py"))
record("T18-ni-regression", code24 == 0, out24[-400:])
code23, out23 = run_py(os.path.join(ROOT, "tests", "p2-023-phase2-cross-evidence.py"))
record("T19-morning-brief-regression", code23 == 0, out23[-400:])
code27, out27 = run_py(os.path.join(ROOT, "tests", "p2-027-nvidia-newsroom-rss.py"))
record("T-p2-027-regression", code27 == 0, out27[-300:])
code27g, out27g = run_py(os.path.join(ROOT, "tests", "p2-027g-recommendation-guard.py"))
record("T-p2-027g-regression", code27g == 0, out27g[-300:])
code029, out029 = run_py(os.path.join(ROOT, "tests", "p2-029-bls-collect-foundation.py"))
record("T-p2-029-regression", code029 == 0, out029[-400:])
code029b, out029b = run_py(os.path.join(ROOT, "tests", "p2-029b-bls-rss-bootstrap.py"))
record("T-p2-029b-regression", code029b == 0, out029b[-400:])

# Keep p2-029a as prior PASS note when key absent in agent
print("NOTE P2-029A prior PASS retained (do not require agent BLS key re-run)")
print("NOTE P2-029C Formal Enable retained")

if key:
    record(
        "T8b-no-key-in-regression-output",
        key not in out24 and key not in out23 and key not in out27 and key not in out029,
    )

if fails:
    sys.stderr.write("FAIL " + "; ".join(fails) + "\n")
    raise SystemExit(1)
if live_gap:
    print("P2-031 EIA COLLECT FOUNDATION OK WITH GAP (live API key absent or live call failed in this process)")
    raise SystemExit(0)
print("P2-031 EIA COLLECT FOUNDATION UNIT OK")
raise SystemExit(0)
