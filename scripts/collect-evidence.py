# Investor Twin 014 / 031-M-2A / 031-M-5 / P2-022 — Evidence collector (Live + fixture).
# Writes Raw + Normalized evidence only. Never writes Morning Brief files.
# Live default expectedAsOf is capturedAt's calendar date, not last_weekday.
# Brent / WTI / VIX / Bitcoin: live_fred (DCOILBRENTEU / DCOILWTICO / VIXCLS / CBBTCUSD).
# US indices: Stooq primary, FRED fallback (NASDAQCOM / SP500 / DJIA / NASDAQSOX).
# TWSE: previous-session weekday lookback (weekends / missing sessions).
# Gold: no reliable daily FRED USD series currently available (LBMA series removed).
# P2-029: BLS Public Data API monthly series (CPI / Employment) — observation month ≠ release date.
# P2-031: EIA API v2 (RWTC/RBRTE/WCESTUS1) — observation period ≠ release date; key via EIA_API_KEY only.
import csv
import datetime
import io
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request

BLS_API_BASE = "https://api.bls.gov/publicAPI/v2/timeseries/data/"
BLS_ATTRIBUTION = "U.S. Bureau of Labor Statistics (BLS)"
BLS_PERIOD_RE = re.compile(r"^M(0[1-9]|1[0-2])$")
# P2-029A: set locally (never commit): BLS_REGISTRATION_KEY=<key from data.bls.gov/registrationEngine/>
BLS_REGISTRATION_KEY_ENV = "BLS_REGISTRATION_KEY"

EIA_API_BASE = "https://api.eia.gov"
EIA_ATTRIBUTION = "U.S. Energy Information Administration (EIA)"
# P2-031: set locally (never commit): EIA_API_KEY=<key from eia.gov/opendata/register.php>
EIA_API_KEY_ENV = "EIA_API_KEY"

DATE_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")
MAX_OBSERVATIONS = 30
TWSE_LOOKBACK_WEEKDAYS = 8
FORBIDDEN_WRITES = (
    os.path.join("data", "morning-brief.json"),
    os.path.join("data", "morning-brief", "latest.json"),
    os.path.join("data", "research-queue.json"),
    os.path.join("data", "investment-cases.json"),
)

SOURCE_CATALOG = {
    "fred-dgs10": {
        "source": "fred",
        "instrument": "US10Y",
        "unit": "percent",
        "asOfKind": "close",
        "fredId": "DGS10",
    },
    "fred-dgs30": {
        "source": "fred",
        "instrument": "US30Y",
        "unit": "percent",
        "asOfKind": "close",
        "fredId": "DGS30",
    },
    "fred-brent": {
        "source": "fred",
        "instrument": "Brent",
        "unit": "USD_per_barrel",
        "asOfKind": "close",
        "fredId": "DCOILBRENTEU",
    },
    "fred-wti": {
        "source": "fred",
        "instrument": "WTI",
        "unit": "USD_per_barrel",
        "asOfKind": "close",
        "fredId": "DCOILWTICO",
    },
    "fred-vix": {
        "source": "fred",
        "instrument": "VIX",
        "unit": "index",
        "asOfKind": "close",
        "fredId": "VIXCLS",
    },
    "fred-bitcoin": {
        "source": "fred",
        "instrument": "Bitcoin",
        "unit": "USD",
        "asOfKind": "close",
        "fredId": "CBBTCUSD",
    },
    "us-index-nasdaq": {
        "source": "us-index",
        "instrument": "Nasdaq",
        "unit": "index",
        "asOfKind": "close",
        "stooq": "ndq.us",
        "fredId": "NASDAQCOM",
    },
    "us-index-spx": {
        "source": "us-index",
        "instrument": "SPX",
        "unit": "index",
        "asOfKind": "close",
        "stooq": "^spx",
        "fredId": "SP500",
    },
    "us-index-dji": {
        "source": "us-index",
        "instrument": "DJI",
        "unit": "index",
        "asOfKind": "close",
        "stooq": "^dji",
        "fredId": "DJIA",
    },
    "us-index-sox": {
        "source": "us-index",
        "instrument": "SOX",
        "unit": "index",
        "asOfKind": "close",
        "stooq": "^sox",
        "fredId": "NASDAQSOX",
    },
    "twse-taiex": {
        "source": "twse",
        "instrument": "TAIEX",
        "unit": "index",
        "asOfKind": "close",
    },
    "twse-institutional": {
        "source": "twse",
        "instruments": [
            ("TW_FOREIGN_NET", "foreign"),
            ("TW_TRUST_NET", "trust"),
            ("TW_DEALER_NET", "dealer"),
        ],
        "unit": "TWD_hundred_million",
        "asOfKind": "close",
    },
    # P2-029 BLS Public Data API (monthly). asOf = observation month start (YYYY-MM-01).
    "bls-cpi-sa": {
        "source": "bls",
        "instrument": "CPI_U_SA",
        "unit": "index",
        "asOfKind": "month",
        "seriesId": "CUSR0000SA0",
        "label": "CPI-U All items (seasonally adjusted)",
    },
    "bls-cpi-nsa": {
        "source": "bls",
        "instrument": "CPI_U_NSA",
        "unit": "index",
        "asOfKind": "month",
        "seriesId": "CUUR0000SA0",
        "label": "CPI-U All items (not seasonally adjusted)",
    },
    "bls-core-cpi-sa": {
        "source": "bls",
        "instrument": "CORE_CPI_SA",
        "unit": "index",
        "asOfKind": "month",
        "seriesId": "CUSR0000SA0L1E",
        "label": "CPI-U All items less food and energy (SA)",
    },
    "bls-core-cpi-nsa": {
        "source": "bls",
        "instrument": "CORE_CPI_NSA",
        "unit": "index",
        "asOfKind": "month",
        "seriesId": "CUUR0000SA0L1E",
        "label": "CPI-U All items less food and energy (NSA)",
    },
    "bls-unemployment": {
        "source": "bls",
        "instrument": "UNEMPLOYMENT_RATE",
        "unit": "percent",
        "asOfKind": "month",
        "seriesId": "LNS14000000",
        "label": "Unemployment rate (U-3)",
    },
    "bls-nonfarm": {
        "source": "bls",
        "instrument": "NONFARM_PAYROLLS",
        "unit": "thousands",
        "asOfKind": "month",
        "seriesId": "CES0000000001",
        "label": "Total nonfarm payroll employment",
    },
    "bls-ahe": {
        "source": "bls",
        "instrument": "AVG_HOURLY_EARNINGS",
        "unit": "USD",
        "asOfKind": "month",
        "seriesId": "CES0500000003",
        "label": "Average hourly earnings of all employees",
    },
    # P2-031 EIA API v2. Parallel to FRED WTI/Brent (distinct instruments — avoid overwrite).
    # asOf = observation period (API `period`); releaseDate unknown from timeseries response.
    "eia-wti": {
        "source": "eia",
        "instrument": "EIA_WTI",
        "unit": "USD_per_barrel",
        "asOfKind": "close",
        "seriesId": "RWTC",
        "route": "/v2/petroleum/pri/spt/data/",
        "frequency": "daily",
        "label": "WTI crude oil spot (EIA RWTC)",
    },
    "eia-brent": {
        "source": "eia",
        "instrument": "EIA_Brent",
        "unit": "USD_per_barrel",
        "asOfKind": "close",
        "seriesId": "RBRTE",
        "route": "/v2/petroleum/pri/spt/data/",
        "frequency": "daily",
        "label": "Brent crude oil spot (EIA RBRTE)",
    },
    "eia-crude-stocks": {
        "source": "eia",
        "instrument": "US_CRUDE_INVENTORIES",
        "unit": "thousand_barrels",
        "asOfKind": "week",
        "seriesId": "WCESTUS1",
        "route": "/v2/petroleum/sum/sndw/data/",
        "frequency": "weekly",
        "label": "US crude oil stocks ex-SPR (EIA WCESTUS1)",
    },
}


