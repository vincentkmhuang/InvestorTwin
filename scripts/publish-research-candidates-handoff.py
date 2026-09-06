# Investor Twin Phase 2 Sprint 009 — Research Candidate Handoff Publish.
# Thin plumbing: merge integrate output into data/research-candidates-handoff.json.
# Opt-in only. Does not write candidate-gate ledger, Queue, Cards, Brief, or Decisions.
# Identity: eventRef / eventId / news id|url. No fuzzy title matching. No new DB.
import json
import os
import sys

HANDOFF_KEYS = ("news", "events", "links", "evaluations", "researchCandidates")


def fail(message, code=2):
    sys.stderr.write("NI_HANDOFF_PUBLISH_FAIL\n" + message + "\n")
    raise SystemExit(code)


def empty_handoff():
    return {
        "news": [],
        "events": [],
        "links": [],
        "evaluations": [],
        "researchCandidates": [],
    }


def as_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def news_identity(item):
    """Precedence: news.id → news.url. Never match on title text."""
    if not isinstance(item, dict):
        return None
    news_id = str(item.get("id") or "").strip()
    if news_id:
        return ("id", news_id)
    url = str(item.get("url") or "").strip()
    if url:
        return ("url", url)
    return None


def event_identity(item):
    if not isinstance(item, dict):
        return None
    event_id = str(item.get("eventId") or "").strip()
    return event_id or None


def evaluation_identity(item):
    if not isinstance(item, dict):
        return None
    event_ref = str(item.get("eventRef") or "").strip()
    return event_ref or None


def candidate_identity(item):
    """Canonical Candidate identity = eventRef (Gate / Attention / Card links)."""
    if not isinstance(item, dict):
        return None
    event_ref = str(item.get("eventRef") or "").strip()
    return event_ref or None


def link_identity(item):
    if not isinstance(item, dict):
        return None
    news_a = str(item.get("newsA") or "").strip()
    news_b = str(item.get("newsB") or "").strip()
    relation = str(item.get("relation") or "").strip()
    if not news_a or not news_b:
        return None
    return (news_a, news_b, relation)


def merge_by_identity(existing_list, incoming_list, identity_fn):
    """Upsert by identity. Additive: keys only in existing are preserved."""
    merged = {}
    order = []
    for item in as_list(existing_list):
        key = identity_fn(item)
        if key is None:
            continue
        if key not in merged:
            order.append(key)
        merged[key] = item
    for item in as_list(incoming_list):
        key = identity_fn(item)
        if key is None:
            continue
        if key not in merged:
            order.append(key)
        merged[key] = item
    return [merged[key] for key in order]


def eligible_candidates(candidates):
    out = []
    for item in as_list(candidates):
        if not isinstance(item, dict):
            continue
        if item.get("eligible") is not True:
            continue
        if not candidate_identity(item):
            fail("eligible Candidate missing eventRef; refuse to publish without identity")
        out.append(item)
    return out


def normalize_payload(payload):
    if not isinstance(payload, dict):
        fail("publish payload must be an object")
    return {
        "news": as_list(payload.get("news")),
        "events": as_list(payload.get("events")),
        "links": as_list(payload.get("links")),
        "evaluations": as_list(payload.get("evaluations")),
        "researchCandidates": eligible_candidates(payload.get("researchCandidates")),
    }


def load_json_file(path):
    with open(path, encoding="utf-8-sig") as handle:
        return json.load(handle)


def load_handoff(path):
    if not path or not os.path.isfile(path):
        return empty_handoff()
    raw = load_json_file(path)
    if not isinstance(raw, dict):
        fail("existing handoff is not an object: " + path)
    out = empty_handoff()
    for key in HANDOFF_KEYS:
        out[key] = as_list(raw.get(key))
    return out


def publish_handoff(payload, handoff_path):
    """
    Merge integrate-shaped payload into handoff_path.
    Never writes candidate-gate ledger / queue / cards / brief.
    """
    incoming = normalize_payload(payload)
    existing = load_handoff(handoff_path)

    # Skip incoming news/events/evals without identity (fail closed for candidates already).
    news_in = [item for item in incoming["news"] if news_identity(item) is not None]
    events_in = [item for item in incoming["events"] if event_identity(item) is not None]
    evals_in = [item for item in incoming["evaluations"] if evaluation_identity(item) is not None]
    links_in = [item for item in incoming["links"] if link_identity(item) is not None]

    merged = {
        "news": merge_by_identity(existing["news"], news_in, news_identity),
        "events": merge_by_identity(existing["events"], events_in, event_identity),
        "links": merge_by_identity(existing["links"], links_in, link_identity),
        "evaluations": merge_by_identity(existing["evaluations"], evals_in, evaluation_identity),
        "researchCandidates": merge_by_identity(
            existing["researchCandidates"],
            incoming["researchCandidates"],
            candidate_identity,
        ),
    }

    # Idempotency guard: unique eventRef in researchCandidates.
    seen = set()
    for item in merged["researchCandidates"]:
        key = candidate_identity(item)
        if key in seen:
            fail("duplicate researchCandidates eventRef after merge: " + key)
        seen.add(key)

    directory = os.path.dirname(os.path.abspath(handoff_path))
    if directory and not os.path.isdir(directory):
        os.makedirs(directory, exist_ok=True)

    with open(handoff_path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(merged, handle, ensure_ascii=False, indent=2)
        handle.write("\n")

    return {
        "handoffPath": handoff_path.replace("\\", "/"),
        "candidateCount": len(merged["researchCandidates"]),
        "publishedEventRefs": [candidate_identity(item) for item in incoming["researchCandidates"]],
    }


def main(argv):
    input_path = None
    handoff_path = None
    i = 1
    while i < len(argv):
        if argv[i] == "--input" and i + 1 < len(argv):
            input_path = os.path.abspath(argv[i + 1])
            i += 2
            continue
        if argv[i] == "--handoff" and i + 1 < len(argv):
            handoff_path = os.path.abspath(argv[i + 1])
            i += 2
            continue
        fail("unknown argument: " + argv[i])

    if not handoff_path:
        fail("--handoff path is required (explicit opt-in publish target)")

    # Refuse accidental DB-shaped destinations.
    unix = handoff_path.replace("\\", "/")
    if unix.rstrip("/").endswith("/data/news") or "/data/news/" in unix:
        fail("refusing to publish into data/news/")
    if unix.rstrip("/").endswith("/data/events") or "/data/events/" in unix:
        fail("refusing to publish into data/events/")
    if unix.rstrip("/").endswith("/candidate-gate.json") or unix.endswith("/candidate-gate.json"):
        fail("refusing to write candidate-gate ledger from publish")

    if input_path:
        payload = load_json_file(input_path)
    else:
        payload = json.load(sys.stdin)

    summary = publish_handoff(payload, handoff_path)
    json.dump(summary, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
