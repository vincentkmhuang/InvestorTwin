#!/usr/bin/env python3
# News Collect Foundation v1 — FSC (金管會) 新聞稿 RSS adapter (Collect only).
# Fetch → parse → normalize → data/news/runs/<runId>/{raw,normalized,run.json}
# Does NOT call evaluate / link / integrate / handoff / Meaning Gate / Brief.
from __future__ import annotations

import hashlib
import html
import importlib.util
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

SOURCE_ID = "fsc-press-rss"
SOURCE_LABEL = "FSC 金管會新聞稿 RSS"
DEFAULT_FEED_URL = (
    "https://www.fsc.gov.tw/RSS/Messages?serno=201202290009&language=chinese"
)
USER_AGENT = "InvestorTwin-NewsCollect/015 (personal; non-commercial)"

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_STORE_ROOT = os.path.join(REPO_ROOT, "data", "news")

TAG_RE = re.compile(r"<[^>]+>")


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
    with open(path, encoding="utf-8") as f:
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
    # FSC feed puts literal &amp; inside CDATA; decode entities before identity use.
    value = html.unescape(str(url or "")).strip()
    if not value:
        return ""
    return value.split("#", 1)[0].strip()


def strip_html(text):
    value = html.unescape(str(text or ""))
    value = TAG_RE.sub(" ", value)
    value = re.sub(r"\s+", " ", value).strip()
    return value


def parse_published(value):
    """Map pubDate → publishedTime. Do not invent a more precise clock time."""
    raw = str(value or "").strip()
    if not raw:
        return "UNKNOWN"
    try:
        dt = parsedate_to_datetime(raw)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
    except (TypeError, ValueError, IndexError, OverflowError):
        return raw


def local_name(tag):
    if not tag:
        return ""
    if "}" in tag:
        return tag.rsplit("}", 1)[-1]
    return tag


def child_text(node, names):
    wanted = set(names)
    for child in list(node):
        if local_name(child.tag) in wanted:
            text = (child.text or "").strip()
            if text:
                return text
            if child.attrib.get("href"):
                return str(child.attrib.get("href")).strip()
    return ""


def parse_rss_items(xml_text):
    root = ET.fromstring(xml_text)
    items = []
    for node in root.iter():
        if local_name(node.tag) != "item":
            continue
        title = child_text(node, ("title",))
        link = child_text(node, ("link",))
        guid = child_text(node, ("guid",))
        pub = child_text(node, ("pubDate", "published", "date"))
        desc = child_text(node, ("description", "summary"))
        items.append({
            "title": title,
            "link": link,
            "guid": guid,
            "pubDate": pub,
            "description": desc,
        })
    return items


def http_get_text(url, timeout=40):
    """Fetch feed text. FSC TLS chain may fail default verify on some hosts — fallback once."""
    request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    last_exc = None
    for verify in (True, False):
        try:
            ctx = ssl.create_default_context() if verify else ssl._create_unverified_context()
            with urllib.request.urlopen(request, timeout=timeout, context=ctx) as response:
                raw = response.read(4_000_000)
                charset = "utf-8"
                ctype = str(response.headers.get("Content-Type") or "")
                if "charset=" in ctype.lower():
                    charset = ctype.split("charset=", 1)[1].split(";")[0].strip() or "utf-8"
            return raw.decode(charset, errors="replace")
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
    url = normalize_url(item.get("link") or item.get("guid") or "")
    title = strip_html(item.get("title") or "")
    # description → summary; missing description is allowed (do not drop item).
    # Contract still needs summary|content — fall back to title when RSS has no description.
    summary = strip_html(item.get("description") or "")
    if not summary and title:
        summary = title
    published = parse_published(item.get("pubDate"))
    news = {
        "source": SOURCE_LABEL,
        "title": title,
        "publishedTime": published,
        "url": url,
        "summary": summary,
        "subject": None,
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
    xml_text = None
    source_mode = "live"

    try:
        if fixture_path:
            source_mode = "fixture"
            with open(fixture_path, encoding="utf-8") as f:
                xml_text = f.read()
            if not xml_text.strip():
                raise ValueError("fixture RSS is empty")
        else:
            xml_text = http_get_text(feed_url)
            if "<rss" not in xml_text.lower() and "<feed" not in xml_text.lower():
                raise ValueError("feed response does not look like RSS/Atom XML")
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
            "writesHandoff": False,
            "writesBrief": False,
        }
        write_json(os.path.join(run_dir, "run.json"), run)
        return run

    raw_name = "fsc-press-rss.xml"
    raw_path = os.path.join(raw_dir, raw_name)
    with open(raw_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(xml_text)

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
        items = parse_rss_items(xml_text)
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
            guid = normalize_url(item.get("guid") or "")
            if not url:
                errors.append({"stage": "normalize", "message": "missing url/link", "title": item.get("title")})
                continue
            if url in seen["byUrl"] or (guid and guid in seen["byGuid"]):
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
                "guid": guid or None,
                "firstSeenAt": collected_at,
                "lastSeenAt": collected_at,
                "collectRunId": run_id,
            }
            if guid:
                seen["byGuid"][guid] = {"url": url, "lastSeenAt": collected_at, "collectRunId": run_id}
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
            errors.append({"stage": "normalize", "message": str(exc), "title": item.get("title")})

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
        sys.stderr.write("FSC_RSS_ADAPTER_FAIL\nunknown argument: " + argv[i] + "\n")
        return 2

    if fixture_path and not os.path.isfile(fixture_path):
        sys.stderr.write("FSC_RSS_ADAPTER_FAIL\nfixture not found: " + fixture_path + "\n")
        return 2

    run = collect(feed_url=feed_url, fixture_path=fixture_path, store_root=store_root)
    sys.stdout.write(json.dumps(run, ensure_ascii=False, indent=2) + "\n")
    if run.get("status") == "failed":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