def fail(message, code=2):
    sys.stderr.write("EVIDENCE_FAIL\n" + message + "\n")
    raise SystemExit(code)


def parse_date(value):
    if not isinstance(value, str):
        return None
    matched = DATE_RE.match(value.strip())
    if not matched:
        return None
    year, month, day = map(int, matched.groups())
    try:
        return datetime.date(year, month, day)
    except ValueError:
        return None


def iso_date(value):
    parsed = parse_date(value) if isinstance(value, str) else value
    if isinstance(parsed, datetime.date):
        return parsed.isoformat()
    return None


def parse_number(value):
    if value is None:
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return round(float(value), 6)
    text = str(value).strip().replace(",", "")
    if text in ("", ".", "NA", "na", "null", "None"):
        return None
    try:
        return round(float(text), 6)
    except ValueError:
        return None


def last_weekday(day):
    current = day
    while current.weekday() >= 5:
        current = current - datetime.timedelta(days=1)
    return current


def default_expected_as_of(captured_dt):
    return captured_dt.date().isoformat()


def parse_captured_at(value):
    if not value:
        return None
    text = str(value).strip().replace("Z", "+00:00")
    try:
        return datetime.datetime.fromisoformat(text)
    except ValueError:
        return None


def run_id_from_captured(captured_at):
    stamp = captured_at.strftime("%Y%m%dT%H%M%SZ")
    if captured_at.tzinfo is None:
        stamp = captured_at.strftime("%Y%m%dT%H%M%S")
    return "run-" + stamp


def load_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def ends_with_protected(path, protected):
    normalized = os.path.normpath(path).replace("/", os.sep)
    return normalized.endswith(protected)


def refuse_brief_input(path):
    for forbidden in FORBIDDEN_WRITES[:2]:
        if ends_with_protected(path, forbidden):
            fail("refusing to read Brief as evidence input: " + forbidden)


def evidence_relpath(root, path):
    try:
        rel = os.path.relpath(os.path.abspath(path), os.path.abspath(root))
    except ValueError:
        fail("refusing to write outside data/evidence/: " + path)
    return rel.replace("\\", "/")


def write_json(path, payload, root=None):
    normalized = os.path.normpath(path)
    for forbidden in FORBIDDEN_WRITES:
        if ends_with_protected(normalized, forbidden):
            fail("refusing to write protected file: " + forbidden)
    if root:
        rel = evidence_relpath(root, path)
        if rel.startswith("..") or not rel.startswith("data/evidence/"):
            fail("refusing to write outside data/evidence/: " + rel)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def row_as_of(row):
    return iso_date(
        row.get("observation_date")
        or row.get("DATE")
        or row.get("date")
        or row.get("asOf")
    )


def trim_observation_payload(payload):
    if not isinstance(payload, dict):
        return payload
    rows = payload.get("observations")
    if not isinstance(rows, list) or len(rows) <= MAX_OBSERVATIONS:
        return payload
    dated = [row for row in rows if isinstance(row, dict) and row_as_of(row)]
    dated.sort(key=lambda row: row_as_of(row))
    out = dict(payload)
    out["observations"] = dated[-MAX_OBSERVATIONS:]
    return out


def observations_from_payload(payload):
    if payload is None:
        return []
    if isinstance(payload, list):
        rows = payload
    elif isinstance(payload, dict):
        if isinstance(payload.get("tables"), list) and payload.get("observations") is None:
            return observations_from_payload(parse_twse_taiex_json(payload))
        if (
            isinstance(payload.get("data"), list)
            and payload.get("tables") is None
            and payload.get("observations") is None
        ):
            return observations_from_payload(parse_twse_institutional_json(payload))
        rows = payload.get("observations")
        if rows is None:
            rows = payload.get("closes")
        if rows is None:
            rows = []
        if isinstance(rows, dict):
            rows = [rows]
    else:
        return []
    out = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        as_of = row_as_of(row)
        value = parse_number(row.get("value") if "value" in row else row.get("close"))
        extras = {}
        for extra in ("foreign", "trust", "dealer"):
            if extra in row:
                extras[extra] = parse_number(row.get(extra))
        if "preliminary" in row:
            extras["preliminary"] = bool(row.get("preliminary"))
        if row.get("seriesId"):
            extras["seriesId"] = row.get("seriesId")
        if row.get("observationPeriod"):
            extras["observationPeriod"] = row.get("observationPeriod")
        if "releaseDate" in row:
            extras["releaseDate"] = row.get("releaseDate")
        # P2-029A: preserve BLS API v2 calculations (distinct from raw value / local delta).
        if isinstance(row.get("blsCalculations"), dict):
            extras["blsCalculations"] = row.get("blsCalculations")
        if row.get("frequency"):
            extras["frequency"] = row.get("frequency")
        if row.get("unit"):
            extras["unit"] = row.get("unit")
        if as_of is None:
            continue
        if value is None and not any(
            item is not None for key, item in extras.items() if key in ("foreign", "trust", "dealer")
        ):
            continue
        item = {"date": as_of, "value": value}
        item.update(extras)
        out.append(item)
    out.sort(key=lambda item: item["date"])
    return out


