#!/usr/bin/env python3
# News Collect Foundation v1 — thin Collect → Integrate pipeline.
# Runs enabled Collect adapters, then feeds THIS RUN's new News Objects into
# existing integrate-news-event-evaluation.integrate() (optional publish_handoff).
# Does NOT reimplement evaluate/link/integrate/handoff. Does NOT write Brief/Evidence.
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


def load_module(filename, name):
    path = os.path.join(SCRIPTS_DIR, filename)
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def read_json(path, default=None):
    if not os.path.isfile(path):
        return default
    # utf-8-sig tolerates PowerShell/Windows BOM when writing test fixtures.
    with open(path, encoding="utf-8-sig") as f:
        return json.load(f)


def write_json(path, obj):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f, ensure_ascii=False, indent=2)
        f.write("\n")


def load_sources(store_root):
    path = os.path.join(store_root, "sources.json")
    # Fall back to repo data/news/sources.json when using a temp store skeleton.
    if not os.path.isfile(path):
        path = os.path.join(DEFAULT_STORE_ROOT, "sources.json")
    data = read_json(path, {"sources": []})
    sources = []
    for row in data.get("sources") or []:
        if row and row.get("enabled") is True:
            sources.append(row)
    return sources


def ensure_pipeline_seen(store_root):
    path = os.path.join(store_root, "pipeline-seen.json")
    if not os.path.isfile(path):
        example = os.path.join(store_root, "pipeline-seen.example.json")
        if not os.path.isfile(example):
            example = os.path.join(DEFAULT_STORE_ROOT, "pipeline-seen.example.json")
        seed = read_json(example, {"schemaVersion": "1.0", "byUrl": {}})
        write_json(path, seed)
    return path


