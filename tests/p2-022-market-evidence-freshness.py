# P2-022 Step 1 — Market Evidence freshness unit checks (no network).
import importlib.util
import os
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
COLLECT = os.path.join(ROOT, "scripts", "collect-evidence.py")
GENERATE = os.path.join(ROOT, "scripts", "generate-morning-brief.py")

spec = importlib.util.spec_from_file_location("collect_evidence", COLLECT)
collect = importlib.util.module_from_spec(spec)
spec.loader.exec_module(collect)

gen_spec = importlib.util.spec_from_file_location("generate_morning_brief", GENERATE)
generate = importlib.util.module_from_spec(gen_spec)
gen_spec.loader.exec_module(generate)

fails = []


def record(name, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(status + " " + name + ((" " + detail) if (detail and not ok) else ""))
    if not ok:
        fails.append(name + ": " + detail)


# Catalog: US index FRED fallback + Bitcoin; Gold must stay absent.
for source_id, fred_id in (
    ("us-index-nasdaq", "NASDAQCOM"),
    ("us-index-spx", "SP500"),
    ("us-index-dji", "DJIA"),
    ("us-index-sox", "NASDAQSOX"),
):
    cat = collect.SOURCE_CATALOG[source_id]
    record(
        "catalog-fallback-" + source_id,
        cat.get("fredId") == fred_id and cat.get("stooq"),
        str(cat),
    )

btc = collect.SOURCE_CATALOG.get("fred-bitcoin") or {}
record(
    "catalog-bitcoin",
    btc.get("fredId") == "CBBTCUSD"
    and btc.get("instrument") == "Bitcoin"
    and btc.get("unit") == "USD",
    str(btc),
)

gold_instruments = [
    row.get("instrument")
    for row in collect.SOURCE_CATALOG.values()
    if isinstance(row, dict) and row.get("instrument") == "Gold"
]
record("no-gold-catalog", gold_instruments == [], str(gold_instruments))

# Weekend lookback skips Sat/Sun and starts from Friday for Sunday brief date.
sunday = collect.twse_session_dates("2026-09-13")
record(
    "sunday-lookback",
    sunday[:3] == ["2026-09-11", "2026-09-10", "2026-09-09"]
    and "2026-09-13" not in sunday
    and "2026-09-12" not in sunday,
    str(sunday[:5]),
)

# Generator maps Bitcoin into Temperature; Gold remains unmapped.
record(
    "generator-bitcoin-temperature",
    generate.TEMPERATURE_KEYS.get("Bitcoin") == "Bitcoin"
    and "Bitcoin" in generate.INSTRUMENT_MAP,
    "Bitcoin missing from generator maps",
)
record(
    "generator-no-gold",
    "Gold" not in generate.TEMPERATURE_KEYS
    and "Gold" not in generate.INSTRUMENT_MAP,
    "Gold unexpectedly mapped",
)

if fails:
    sys.stderr.write("FAIL " + "; ".join(fails) + "\n")
    raise SystemExit(1)
print("P2-022 MARKET EVIDENCE FRESHNESS UNIT OK")
raise SystemExit(0)