def pick_observation(observations, expected_as_of):
    if not observations:
        return None
    if expected_as_of:
        exact = [row for row in observations if row["date"] == expected_as_of]
        if exact:
            return exact[-1]
        older = [row for row in observations if row["date"] < expected_as_of]
        if older:
            return older[-1]
        return None
    return observations[-1]


def classify_status(source_status, value, as_of, expected_as_of):
    if source_status == "unavailable":
        return "unavailable"
    if source_status == "missing" or value is None or as_of is None:
        return "missing"
    if expected_as_of and as_of < expected_as_of:
        return "stale"
    return "fresh"


def load_history(root, instrument):
    folder = os.path.join(root, "data", "evidence", "history", instrument)
    rows = []
    if not os.path.isdir(folder):
        return rows
    for name in os.listdir(folder):
        if not name.endswith(".json"):
            continue
        path = os.path.join(folder, name)
        try:
            item = load_json(path)
        except Exception:
            continue
        as_of = iso_date(item.get("asOf"))
        value = parse_number(item.get("value"))
        if as_of and value is not None:
            rows.append({"date": as_of, "value": value})
    rows.sort(key=lambda item: item["date"])
    return rows


def merge_series(payload_obs, history_rows, field="value"):
    merged = {}
    for row in history_rows:
        value = parse_number(row.get(field if field in row else "value"))
        if row.get("date") and value is not None:
            merged[row["date"]] = value
    for row in payload_obs:
        value = parse_number(row.get(field, row.get("value")))
        if row.get("date") and value is not None:
            merged[row["date"]] = value
    return [{"date": date, "value": merged[date]} for date in sorted(merged)]


def change_vs(series, as_of, mode):
    if not as_of:
        return None, None, "unavailable"
    prior_rows = [row for row in series if row["date"] < as_of]
    if not prior_rows:
        return None, None, "unavailable"
    if mode == "dod":
        prior = prior_rows[-1]
    else:
        target = (parse_date(as_of) - datetime.timedelta(days=7)).isoformat()
        week = [row for row in prior_rows if row["date"] <= target]
        if week:
            prior = week[-1]
        elif len(prior_rows) >= 5:
            prior = prior_rows[-5]
        else:
            return None, None, "unavailable"
    current = next((row for row in series if row["date"] == as_of), None)
    if current is None:
        return None, None, "unavailable"
    return prior["value"], round(current["value"] - prior["value"], 6), "ok"


def http_get(url, timeout=20, insecure=False):
    request = urllib.request.Request(url, headers={"User-Agent": "InvestorTwin-Evidence/014"})
    context = ssl._create_unverified_context() if insecure else None
    with urllib.request.urlopen(request, timeout=timeout, context=context) as response:
        return response.read().decode("utf-8", errors="replace")


def live_fred(series_id):
    api_key = os.environ.get("FRED_API_KEY", "").strip()
    if api_key:
        url = (
            "https://api.stlouisfed.org/fred/series/observations"
            "?series_id=" + series_id +
            "&api_key=" + api_key +
            "&file_type=json&sort_order=desc&limit=30"
        )
        data = json.loads(http_get(url))
        rows = []
        for item in data.get("observations") or []:
            value = parse_number(item.get("value"))
            as_of = row_as_of(item)
            if as_of and value is not None:
                rows.append({"date": as_of, "value": value})
        rows.sort(key=lambda item: item["date"])
        return {"observations": rows[-MAX_OBSERVATIONS:]}
    url = "https://fred.stlouisfed.org/graph/fredgraph.csv?id=" + series_id
    text = http_get(url)
    rows = []
    reader = csv.DictReader(io.StringIO(text))
    for item in reader:
        as_of = row_as_of(item)
        value = parse_number(item.get(series_id) or item.get("value"))
        if as_of and value is not None:
            rows.append({"date": as_of, "value": value})
    rows.sort(key=lambda item: item["date"])
    return {"observations": rows[-MAX_OBSERVATIONS:]}


def bls_period_to_asof(year, period):
    """Map BLS year+Mxx to observation-month asOf (first calendar day). Not release date."""
    year_s = str(year or "").strip()
    period_s = str(period or "").strip().upper()
    if not year_s.isdigit() or not BLS_PERIOD_RE.match(period_s):
        return None
    month = int(period_s[1:])
    return datetime.date(int(year_s), month, 1).isoformat()


def bls_footnotes_preliminary(footnotes):
    if not isinstance(footnotes, list):
        return False
    for note in footnotes:
        if not isinstance(note, dict):
            continue
        code = str(note.get("code") or "").upper()
        text = str(note.get("text") or "").lower()
        if code == "P" or "preliminary" in text:
            return True
    return False


def bls_registration_key():
    """Return BLS API v2 registration key from environment (never log or persist)."""
    return os.environ.get(BLS_REGISTRATION_KEY_ENV, "").strip()


def bls_parse_api_calculations(row):
    """Extract BLS v2 calculations; kept separate from raw observation value."""
    calc = row.get("calculations") if isinstance(row, dict) else None
    if not isinstance(calc, dict):
        return None
    net = calc.get("net_changes")
    pct = calc.get("pct_changes")
    if not isinstance(net, dict) and not isinstance(pct, dict):
        return None
    out = {"source": "bls-api-v2"}
    if isinstance(net, dict) and net:
        out["net_changes"] = {str(k): str(v) for k, v in net.items() if v is not None}
    if isinstance(pct, dict) and pct:
        out["pct_changes"] = {str(k): str(v) for k, v in pct.items() if v is not None}
    return out if len(out) > 1 else None


