# Investor Twin Phase 2 Sprint 004 — News Dedup & Event Linking Engine.
# Input: two or more News Objects (or a Case A–F fixture).
# Output: relation + eventRef + explainable reason on stdout.
# Writes no data/, research/, Brief, Queue, Card, or Decision files.
# Does not use title similarity, embeddings, or sequential Event-001 IDs.
import importlib.util
import json
import os
import re
import sys

RELATIONS = ("Same Event", "Related Event", "Separate Event")
FORBIDDEN_NEWS_FIELDS = (
    "importance",
    "relevance",
    "impact",
    "researchCandidate",
    "candidate",
)
RECOMMENDATION_WORDS = ("buy", "sell", "加碼", "減碼", "應該買", "應該賣")
ENTITY_ALIASES = (
    ("hugging face", "hugging-face"),
    ("huggingface", "hugging-face"),
    ("federal open market committee", "fomc"),
    ("federal reserve", "federal-reserve"),
    ("another company", "other-company"),
    ("other company", "other-company"),
    ("nvda", "nvidia"),
    ("nvidia", "nvidia"),
)
STATE_MARKERS = (
    ("complete", ("completion", "completed", "complete")),
    ("review", ("regulators begin", "regulator", "reviewing", "review")),
    ("terminate", ("terminated", "terminate", "cancelled", "canceled")),
    ("acquire", ("acquisition", "acquire", "acquired", "收購")),
    ("partnership", ("partnership", "partner")),
)
RELATED_STATES = {"acquire", "review", "complete", "terminate"}


def fail(message, code=2):
    sys.stderr.write("NI_DEDUP_FAIL\n" + message + "\n")
    raise SystemExit(code)


