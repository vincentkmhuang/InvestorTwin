# Investor Twin Phase 2 Sprint 002 — NVIDIA Official Source Adapter.
# Input: one NVIDIA official article URL, or offline HTML + that URL.
# Output: Sprint 001 News Object on stdout. Writes no data/, research/, or Brief files.
# Does not score Importance / Relevance / Impact / Candidate.
import datetime
import html as html_lib
import importlib.util
import json
import os
import re
import ssl
import sys
import urllib.error
import urllib.parse
import urllib.request
from html.parser import HTMLParser

ALLOWED_HOSTS = (
    "blogs.nvidia.com",
    "nvidianews.nvidia.com",
)
FORBIDDEN_NEWS_FIELDS = (
    "importance",
    "relevance",
    "impact",
    "researchCandidate",
    "candidate",
)
DATE_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")
MONTHS = {
    "january": 1, "february": 2, "march": 3, "april": 4, "may": 5, "june": 6,
    "july": 7, "august": 8, "september": 9, "october": 10, "november": 11, "december": 12,
}


def fail(message, code=2):
    sys.stderr.write("NI_ADAPTER_FAIL\n" + message + "\n")
    raise SystemExit(code)


def load_eval_module():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "evaluate-news-intelligence.py")
    spec = importlib.util.spec_from_file_location("evaluate_news_intelligence", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def assert_nvidia_https(url):
    if not isinstance(url, str) or not url.strip():
        fail("missing NVIDIA official URL")
    parsed = urllib.parse.urlparse(url.strip())
    if parsed.scheme != "https":
        fail("only HTTPS NVIDIA official URLs are allowed")
    host = (parsed.hostname or "").lower()
    if host not in ALLOWED_HOSTS:
        fail("REJECT non-NVIDIA official source: " + host)
    if parsed.username or parsed.password:
        fail("URL credentials are not allowed")
    return parsed.geturl()


def http_get_text(url):
    request = urllib.request.Request(url, headers={"User-Agent": "InvestorTwin-NewsAdapter/002"})
    try:
        with urllib.request.urlopen(request, timeout=20, context=ssl.create_default_context()) as response:
            content_type = str(response.headers.get("Content-Type") or "")
            if "html" not in content_type.lower() and "text" not in content_type.lower():
                fail("refused non-text response")
            raw = response.read(800000)
    except urllib.error.HTTPError as exc:
        fail("invalid NVIDIA URL: HTTP " + str(exc.code))
    except urllib.error.URLError as exc:
        fail("invalid NVIDIA URL: " + str(exc.reason))
    except TimeoutError:
        fail("invalid NVIDIA URL: timeout")
    text = raw.decode("utf-8", errors="replace")
    if "<" not in text:
        fail("NVIDIA article did not return HTML")
    return text


class ArticleParser(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self._tag = []
        self._capture = None
        self._buf = []
        self.title = ""
        self.published = ""
        self.description = ""
        self.paragraphs = []
        self._skip = False

    def handle_starttag(self, tag, attrs):
        attrs = {key.lower(): (value or "") for key, value in attrs}
        self._tag.append(tag)
        if tag in ("script", "style", "nav", "footer", "noscript"):
            self._skip = True
            return
        if tag == "meta":
            prop = (attrs.get("property") or attrs.get("name") or "").lower()
            content = attrs.get("content", "").strip()
            if prop in ("og:title", "twitter:title") and content and not self.title:
                self.title = content
            if prop in ("article:published_time", "publish-date", "date") and content and not self.published:
                self.published = content
            if prop in ("og:description", "description", "twitter:description") and content and not self.description:
                self.description = content
        if tag == "time" and attrs.get("datetime") and not self.published:
            self.published = attrs.get("datetime")
        if tag in ("title", "h1", "p"):
            self._capture = tag
            self._buf = []

    def handle_endtag(self, tag):
        if tag in ("script", "style", "nav", "footer", "noscript"):
            self._skip = False
        if self._capture == tag:
            text = clean_text("".join(self._buf))
            if tag == "title" and text and not self.title:
                self.title = text
            elif tag == "h1" and text and (not self.title or "nvidia blog" in self.title.lower()):
                self.title = text
            elif tag == "p" and text and len(text) >= 40:
                self.paragraphs.append(text)
            self._capture = None
            self._buf = []
        if self._tag and self._tag[-1] == tag:
            self._tag.pop()

    def handle_data(self, data):
        if self._skip or self._capture is None:
            return
        self._buf.append(data)


def clean_text(value):
    text = html_lib.unescape(str(value or ""))
    text = re.sub(r"\s+", " ", text).strip()
    return text


def normalize_title(title):
    text = clean_text(title)
    for suffix in (" | NVIDIA Blog", " | NVIDIA News", " | NVIDIA"):
        if text.endswith(suffix):
            text = text[: -len(suffix)].strip()
    return text


def normalize_published(value):
    text = clean_text(value)
    if not text:
        return ""
    iso = text[:10]
    if DATE_RE.match(iso):
        return iso
    matched = re.search(r"(January|February|March|April|May|June|July|August|September|October|November|December)\s+(\d{1,2}),\s+(\d{4})", text, re.I)
    if not matched:
        return ""
    month = MONTHS[matched.group(1).lower()]
    day = int(matched.group(2))
    year = int(matched.group(3))
    return datetime.date(year, month, day).isoformat()


def infer_subject(title, summary):
    hay = (title + " " + summary).lower()
    if "nvidia" in hay and "hugging face" in hay:
        return "NVIDIA / Hugging Face"
    if "nvidia" in hay:
        return "NVIDIA"
    return None


def news_object(url, html_text):
    parser = ArticleParser()
    parser.feed(html_text)
    title = normalize_title(parser.title)
    published = normalize_published(parser.published)
    if not published:
        published = normalize_published(html_text)
    summary = clean_text(parser.description)
    if not summary:
        summary = " ".join(parser.paragraphs[:3]).strip()
    news = {
        "source": "NVIDIA Official Blog",
        "title": title,
        "publishedTime": published,
        "url": url,
        "summary": summary,
        "subject": infer_subject(title, summary),
        "eventRef": None,
    }
    for field in FORBIDDEN_NEWS_FIELDS:
        news.pop(field, None)
    return news


def main(argv):
    url = None
    html_path = None
    i = 1
    while i < len(argv):
        if argv[i] == "--url" and i + 1 < len(argv):
            url = argv[i + 1]
            i += 2
            continue
        if argv[i] == "--html" and i + 1 < len(argv):
            html_path = argv[i + 1]
            i += 2
            continue
        fail("unknown argument: " + argv[i])
    url = assert_nvidia_https(url)
    if html_path:
        path = os.path.abspath(html_path)
        unix = path.replace("\\", "/")
        if "/data/" in unix or "/research/" in unix:
            fail("adapter may not read production data/ or research/")
        with open(path, encoding="utf-8") as handle:
            html_text = handle.read()
    else:
        html_text = http_get_text(url)
    news = news_object(url, html_text)
    evaluate = load_eval_module()
    evaluate.validate_news_object(news)
    json.dump(news, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
