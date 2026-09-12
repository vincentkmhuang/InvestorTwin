#!/usr/bin/env python3
# MOPS 重大訊息 OpenAPI Bootstrap / First-Enable v1 — seen-only snapshot.
#
# Bootstrap is NOT Collect.
#   Fetch (listed + OTC) → Parse → Identity → data/news/seen.json
# Forbidden:
#   normalize News Objects, integrate, handoff, candidates, Brief, Meaning Gate
#
# Identity MUST match scripts/collect-mops-material-openapi.py exactly
# (reuse that module's fetch / parse / item_to_news / build_identity_url).
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


def load_mops_adapter():
    path = os.path.join(SCRIPTS_DIR, "collect-mops-material-openapi.py")
    spec = importlib.util.spec_from_file_location("collect_mops_material_openapi", path)
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


def item_identity(adapter, item, collected_at):
    """Same identity as collect-mops-material-openapi.item_to_news / collect loop."""
    news = adapter.item_to_news(item, collected_at, "bootstrap")
    return news.get("url") or ""


def merge_bootstrap_state(store_root, entry):
    """Merge per-source bootstrap metadata; preserve legacy flat FSC shape if present."""
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
        "otcUrl": entry.get("otcUrl"),
        "listedCount": entry.get("listedCount"),
        "otcCount": entry.get("otcCount"),
        "normalizedCount": 0,
        "integrateCount": 0,
    }
    write_json(state_path, payload)
    return state_path


def fail_result(
    adapter,
    started_at,
    source_mode,
    listed_url,
    otc_url,
    fixture_path,
    stage,
    message,
):
    return {
        "schemaVersion": "1.0",
        "kind": "news-bootstrap-seen",
        "sourceId": adapter.SOURCE_ID,
        "mode": "seen-only",
        "sourceMode": source_mode,
        "feedUrl": None if fixture_path else listed_url,
        "otcUrl": None if fixture_path else otc_url,
        "fixture": fixture_path,
        "startedAt": started_at,
        "finishedAt": utc_now_iso(),
        "status": "failed",
        "fetchedCount": 0,
        "seededCount": 0,
        "alreadySeenCount": 0,
        "skippedMissingUrl": 0,
        "listedCount": 0,
        "otcCount": 0,
        "normalizedCount": 0,
        "integrateCount": 0,
        "writesNormalized": False,
        "writesHandoff": False,
        "writesBrief": False,
        "callsIntegrate": False,
        "errors": [{"stage": stage, "message": message}],
    }


def bootstrap(
    feed_url=None,
    fixture_path=None,
    store_root=None,
    listed_url=None,
    otc_url=None,
):
    adapter = load_mops_adapter()
    store_root = store_root or DEFAULT_STORE_ROOT
    listed_url = (listed_url or feed_url or adapter.DEFAULT_LISTED_URL).strip()
    otc_url = (otc_url or adapter.DEFAULT_OTC_URL).strip()
    started_at = utc_now_iso()
    errors = []
    status = "ok"
    source_mode = "live"
    items = []
    listed_count = 0
    otc_count = 0

    runs_before = set()
    runs_root = os.path.join(store_root, "runs")
    if os.path.isdir(runs_root):
        runs_before = set(os.listdir(runs_root))

    try:
        if fixture_path:
            source_mode = "fixture"
            with open(fixture_path, encoding="utf-8-sig") as f:
                raw_text = f.read()
            if not raw_text.strip():
                raise ValueError("fixture JSON is empty")
            payload = json.loads(raw_text)
            items = adapter.parse_payload_items(payload)
            listed_count = sum(1 for i in items if i.get("market") == "listed")
            otc_count = sum(1 for i in items if i.get("market") == "otc")
        else:
            _listed_text, listed_payload = adapter.http_get_json(listed_url)
            _otc_text, otc_payload = adapter.http_get_json(otc_url)
            listed_items = adapter.parse_payload_items(listed_payload, default_market="listed")
            otc_items = adapter.parse_payload_items(otc_payload, default_market="otc")
            listed_count = len(listed_items)
            otc_count = len(otc_items)
            items = listed_items + otc_items
    except Exception as exc:
        return fail_result(
            adapter,
            started_at,
            source_mode,
            listed_url,
            otc_url,
            fixture_path,
            "fetch",
            str(exc),
        )

    seen_path, _hist_path = adapter.ensure_runtime_state(store_root)
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
        url = item_identity(adapter, item, started_at)
        title = item.get("title") or ""
        if not title:
            errors.append({
                "stage": "identity",
                "message": "missing title/主旨",
                "market": item.get("market"),
                "code": item.get("code"),
            })
            continue
        if not url:
            skipped_missing_url += 1
            errors.append({
                "stage": "identity",
                "message": "missing identity url",
                "market": item.get("market"),
                "code": item.get("code"),
            })
            continue

        if url in seen["byUrl"]:
            already_seen_count += 1
            prev = seen["byUrl"].get(url) or {}
            prev["lastSeenAt"] = started_at
            prev["bootstrap"] = True
            prev["bootstrapSourceId"] = adapter.SOURCE_ID
            prev["market"] = item.get("market")
            seen["byUrl"][url] = prev
        else:
            seeded_count += 1
            seen["byUrl"][url] = {
                "newsId": url,
                "guid": None,
                "firstSeenAt": started_at,
                "lastSeenAt": started_at,
                "bootstrap": True,
                "bootstrapSourceId": adapter.SOURCE_ID,
                "market": item.get("market"),
            }

    write_json(seen_path, seen)

    finished_at = utc_now_iso()
    state_entry = {
        "schemaVersion": "1.0",
        "sourceId": adapter.SOURCE_ID,
        "mode": "seen-only",
        "completedAt": finished_at,
        "seededCount": seeded_count,
        "alreadySeenCount": already_seen_count,
        "fetchedCount": fetched_count,
        "listedCount": listed_count,
        "otcCount": otc_count,
        "feedUrl": None if fixture_path else listed_url,
        "otcUrl": None if fixture_path else otc_url,
        "fixture": bool(fixture_path),
        "sourceMode": source_mode,
        "normalizedCount": 0,
        "integrateCount": 0,
    }
    state_path = merge_bootstrap_state(store_root, state_entry)

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

    return {
        "schemaVersion": "1.0",
        "kind": "news-bootstrap-seen",
        "sourceId": adapter.SOURCE_ID,
        "mode": "seen-only",
        "sourceMode": source_mode,
        "feedUrl": None if fixture_path else listed_url,
        "otcUrl": None if fixture_path else otc_url,
        "fixture": fixture_path,
        "storeRoot": store_root.replace("\\", "/"),
        "startedAt": started_at,
        "finishedAt": finished_at,
        "status": status,
        "fetchedCount": fetched_count,
        "seededCount": seeded_count,
        "alreadySeenCount": already_seen_count,
        "skippedMissingUrl": skipped_missing_url,
        "listedCount": listed_count,
        "otcCount": otc_count,
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
    otc_url = None
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
        sys.stderr.write("MOPS_BOOTSTRAP_FAIL\nunknown argument: " + argv[i] + "\n")
        return 2

    if fixture_path and not os.path.isfile(fixture_path):
        sys.stderr.write("MOPS_BOOTSTRAP_FAIL\nfixture not found: " + fixture_path + "\n")
        return 2

    result = bootstrap(
        feed_url=feed_url,
        fixture_path=fixture_path,
        store_root=store_root,
        listed_url=feed_url,
        otc_url=otc_url,
    )
    sys.stdout.write(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    if result.get("status") == "failed":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