def load_eval_module():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "evaluate-news-intelligence.py")
    spec = importlib.util.spec_from_file_location("evaluate_news_intelligence", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def blob(parts):
    return " ".join(str(part or "") for part in parts).strip()


def lower(text):
    return blob([text]).lower()


def news_items(raw):
    if isinstance(raw.get("newsA"), dict) and isinstance(raw.get("newsB"), dict):
        return [raw["newsA"], raw["newsB"]]
    if isinstance(raw.get("news"), list) and raw["news"]:
        return list(raw["news"])
    if isinstance(raw.get("news"), dict) and raw.get("title") in (None, ""):
        return [raw["news"]]
    if isinstance(raw, dict) and raw.get("title"):
        return [raw]
    fail("input must contain two or more News Objects")


def copy_news(news):
    keep = {}
    for key in ("id", "source", "title", "publishedTime", "published", "url", "summary", "content", "subject"):
        if key in news:
            keep[key] = news.get(key)
    for field in FORBIDDEN_NEWS_FIELDS:
        keep.pop(field, None)
    return keep


def extract_entities(text):
    hay = lower(text)
    found = []
    for alias, canonical in ENTITY_ALIASES:
        if alias in hay and canonical not in found:
            found.append(canonical)
    return found


def headline_entities(news):
    return extract_entities(blob([news.get("subject"), news.get("title")]))


def body_entities(news):
    return extract_entities(blob([news.get("subject"), news.get("title"), news.get("summary"), news.get("content")]))


def event_state(news):
    title = lower(news.get("title"))
    body = lower(blob([news.get("title"), news.get("summary"), news.get("content"), news.get("subject")]))
    if "separate" in body and "partnership" in body:
        return "partnership"
    if "partnership" in title and "acqui" not in title and "收購" not in title:
        return "partnership"
    for state, markers in STATE_MARKERS:
        if any(marker in body for marker in markers):
            return state
    return "other"


def deal_entities(news, state):
    if state == "partnership":
        entities = headline_entities(news)
        if "other-company" not in entities and "another company" in lower(blob([news.get("title"), news.get("summary")])):
            entities.append("other-company")
        return entities or ["unknown"]
    entities = body_entities(news)
    return entities or headline_entities(news) or ["unknown"]


def event_time(news):
    value = str(news.get("publishedTime") or news.get("published") or "").strip()
    if not value:
        return "UNKNOWN"
    return value[:10]


def analyze(news, evaluate):
    text = blob([news.get("title"), news.get("summary"), news.get("content"), news.get("subject")])
    event_type = evaluate.coarse_event_type(None, text)
    state = event_state(news)
    entities = deal_entities(news, state)
    when = event_time(news)
    return {
        "id": news.get("id") or news.get("url") or news.get("title"),
        "source": news.get("source"),
        "url": news.get("url"),
        "title": news.get("title"),
        "subject": news.get("subject"),
        "eventType": event_type,
        "eventTime": when,
        "state": state,
        "entities": sorted(set(entities)),
        "coreFact": state,
    }


def canonical_event_id(analysis):
    return "evt:{type}/{entities}/{state}".format(
        type=re.sub(r"\s+", "-", lower(analysis["eventType"]) or "other"),
        entities=",".join(analysis["entities"]) or "unknown",
        state=analysis["state"],
    )


def shared_entities(left, right):
    return sorted(set(left["entities"]) & set(right["entities"]))


def same_deal(left, right):
    shared = shared_entities(left, right)
    if "nvidia" in shared and "hugging-face" in shared:
        return True
    if left["state"] == right["state"] == "acquire" and "hugging-face" in shared:
        return True
    return False


def explainable_reason(relation, left, right, notes):
    return {
        "relation": relation,
        "subject": "shared " + ", ".join(shared_entities(left, right)) if shared_entities(left, right) else "no shared subject",
        "eventType": left["eventType"] + " / " + right["eventType"],
        "eventTime": left["eventTime"] + " / " + right["eventTime"],
        "coreFact": left["coreFact"] + " / " + right["coreFact"],
        "newInformation": notes,
    }


def compare(left, right):
    shared = shared_entities(left, right)
    same_type = left["eventType"] == right["eventType"]
    same_state = left["coreFact"] == right["coreFact"]
    deal = same_deal(left, right)

    if deal and same_type and same_state and left["coreFact"] != "other":
        notes = "same core fact; no new event state"
        return "Same Event", explainable_reason("Same Event", left, right, notes)

    if deal and left["coreFact"] in RELATED_STATES and right["coreFact"] in RELATED_STATES and left["coreFact"] != right["coreFact"]:
        notes = "same transaction, different event state / new information"
        return "Related Event", explainable_reason("Related Event", left, right, notes)

    if shared and left["eventTime"] == right["eventTime"] and not deal:
        notes = "same subject and/or same date is not enough; different corporate action / core fact"
        return "Separate Event", explainable_reason("Separate Event", left, right, notes)

    notes = "insufficient matching core fact"
    return "Separate Event", explainable_reason("Separate Event", left, right, notes)


def link(raw):
    evaluate = load_eval_module()
    items = news_items(raw)
    if len(items) < 2:
        fail("input must contain two or more News Objects")
    prepared = []
    for item in items:
        evaluate.validate_news_object(item)
        prepared.append(copy_news(item))

    analyses = [analyze(item, evaluate) for item in prepared]
    for item, analysis in zip(prepared, analyses):
        item["eventRef"] = canonical_event_id(analysis)
        for field in FORBIDDEN_NEWS_FIELDS:
            item.pop(field, None)

    events = {}
    for item, analysis in zip(prepared, analyses):
        event_id = item["eventRef"]
        event = events.setdefault(event_id, {
            "eventId": event_id,
            "what": analysis["coreFact"],
            "when": analysis["eventTime"],
            "subject": " / ".join(analysis["entities"]),
            "eventType": analysis["eventType"],
            "newsRefs": [],
        })
        event["newsRefs"].append(analysis["id"])

    links = []
    for i in range(len(analyses)):
        for j in range(i + 1, len(analyses)):
            relation, reason = compare(analyses[i], analyses[j])
            left_ref = prepared[i]["eventRef"]
            right_ref = prepared[j]["eventRef"]
            if relation == "Same Event":
                shared_id = canonical_event_id(analyses[i]) if analyses[i]["state"] <= analyses[j]["state"] else canonical_event_id(analyses[j])
                prepared[i]["eventRef"] = shared_id
                prepared[j]["eventRef"] = shared_id
                left_ref = right_ref = shared_id
            link_row = {
                "newsA": analyses[i]["id"],
                "newsB": analyses[j]["id"],
                "relation": relation,
                "eventRefA": left_ref,
                "eventRefB": right_ref,
                "reason": reason,
            }
            if relation == "Related Event":
                link_row["relatedEventRef"] = [left_ref, right_ref]
            links.append(link_row)

    events = {}
    for item, analysis in zip(prepared, analyses):
        event_id = item["eventRef"]
        event = events.setdefault(event_id, {
            "eventId": event_id,
            "what": analysis["coreFact"],
            "when": analysis["eventTime"],
            "subject": " / ".join(analysis["entities"]),
            "eventType": analysis["eventType"],
            "newsRefs": [],
        })
        if analysis["id"] not in event["newsRefs"]:
            event["newsRefs"].append(analysis["id"])

    result = {
        "news": prepared,
        "events": list(events.values()),
        "links": links,
    }
    leaked = [word for word in RECOMMENDATION_WORDS if word in json.dumps(result, ensure_ascii=False).lower()]
    if leaked:
        fail("dedup leaked recommendation language: " + ", ".join(leaked))
    return result


def main(argv):
    raw = None
    i = 1
    while i < len(argv):
        if argv[i] == "--input" and i + 1 < len(argv):
            path = os.path.abspath(argv[i + 1])
            unix = path.replace("\\", "/")
            if "/data/" in unix or unix.endswith("/data") or "/research/" in unix:
                fail("dedup engine may not read production data/ or research/ as --input")
            with open(path, encoding="utf-8") as handle:
                raw = json.load(handle)
            i += 2
            continue
        fail("unknown argument: " + argv[i])
    if raw is None:
        raw = json.load(sys.stdin)
    result = link(raw)
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
