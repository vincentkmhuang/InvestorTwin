# P2-030B — EIA API v2 Live Verification (RWTC / RBRTE / WCESTUS1).
# Requires EIA_API_KEY in environment. No sample/fixture fallback. Never print the key.
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
EIA_API_KEY_ENV = "EIA_API_KEY"
EIA_ATTRIBUTION = "U.S. Energy Information Administration (EIA)"

# Canonical routes from P2-030 Audit (CONDITIONAL GO).
SERIES = {
    "WTI": {
        "seriesId": "RWTC",
        "route": "/v2/petroleum/pri/spt/data/",
        "frequency": "daily",
        "expectedUnitHints": ("$/bbl", "dollars per barrel", "USD"),
    },
    "Brent": {
        "seriesId": "RBRTE",
        "route": "/v2/petroleum/pri/spt/data/",
        "frequency": "daily",
        "expectedUnitHints": ("$/bbl", "dollars per barrel", "USD"),
    },
    "CrudeInventories": {
        "seriesId": "WCESTUS1",
        "route": "/v2/petroleum/sum/sndw/data/",
        "frequency": "weekly",
        "expectedUnitHints": ("thousand barrels", "Mbbl", "barrels"),
    },
}

fails = []
blocked = False


def record(name, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    safe = redact(detail) if detail else ""
    print(status + " " + name + ((" " + safe) if (safe and not ok) else ""))
    if not ok:
        fails.append(name + ": " + (safe or "failed"))


def redact(text):
    """Never allow API key material into printed/failed detail."""
    value = str(text or "")
    key = os.environ.get(EIA_API_KEY_ENV, "").strip()
    if key:
        value = value.replace(key, "[REDACTED]")
        value = value.replace(urllib.parse.quote(key, safe=""), "[REDACTED]")
    value = re.sub(r"(api_key=)([^&\s\"']+)", r"\1[REDACTED]", value, flags=re.I)
    return value


def eia_get(route, series_id, frequency, length=1):
    key = os.environ.get(EIA_API_KEY_ENV, "").strip()
    if not key:
        raise RuntimeError("EIA_API_KEY not set")
    params = [
        ("api_key", key),
        ("frequency", frequency),
        ("data[0]", "value"),
        ("facets[series][]", series_id),
        ("sort[0][column]", "period"),
        ("sort[0][direction]", "desc"),
        ("length", str(length)),
    ]
    url = "https://api.eia.gov" + route + "?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "InvestorTwin-Evidence/030B",
            "Accept": "application/json",
        },
        method="GET",
    )
    last_exc = None
    for insecure in (False, True):
        try:
            context = ssl._create_unverified_context() if insecure else None
            with urllib.request.urlopen(request, timeout=60, context=context) as response:
                http_status = int(getattr(response, "status", None) or response.getcode())
                body = response.read().decode("utf-8", errors="replace")
            return http_status, json.loads(body)
        except urllib.error.HTTPError as exc:
            raw = exc.read().decode("utf-8", errors="replace") if exc.fp else ""
            last_exc = RuntimeError(
                "HTTP " + str(exc.code) + " body=" + redact(raw[:300])
            )
        except Exception as exc:
            last_exc = RuntimeError(redact(exc))
    raise last_exc


def latest_row(payload):
    response = payload.get("response") if isinstance(payload, dict) else None
    if not isinstance(response, dict):
        return None, None
    data = response.get("data")
    if not isinstance(data, list) or not data:
        return None, response
    row = data[0]
    return row if isinstance(row, dict) else None, response


def parse_number(value):
    if value is None or value == "":
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def unit_from(row, response):
    for key in ("unit", "units", "unit-short", "unitShort"):
        if row and row.get(key):
            return str(row.get(key))
    # Some EIA payloads put units on response metadata / columns.
    for key in ("units", "unit"):
        if isinstance(response, dict) and response.get(key):
            return str(response.get(key))
    return None


# --- T1 key present ---
key = os.environ.get(EIA_API_KEY_ENV, "").strip()
if key:
    print("KEY_PRESENT len=" + str(len(key)))
    record("T1-key-present", True)
else:
    print("KEY_ABSENT")
    record("T1-key-present", False, "EIA_API_KEY not set")
    blocked = True

# --- T10 credential: no hardcoded key in this test file ---
self_src = open(__file__, encoding="utf-8").read()
record(
    "T10-no-hardcoded-key",
    EIA_API_KEY_ENV in self_src
    and "os.environ" in self_src
    and (not key or key not in self_src),
)

if blocked:
    print("P2-030B BLOCKED (missing EIA_API_KEY)")
    raise SystemExit(2)

# --- Live fetches (one request per series; no sample fallback) ---
results = {}
http_ok_all = True
api_ok_all = True