def live_bls(series_id):
    """Fetch one BLS series (wrapper around multi-series POST)."""
    bundled = live_bls_multi([series_id])
    return bundled.get(str(series_id)) or {
        "observations": [],
        "seriesId": series_id,
        "attribution": BLS_ATTRIBUTION,
        "source": "bls",
    }


def live_bls_multi(series_ids, require_registration_key=False):
    """POST multiple BLS series in one request to conserve daily query quota."""
    ids = [str(sid) for sid in series_ids if sid]
    if not ids:
        return {}
    reg_key = bls_registration_key()
    if require_registration_key and not reg_key:
        raise ValueError("BLS_REGISTRATION_KEY not set")
    request_body = {"seriesid": ids}
    if reg_key:
        request_body["registrationkey"] = reg_key
        request_body["calculations"] = True
        today = datetime.date.today()
        request_body["endyear"] = str(today.year)
        request_body["startyear"] = str(today.year - 2)
    body = json.dumps(request_body).encode("utf-8")
    url = BLS_API_BASE.rstrip("/") + "/"
    request = urllib.request.Request(
        url,
        data=body,
        headers={
            "User-Agent": "InvestorTwin-Evidence/029A",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )
    last_exc = None
    text = None
    live_bls_multi.last_http_status = None
    live_bls_multi.last_api_status = None
    live_bls_multi.registration_key_used = bool(reg_key)
    for insecure in (False, True):
        try:
            context = ssl._create_unverified_context() if insecure else None
            with urllib.request.urlopen(request, timeout=60, context=context) as response:
                live_bls_multi.last_http_status = int(getattr(response, "status", None) or response.getcode())
                text = response.read().decode("utf-8", errors="replace")
            break
        except Exception as exc:
            last_exc = exc
    if text is None:
        raise last_exc
    payload = json.loads(text)
    live_bls_multi.last_api_status = str(payload.get("status") or "")
    if live_bls_multi.last_api_status != "REQUEST_SUCCEEDED":
        raise ValueError(
            "BLS API status=" + live_bls_multi.last_api_status
            + " message=" + str(payload.get("message"))
        )
    out = {}
    for series_row in ((payload.get("Results") or {}).get("series") or []):
        series_id = str(series_row.get("seriesID") or "")
        data = series_row.get("data") or []
        observations = []
        for row in data:
            if not isinstance(row, dict):
                continue
            value = parse_number(row.get("value"))
            as_of = bls_period_to_asof(row.get("year"), row.get("period"))
            if value is None or as_of is None:
                continue
            period = str(row.get("period") or "").upper()
            observation_period = None
            if period.startswith("M") and len(period) == 3:
                observation_period = str(row.get("year")) + "-" + period[1:]
            observation = {
                "date": as_of,
                "value": value,
                "seriesId": series_id,
                "observationPeriod": observation_period,
                "periodName": row.get("periodName"),
                "preliminary": bls_footnotes_preliminary(row.get("footnotes")),
                "releaseDate": None,
            }
            bls_calc = bls_parse_api_calculations(row)
            if bls_calc:
                observation["blsCalculations"] = bls_calc
            observations.append(observation)
        observations.sort(key=lambda item: item["date"])
        out[series_id] = {
            "observations": observations[-MAX_OBSERVATIONS:],
            "seriesId": series_id,
            "attribution": BLS_ATTRIBUTION,
            "source": "bls",
            "api": BLS_API_BASE,
            "registrationKeyUsed": bool(reg_key),
            "calculationsAvailable": any(item.get("blsCalculations") for item in observations),
        }
    for series_id in ids:
        if series_id not in out:
            out[series_id] = {
                "observations": [],
                "seriesId": series_id,
                "attribution": BLS_ATTRIBUTION,
                "source": "bls",
                "api": BLS_API_BASE,
                "registrationKeyUsed": bool(reg_key),
                "calculationsAvailable": False,
            }
    return out


def eia_api_key():
    """Return EIA API key from environment (never log or persist)."""
    return os.environ.get(EIA_API_KEY_ENV, "").strip()


def eia_redact(text):
    value = str(text or "")
    key = eia_api_key()
    if key:
        value = value.replace(key, "[REDACTED]")
        value = value.replace(urllib.parse.quote(key, safe=""), "[REDACTED]")
    value = re.sub(r"(api_key=)([^&\s\"']+)", r"\1[REDACTED]", value, flags=re.I)
    return value


def eia_period_to_asof(period):
    """Map EIA API period string to observation asOf. Not a release timestamp."""
    raw = str(period or "").strip()
    if not raw:
        return None
    # Daily / weekly often YYYY-MM-DD
    as_of = iso_date(raw)
    if as_of:
        return as_of
    # Accept YYYY-MM (month) → first day
    if re.match(r"^\d{4}-\d{2}$", raw):
        return raw + "-01"
    return None


def live_eia(series_id, route, frequency, length=None):
    """GET one EIA APIv2 series. Requires EIA_API_KEY. No sample fallback."""
    key = eia_api_key()
    if not key:
        raise ValueError("EIA_API_KEY not set")
    length = length or MAX_OBSERVATIONS
    params = [
        ("api_key", key),
        ("frequency", frequency),
        ("data[0]", "value"),
        ("facets[series][]", str(series_id)),
        ("sort[0][column]", "period"),
        ("sort[0][direction]", "desc"),
        ("length", str(length)),
    ]
    url = EIA_API_BASE.rstrip("/") + str(route) + "?" + urllib.parse.urlencode(params)
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "InvestorTwin-Evidence/031",
            "Accept": "application/json",
        },
        method="GET",
    )
    last_exc = None
    text = None
    http_status = None
    for insecure in (False, True):
        try:
            context = ssl._create_unverified_context() if insecure else None
            with urllib.request.urlopen(request, timeout=60, context=context) as response:
                http_status = int(getattr(response, "status", None) or response.getcode())
                text = response.read().decode("utf-8", errors="replace")
            break
        except urllib.error.HTTPError as exc:
            body = ""
            try:
                body = exc.read().decode("utf-8", errors="replace")[:300]
            except Exception:
                body = ""
            last_exc = ValueError("EIA HTTP " + str(exc.code) + " " + eia_redact(body))
        except Exception as exc:
            last_exc = ValueError(eia_redact(exc))
    if text is None:
        raise last_exc
    if http_status != 200:
        raise ValueError("EIA HTTP " + str(http_status))
    payload = json.loads(text)
    response = payload.get("response") if isinstance(payload, dict) else None
    if not isinstance(response, dict):
        raise ValueError("EIA API response missing response object")
    data = response.get("data")
    if not isinstance(data, list):
        raise ValueError("EIA API response missing data[]")
    observations = []
    for row in data:
        if not isinstance(row, dict):
            continue
        value = parse_number(row.get("value"))
        period = str(row.get("period") or "").strip()
        as_of = eia_period_to_asof(period)
        if value is None or as_of is None:
            continue
        unit = row.get("unit") or row.get("units") or row.get("unit-short")
        observations.append({
            "date": as_of,
            "value": value,
            "seriesId": str(series_id),
            "observationPeriod": period,
            "unit": str(unit) if unit else None,
            "frequency": str(row.get("frequency") or frequency),
            # Timeseries API has no publication timestamp.
            "releaseDate": None,
        })
    observations.sort(key=lambda item: item["date"])
    return {
        "observations": observations[-MAX_OBSERVATIONS:],
        "seriesId": str(series_id),
        "attribution": EIA_ATTRIBUTION,
        "source": "eia",
        "api": EIA_API_BASE + str(route),
        "frequency": frequency,
        "httpStatus": http_status,
    }


