# 031-M-5: expectedAsOf defaults to capturedAt calendar date. No network.
import datetime
import importlib.util
import os
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
COLLECT = os.path.join(ROOT, "scripts", "collect-evidence.py")
spec = importlib.util.spec_from_file_location("collect_evidence", COLLECT)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

fails = []


def record(name, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(status + " " + name + ((" " + detail) if (detail and not ok) else ""))
    if not ok:
        fails.append(name + ": " + detail)


saturday = datetime.date(2026, 8, 29)
friday = datetime.date(2026, 8, 28)
captured = datetime.datetime(2026, 8, 29, 0, 0, 8, tzinfo=datetime.timezone.utc)

record(
    "saturday-calendar",
    mod.default_expected_as_of(captured) == "2026-08-29"
    and mod.last_weekday(saturday).isoformat() == "2026-08-28",
    mod.default_expected_as_of(captured),
)
record(
    "friday-unchanged",
    mod.default_expected_as_of(datetime.datetime(2026, 8, 28, 0, 0, 11, tzinfo=datetime.timezone.utc))
    == "2026-08-28",
    "weekday default must stay the Friday calendar date",
)

mod.collect_live = lambda expected: []
tmp = tempfile.mkdtemp(prefix="InvestorTwin-031M5-")
code = mod.main([
    COLLECT,
    "--root",
    tmp,
    "--live",
    "--captured-at",
    "2026-08-29T00:00:08Z",
])
run_path = os.path.join(tmp, "data", "evidence", "runs", "run-20260829T000008Z", "run.json")
meta = mod.load_json(run_path) if os.path.isfile(run_path) else {}
record(
    "live-default-saturday",
    code == 0 and meta.get("expectedAsOf") == "2026-08-29",
    str(meta),
)

code_fri = mod.main([
    COLLECT,
    "--root",
    tmp,
    "--live",
    "--captured-at",
    "2026-08-28T00:00:11Z",
])
run_fri = os.path.join(tmp, "data", "evidence", "runs", "run-20260828T000011Z", "run.json")
meta_fri = mod.load_json(run_fri) if os.path.isfile(run_fri) else {}
record(
    "live-default-friday",
    code_fri == 0 and meta_fri.get("expectedAsOf") == "2026-08-28",
    str(meta_fri),
)

if fails:
    sys.stderr.write("FAIL " + "; ".join(fails) + "\n")
    raise SystemExit(1)
print("031-M-5 WEEKEND BRIEF DATE UNIT OK")
raise SystemExit(0)
