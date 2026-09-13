#!/usr/bin/env python3
# News Collect Foundation — BLS Employment Situation RSS adapter (Collect only).
# Official feed: https://www.bls.gov/feed/empsit.rss (Atom)
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
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime

SOURCE_ID = "bls-empsit-rss"
SOURCE_LABEL = "BLS Employment Situation RSS"
DEFAULT_FEED_URL = "https://www.bls.gov/feed/empsit.rss"
USER_AGENT = "InvestorTwin-NewsCollect/029 (personal; non-commercial)"
ALLOWED_HOSTS = ("www.bls.gov", "bls.gov")
MAX_FEED_BYTES = 2_000_000

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_STORE_ROOT = os.path.join(REPO_ROOT, "data", "news")
TAG_RE = re.compile(r"<[^>]+>")


def utc_now_iso():
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def make_run_id(when=None):
    mod = sys.modules.get("news_collect_run_id")
    if mod is None:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "news-collect-run-id.py")
        spec = importlib.util.spec_from_file_location("news_collect_run_id", path)
        mod = importlib.util.module_from_spec(spec)
        sys.modules["news_collect_run_id"] = mod
        spec.loader.exec_module(mod)
    return mod.make_run_id(when)


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


def assert_bls_link(url):
    value = normalize_url(url)
    if not value:
        return ""
    parsed = urllib.parse.urlparse(value)
    host = (parsed.hostname or "").lower()
    if host not in ALLOWED_HOSTS:
        raise ValueError("REJECT non-BLS official link host: " + host)
    if parsed.scheme == "http":
        value = urllib.parse.urlunparse(("https",) + parsed[1:])
    elif parsed.scheme != "https":
        raise ValueError("BLS item link must be HTTPS: " + value)
    return value


def strip_html(text):
    value = html.unescape(str(text or ""))
    value = TAG_RE.sub(" ", value)
    value = re.sub(r"\s+", " ", value).strip()
    return value


def parse_published(value):
    raw = str(value or "").strip()
    if not raw:
        return "UNKNOWN"
    if "T" in raw:
        try:
            cleaned = raw.replace("Z", "+00:00")
            if "." in cleaned:
                head, rest = cleaned.split(".", 1)
                frac = ""
                tz = ""
                for i, ch in enumerate(rest):
                    if ch.isdigit():
                        frac += ch
                    else:
                        tz = rest[i:]
                        break
                cleaned = head + "." + (frac[:6].ljust(1, "0")) + tz
            dt = datetime.fromisoformat(cleaned)
            if dt.tzinfo is None:
                dt = dt.replace(tzinfo=timezone.utc)
            return dt.astimezone(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        except (TypeError, ValueError, IndexError, OverflowError):
            pass
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


def entry_link(node):
    for child in list(node):
        if local_name(child.tag) != "link":
            continue
        href = (child.attrib.get("href") or child.text or "").strip()
        rel = (child.attrib.get("rel") or "alternate").lower()
        if href and rel in ("alternate", ""):
            return href
    return child_text(node, ("link",))


def parse_rss_items(xml_text):
    """Parse RSS 2.0 <item> or Atom <entry> into a common item dict."""
    text = str(xml_text or "").lstrip("\ufeff")
    root = ET.fromstring(text)
    items = []
    for node in root.iter():
        tag = local_name(node.tag)
        if tag == "item":
            items.append({
                "title": child_text(node, ("title",)),
                "link": child_text(node, ("link",)),
                "guid": child_text(node, ("guid", "id")),
                "pubDate": child_text(node, ("pubDate", "published", "updated", "date")),
                "description": child_text(node, ("description", "summary", "content")),
            })
        elif tag == "entry":
            link = entry_link(node)
            entry_id = child_text(node, ("id",))
            items.append({
                "title": child_text(node, ("title",)),
                "link": link,
                "guid": entry_id or link,
                "pubDate": child_text(node, ("published", "updated")),
                "description": child_text(node, ("summary", "content")),
            })
    return items


def http_get_text(url, timeout=60):
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "application/atom+xml, application/rss+xml, application/xml, text/xml, */*",
        },
    )
    last_exc = None
    # BLS intermittently 403s TLS/UA combinations; try verified then unverified, with one retry.
    for attempt in range(2):
        for verify in (True, False):
            try:
                ctx = ssl.create_default_context() if verify else ssl._create_unverified_context()
                with urllib.request.urlopen(request, timeout=timeout, context=ctx) as response:
                    status = getattr(response, "status", None) or response.getcode()
                    raw = response.read(MAX_FEED_BYTES)
                    charset = "utf-8"
                    ctype = str(response.headers.get("Content-Type") or "")
                    if "charset=" in ctype.lower():
                        charset = ctype.split("charset=", 1)[1].split(";")[0].strip() or "utf-8"
                text = raw.decode(charset, errors="replace").lstrip("\ufeff")
                http_get_text.last_status = int(status) if status else 200
                return text
            except Exception as exc:
                last_exc = exc
                continue
        if attempt == 0:
            continue
    raise last_exc