def live_stooq(symbol):
    url = "https://stooq.com/q/d/l/?s=" + symbol + "&i=d"
    text = http_get(url)
    head = text[:2000].lower()
    if "<html" in head or "verify your browser" in head or "/__verify" in head:
        raise ValueError("stooq returned HTML challenge, not CSV")
    reader = csv.DictReader(io.StringIO(text))
    fields = [name.strip() for name in (reader.fieldnames or []) if name]
    has_date = any(name in ("Date", "DATE", "date") for name in fields)
    has_close = any(name in ("Close", "close") for name in fields)
    if not has_date or not has_close:
        raise ValueError("stooq response missing Date/Close columns")
    rows = []
    for item in reader:
        as_of = iso_date(item.get("Date") or item.get("DATE") or item.get("date"))
        value = parse_number(item.get("Close") or item.get("close"))
        if as_of and value is not None:
            rows.append({"date": as_of, "value": value})
    if not rows:
        raise ValueError("stooq CSV had Date/Close but no usable observations")
    return {"observations": rows[-MAX_OBSERVATIONS:]}


def fetch_us_index(catalog):
    """Stooq primary; FRED fallback. Never rewrite observation asOf."""
    stooq_symbol = catalog.get("stooq")
    fred_id = catalog.get("fredId")
    stooq_error = None
    if stooq_symbol:
        try:
            payload = live_stooq(stooq_symbol)
            if observations_from_payload(payload):
                out = dict(payload)
                out["provider"] = "stooq"
                return out
            stooq_error = "stooq returned no usable observations"
        except Exception as exc:
            stooq_error = str(exc)
    else:
        stooq_error = "stooq symbol missing"
    if not fred_id:
        raise ValueError(stooq_error or "us-index unavailable")
    try:
        payload = live_fred(fred_id)
        if not observations_from_payload(payload):
            raise ValueError("fred returned no usable observations")
        out = dict(payload)
        out["provider"] = "fred"
        return out
    except Exception as exc:
        raise ValueError(
            "stooq: " + (stooq_error or "unavailable") + "; fred: " + str(exc)
        )


def twse_session_dates(expected_as_of, max_sessions=TWSE_LOOKBACK_WEEKDAYS):
    """Weekday session candidates: expected day first, weekends skipped, no future dates."""
    day = parse_date(expected_as_of)
    if day is None:
        return []
    dates = []
    current = day
    guard = 0
    while len(dates) < max_sessions and guard < 40:
        if current.weekday() < 5:
            dates.append(current.isoformat())
        current = current - datetime.timedelta(days=1)
        guard += 1
    return dates


def fetch_twse_session(fetcher, expected_as_of):
    """Try expected session day, then prior weekdays. Preserve source asOf."""
    last_error = None
    for day in twse_session_dates(expected_as_of):
        try:
            payload = fetcher(day)
            if observations_from_payload(payload):
                return payload
            last_error = "empty observations for " + day
        except Exception as exc:
            last_error = str(exc)
            continue
    detail = ("; last=" + last_error) if last_error else ""
    raise ValueError("no session in lookback for " + str(expected_as_of) + detail)


def twse_date(value):
    day = parse_date(value)
    return day.strftime("%Y%m%d") if day else None


def twse_response_date(data, fallback_ymd):
    raw = str(data.get("date") or fallback_ymd or "")
    digits = re.sub(r"\D", "", raw)
    if len(digits) == 8:
        return iso_date(digits[:4] + "-" + digits[4:6] + "-" + digits[6:8])
    return None


TAIEX_LABEL = "發行量加權股價指數"
DEALER_LABELS = ("自營商(自行買賣)", "自營商（自行買賣）")
INSTITUTIONAL_INSTRUMENTS = ("TW_FOREIGN_NET", "TW_TRUST_NET", "TW_DEALER_NET")
TWD_TO_HUNDRED_MILLION = 100000000.0


def parse_twse_taiex_json(data):
    as_of = twse_response_date(data, None)
    close = None
    for table in data.get("tables") or []:
        for row in table.get("data") or []:
            label = str(row[0]).strip() if row else ""
            if label == TAIEX_LABEL:
                close = parse_number(row[1] if len(row) > 1 else None)
                break
        if close is not None:
            break
    if as_of is None or close is None:
        raise ValueError("TAIEX observation date/value not found in source")
    return {"observations": [{"date": as_of, "value": close}]}


def parse_twse_institutional_json(data):
    as_of = twse_response_date(data, None)
    foreign = trust = dealer = None
    for row in data.get("data") or []:
        label = str(row[0]).strip() if row else ""
        net = parse_number(row[-1] if row else None)
        if label in DEALER_LABELS:
            dealer = net
        elif "投信" in label:
            trust = net
        elif "外資及陸資" in label and not label.startswith("外資自營商"):
            foreign = net
    if as_of is None or (foreign is None and trust is None and dealer is None):
        raise ValueError("institutional observation date/value not found in source")
    return {
        "observations": [{
            "date": as_of,
            "value": foreign,
            "foreign": foreign,
            "trust": trust,
            "dealer": dealer,
        }]
    }


