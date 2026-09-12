#!/usr/bin/env python3
# News Collect Foundation — TWSE 證交所新聞 OpenAPI adapter (Collect only).
# GET openapi.twse.com.tw/v1/news/newsList → News Object v1 → data/news/runs/<runId>/
# Does NOT call evaluate / link / integrate / handoff / Meaning Gate / Brief.
#
# Observed live schema (2026-09): JSON array of
#   {"Title": str, "Url": str (absolute https), "Date": "YYYYmmdd" ROC calendar}
# No pagination parameters in OpenAPI; response is a single full list.
# No summary/body field — Collect uses title as summary fallback (contract needs summary|content).
# No subject/category field — subject remains null.
from __future__ import annotations

import hashlib
import html
import importlib.util
import json
import os
import ssl
import sys
import urllib.request
from datetime import datetime, timezone

SOURCE_ID = "twse-news-openapi"
SOURCE_LABEL = "TWSE 證交所新聞 OpenAPI"
DEFAULT_FEED_URL = "https://openapi.twse.com.tw/v1/news/newsList"
USER_AGENT = "InvestorTwin-NewsCollect/016 (personal; non-commercial)"

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_STORE_ROOT = os.path.join(REPO_ROOT, "data", "news")


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


def normalize_url(url):
    value = html.unescape(str(url or "")).strip()
    if not value:
        return ""
    return value.split("#", 1)[0].strip()


def clean_text(text):
    value = html.unescape(str(text or ""))
    value = " ".join(value.split()).strip()
    return value


def parse_roc_date(value):
    """Map TWSE Date (ROC YYYYmmdd, e.g. 1150911) → publishedTime ISO date at 00:00:00Z.

    Do not invent a more precise clock time. Empty → UNKNOWN.
    Non-7-digit shapes → keep raw string (do not guess CE/ROC).
    """
    raw = str(value or "").strip()
    if not raw:
        return "UNKNOWN"
    digits = "".join(ch for ch in raw if ch.isdigit())
    if len(digits) != 7:
        return raw
    try:
        roc_y = int(digits[0:3])
        month = int(digits[3:5])
        day = int(digits[5:7])
        ce_y = roc_y + 1911
        dt = datetime(ce_y, month, day, tzinfo=timezone.utc)
        return dt.replace(microsecond=0).isoformat().replace("+00:00", "Z")
    except (TypeError, ValueError, OverflowError):
        return raw


def http_get_json(url, timeout=40):
    """Fetch JSON. TWSE TLS may fail default verify on some hosts — fallback once."""
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "application/json",
        },
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


def parse_news_items(payload):
    """Normalize API/fixture payload into list of dicts with Title/Url/Date keys."""
    if isinstance(payload, dict):
        # Future-proof if API wraps list.
        for key in ("data", "items", "result", "news"):
            if isinstance(payload.get(key), list):
                payload = payload[key]
                break
        else:
            raise ValueError("TWSE news payload is an object without a list field")
    if not isinstance(payload, list):
        raise ValueError("TWSE news payload must be a JSON array")
    items = []
    for row in payload:
        if not isinstance(row, dict):
            continue
        # Accept documented PascalCase; tolerate lowercase aliases if ever emitted.
        title = row.get("Title") if "Title" in row else row.get("title")
        url = row.get("Url") if "Url" in row else row.get("url")
        date = row.get("Date") if "Date" in row else row.get("date")
        items.append({
            "Title": title,
            "Url": url,
            "Date": date,
        })
    return items


def news_filename(url):
    digest = hashlib.sha1(url.encode("utf-8")).hexdigest()[:16]
    return digest + ".json"


def item_to_news(item, collected_at, run_id):
    url = normalize_url(item.get("Url") or "")
    title = clean_text(item.get("Title") or "")
    # API has no summary/content — fallback to title so contract (summary|content) passes.
    summary = title
    published = parse_roc_date(item.get("Date"))
    news = {
        "source": SOURCE_LABEL,
        "title": title,
        "publishedTime": published,
        "url": url,
        "summary": summary,
        "subject": None,  # OpenAPI newsList has no subject/category field
        "eventRef": None,
        "id": url,
        "sourceId": SOURCE_ID,
        "collectedAt": collected_at,
        "collectRunId": run_id,
    }
    return news