http_get_text.last_status = None


def news_filename(url):
    digest = hashlib.sha1(url.encode("utf-8")).hexdigest()[:16]
    return digest + ".json"


def infer_subject(title, summary):
    hay = (title + " " + summary).lower()
    if "unemployment" in hay or "payroll" in hay or "employment situation" in hay or "nonfarm" in hay:
        return "Employment Situation"
    return "BLS"


def item_to_news(item, collected_at, run_id):
    url = assert_bls_link(item.get("link") or item.get("guid") or "")
    title = strip_html(item.get("title") or "")
    summary = strip_html(item.get("description") or "")
    if not summary and title:
        summary = title
    published = parse_published(item.get("pubDate"))
    return {
        "source": SOURCE_LABEL,
        "title": title,
        "publishedTime": published,
        "url": url,
        "summary": summary,
        "subject": infer_subject(title, summary),
        "eventRef": None,
        "id": url,
        "sourceId": SOURCE_ID,
        "collectedAt": collected_at,
        "collectRunId": run_id,
        "attribution": "U.S. Bureau of Labor Statistics (BLS)",
    }


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
    http_status = None

    try:
        if fixture_path:
            source_mode = "fixture"
            with open(fixture_path, encoding="utf-8-sig") as f:
                xml_text = f.read().lstrip("\ufeff")
            if not xml_text.strip():
                raise ValueError("fixture RSS is empty")
        else:
            xml_text = http_get_text(feed_url)
            http_status = http_get_text.last_status
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
            "httpStatus": http_status,
            "startedAt": started_at,
            "finishedAt": finished_at,
            "collectedAt": started_at,
            "status": status,
            "counts": {"fetched": 0, "normalized": 0, "skippedSeen": 0, "errors": len(errors)},
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

    raw_name = "bls-empsit-rss.xml"
    raw_path = os.path.join(raw_dir, raw_name)
    with open(raw_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(xml_text if xml_text.endswith("\n") else xml_text + "\n")

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
            if guid:
                try:
                    guid = assert_bls_link(guid)
                except ValueError:
                    guid = ""
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
        "httpStatus": http_status,
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
        sys.stderr.write("BLS_EMPSIT_RSS_ADAPTER_FAIL\nunknown argument: " + argv[i] + "\n")
        return 2

    if fixture_path and not os.path.isfile(fixture_path):
        sys.stderr.write("BLS_EMPSIT_RSS_ADAPTER_FAIL\nfixture not found: " + fixture_path + "\n")
        return 2

    run = collect(feed_url=feed_url, fixture_path=fixture_path, store_root=store_root)
    sys.stdout.write(json.dumps(run, ensure_ascii=False, indent=2) + "\n")
    if run.get("status") == "failed":
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
