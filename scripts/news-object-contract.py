#!/usr/bin/env python3
# News Object v1 contract helpers for News Collect Foundation.
# Reuses scripts/evaluate-news-intelligence.py validate_news_object — does not modify NI engines.
#
# Usage:
#   python scripts/news-object-contract.py --validate-file path/to/news.json
#   python scripts/news-object-contract.py --check-store
#   python scripts/news-object-contract.py --validate-file news.json --require-collect-url

from __future__ import annotations

import importlib.util
import json
import os
import sys

FORBIDDEN_NEWS_FIELDS = (
    "importance",
    "relevance",
    "impact",
    "researchCandidate",
    "candidate",
)

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
NEWS_STORE_ROOT = os.path.join(REPO_ROOT, "data", "news")


def fail(message, code=2):
    sys.stderr.write("NEWS_OBJECT_CONTRACT_FAIL\n" + message + "\n")
    raise SystemExit(code)


def load_evaluate_module():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "evaluate-news-intelligence.py")
    spec = importlib.util.spec_from_file_location("evaluate_news_intelligence", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def assert_no_forbidden_fields(news):
    bad = [name for name in FORBIDDEN_NEWS_FIELDS if name in news and news.get(name) is not None]
    if bad:
        fail("News Object must not carry evaluation fields: " + ", ".join(bad))


def validate_news_object_v1(news, require_collect_url=False):
    """Core Sprint 001 validation + Collect Foundation rules."""
    evaluate = load_evaluate_module()
    evaluate.validate_news_object(news)
    assert_no_forbidden_fields(news)
    if require_collect_url and not str(news.get("url") or "").strip():
        fail("Collect Foundation requires non-empty url for seen/history identity")
    return True


def normalize_news_object_v1(news, require_collect_url=False):
    """Return the canonical News Object shape used by news_from, plus optional collect fields."""
    validate_news_object_v1(news, require_collect_url=require_collect_url)
    evaluate = load_evaluate_module()
    core = evaluate.news_from(news)
    # Preserve optional collect-store metadata without inventing evaluation fields.
    for key in ("id", "sourceId", "collectedAt", "collectRunId"):
        if key in news and news.get(key) is not None:
            core[key] = news.get(key)
    if require_collect_url and not core.get("url"):
        fail("Collect Foundation requires non-empty url")
    if not core.get("id") and core.get("url"):
        core["id"] = str(core["url"]).strip()
    return core


def check_news_store_layout(root=None):
    base = root or NEWS_STORE_ROOT
    # Committed product skeleton (runtime seen/history/runs are gitignored).
    required = [
        os.path.join(base, "schemaVersion.json"),
        os.path.join(base, "news-object-v1.contract.json"),
        os.path.join(base, "seen.example.json"),
        os.path.join(base, "history", "by-url", "index.example.json"),
        os.path.join(base, "runs"),
        os.path.join(base, "runs", "run.template.json"),
    ]
    missing = [path for path in required if not os.path.exists(path)]
    if missing:
        fail("News store layout incomplete:\n" + "\n".join(missing))

    schema = json.loads(open(os.path.join(base, "schemaVersion.json"), encoding="utf-8").read())
    if str(schema.get("schemaVersion") or "") != "1.0":
        fail("data/news/schemaVersion.json schemaVersion must be 1.0")

    example_seen = json.loads(open(os.path.join(base, "seen.example.json"), encoding="utf-8").read())
    if "byUrl" not in example_seen or "byGuid" not in example_seen:
        fail("data/news/seen.example.json must contain byUrl and byGuid objects")

    example_history = json.loads(
        open(os.path.join(base, "history", "by-url", "index.example.json"), encoding="utf-8").read()
    )
    if "entries" not in example_history:
        fail("data/news/history/by-url/index.example.json must contain entries object")

    return {
        "ok": True,
        "root": base.replace("\\", "/"),
        "schemaVersion": schema.get("schemaVersion"),
        "sourceIdV1": schema.get("sourceIdV1"),
        "runtimeOptional": {
            "seen": os.path.exists(os.path.join(base, "seen.json")),
            "historyIndex": os.path.exists(os.path.join(base, "history", "by-url", "index.json")),
        },
    }


def main(argv):
    validate_path = None
    require_collect_url = False
    check_store = False
    i = 1
    while i < len(argv):
        if argv[i] == "--validate-file" and i + 1 < len(argv):
            validate_path = argv[i + 1]
            i += 2
            continue
        if argv[i] == "--require-collect-url":
            require_collect_url = True
            i += 1
            continue
        if argv[i] == "--check-store":
            check_store = True
            i += 1
            continue
        fail("unknown argument: " + argv[i])

    if not validate_path and not check_store:
        fail("use --validate-file <path> and/or --check-store")

    result = {}
    if check_store:
        result["store"] = check_news_store_layout()
    if validate_path:
        raw = json.loads(open(validate_path, encoding="utf-8").read())
        if isinstance(raw, dict) and isinstance(raw.get("news"), dict) and not raw.get("title"):
            raw = raw["news"]
        normalized = normalize_news_object_v1(raw, require_collect_url=require_collect_url)
        result["news"] = normalized
        result["ok"] = True

    sys.stdout.write(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
