#!/usr/bin/env python3
# News Collect Foundation — MOPS 重大訊息 OpenAPI adapter (Collect only).
# Pulls official daily material-information open data for:
#   listed: GET https://openapi.twse.com.tw/v1/opendata/t187ap04_L
#   otc:    GET http://www.tpex.org.tw/openapi/v1/mopsfin_t187ap04_O
# → News Object v1 → data/news/runs/<runId>/{raw,normalized,run.json}
# Does NOT call evaluate / link / integrate / handoff / Meaning Gate / Brief.
#
# URL POLICY (locked):
#   API responses have no reliable official single-item permalink.
#   Adapter builds a deterministic identity/dedup URL for seen.json only.
#   That URL is NOT an official MOPS detail page and is NOT guaranteed to open.
from __future__ import annotations

import hashlib
import html
import importlib.util
import json
import os
import re
import ssl
import sys
import urllib.request
from datetime import datetime, timezone

SOURCE_ID = "mops-material-openapi"
SOURCE_LABEL = "MOPS 重大訊息 OpenAPI"
DEFAULT_FEED_URL = "https://openapi.twse.com.tw/v1/opendata/t187ap04_L"
DEFAULT_LISTED_URL = "https://openapi.twse.com.tw/v1/opendata/t187ap04_L"
DEFAULT_OTC_URL = "http://www.tpex.org.tw/openapi/v1/mopsfin_t187ap04_O"
USER_AGENT = "InvestorTwin-NewsCollect/017 (personal; non-commercial)"

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_STORE_ROOT = os.path.join(REPO_ROOT, "data", "news")

# Identity/dedup URL prefix — NOT a browsable MOPS announcement permalink.
IDENTITY_URL_PREFIX = "https://mops.twse.com.tw/material"


def utc_now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def make_run_id(when=None):
    dt = when or datetime.now(timezone.utc)
    return "run-" + dt.strftime("%Y%m%dT%H%M%SZ")


