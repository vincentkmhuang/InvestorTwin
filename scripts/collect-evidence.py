# Investor Twin 014 — Evidence collector (Live + fixture).
# Writes Raw + Normalized evidence only. Never writes Morning Brief files.
import csv
import datetime
import io
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request

DATE_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")
MAX_OBSERVATIONS = 30
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
    "us-index-nasdaq": {
        "source": "us-index",
        "instrument": "Nasdaq",
        "unit": "index",
        "asOfKind": "close",
        "stooq": "ndq.us",
    },
    "us-index-spx": {
        "source": "us-index",
        "instrument": "SPX",
        "unit": "index",
        "asOfKind": "close",
        "stooq": "^spx",
    },
    "us-index-dji": {
        "source": "us-index",
        "instrument": "DJI",
        "unit": "index",
        "asOfKind": "close",
        "stooq": "^dji",
    },
    "us-index-sox": {
        "source": "us-index",
        "instrument": "SOX",
        "unit": "index",
        "asOfKind": "close",
        "stooq": "^sox",
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
        if as_of is None:
            continue
        if value is None and not any(item is not None for item in extras.values()):
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
        return live_stooq(catalog["stooq"])
    if source_id == "twse-taiex":
        return live_twse_taiex(expected_as_of)
    if source_id == "twse-institutional":
        return live_twse_institutional(expected_as_of)
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
    for source_id in SOURCE_CATALOG:
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
            expected_as_of = last_weekday(captured_dt.date()).isoformat()
    else:
        captured_dt = parse_captured_at(captured_raw)
        if captured_dt is None:
            captured_dt = datetime.datetime.now(datetime.timezone.utc)
            captured_raw = captured_dt.strftime("%Y-%m-%dT%H:%M:%SZ")
        if expected_as_of is None:
            expected_as_of = last_weekday(captured_dt.date()).isoformat()
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
    print("EVIDENCE_OK")
    print("runId=" + run_id)
    print("expectedAsOf=" + expected_as_of)
    print("runDir=" + run_dir)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