def scale_institutional_value(value):
    if value is None:
        return None
    if abs(value) >= 1000000:
        return round(value / TWD_TO_HUNDRED_MILLION, 6)
    return value


def live_twse_taiex(request_date):
    ymd = twse_date(request_date)
    if not ymd:
        raise ValueError("request date missing")
    url = (
        "https://www.twse.com.tw/rwd/zh/afterTrading/MI_INDEX"
        "?date=" + ymd + "&type=IND&response=json"
    )
    data = json.loads(http_get(url, insecure=True))
    parsed = parse_twse_taiex_json(data)
    parsed["source"] = data
    return parsed


def live_twse_institutional(request_date):
    ymd = twse_date(request_date)
    if not ymd:
        raise ValueError("request date missing")
    url = (
        "https://www.twse.com.tw/rwd/zh/fund/BFI82U"
        "?response=json&dayDate=" + ymd + "&type=day"
    )
    data = json.loads(http_get(url, insecure=True))
    parsed = parse_twse_institutional_json(data)
    parsed["source"] = data
    return parsed


def fetch_live(source_id, expected_as_of):
    catalog = SOURCE_CATALOG[source_id]
    if catalog["source"] == "fred":
        return live_fred(catalog["fredId"])
    if catalog["source"] == "us-index":
        return fetch_us_index(catalog)
    if catalog["source"] == "bls":
        return live_bls(catalog["seriesId"])
    if catalog["source"] == "eia":
        return live_eia(catalog["seriesId"], catalog["route"], catalog["frequency"])
    if source_id == "twse-taiex":
        return fetch_twse_session(live_twse_taiex, expected_as_of)
    if source_id == "twse-institutional":
        return fetch_twse_session(live_twse_institutional, expected_as_of)
    raise ValueError("unknown live source")


def raw_record(source_id, source, captured_at, status, payload=None, error=None, file_ref=None):
    record = {
        "sourceId": source_id,
        "capturedAt": captured_at,
        "source": source,
        "payload": payload,
        "fileRef": file_ref,
        "status": status,
    }
    if error:
        record["error"] = error
    return record


def normalized_record(
    instrument,
    source_id,
    unit,
    as_of_kind,
    source_status,
    value,
    as_of,
    expected_as_of,
    series,
    captured_at,
):
    status = classify_status(source_status, value, as_of, expected_as_of)
    prior_dod, change_dod, dod_status = change_vs(series, as_of, "dod")
    prior_wow, change_wow, wow_status = change_vs(series, as_of, "wow")
    if status in ("missing", "unavailable"):
        prior_dod = change_dod = prior_wow = change_wow = None
        dod_status = wow_status = "unavailable"
    return {
        "instrument": instrument,
        "value": value if status not in ("missing", "unavailable") else None,
        "unit": unit,
        "asOf": as_of if status not in ("missing", "unavailable") else None,
        "asOfKind": as_of_kind,
        "expectedAsOf": expected_as_of,
        "priorValue": prior_dod,
        "changeDoD": change_dod,
        "changeWoW": change_wow,
        "changeDoDStatus": dod_status,
        "changeWoWStatus": wow_status,
        "sourceId": source_id,
        "status": status,
        "capturedAt": captured_at,
    }


def write_history(root, instrument, record):
    if record.get("value") is None or not record.get("asOf"):
        return
    path = os.path.join(root, "data", "evidence", "history", instrument, record["asOf"] + ".json")
    write_json(path, {
        "instrument": instrument,
        "value": record["value"],
        "unit": record.get("unit"),
        "asOf": record["asOf"],
        "asOfKind": record.get("asOfKind"),
        "sourceId": record["sourceId"],
    }, root=root)


def is_valued_record(record):
    if not isinstance(record, dict):
        return False
    if record.get("status") in ("missing", "unavailable"):
        return False
    return record.get("value") is not None and iso_date(record.get("asOf")) is not None


def load_theses(root):
    folder = os.path.join(root, "data", "theses")
    out = []
    if not os.path.isdir(folder):
        return out
    for name in os.listdir(folder):
        if not name.endswith(".json"):
            continue
        try:
            item = load_json(os.path.join(folder, name))
        except Exception:
            continue
        if isinstance(item, dict) and item.get("thesisId"):
            out.append(item)
    return out


def load_research_cards(root):
    folder = os.path.join(root, "research")
    out = []
    if not os.path.isdir(folder):
        return out
    for name in os.listdir(folder):
        path = os.path.join(folder, name, "card.json")
        if not os.path.isfile(path):
            continue
        try:
            card = load_json(path)
        except Exception:
            continue
        if not isinstance(card, dict):
            continue
        if not card.get("id"):
            card = dict(card)
            card["id"] = name
        out.append(card)
    return out


def load_research_notes(root, research_id):
    path = os.path.join(root, "research", research_id, "notes.json")
    if not os.path.isfile(path):
        return []
    try:
        data = load_json(path)
    except Exception:
        return []
    if isinstance(data, dict) and isinstance(data.get("notes"), list):
        return data["notes"]
    if isinstance(data, list):
        return data
    return []


def thesis_instrument_relation(thesis, instrument):
    supporting = thesis.get("supportingEvidence") if isinstance(thesis.get("supportingEvidence"), list) else []
    contradicting = thesis.get("contradictingEvidence") if isinstance(thesis.get("contradictingEvidence"), list) else []

    def has_instrument(refs):
        for ref in refs:
            if isinstance(ref, dict) and str(ref.get("instrument") or "").strip() == instrument:
                return True
        return False

    in_contradicting = has_instrument(contradicting)
    in_supporting = has_instrument(supporting)
    if in_contradicting:
        return "contradicting"
    if in_supporting:
        return "supporting"
    return None


def thesis_research_ids(thesis, cards):
    ids = []
    linked = thesis.get("linkedResearch") if isinstance(thesis.get("linkedResearch"), list) else []
    for ref in linked:
        if not isinstance(ref, dict):
            continue
        research_id = str(ref.get("researchId") or "").strip()
        if research_id and research_id not in ids:
            ids.append(research_id)
    thesis_id = str(thesis.get("thesisId") or "").strip()
    if thesis_id:
        for card in cards:
            research_id = str(card.get("id") or "").strip()
            if research_id and str(card.get("thesisId") or "").strip() == thesis_id and research_id not in ids:
                ids.append(research_id)
    return ids