def load_normalized_news(run_dir):
    norm_dir = os.path.join(run_dir, "normalized")
    if not os.path.isdir(norm_dir):
        return []
    rows = []
    for name in sorted(os.listdir(norm_dir)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(norm_dir, name)
        item = read_json(path)
        if isinstance(item, dict):
            rows.append(item)
    return rows


def news_url(item):
    return str((item or {}).get("url") or (item or {}).get("id") or "").strip()


def filter_new_for_pipeline(news_list, pipeline_seen):
    by_url = pipeline_seen.get("byUrl") if isinstance(pipeline_seen.get("byUrl"), dict) else {}
    fresh = []
    skipped = []
    for item in news_list:
        url = news_url(item)
        if not url:
            skipped.append({"reason": "missing_url", "title": (item or {}).get("title")})
            continue
        if url in by_url:
            skipped.append({"reason": "pipeline_seen", "url": url})
            continue
        fresh.append(item)
    return fresh, skipped


def mark_pipeline_seen(pipeline_seen, news_list, run_id, when):
    by_url = pipeline_seen.setdefault("byUrl", {})
    for item in news_list:
        url = news_url(item)
        if not url:
            continue
        prev = by_url.get(url) or {"firstSeenAt": when}
        prev["lastSeenAt"] = when
        prev["lastPipelineRunId"] = run_id
        prev["newsId"] = item.get("id") or url
        by_url[url] = prev
    return pipeline_seen


def strip_collect_meta_for_integrate(news_list):
    """Pass core News Object fields; leave evaluation fields absent."""
    keep_keys = (
        "id", "source", "title", "publishedTime", "published", "url",
        "summary", "content", "subject", "eventRef",
    )
    out = []
    for item in news_list:
        row = {}
        for key in keep_keys:
            if key in item:
                row[key] = item.get(key)
        out.append(row)
    return out


def run_cna_collect(source, store_root, fixture_path=None):
    adapter = load_module("collect-cna-finance-rss.py", "collect_cna_finance_rss")
    feed_url = source.get("feedUrl") or adapter.DEFAULT_FEED_URL
    return adapter.collect(
        feed_url=feed_url,
        fixture_path=fixture_path,
        store_root=store_root,
    )


def pipeline(
    store_root=None,
    fixture_path=None,
    publish_handoff_path=None,
    skip_collect=False,
    run_id=None,
):
    store_root = store_root or DEFAULT_STORE_ROOT
    started_at = utc_now_iso()
    errors = []
    collect_runs = []
    integrate_result = None
    status = "ok"
    pipeline_news = []
    skipped = []

    sources = load_sources(store_root)
    if not sources:
        status = "failed"
        errors.append({"stage": "registry", "message": "no enabled sources in sources.json"})

    collect_run = None
    if status != "failed" and not skip_collect:
        for source in sources:
            source_id = str(source.get("sourceId") or "")
            if source_id != "cna-finance-rss":
                errors.append({
                    "stage": "collect",
                    "message": "v1 only supports cna-finance-rss; skipped " + source_id,
                })
                continue
            try:
                collect_run = run_cna_collect(source, store_root, fixture_path=fixture_path)
                collect_runs.append({
                    "sourceId": source_id,
                    "runId": collect_run.get("runId"),
                    "status": collect_run.get("status"),
                    "normalizedCount": collect_run.get("normalizedCount"),
                    "skippedSeenCount": collect_run.get("skippedSeenCount"),
                    "errorCount": collect_run.get("errorCount"),
                })
                if collect_run.get("status") == "failed":
                    status = "failed"
                    errors.append({
                        "stage": "collect",
                        "message": "collect failed",
                        "errors": collect_run.get("errors") or [],
                    })
            except Exception as exc:
                status = "failed"
                errors.append({"stage": "collect", "message": str(exc), "sourceId": source_id})
    elif status != "failed" and skip_collect:
        if not run_id:
            status = "failed"
            errors.append({"stage": "collect", "message": "--run-id required with --skip-collect"})
        else:
            collect_run = {"runId": run_id, "status": "reuse"}

    news_for_integrate = []
    if status != "failed" and collect_run and collect_run.get("runId"):
        run_dir = os.path.join(store_root, "runs", collect_run["runId"])
        normalized = load_normalized_news(run_dir)
        pipeline_seen_path = ensure_pipeline_seen(store_root)
        pipeline_seen = read_json(pipeline_seen_path, {"schemaVersion": "1.0", "byUrl": {}})
        pipeline_news, skipped = filter_new_for_pipeline(normalized, pipeline_seen)
        news_for_integrate = strip_collect_meta_for_integrate(pipeline_news)

        if len(news_for_integrate) == 0:
            status = "skipped_no_new_news"
        elif len(news_for_integrate) < 2:
            # Existing integrate contract requires 2+ News Objects — do not invent filler news.
            status = "skipped_insufficient_news"
            errors.append({
                "stage": "integrate",
                "message": "existing integrate requires two or more News Objects; refusing to invent filler",
                "newsCount": len(news_for_integrate),
            })
        else:
            try:
                integrate_mod = load_module(
                    "integrate-news-event-evaluation.py",
                    "integrate_news_event_evaluation",
                )
                integrate_result = integrate_mod.integrate({"news": news_for_integrate})
                if publish_handoff_path:
                    publisher = load_module(
                        "publish-research-candidates-handoff.py",
                        "publish_research_candidates_handoff",
                    )
                    publisher.publish_handoff(integrate_result, publish_handoff_path)
                # Only mark pipeline-seen after successful integrate.
                pipeline_seen = mark_pipeline_seen(
                    pipeline_seen, pipeline_news, collect_run["runId"], started_at
                )
                write_json(pipeline_seen_path, pipeline_seen)
            except SystemExit as exc:
                status = "failed"
                errors.append({
                    "stage": "integrate",
                    "message": "integrate failed",
                    "detail": str(exc),
                })
                integrate_result = None
            except Exception as exc:
                status = "failed"
                errors.append({"stage": "integrate", "message": str(exc)})
                integrate_result = None

    finished_at = utc_now_iso()
    summary = {
        "schemaVersion": "1.0",
        "kind": "news-collect-pipeline",
        "startedAt": started_at,
        "finishedAt": finished_at,
        "status": status,
        "storeRoot": store_root.replace("\\", "/"),
        "collectRuns": collect_runs,
        "collectRunId": (collect_run or {}).get("runId"),
        "newsInRun": len(pipeline_news) + len([s for s in skipped if s.get("reason") == "pipeline_seen"]),
        "newsSentToIntegrate": len(news_for_integrate),
        "pipelineSkipped": skipped,
        "publishHandoff": bool(publish_handoff_path),
        "publishHandoffPath": publish_handoff_path,
        "writesBrief": False,
        "writesEvidence": False,
        "usesExistingIntegrate": True,
        "errorCount": len(errors),
        "errors": errors,
        "integrate": None,
    }
    if integrate_result is not None:
        summary["integrate"] = {
            "newsCount": len(integrate_result.get("news") or []),
            "eventCount": len(integrate_result.get("events") or []),
            "evaluationCount": len(integrate_result.get("evaluations") or []),
            "candidateCount": len(integrate_result.get("researchCandidates") or []),
        }

    # Persist pipeline summary beside collect run when possible (runtime; under runs/ = gitignored).
    if collect_run and collect_run.get("runId"):
        run_dir = os.path.join(store_root, "runs", collect_run["runId"])
        if os.path.isdir(run_dir):
            write_json(os.path.join(run_dir, "pipeline.json"), summary)

    return summary


def main(argv):
    store_root = DEFAULT_STORE_ROOT
    fixture_path = None
    publish_handoff_path = None
    skip_collect = False
    run_id = None
    i = 1
    while i < len(argv):
        if argv[i] == "--store-root" and i + 1 < len(argv):
            store_root = os.path.abspath(argv[i + 1])
            i += 2
            continue
        if argv[i] == "--fixture" and i + 1 < len(argv):
            fixture_path = os.path.abspath(argv[i + 1])
            i += 2
            continue
        if argv[i] == "--publish-handoff" and i + 1 < len(argv):
            publish_handoff_path = os.path.abspath(argv[i + 1])
            i += 2
            continue
        if argv[i] == "--skip-collect":
            skip_collect = True
            i += 1
            continue
        if argv[i] == "--run-id" and i + 1 < len(argv):
            run_id = argv[i + 1]
            i += 2
            continue
        sys.stderr.write("NEWS_COLLECT_PIPELINE_FAIL\nunknown argument: " + argv[i] + "\n")
        return 2

    if fixture_path and not os.path.isfile(fixture_path):
        sys.stderr.write("NEWS_COLLECT_PIPELINE_FAIL\nfixture not found: " + fixture_path + "\n")
        return 2

    summary = pipeline(
        store_root=store_root,
        fixture_path=fixture_path,
        publish_handoff_path=publish_handoff_path,
        skip_collect=skip_collect,
        run_id=run_id,
    )
    sys.stdout.write(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    if summary.get("status") == "failed":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
