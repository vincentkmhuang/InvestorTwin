#!/usr/bin/env python3
# EIA Today in Energy RSS Bootstrap / First-Enable v1 — seen-only snapshot.
# Fetch → Parse → Identity → data/news/seen.json
# Forbidden: normalize News Objects, integrate, handoff, Brief, Meaning Gate.
from __future__ import annotations

import importlib.util
import json
import os
import sys
from datetime import datetime, timezone

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_STORE_ROOT = os.path.join(REPO_ROOT, "data", "news")
SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))
ADAPTER_FILE = "collect-eia-today-energy-rss.py"
ADAPTER_MODULE = "collect_eia_today_energy_rss"


def utc_now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def load_adapter():
    path = os.path.join(SCRIPTS_DIR, ADAPTER_FILE)
    spec = importlib.util.spec_from_file_location(ADAPTER_MODULE, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_json(path, obj):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")


def read_json(path, default=None):
    if not os.path.isfile(path):
        return default
    with open(path, encoding="utf-8-sig") as f:
        return json.load(f)


def item_identity(adapter, item, feed_url=None):
    base = feed_url or getattr(adapter, "DEFAULT_FEED_URL", None)
    try:
        url = adapter.assert_eia_link(item.get("link") or item.get("guid") or "", base_url=base)
    except ValueError:
        url = ""
    guid = adapter.normalize_url(item.get("guid") or "")
    if guid:
        try:
            guid = adapter.assert_eia_link(guid, base_url=base)
        except ValueError:
            guid = ""
    return url, guid


def merge_bootstrap_state(store_root, entry):
    state_path = os.path.join(store_root, "bootstrap-state.json")
    existing = read_json(state_path, {}) or {}
    by_source = {}
    if isinstance(existing.get("bySource"), dict):
        by_source = dict(existing["bySource"])
    elif existing.get("sourceId"):
        legacy_id = str(existing.get("sourceId"))
        by_source[legacy_id] = {
            k: v for k, v in existing.items() if k not in ("description", "bySource")
        }
    by_source[entry["sourceId"]] = entry
    payload = {
        "schemaVersion": "1.0",
        "mode": "seen-only",
        "lastSourceId": entry["sourceId"],
        "completedAt": entry["completedAt"],
        "bySource": by_source,
        "sourceId": entry["sourceId"],
        "seededCount": entry.get("seededCount"),
        "alreadySeenCount": entry.get("alreadySeenCount"),
        "fetchedCount": entry.get("fetchedCount"),
        "feedUrl": entry.get("feedUrl"),
        "normalizedCount": 0,
        "integrateCount": 0,
    }
    write_json(state_path, payload)
    return state_path


def bootstrap(feed_url=None, fixture_path=None, store_root=None):
    adapter = load_adapter()
    store_root = store_root or DEFAULT_STORE_ROOT
    feed_url = (feed_url or adapter.DEFAULT_FEED_URL).strip()
    started_at = utc_now_iso()
    errors = []
    status = "ok"
    source_mode = "live"
    xml_text = None
    http_status = None

    runs_before = set()
    runs_root = os.path.join(store_root, "runs")
    if os.path.isdir(runs_root):
        runs_before = set(os.listdir(runs_root))

    try:
        if fixture_path:
            source_mode = "fixture"
            with open(fixture_path, encoding="utf-8-sig") as f:
                xml_text = f.read().lstrip("\ufeff")
            if not xml_text.strip():
                raise ValueError("fixture RSS is empty")
        else:
            xml_text = adapter.http_get_text(feed_url)
            http_status = adapter.http_get_text.last_status
            if "<rss" not in xml_text.lower() and "<feed" not in xml_text.lower():
                raise ValueError("feed response does not look like RSS/Atom XML")
    except Exception as exc:
        return {
            "schemaVersion": "1.0",
            "kind": "news-bootstrap-seen",
            "sourceId": adapter.SOURCE_ID,
            "mode": "seen-only",
            "sourceMode": source_mode,
            "feedUrl": None if fixture_path else feed_url,
            "fixture": fixture_path,
            "httpStatus": http_status,
            "startedAt": started_at,
            "finishedAt": utc_now_iso(),
            "status": "failed",
            "fetchedCount": 0,
            "seededCount": 0,
            "alreadySeenCount": 0,
            "skippedMissingUrl": 0,
            "normalizedCount": 0,
            "integrateCount": 0,
            "writesNormalized": False,
            "writesHandoff": False,
            "writesBrief": False,
            "callsIntegrate": False,
            "errors": [{"stage": "fetch", "message": str(exc)}],
        }

    try:
        items = adapter.parse_rss_items(xml_text)
    except Exception as exc:
        return {
            "schemaVersion": "1.0",
            "kind": "news-bootstrap-seen",
            "sourceId": adapter.SOURCE_ID,
            "mode": "seen-only",
            "sourceMode": source_mode,
            "feedUrl": None if fixture_path else feed_url,
            "fixture": fixture_path,
            "httpStatus": http_status,
            "startedAt": started_at,
            "finishedAt": utc_now_iso(),
            "status": "failed",
            "fetchedCount": 0,
            "seededCount": 0,
            "alreadySeenCount": 0,
            "skippedMissingUrl": 0,
            "normalizedCount": 0,
            "integrateCount": 0,
            "writesNormalized": False,
            "writesHandoff": False,
            "writesBrief": False,
            "callsIntegrate": False,
            "errors": [{"stage": "parse", "message": str(exc)}],
        }

    seen_path, _hist = adapter.ensure_runtime_state(store_root)
    seen = read_json(seen_path, {"schemaVersion": "1.0", "byUrl": {}, "byGuid": {}})
    if not isinstance(seen.get("byUrl"), dict):
        seen["byUrl"] = {}
    if not isinstance(seen.get("byGuid"), dict):
        seen["byGuid"] = {}

    fetched_count = len(items)
    seeded_count = 0
    already_seen_count = 0
    skipped_missing_url = 0

    for item in items:
        url, guid = item_identity(adapter, item, feed_url=feed_url)
        if not url:
            skipped_missing_url += 1
            errors.append({
                "stage": "identity",
                "message": "missing or non-EIA url/link",
                "title": item.get("title"),
            })
            continue
        if url in seen["byUrl"]:
            already_seen_count += 1
            prev = seen["byUrl"].get(url) or {}
            prev["lastSeenAt"] = started_at
            prev["bootstrap"] = True
            if guid:
                prev["guid"] = guid
            seen["byUrl"][url] = prev
        else:
            seeded_count += 1
            seen["byUrl"][url] = {
                "newsId": url,
                "guid": guid or None,
                "firstSeenAt": started_at,
                "lastSeenAt": started_at,
                "bootstrap": True,
                "bootstrapSourceId": adapter.SOURCE_ID,
            }
        if guid:
            seen["byGuid"][guid] = {
                "url": url,
                "lastSeenAt": started_at,
                "bootstrap": True,
            }

    write_json(seen_path, seen)
    finished_at = utc_now_iso()
    entry = {
        "schemaVersion": "1.0",
        "sourceId": adapter.SOURCE_ID,
        "mode": "seen-only",
        "completedAt": finished_at,
        "seededCount": seeded_count,
        "alreadySeenCount": already_seen_count,
        "fetchedCount": fetched_count,
        "feedUrl": None if fixture_path else feed_url,
        "fixture": bool(fixture_path),
        "sourceMode": source_mode,
        "httpStatus": http_status,
        "normalizedCount": 0,
        "integrateCount": 0,
    }
    state_path = merge_bootstrap_state(store_root, entry)

    runs_after = set(os.listdir(runs_root)) if os.path.isdir(runs_root) else set()
    new_runs = sorted(runs_after - runs_before)
    if new_runs:
        status = "failed"
        errors.append({
            "stage": "safety",
            "message": "bootstrap created unexpected runs entries",
            "newRuns": new_runs,
        })
    if errors and seeded_count == 0 and already_seen_count == 0 and fetched_count > 0:
        status = "failed"
    elif errors:
        status = "partial" if status == "ok" else status

    return {
        "schemaVersion": "1.0",
        "kind": "news-bootstrap-seen",
        "sourceId": adapter.SOURCE_ID,
        "mode": "seen-only",
        "sourceMode": source_mode,
        "feedUrl": None if fixture_path else feed_url,
        "fixture": fixture_path,
        "httpStatus": http_status,
        "storeRoot": store_root.replace("\\", "/"),
        "startedAt": started_at,
        "finishedAt": finished_at,
        "status": status,
        "fetchedCount": fetched_count,
        "seededCount": seeded_count,
        "alreadySeenCount": already_seen_count,
        "skippedMissingUrl": skipped_missing_url,
        "normalizedCount": 0,
        "integrateCount": 0,
        "writesNormalized": False,
        "writesHandoff": False,
        "writesBrief": False,
        "callsIntegrate": False,
        "seenPath": seen_path.replace("\\", "/"),
        "bootstrapStatePath": state_path.replace("\\", "/"),
        "errorCount": len(errors),
        "errors": errors,
    }


def main(argv):
    feed_url = None
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
        sys.stderr.write("EIA_TODAY_ENERGY_BOOTSTRAP_FAIL\nunknown argument: " + argv[i] + "\n")
        return 2
    if fixture_path and not os.path.isfile(fixture_path):
        sys.stderr.write("EIA_TODAY_ENERGY_BOOTSTRAP_FAIL\nfixture not found: " + fixture_path + "\n")
        return 2
    result = bootstrap(feed_url=feed_url, fixture_path=fixture_path, store_root=store_root)
    sys.stdout.write(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    return 1 if result.get("status") == "failed" else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