def load_contract_module():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "news-object-contract.py")
    spec = importlib.util.spec_from_file_location("news_object_contract", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_json(path, default=None):
    if not os.path.isfile(path):
        return default
    with open(path, encoding="utf-8-sig") as f:
        return json.load(f)


def write_json(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")


def ensure_runtime_state(store_root):
    seen_path = os.path.join(store_root, "seen.json")
    hist_path = os.path.join(store_root, "history", "by-url", "index.json")
    if not os.path.isfile(seen_path):
        example = os.path.join(store_root, "seen.example.json")
        seed = read_json(example, {"schemaVersion": "1.0", "byUrl": {}, "byGuid": {}})
        write_json(seen_path, seed)
    if not os.path.isfile(hist_path):
        example = os.path.join(store_root, "history", "by-url", "index.example.json")
        seed = read_json(example, {"schemaVersion": "1.0", "entries": {}})
        write_json(hist_path, seed)
    return seen_path, hist_path


def clean_text(text):
    value = html.unescape(str(text or ""))
    value = value.replace("\r\n", "\n").replace("\r", "\n")
    value = re.sub(r"[ \t]+\n", "\n", value)
    value = re.sub(r"\n{3,}", "\n\n", value)
    value = re.sub(r"[ \t]{2,}", " ", value).strip()
    return value


def row_get(row, *names):
    """Lookup with exact names first, then trimmed-key fallback (TWSE '主旨 ' quirk)."""
    if not isinstance(row, dict):
        return ""
    for name in names:
        if name in row and row.get(name) is not None:
            return row.get(name)
    trimmed = {str(k).strip(): v for k, v in row.items()}
    for name in names:
        key = str(name).strip()
        if key in trimmed and trimmed.get(key) is not None:
            return trimmed.get(key)
    return ""


def parse_published(spoke_date, spoke_time):
    """發言日期(ROC) + 發言時間 → publishedTime ISO.

    If date OR time missing/unparseable → UNKNOWN. Do not invent clock time.
    """
    date_raw = str(spoke_date or "").strip()
    time_raw = str(spoke_time or "").strip()
    if not date_raw or not time_raw:
        return "UNKNOWN"
    date_digits = "".join(ch for ch in date_raw if ch.isdigit())
    time_digits = "".join(ch for ch in time_raw if ch.isdigit())
    if len(date_digits) != 7:
        return "UNKNOWN"
    if not time_digits:
        return "UNKNOWN"
    if len(time_digits) > 6:
        return "UNKNOWN"
    time_digits = time_digits.zfill(6)
    try:
        roc_y = int(date_digits[0:3])
        month = int(date_digits[3:5])
        day = int(date_digits[5:7])
        hour = int(time_digits[0:2])
        minute = int(time_digits[2:4])
        second = int(time_digits[4:6])
        ce_y = roc_y + 1911
        dt = datetime(ce_y, month, day, hour, minute, second, tzinfo=timezone.utc)
        return dt.replace(microsecond=0).isoformat().replace("+00:00", "Z")
    except (TypeError, ValueError, OverflowError):
        return "UNKNOWN"


def build_identity_url(market, code, spoke_date, spoke_time, title):
    """Deterministic identity/dedup URL — NOT an official MOPS detail permalink.

    Format:
      https://mops.twse.com.tw/material/{market}/{code}/{spokeDate}/{spokeTime}/{sha1(title)[:16]}
    """
    market_key = "listed" if market == "listed" else "otc"
    code_key = str(code or "").strip() or "UNKNOWN"
    date_key = "".join(ch for ch in str(spoke_date or "") if ch.isdigit()) or "UNKNOWN"
    time_key = "".join(ch for ch in str(spoke_time or "") if ch.isdigit()) or "UNKNOWN"
    if time_key != "UNKNOWN":
        time_key = time_key.zfill(6)
    title_digest = hashlib.sha1(clean_text(title).encode("utf-8")).hexdigest()[:16]
    return (
        f"{IDENTITY_URL_PREFIX}/{market_key}/{code_key}/{date_key}/{time_key}/{title_digest}"
    )


def market_label(market):
    return "上市" if market == "listed" else "上櫃"


def normalize_row(row, market):
    """Map listed/otc row variants into a common internal shape."""
    title = clean_text(row_get(row, "主旨", "主旨 ", "Subject", "title"))
    code = clean_text(row_get(row, "公司代號", "SecuritiesCompanyCode", "code"))
    name = clean_text(row_get(row, "公司名稱", "CompanyName", "name"))
    # Never fall back to Date/出表日期 — that is report date, not spoke datetime.
    spoke_date = clean_text(row_get(row, "發言日期"))
    spoke_time = clean_text(row_get(row, "發言時間"))
    explanation = clean_text(row_get(row, "說明", "content", "summary"))
    return {
        "market": market,
        "title": title,
        "code": code,
        "name": name,
        "spokeDate": spoke_date,
        "spokeTime": spoke_time,
        "explanation": explanation,
    }


def parse_payload_items(payload, default_market=None):
    """Accept fixture shapes: {listed:[], otc:[]} or bare list with market."""
    items = []
    if isinstance(payload, dict):
        if isinstance(payload.get("listed"), list) or isinstance(payload.get("otc"), list):
            for row in payload.get("listed") or []:
                if isinstance(row, dict):
                    items.append(normalize_row(row, "listed"))
            for row in payload.get("otc") or []:
                if isinstance(row, dict):
                    items.append(normalize_row(row, "otc"))
            return items
        # Single wrapped list
        for key in ("data", "items", "result"):
            if isinstance(payload.get(key), list):
                payload = payload[key]
                break
        else:
            raise ValueError("MOPS payload object missing listed/otc/data list")
    if not isinstance(payload, list):
        raise ValueError("MOPS payload must be a list or {listed, otc} object")
    market = default_market or "listed"
    for row in payload:
        if isinstance(row, dict):
            items.append(normalize_row(row, market))
    return items


def http_get_json(url, timeout=40):
    request = urllib.request.Request(
        url,
        headers={"User-Agent": USER_AGENT, "Accept": "application/json"},
    )
    last_exc = None
    for verify in (True, False):
        try:
            ctx = ssl.create_default_context() if verify else ssl._create_unverified_context()
            with urllib.request.urlopen(request, timeout=timeout, context=ctx) as response:
                raw = response.read(8_000_000)
                charset = "utf-8"
                ctype = str(response.headers.get("Content-Type") or "")
                if "charset=" in ctype.lower():
                    charset = ctype.split("charset=", 1)[1].split(";")[0].strip() or "utf-8"
            text = raw.decode(charset, errors="replace")
            return text, json.loads(text)
        except Exception as exc:
            last_exc = exc
            if verify:
                continue
            raise
    raise last_exc  # pragma: no cover


def news_filename(url):
    digest = hashlib.sha1(url.encode("utf-8")).hexdigest()[:16]
    return digest + ".json"


def item_to_news(item, collected_at, run_id):
    title = item.get("title") or ""
    code = item.get("code") or ""
    name = item.get("name") or ""
    market = item.get("market") or "listed"
    spoke_date = item.get("spokeDate") or ""
    spoke_time = item.get("spokeTime") or ""
    explanation = item.get("explanation") or ""
    summary = explanation if explanation else title
    published = parse_published(spoke_date, spoke_time)
    # Identity/dedup URL only — not an official MOPS detail permalink.
    url = build_identity_url(market, code, spoke_date, spoke_time, title)
    subject = f"[{market_label(market)}] [{code}] [{name}]"
    news = {
        "source": SOURCE_LABEL,
        "title": title,
        "publishedTime": published,
        "url": url,
        "summary": summary,
        "subject": subject,
        "eventRef": None,
        "id": url,
        "sourceId": SOURCE_ID,
        "collectedAt": collected_at,
        "collectRunId": run_id,
    }
    return news


def collect(
    feed_url=None,
    fixture_path=None,
    store_root=None,
    listed_url=None,
    otc_url=None,
):
    store_root = store_root or DEFAULT_STORE_ROOT
    listed_url = (listed_url or feed_url or DEFAULT_LISTED_URL).strip()
    otc_url = (otc_url or DEFAULT_OTC_URL).strip()
    started_at = utc_now_iso()
    run_id = make_run_id()
    run_dir = os.path.join(store_root, "runs", run_id)
    raw_dir = os.path.join(run_dir, "raw")
    norm_dir = os.path.join(run_dir, "normalized")
    os.makedirs(raw_dir, exist_ok=True)
    os.makedirs(norm_dir, exist_ok=True)

    errors = []
    fetched_count = 0
    normalized_count = 0
    skipped_seen_count = 0
    status = "ok"
    source_mode = "live"
    items = []
    raw_files = []
    live_counts = {"listed": 0, "otc": 0}

    try:
        if fixture_path:
            source_mode = "fixture"
            with open(fixture_path, encoding="utf-8-sig") as f:
                raw_text = f.read()
            if not raw_text.strip():
                raise ValueError("fixture JSON is empty")
            payload = json.loads(raw_text)
            raw_name = "mops-material-openapi.json"
            raw_path = os.path.join(raw_dir, raw_name)
            with open(raw_path, "w", encoding="utf-8", newline="\n") as f:
                f.write(raw_text if raw_text.endswith("\n") else raw_text + "\n")
            raw_files.append(os.path.join("raw", raw_name).replace("\\", "/"))
            items = parse_payload_items(payload)
        else:
            # Live: fetch both markets. Do not filter OTC at Collect.
            listed_text, listed_payload = http_get_json(listed_url)
            otc_text, otc_payload = http_get_json(otc_url)
            listed_path = os.path.join(raw_dir, "mops-material-listed.json")
            otc_path = os.path.join(raw_dir, "mops-material-otc.json")
            with open(listed_path, "w", encoding="utf-8", newline="\n") as f:
                f.write(listed_text if listed_text.endswith("\n") else listed_text + "\n")
            with open(otc_path, "w", encoding="utf-8", newline="\n") as f:
                f.write(otc_text if otc_text.endswith("\n") else otc_text + "\n")
            raw_files.extend([
                "raw/mops-material-listed.json",
                "raw/mops-material-otc.json",
            ])
            listed_items = parse_payload_items(listed_payload, default_market="listed")
            otc_items = parse_payload_items(otc_payload, default_market="otc")
            live_counts["listed"] = len(listed_items)
            live_counts["otc"] = len(otc_items)
            items = listed_items + otc_items
    except Exception as exc:
        status = "failed"
        errors.append({
            "stage": "fetch",
            "message": str(exc),
            "listedUrl": None if fixture_path else listed_url,
            "otcUrl": None if fixture_path else otc_url,
            "fixture": fixture_path,
        })
        finished_at = utc_now_iso()
        run = {
            "schemaVersion": "1.0",
            "kind": "news-collect-run",
            "runId": run_id,
            "sourceId": SOURCE_ID,
            "sourceLabel": SOURCE_LABEL,
            "feedUrl": None if fixture_path else listed_url,
            "otcUrl": None if fixture_path else otc_url,
            "sourceMode": source_mode,
            "startedAt": started_at,
            "finishedAt": finished_at,
            "collectedAt": started_at,
            "status": status,
            "counts": {
                "fetched": 0,
                "normalized": 0,
                "skippedSeen": 0,
                "errors": len(errors),
                "listed": 0,
                "otc": 0,
            },
            "fetchedCount": 0,
            "normalizedCount": 0,
            "skippedSeenCount": 0,
            "errorCount": len(errors),
            "errors": errors,
            "rawFiles": [],
            "urlCompositionRule": (
                "deterministic identity/dedup URL only; "
                "NOT an official MOPS detail permalink; not guaranteed to open"
            ),
            "writesHandoff": False,
            "writesBrief": False,
        }
        write_json(os.path.join(run_dir, "run.json"), run)
        return run

    seen_path, hist_path = ensure_runtime_state(store_root)
    seen = read_json(seen_path, {"schemaVersion": "1.0", "byUrl": {}, "byGuid": {}})
    history = read_json(hist_path, {"schemaVersion": "1.0", "entries": {}})
    if not isinstance(seen.get("byUrl"), dict):
        seen["byUrl"] = {}
    if not isinstance(seen.get("byGuid"), dict):
        seen["byGuid"] = {}
    if not isinstance(history.get("entries"), dict):
        history["entries"] = {}

    contract = load_contract_module()
    fetched_count = len(items)
    if source_mode == "fixture":
        live_counts["listed"] = sum(1 for i in items if i.get("market") == "listed")
        live_counts["otc"] = sum(1 for i in items if i.get("market") == "otc")
    collected_at = started_at

    for item in items:
        try:
            news = item_to_news(item, collected_at, run_id)
            url = news.get("url") or ""
            if not news.get("title"):
                errors.append({
                    "stage": "normalize",
                    "message": "missing title/主旨",
                    "market": item.get("market"),
                    "code": item.get("code"),
                })
                continue
            if not url:
                errors.append({"stage": "normalize", "message": "missing identity url"})
                continue
            if url in seen["byUrl"]:
                skipped_seen_count += 1
                continue
            normalized = contract.normalize_news_object_v1(news, require_collect_url=True)
            for bad in contract.FORBIDDEN_NEWS_FIELDS:
                normalized.pop(bad, None)
            out_path = os.path.join(norm_dir, news_filename(url))
            write_json(out_path, normalized)
            normalized_count += 1
            seen["byUrl"][url] = {
                "newsId": normalized.get("id") or url,
                "guid": None,
                "firstSeenAt": collected_at,
                "lastSeenAt": collected_at,
                "collectRunId": run_id,
                "market": item.get("market"),
            }
            hist_entry = history["entries"].get(url) or {
                "newsId": normalized.get("id") or url,
                "firstSeenAt": collected_at,
                "seenCount": 0,
            }
            hist_entry["lastSeenAt"] = collected_at
            hist_entry["lastCollectRunId"] = run_id
            hist_entry["seenCount"] = int(hist_entry.get("seenCount") or 0) + 1
            history["entries"][url] = hist_entry
        except SystemExit as exc:
            errors.append({"stage": "normalize", "message": "contract validation failed", "detail": str(exc)})
        except Exception as exc:
            errors.append({
                "stage": "normalize",
                "message": str(exc),
                "title": item.get("title"),
                "market": item.get("market"),
            })

    if status != "failed":
        if errors and normalized_count == 0 and fetched_count > 0:
            status = "failed"
        elif errors:
            status = "partial"
        else:
            status = "ok"

    if normalized_count > 0 or skipped_seen_count > 0:
        write_json(seen_path, seen)
        write_json(hist_path, history)

    finished_at = utc_now_iso()
    run = {
        "schemaVersion": "1.0",
        "kind": "news-collect-run",
        "runId": run_id,
        "sourceId": SOURCE_ID,
        "sourceLabel": SOURCE_LABEL,
        "feedUrl": None if fixture_path else listed_url,
        "otcUrl": None if fixture_path else otc_url,
        "sourceMode": source_mode,
        "startedAt": started_at,
        "finishedAt": finished_at,
        "collectedAt": collected_at,
        "status": status,
        "counts": {
            "fetched": fetched_count,
            "normalized": normalized_count,
            "skippedSeen": skipped_seen_count,
            "errors": len(errors),
            "listed": live_counts["listed"],
            "otc": live_counts["otc"],
        },
        "fetchedCount": fetched_count,
        "normalizedCount": normalized_count,
        "skippedSeenCount": skipped_seen_count,
        "errorCount": len(errors),
        "errors": errors,
        "rawFiles": raw_files,
        "urlCompositionRule": (
            "deterministic identity/dedup URL only "
            f"({IDENTITY_URL_PREFIX}/{{market}}/{{code}}/{{spokeDate}}/{{spokeTime}}/{{sha1(title)[:16]}}); "
            "NOT an official MOPS detail permalink; not guaranteed to open"
        ),
        "dateTimeMapping": (
            "發言日期 ROC YYYYmmdd + 發言時間 HHmmss → publishedTime CE ISO; "
            "missing either → UNKNOWN"
        ),
        "writesHandoff": False,
        "writesBrief": False,
    }
    write_json(os.path.join(run_dir, "run.json"), run)
    return run


def main(argv):
    feed_url = DEFAULT_LISTED_URL
    otc_url = DEFAULT_OTC_URL
    fixture_path = None
    store_root = DEFAULT_STORE_ROOT
    i = 1
    while i < len(argv):
        if argv[i] == "--feed-url" and i + 1 < len(argv):
            feed_url = argv[i + 1]
            i += 2
            continue
        if argv[i] == "--otc-url" and i + 1 < len(argv):
            otc_url = argv[i + 1]
            i += 2
            continue
        if argv[i] == "--fixture" and i + 1 < len(argv):
            fixture_path = os.path.abspath(argv[i + 1])
            i += 2
            continue
        if argv[i] == "--store-root" and i + 1 < len(argv):
            store_root = os.path.abspath(argv[i + 1])
            i += 2
            continue
        sys.stderr.write("MOPS_MATERIAL_ADAPTER_FAIL\nunknown argument: " + argv[i] + "\n")
        return 2

    if fixture_path and not os.path.isfile(fixture_path):
        sys.stderr.write("MOPS_MATERIAL_ADAPTER_FAIL\nfixture not found: " + fixture_path + "\n")
        return 2

    run = collect(
        feed_url=feed_url,
        fixture_path=fixture_path,
        store_root=store_root,
        listed_url=feed_url,
        otc_url=otc_url,
    )
    sys.stdout.write(json.dumps(run, ensure_ascii=False, indent=2) + "\n")
    if run.get("status") == "failed":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