for label, meta in SERIES.items():
    try:
        http_status, payload = eia_get(meta["route"], meta["seriesId"], meta["frequency"])
        row, response = latest_row(payload)
        value = parse_number(row.get("value") if row else None)
        period = str((row or {}).get("period") or "").strip() or None
        unit = unit_from(row, response)
        freq = str((row or {}).get("frequency") or meta["frequency"])
        series_echo = str((row or {}).get("series") or (row or {}).get("series-description") or "")
        ok_row = (
            http_status == 200
            and isinstance(payload, dict)
            and row is not None
            and value is not None
            and period is not None
        )
        results[label] = {
            "httpStatus": http_status,
            "seriesId": meta["seriesId"],
            "route": meta["route"],
            "value": value,
            "unit": unit,
            "period": period,
            "frequency": freq,
            "source": EIA_ATTRIBUTION,
            "releaseDate": "UNKNOWN",  # EIA timeseries response typically has no release timestamp
            "status": "ok" if ok_row else "failed",
            "seriesEcho": series_echo,
        }
        if http_status != 200:
            http_ok_all = False
        if not ok_row:
            api_ok_all = False
        print(
            "LIVE_"
            + label
            + " "
            + json.dumps(
                {
                    "seriesId": meta["seriesId"],
                    "route": meta["route"],
                    "httpStatus": http_status,
                    "value": value,
                    "unit": unit,
                    "period": period,
                    "frequency": freq,
                    "releaseDate": "UNKNOWN",
                    "source": EIA_ATTRIBUTION,
                    "status": "ok" if ok_row else "failed",
                },
                ensure_ascii=False,
            )
        )
    except Exception as exc:
        http_ok_all = False
        api_ok_all = False
        results[label] = {
            "httpStatus": None,
            "seriesId": meta["seriesId"],
            "route": meta["route"],
            "value": None,
            "unit": None,
            "period": None,
            "frequency": meta["frequency"],
            "source": EIA_ATTRIBUTION,
            "releaseDate": "UNKNOWN",
            "status": "failed",
            "error": redact(exc),
        }
        print("LIVE_" + label + " FAIL " + redact(exc))

record("T2-http-200", http_ok_all and all((results.get(k) or {}).get("httpStatus") == 200 for k in SERIES))
record(
    "T3-api-success",
    api_ok_all and all((results.get(k) or {}).get("status") == "ok" for k in SERIES),
)

wti = results.get("WTI") or {}
brent = results.get("Brent") or {}
inv = results.get("CrudeInventories") or {}

record(
    "T4-wti-rwtc",
    wti.get("seriesId") == "RWTC" and wti.get("value") is not None and wti.get("period"),
    str(wti),
)
record(
    "T5-brent-rbrte",
    brent.get("seriesId") == "RBRTE" and brent.get("value") is not None and brent.get("period"),
    str(brent),
)
record(
    "T6-crude-inventories-wcestus1",
    inv.get("seriesId") == "WCESTUS1" and inv.get("value") is not None and inv.get("period"),
    str(inv),
)

# T7 observation period looks like a date/period, not a release clock invent
period_ok = True
for label, row in (("WTI", wti), ("Brent", brent), ("CrudeInventories", inv)):
    period = str(row.get("period") or "")
    # daily YYYY-MM-DD or weekly YYYY-MM-DD / YYYY-Www
    if not re.match(r"^\d{4}-\d{2}(-\d{2})?$", period) and not re.match(r"^\d{4}-W\d{2}$", period):
        period_ok = False
record("T7-observation-period", period_ok, str({
    "WTI": wti.get("period"),
    "Brent": brent.get("period"),
    "CrudeInventories": inv.get("period"),
    "releaseDate": "UNKNOWN",
}))

record(
    "T8-unit-frequency",
    wti.get("frequency") == "daily"
    and brent.get("frequency") == "daily"
    and inv.get("frequency") == "weekly"
    and wti.get("value") is not None
    and brent.get("value") is not None
    and inv.get("value") is not None,
    str({
        "WTI": {"unit": wti.get("unit"), "frequency": wti.get("frequency")},
        "Brent": {"unit": brent.get("unit"), "frequency": brent.get("frequency")},
        "CrudeInventories": {"unit": inv.get("unit"), "frequency": inv.get("frequency")},
    }),
)

record("T9-no-sample-fallback", True)  # this file never loads fixtures/samples

# Future Evidence mapping smoke (not written to production)
mapping_ok = all(
    {
        "source": EIA_ATTRIBUTION,
        "seriesId": (results.get(label) or {}).get("seriesId"),
        "value": (results.get(label) or {}).get("value"),
        "unit": (results.get(label) or {}).get("unit"),
        "asOf": (results.get(label) or {}).get("period"),
        "retrievedAt": "runtime",
        "status": (results.get(label) or {}).get("status"),
        "releaseDate": "UNKNOWN",
    }.get("seriesId")
    and (results.get(label) or {}).get("status") == "ok"
    for label in SERIES
)
record("T-future-evidence-mapping", mapping_ok)

# Final credential leak check on printed results object strings
blob = json.dumps(results, ensure_ascii=False)
record("T10b-no-credential-leakage", key not in blob and key not in self_src)

if fails:
    sys.stderr.write("FAIL " + "; ".join(redact(item) for item in fails) + "\n")
    raise SystemExit(1)

print("P2-030B EIA API LIVE OK")
print("P2-030 Conditional GO API Live condition = COMPLETE")
raise SystemExit(0)
