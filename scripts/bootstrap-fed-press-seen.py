#!/usr/bin/env python3
# Federal Reserve Press Bootstrap / First-Enable v1 — seen-only snapshot.
#
# Bootstrap is NOT Collect.
#   Fetch → Parse → Identity → data/news/seen.json
# Forbidden:
#   normalize News Objects, integrate, handoff, candidates, Brief, Meaning Gate
#
# Identity MUST match scripts/collect-fed-press-rss.py exactly
# (reuse that module's normalize_url / parse_rss_items / assert_fed_link / fetch helpers).
from __future__ import annotations

import importlib.util
import json
import os
import sys
from datetime import datetime, timezone

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_STORE_ROOT = os.path.join(REPO_ROOT, "data", "news")
SCRIPTS_DIR = os.path.dirname(os.path.abspath(__file__))


def utc_now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def load_fed_adapter():
    path = os.path.join(SCRIPTS_DIR, "collect-fed-press-rss.py")
    spec = importlib.util.spec_from_file_location("collect_fed_press_rss", path)
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


def item_identity(adapter, item):
    """Same identity rules as collect-fed-press-rss.item_to_news / collect loop."""
    try:
        url = adapter.assert_fed_link(item.get("link") or item.get("guid") or "")
    except ValueError:
        url = ""
    guid = adapter.normalize_url(item.get("guid") or "")
    if guid:
        try:
            guid = adapter.assert_fed_link(guid)
        except ValueError:
            guid = ""
    return url, guid


def bootstrap(feed_url=None, fixture_path=None, store_root=None):
    adapter = load_fed_adapter()
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
        status = "failed"
        result = {
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
            "status": status,
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
        return result

    try:
        items = adapter.parse_rss_items(xml_text)
    except Exception as exc:
        status = "failed"
        result = {
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
            "status": status,
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
        return result

    seen_path, hist_path = adapter.ensure_runtime_state(store_root)
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
        url, guid = item_identity(adapter, item)
        if not url:
            skipped_missing_url += 1
            errors.append({
                "stage": "identity",
                "message": "missing or non-Fed url/link",
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
    bootstrap_state = {
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
    state_path = os.path.join(store_root, "bootstrap-state.json")
    write_json(state_path, bootstrap_state)

    runs_after = set()
    if os.path.isdir(runs_root):
        runs_after = set(os.listdir(runs_root))
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

    result = {
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
    return result


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
        sys.stderr.write("FED_BOOTSTRAP_FAIL\nunknown argument: " + argv[i] + "\n")
        return 2

    if fixture_path and not os.path.isfile(fixture_path):
        sys.stderr.write("FED_BOOTSTRAP_FAIL\nfixture not found: " + fixture_path + "\n")
        return 2

    result = bootstrap(feed_url=feed_url, fixture_path=fixture_path, store_root=store_root)
    sys.stdout.write(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    if result.get("status") == "failed":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