def research_anchor_as_of(card, notes):
    conclusion = card.get("researchConclusion") if isinstance(card.get("researchConclusion"), dict) else None
    if conclusion:
        as_of = iso_date(conclusion.get("asOf"))
        if as_of:
            return as_of, "researchConclusion"
    dates = []
    for entry in notes:
        if isinstance(entry, dict):
            as_of = iso_date(entry.get("date"))
            if as_of:
                dates.append(as_of)
    if dates:
        return max(dates), "notes"
    return None, None


def recheck_research(root, normalized_rows, run_id):
    valued = [row for row in normalized_rows if is_valued_record(row)]
    theses = load_theses(root)
    cards = load_research_cards(root)
    card_by_id = {}
    for card in cards:
        research_id = str(card.get("id") or "").strip()
        if research_id:
            card_by_id[research_id] = card
    items = []
    seen = set()
    for row in valued:
        instrument = str(row.get("instrument") or "").strip()
        evidence_as_of = iso_date(row.get("asOf"))
        if not instrument or not evidence_as_of:
            continue
        for thesis in theses:
            relation = thesis_instrument_relation(thesis, instrument)
            if not relation:
                continue
            for research_id in thesis_research_ids(thesis, cards):
                key = (research_id, instrument, evidence_as_of)
                if key in seen:
                    continue
                card = card_by_id.get(research_id)
                if not card:
                    continue
                notes = load_research_notes(root, research_id)
                anchor_as_of, anchor_kind = research_anchor_as_of(card, notes)
                if not anchor_as_of or evidence_as_of <= anchor_as_of:
                    continue
                seen.add(key)
                conclusion = card.get("researchConclusion") if isinstance(card.get("researchConclusion"), dict) else None
                items.append({
                    "researchId": research_id,
                    "thesisId": thesis.get("thesisId"),
                    "instrument": instrument,
                    "evidenceAsOf": evidence_as_of,
                    "evidenceStatus": row.get("status"),
                    "relation": relation,
                    "anchorKind": anchor_kind,
                    "anchorAsOf": anchor_as_of,
                    "conclusionAsOf": iso_date(conclusion.get("asOf")) if conclusion else None,
                    "conclusionImpact": "UNKNOWN",
                    "needsReview": True,
                })
    items.sort(key=lambda item: (item["researchId"], item["instrument"]))
    return {
        "runId": run_id,
        "writesBrief": False,
        "writesResearch": False,
        "items": items,
    }


def instruments_for_source(source_id, raw_item, catalog):
    if source_id == "twse-institutional" or raw_item.get("instrument") == "TW_INSTITUTIONAL":
        return catalog.get("instruments") or [
            ("TW_FOREIGN_NET", "foreign"),
            ("TW_TRUST_NET", "trust"),
            ("TW_DEALER_NET", "dealer"),
        ]
    instrument = raw_item.get("instrument") or catalog.get("instrument")
    return [(instrument, "value")]


def process_source(root, raw_item, expected_as_of, captured_at, run_dir):
    source_id = raw_item.get("sourceId")
    if not source_id or source_id not in SOURCE_CATALOG:
        fail("unknown or missing sourceId: " + str(source_id))
    catalog = SOURCE_CATALOG[source_id]
    source_status = raw_item.get("status") or "ok"
    payload = raw_item.get("payload")
    if payload is None and raw_item.get("observations") is not None:
        payload = {"observations": raw_item.get("observations")}
    payload = trim_observation_payload(payload)
    raw = raw_record(
        source_id,
        catalog["source"],
        captured_at,
        "unavailable" if source_status == "unavailable" else ("missing" if source_status == "missing" else "ok"),
        payload=payload,
        error=raw_item.get("error"),
        file_ref=raw_item.get("fileRef"),
    )
    write_json(os.path.join(run_dir, "raw", source_id + ".json"), raw, root=root)

    produced = []
    observations = observations_from_payload(payload) if raw["status"] == "ok" else []
    for instrument, field in instruments_for_source(source_id, raw_item, catalog):
        field_rows = []
        for row in observations:
            value = parse_number(row.get(field) if field != "value" else row.get("value"))
            if instrument in INSTITUTIONAL_INSTRUMENTS:
                value = scale_institutional_value(value)
            if row.get("date") and value is not None:
                field_rows.append({"date": row["date"], "value": value})
        history = load_history(root, instrument)
        series = merge_series(field_rows, history, field="value")
        chosen = pick_observation(series, expected_as_of) if raw["status"] == "ok" else None
        as_of = chosen["date"] if chosen else None
        value = chosen["value"] if chosen else None
        if raw["status"] == "ok" and not field_rows:
            source_state = "missing"
        else:
            source_state = raw["status"]
        record = normalized_record(
            instrument,
            source_id,
            raw_item.get("unit") or catalog.get("unit"),
            raw_item.get("asOfKind") or catalog.get("asOfKind") or "close",
            source_state,
            value,
            as_of,
            expected_as_of,
            series,
            captured_at,
        )
        if catalog.get("source") == "bls":
            record["seriesId"] = catalog.get("seriesId")
            record["attribution"] = BLS_ATTRIBUTION
            record["retrievedAt"] = captured_at
            # Adjacent prior observation delta via existing changeDoD — not a BLS-published MoM %.
            if record.get("changeDoD") is not None and record.get("changeDoDStatus") == "ok":
                record["calculationMethod"] = "adjacent-observation-delta"
            meta = next((row for row in observations if row.get("date") == as_of), None) or {}
            if "preliminary" in meta:
                record["preliminary"] = bool(meta.get("preliminary"))
            if meta.get("observationPeriod"):
                record["observationPeriod"] = meta.get("observationPeriod")
            # Explicit: timeseries API has no release datetime.
            record["releaseDate"] = meta.get("releaseDate")
            bls_calc = meta.get("blsCalculations")
            if isinstance(bls_calc, dict):
                record["blsCalculations"] = bls_calc
                record["calculationSource"] = bls_calc.get("source") or "bls-api-v2"
        if catalog.get("source") == "eia":
            record["seriesId"] = catalog.get("seriesId")
            record["attribution"] = EIA_ATTRIBUTION
            record["retrievedAt"] = captured_at
            meta = next((row for row in observations if row.get("date") == as_of), None) or {}
            if meta.get("observationPeriod"):
                record["observationPeriod"] = meta.get("observationPeriod")
            if meta.get("frequency"):
                record["frequency"] = meta.get("frequency")
            # Explicit: EIA timeseries response has no release datetime → UNKNOWN.
            record["releaseDate"] = None
        write_json(os.path.join(run_dir, "normalized", instrument + ".json"), record, root=root)
        write_history(root, instrument, record)
        produced.append(record)
    return raw, produced


