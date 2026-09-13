# P2-029A — BLS API registration key integration + live verification.
# Requires BLS_REGISTRATION_KEY in environment. No sample fallback for live PASS.
import importlib.util
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPTS = os.path.join(ROOT, "scripts")

REQUIRED_SERIES = {
    "bls-cpi-sa": "CUSR0000SA0",
    "bls-cpi-nsa": "CUUR0000SA0",
    "bls-core-cpi-sa": "CUSR0000SA0L1E",
    "bls-core-cpi-nsa": "CUUR0000SA0L1E",
    "bls-unemployment": "LNS14000000",
    "bls-nonfarm": "CES0000000001",
    "bls-ahe": "CES0500000003",
}


def load_py(name, filename):
    path = os.path.join(SCRIPTS, filename)
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


fails = []
blocked = False


def record(name, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(status + " " + name + ((" " + detail) if (detail and not ok) else ""))
    if not ok:
        fails.append(name + ": " + (detail or "failed"))


evidence = load_py("evidence", "collect-evidence.py")
reg_key = evidence.bls_registration_key()

# T1 key injection exists but never printed
record(
    "T1-key-injection",
    hasattr(evidence, "bls_registration_key")
    and evidence.BLS_REGISTRATION_KEY_ENV == "BLS_REGISTRATION_KEY",
)
if reg_key:
    print("T1-key-present length=" + str(len(reg_key)))
else:
    print("BLOCKED BLS_REGISTRATION_KEY not set")
    blocked = True

# T8 credential leak — source must not embed key; stdout must not contain key
collector_src = open(os.path.join(SCRIPTS, "collect-evidence.py"), encoding="utf-8").read()
record(
    "T8-no-hardcoded-key",
    "registrationkey" not in collector_src.lower()
    or "BLS_REGISTRATION_KEY" in collector_src,
)
if reg_key and reg_key in collector_src:
    record("T8-no-hardcoded-key", False, "key found in source")
if reg_key and reg_key in sys.stdout.getvalue() if hasattr(sys.stdout, "getvalue") else False:
    record("T8-no-leak-stdout", False, "key in stdout")

if blocked:
    # Regression tests that do not require live BLS key
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

    code9, out9 = run_py(os.path.join(ROOT, "tests", "p2-029-bls-collect-foundation.py"))
    record("T9-p2-029-regression", code9 == 0, out9[-500:])
    code10, out10 = run_py(os.path.join(ROOT, "tests", "p2-024-event-understanding.py"))
    record("T10-ni-regression", code10 == 0, out10[-400:])
    code11, out11 = run_py(os.path.join(ROOT, "tests", "p2-023-phase2-cross-evidence.py"))
    record("T11-morning-brief-regression", code11 == 0, out11[-400:])
    code27, out27 = run_py(os.path.join(ROOT, "tests", "p2-027-nvidia-newsroom-rss.py"))
    record("T11b-p2-027-regression", code27 == 0, out27[-400:])
    print("P2-029A BLOCKED (missing BLS_REGISTRATION_KEY)")
    raise SystemExit(2)

captured = io.StringIO()
old_stdout = sys.stdout


class Tee:
    def __init__(self, *streams):
        self.streams = streams

    def write(self, data):
        for stream in self.streams:
            stream.write(data)

    def flush(self):
        for stream in self.streams:
            stream.flush()


sys.stdout = Tee(sys.stdout, captured)

live_rows = {}
try:
    bundled = evidence.live_bls_multi(
        list(REQUIRED_SERIES.values()),
        require_registration_key=True,
    )
    for source_id, series_id in REQUIRED_SERIES.items():
        live_rows[source_id] = bundled.get(series_id) or {}
except Exception as exc:
    sys.stdout = old_stdout
    record("T2-live-api", False, str(exc))
    print("P2-029A BLOCKED (live API error)")
    raise SystemExit(2)

sys.stdout = old_stdout
output_text = captured.getvalue()

record("T1-http-200", evidence.live_bls_multi.last_http_status == 200)
record("T2-live-api", evidence.live_bls_multi.last_api_status == "REQUEST_SUCCEEDED")
record(
    "T8-no-leak-output",
    reg_key not in output_text and reg_key not in collector_src,
)

# T3 seven series returned with live observations
for source_id, series_id in REQUIRED_SERIES.items():
    payload = live_rows.get(source_id) or {}
    obs = payload.get("observations") or []
    latest = obs[-1] if obs else {}
    cat = evidence.SOURCE_CATALOG.get(source_id) or {}
    record(
        "T3-series-" + source_id,
        len(obs) >= 1
        and latest.get("value") is not None
        and latest.get("date")
        and payload.get("seriesId") == series_id
        and cat.get("unit"),
        str({"date": latest.get("date"), "unit": cat.get("unit")}),
    )

# T4 calculations available (registered v2)
calc_series = [
    sid for sid, payload in live_rows.items()
    if (payload or {}).get("calculationsAvailable")
]
record(
    "T4-calculations",
    len(calc_series) >= 1 and evidence.live_bls_multi.registration_key_used is True,
    str(calc_series),
)

# T5 observation date = month start, not release date
cpi_sa = (live_rows.get("bls-cpi-sa") or {}).get("observations") or []
if cpi_sa:
    latest = cpi_sa[-1]
    record(
        "T5-observation-date",
        str(latest.get("date") or "").endswith("-01")
        and latest.get("observationPeriod")
        and latest.get("releaseDate") is None,
        str(latest),
    )
else:
    record("T5-observation-date", False, "no CPI SA observations")

# T6 preliminary handling
nfp = (live_rows.get("bls-nonfarm") or {}).get("observations") or []
ahe = (live_rows.get("bls-ahe") or {}).get("observations") or []
record(
    "T6-preliminary",
    (nfp and isinstance(nfp[-1].get("preliminary"), bool))
    and (ahe and isinstance(ahe[-1].get("preliminary"), bool)),
    str({"nfp": nfp[-1] if nfp else None, "ahe": ahe[-1] if ahe else None}),
)

# T7 evidence schema write
# Evidence contract status is fresh|stale|missing|unavailable (not ok/partial).
# BLS API calculations must survive observations_from_payload → normalized Evidence.
tmp_ev = tempfile.mkdtemp(prefix="InvestorTwin-P2029A-ev-")
try:
    run_dir = os.path.join(tmp_ev, "data", "evidence", "runs", "run-p2029a")
    os.makedirs(os.path.join(run_dir, "raw"), exist_ok=True)
    os.makedirs(os.path.join(run_dir, "normalized"), exist_ok=True)
    live_payload = live_rows.get("bls-cpi-sa") or {}
    live_latest = (live_payload.get("observations") or [])[-1] if live_payload.get("observations") else {}
    raw_item = {
        "sourceId": "bls-cpi-sa",
        "status": "ok",
        "payload": live_payload,
    }
    expected = cpi_sa[-1]["date"] if cpi_sa else None
    raw, produced = evidence.process_source(
        tmp_ev, raw_item, expected, "2026-09-13T14:00:00Z", run_dir
    )
    row = produced[0] if produced else {}
    live_had_calc = isinstance(live_latest.get("blsCalculations"), dict)
    calc_ok = True
    if live_had_calc:
        calc_ok = (
            isinstance(row.get("blsCalculations"), dict)
            and row.get("calculationSource") == "bls-api-v2"
            and row.get("value") != row.get("blsCalculations")
        )
    else:
        # Do not invent API calculations; local adjacency delta may still be present.
        calc_ok = row.get("blsCalculations") is None and row.get("calculationSource") is None
    record(
        "T7-evidence-schema",
        row.get("seriesId") == "CUSR0000SA0"
        and row.get("sourceId") == "bls-cpi-sa"
        and row.get("attribution") == evidence.BLS_ATTRIBUTION
        and row.get("status") in ("fresh", "stale", "missing", "unavailable")
        and row.get("asOf") == expected
        and row.get("retrievedAt") == "2026-09-13T14:00:00Z"
        and row.get("value") is not None
        and row.get("unit") == "index"
        and calc_ok,
        str({k: row.get(k) for k in (
            "seriesId", "sourceId", "status", "asOf", "value", "unit",
            "calculationSource", "blsCalculations", "calculationMethod",
        )}),
    )
    if live_had_calc:
        record(
            "T7-calc-distinct",
            row.get("calculationSource") == "bls-api-v2"
            and isinstance(row.get("blsCalculations"), dict)
            and row.get("calculationMethod") in (None, "adjacent-observation-delta"),
            str({
                "calculationSource": row.get("calculationSource"),
                "calculationMethod": row.get("calculationMethod"),
                "blsCalcKeys": list((row.get("blsCalculations") or {}).keys()),
            }),
        )
finally:
    shutil.rmtree(tmp_ev, ignore_errors=True)

# T8–T15 metric spot checks from live payloads
def latest_obs(source_id):
    obs = (live_rows.get(source_id) or {}).get("observations") or []
    return obs[-1] if obs else {}


def pct_change(source_id, periods):
    calc = latest_obs(source_id).get("blsCalculations") or {}
    pct = calc.get("pct_changes") or {}
    return pct.get(str(periods))


cpi_latest = latest_obs("bls-cpi-sa")
record("LIVE-T8-cpi-mom", pct_change("bls-cpi-sa", 1) is not None or not cpi_latest.get("blsCalculations"), str(pct_change("bls-cpi-sa", 1)))
record("LIVE-T9-cpi-yoy", pct_change("bls-cpi-sa", 12) is not None or not cpi_latest.get("blsCalculations"), str(pct_change("bls-cpi-sa", 12)))
record("LIVE-T10-core-cpi", latest_obs("bls-core-cpi-sa").get("value") is not None, str(latest_obs("bls-core-cpi-sa")))
record("LIVE-T11-unemployment", latest_obs("bls-unemployment").get("value") is not None, str(latest_obs("bls-unemployment")))
record("LIVE-T12-nfp", latest_obs("bls-nonfarm").get("value") is not None, str(latest_obs("bls-nonfarm")))
record("LIVE-T13-ahe", latest_obs("bls-ahe").get("value") is not None, str(latest_obs("bls-ahe")))
record("LIVE-T14-nfp-preliminary", isinstance(latest_obs("bls-nonfarm").get("preliminary"), bool), str(latest_obs("bls-nonfarm").get("preliminary")))
record("LIVE-T15-ahe-preliminary", isinstance(latest_obs("bls-ahe").get("preliminary"), bool), str(latest_obs("bls-ahe").get("preliminary")))

# Regressions
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


code9, out9 = run_py(os.path.join(ROOT, "tests", "p2-029-bls-collect-foundation.py"))
record("T9-p2-029-regression", code9 == 0, out9[-500:])
code10, out10 = run_py(os.path.join(ROOT, "tests", "p2-024-event-understanding.py"))
record("T10-ni-regression", code10 == 0, out10[-400:])
code11, out11 = run_py(os.path.join(ROOT, "tests", "p2-023-phase2-cross-evidence.py"))
record("T11-morning-brief-regression", code11 == 0, out11[-400:])
code27, out27 = run_py(os.path.join(ROOT, "tests", "p2-027-nvidia-newsroom-rss.py"))
record("T11b-p2-027-regression", code27 == 0, out27[-400:])

if reg_key:
    record(
        "T8-no-credential-leakage",
        reg_key not in out9 and reg_key not in out10 and reg_key not in out11 and reg_key not in out27,
    )

if fails:
    sys.stderr.write("FAIL " + "; ".join(fails) + "\n")
    raise SystemExit(1)

print("P2-029A BLS API LIVE OK")
raise SystemExit(0)
