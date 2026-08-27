# 031-M-2A unit checks: Brent/WTI/VIX catalog uses live_fred. No network.
import importlib.util
import os
import sys

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


EXPECT = (
    ("fred-brent", "Brent", "DCOILBRENTEU", "USD_per_barrel"),
    ("fred-wti", "WTI", "DCOILWTICO", "USD_per_barrel"),
    ("fred-vix", "VIX", "VIXCLS", "index"),
)

for source_id, instrument, fred_id, unit in EXPECT:
    cat = mod.SOURCE_CATALOG.get(source_id) or {}
    record(
        "catalog-" + source_id,
        cat.get("source") == "fred"
        and cat.get("instrument") == instrument
        and cat.get("fredId") == fred_id
        and cat.get("unit") == unit,
        str(cat),
    )

called = []


def fake_fred(series_id):
    called.append(series_id)
    return {"observations": [{"date": "2026-08-25", "value": 1.0}]}


mod.live_fred = fake_fred
mod.fetch_live("fred-brent", "2026-08-25")
mod.fetch_live("fred-wti", "2026-08-25")
mod.fetch_live("fred-vix", "2026-08-25")
record(
    "uses-live-fred",
    called == ["DCOILBRENTEU", "DCOILWTICO", "VIXCLS"],
    str(called),
)

if fails:
    sys.stderr.write("FAIL " + "; ".join(fails) + "\n")
    raise SystemExit(1)
print("031-M-2A FRED OIL VIX UNIT OK")
raise SystemExit(0)