def collect_from_fixture(root, fixture_path, expected_as_of, captured_at):
    fixture = load_json(fixture_path)
    if fixture.get("expectedAsOf") and not expected_as_of:
        expected_as_of = iso_date(fixture.get("expectedAsOf"))
    if fixture.get("capturedAt") and not captured_at:
        captured_at = fixture.get("capturedAt")
    items = fixture.get("raw") or fixture.get("sources") or []
    if isinstance(items, dict):
        items = [items]
    if not isinstance(items, list) or not items:
        fail("fixture must contain raw[] sources")
    return items, expected_as_of, captured_at


def collect_live(expected_as_of):
    items = []
    bls_ids = [
        source_id for source_id, catalog in SOURCE_CATALOG.items()
        if catalog.get("source") == "bls"
    ]
    bls_payloads = {}
    bls_error = None
    if bls_ids:
        try:
            if not bls_registration_key():
                raise ValueError("BLS_REGISTRATION_KEY not set")
            series_ids = [SOURCE_CATALOG[sid]["seriesId"] for sid in bls_ids]
            bundled = live_bls_multi(series_ids)
            for source_id in bls_ids:
                series_id = SOURCE_CATALOG[source_id]["seriesId"]
                bls_payloads[source_id] = bundled.get(series_id) or {
                    "observations": [],
                    "seriesId": series_id,
                    "attribution": BLS_ATTRIBUTION,
                    "source": "bls",
                }
        except Exception as exc:
            bls_error = str(exc)

    for source_id in SOURCE_CATALOG:
        catalog = SOURCE_CATALOG[source_id]
        if catalog.get("source") == "bls":
            if bls_error:
                items.append({
                    "sourceId": source_id,
                    "status": "unavailable",
                    "payload": None,
                    "error": bls_error,
                })
                continue
            payload = bls_payloads.get(source_id)
            obs = observations_from_payload(payload)
            items.append({
                "sourceId": source_id,
                "status": "ok" if obs else "missing",
                "payload": payload,
                "error": None if obs else "source returned no usable observations",
            })
            continue
        try:
            payload = fetch_live(source_id, expected_as_of)
            obs = observations_from_payload(payload)
            items.append({
                "sourceId": source_id,
                "status": "ok" if obs else "missing",
                "payload": payload,
                "error": None if obs else "source returned no usable observations",
            })
        except Exception as exc:
            items.append({
                "sourceId": source_id,
                "status": "unavailable",
                "payload": None,
                "error": str(exc),
            })
    return items


def main(argv):
    args = {
        "root": None,
        "input": None,
        "expected": None,
        "captured": None,
        "live": False,
    }
    index = 1
    while index < len(argv):
        key = argv[index]
        if key == "--root":
            args["root"] = argv[index + 1]
            index += 2
        elif key == "--input":
            args["input"] = argv[index + 1]
            index += 2
        elif key == "--expected-asof":
            args["expected"] = argv[index + 1]
            index += 2
        elif key == "--captured-at":
            args["captured"] = argv[index + 1]
            index += 2
        elif key == "--live":
            args["live"] = True
            index += 1
        else:
            fail("unknown argument: " + key)

    root = os.path.abspath(args["root"] or ".")
    if args["live"] and args["input"]:
        fail("use either --input or --live, not both")
    if not args["live"] and not args["input"]:
        fail("InputPath fixture is required unless --live is set")
    if args["input"]:
        refuse_brief_input(os.path.abspath(args["input"]))

    captured_raw = args["captured"]
    expected_as_of = iso_date(args["expected"]) if args["expected"] else None

    if args["input"]:
        items, expected_as_of, captured_raw = collect_from_fixture(
            root, os.path.abspath(args["input"]), expected_as_of, captured_raw
        )
        captured_dt = parse_captured_at(captured_raw)
        if captured_dt is None:
            fail("capturedAt is required so market asOf is never taken from the clock")
        if expected_as_of is None:
            expected_as_of = default_expected_as_of(captured_dt)
    else:
        captured_dt = parse_captured_at(captured_raw)
        if captured_dt is None:
            captured_dt = datetime.datetime.now(datetime.timezone.utc)
            captured_raw = captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
        if expected_as_of is None:
            expected_as_of = default_expected_as_of(captured_dt)
        items = collect_live(expected_as_of)

    run_id = run_id_from_captured(captured_dt)
    run_dir = os.path.join(root, "data", "evidence", "runs", run_id)
    os.makedirs(os.path.join(run_dir, "raw"), exist_ok=True)
    os.makedirs(os.path.join(run_dir, "normalized"), exist_ok=True)

    raw_rows = []
    normalized_rows = []
    for item in items:
        raw, produced = process_source(root, item, expected_as_of, captured_raw, run_dir)
        raw_rows.append(raw)
        normalized_rows.extend(produced)

    summary = {
        "runId": run_id,
        "capturedAt": captured_raw,
        "expectedAsOf": expected_as_of,
        "writesBrief": False,
        "rawCount": len(raw_rows),
        "normalizedCount": len(normalized_rows),
        "statuses": {row["instrument"]: row["status"] for row in normalized_rows},
    }
    write_json(os.path.join(run_dir, "run.json"), summary, root=root)
    recheck = recheck_research(root, normalized_rows, run_id)
    write_json(os.path.join(run_dir, "recheck.json"), recheck, root=root)
    print("EVIDENCE_OK")
    print("runId=" + run_id)
    print("expectedAsOf=" + expected_as_of)
    print("runDir=" + run_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