def collect(feed_url=None, fixture_path=None, store_root=None):
    store_root = store_root or DEFAULT_STORE_ROOT
    feed_url = (feed_url or DEFAULT_FEED_URL).strip()
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
    raw_text = None
    payload = None
    source_mode = "live"

    try:
        if fixture_path:
            source_mode = "fixture"
            with open(fixture_path, encoding="utf-8-sig") as f:
                raw_text = f.read()
            if not raw_text.strip():
                raise ValueError("fixture JSON is empty")
            payload = json.loads(raw_text)
        else:
            raw_text, payload = http_get_json(feed_url)
    except Exception as exc:
        status = "failed"
        errors.append({
            "stage": "fetch",
            "message": str(exc),
            "feedUrl": None if fixture_path else feed_url,
            "fixture": fixture_path,
        })
        finished_at = utc_now_iso()
        run = {
            "schemaVersion": "1.0",
            "kind": "news-collect-run",
            "runId": run_id,
            "sourceId": SOURCE_ID,
            "sourceLabel": SOURCE_LABEL,
            "feedUrl": None if fixture_path else feed_url,
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
            },
            "fetchedCount": 0,
            "normalizedCount": 0,
            "skippedSeenCount": 0,
            "errorCount": len(errors),
            "errors": errors,
            "rawFiles": [],
            "urlCompositionRule": "API Url field is used as-is (absolute https); no composition",
            "pagination": "none — OpenAPI documents no page params; single full list response",
            "writesHandoff": False,
            "writesBrief": False,
        }
        write_json(os.path.join(run_dir, "run.json"), run)
        return run

    raw_name = "twse-news-openapi.json"
    raw_path = os.path.join(raw_dir, raw_name)
    with open(raw_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(raw_text if raw_text.endswith("\n") else raw_text + "\n")

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
    try:
        items = parse_news_items(payload)
    except Exception as exc:
        status = "failed"
        errors.append({"stage": "parse", "message": str(exc)})
        items = []

    fetched_count = len(items)
    collected_at = started_at

    for item in items:
        try:
            news = item_to_news(item, collected_at, run_id)
            url = news.get("url") or ""
            if not url:
                errors.append({"stage": "normalize", "message": "missing Url", "title": item.get("Title")})
                continue
            if not news.get("title"):
                errors.append({"stage": "normalize", "message": "missing Title", "url": url})
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
            errors.append({"stage": "normalize", "message": str(exc), "title": item.get("Title")})

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
        "feedUrl": None if fixture_path else feed_url,
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
        },
        "fetchedCount": fetched_count,
        "normalizedCount": normalized_count,
        "skippedSeenCount": skipped_seen_count,
        "errorCount": len(errors),
        "errors": errors,
        "rawFiles": [os.path.join("raw", raw_name).replace("\\", "/")],
        "urlCompositionRule": "API Url field is used as-is (absolute https); no composition",
        "pagination": "none — OpenAPI documents no page params; single full list response",
        "dateMapping": "Date ROC YYYYmmdd → publishedTime CE ISO at 00:00:00Z; invalid → UNKNOWN/raw",
        "summaryMapping": "no API body field; summary = title",
        "writesHandoff": False,
        "writesBrief": False,
    }
    write_json(os.path.join(run_dir, "run.json"), run)
    return run


def main(argv):
    feed_url = DEFAULT_FEED_URL
    fixture_path = None
    store_root = DEFAULT_STORE_ROOT
    i = 1
    while i < len(argv):
        if argv[i] == "--feed-url" and i + 1 < len(argv):
            feed_url = argv[i + 1]
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
        sys.stderr.write("TWSE_NEWS_ADAPTER_FAIL\nunknown argument: " + argv[i] + "\n")
        return 2

    if fixture_path and not os.path.isfile(fixture_path):
        sys.stderr.write("TWSE_NEWS_ADAPTER_FAIL\nfixture not found: " + fixture_path + "\n")
        return 2

    run = collect(feed_url=feed_url, fixture_path=fixture_path, store_root=store_root)
    sys.stdout.write(json.dumps(run, ensure_ascii=False, indent=2) + "\n")
    if run.get("status") == "failed":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
