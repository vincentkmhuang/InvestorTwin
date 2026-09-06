# Investor Twin Phase 2 Sprint 005 — News → Event → Evaluation Integration.
# Reuses link-news-events.py then evaluate-news-intelligence.py helpers.
# Output: news[] / events[] / evaluations[] / researchCandidates[].
# Default: stdout only — writes no data/, research/, Brief, Queue, Card, or Decision files.
# Sprint 009 opt-in: --publish-handoff <path> merges stdout payload into research-candidates-handoff.json
# via publish-research-candidates-handoff.py (never writes candidate-gate ledger / Cards / Queue).
import importlib.util
import json
import os
import sys

RECOMMENDATION_WORDS = ("buy", "sell", "加碼", "減碼", "應該買", "應該賣")
SEPARATION_KEYS = ("FACT", "ESTIMATE", "INFERENCE", "UNKNOWN")
CONCERN_MARKERS = (
    "concern",
    "疑慮",
    "competitive pressure",
    "competition concern",
    "市場疑慮",
    "競爭影響",
    "壓力",
)


def fail(message, code=2):
    sys.stderr.write("NI_INTEGRATE_FAIL\n" + message + "\n")
    raise SystemExit(code)


def load_module(filename, module_name):
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), filename)
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def lower(text):
    return str(text or "").lower()


def news_id(news):
    return news.get("id") or news.get("url") or news.get("title")


def pick_title(group):
    for item in group:
        source = lower(item.get("source"))
        if "official" in source:
            return item.get("title")
    return group[0].get("title")


def combined_summary(group):
    parts = []
    for item in group:
        text = item.get("summary") or item.get("content") or ""
        if text and text not in parts:
            parts.append(text)
    return " ".join(parts).strip()


def collect_evidence_refs(group, event, evaluate):
    refs = []
    seen = set()
    event_block = {
        "what": event.get("what"),
        "when": event.get("when"),
        "subject": event.get("subject"),
        "eventType": event.get("eventType"),
    }
    for item in group:
        local_event = evaluate.event_from({"event": event_block}, item)
        status = evaluate.derive_evidence_status(item, local_event)
        for key in SEPARATION_KEYS:
            for claim in status.get(key) or []:
                claim_text = str(claim).strip()
                if not claim_text:
                    continue
                marker = (news_id(item), key, claim_text)
                if marker in seen:
                    continue
                seen.add(marker)
                refs.append({
                    "newsRef": news_id(item),
                    "source": item.get("source"),
                    "class": key,
                    "claim": claim_text,
                })
        hay = lower(evaluate.blob([item.get("title"), item.get("summary"), item.get("content")]))
        if any(marker in hay for marker in CONCERN_MARKERS):
            claim_text = "Third-party market / competitive concern reported for the same event"
            marker = (news_id(item), "ESTIMATE", claim_text)
            if marker not in seen:
                seen.add(marker)
                refs.append({
                    "newsRef": news_id(item),
                    "source": item.get("source"),
                    "class": "ESTIMATE",
                    "claim": claim_text,
                })
    return refs


def evidence_status_from_refs(refs):
    status = {key: [] for key in SEPARATION_KEYS}
    for item in refs:
        status[item["class"]].append({
            "claim": item["claim"],
            "newsRef": item["newsRef"],
            "source": item["source"],
        })
    return status


def build_eval_raw(group, event, fixture_raw):
    sources = []
    for item in group:
        source = item.get("source")
        if source and source not in sources:
            sources.append(source)
    raw = {
        "source": " / ".join(sources) if sources else "Unknown",
        "title": pick_title(group),
        "publishedTime": event.get("when") or group[0].get("publishedTime"),
        "summary": combined_summary(group),
        "subject": group[0].get("subject") or event.get("subject"),
        "url": next((item.get("url") for item in group if item.get("url")), None),
        "eventRef": event.get("eventId"),
        "event": {
            "what": event.get("what"),
            "when": event.get("when"),
            "subject": event.get("subject") or group[0].get("subject"),
            "eventType": event.get("eventType"),
        },
    }
    if isinstance(fixture_raw, dict):
        if isinstance(fixture_raw.get("evidenceSeparation"), dict):
            raw["evidenceSeparation"] = fixture_raw["evidenceSeparation"]
        if isinstance(fixture_raw.get("researchQuestion"), str):
            raw["researchQuestion"] = fixture_raw["researchQuestion"]
        if isinstance(fixture_raw.get("impact"), dict):
            raw["impact"] = fixture_raw["impact"]
    return raw


def evaluate_event(event, group, evaluate, fixture_raw):
    raw = build_eval_raw(group, event, fixture_raw)
    # Prefer richer what for NVIDIA / Policy scoring when event.what is a coarse state token.
    if event.get("what") in ("acquire", "review", "complete", "terminate", "partnership", "other"):
        raw["event"]["what"] = raw["summary"] or raw["title"]
    result = evaluate.evaluate(raw)
    evidence_refs = collect_evidence_refs(group, event, evaluate)
    if isinstance(fixture_raw, dict) and isinstance(fixture_raw.get("evidenceSeparation"), dict):
        for key in SEPARATION_KEYS:
            for claim in fixture_raw["evidenceSeparation"].get(key) or []:
                claim_text = str(claim).strip()
                if not claim_text:
                    continue
                evidence_refs.append({
                    "newsRef": news_id(group[0]),
                    "source": group[0].get("source"),
                    "class": key,
                    "claim": claim_text,
                })
    # Dedup evidence refs after fixture merge.
    unique = []
    seen = set()
    for item in evidence_refs:
        marker = (item.get("newsRef"), item.get("class"), item.get("claim"))
        if marker in seen:
            continue
        seen.add(marker)
        unique.append(item)
    impact = result["impact"]
    evaluation = {
        "eventRef": event["eventId"],
        "importance": result["importance"],
        "relevance": result["relevance"],
        "relevanceBasis": result["relevanceBasis"],
        "impact": {
            "target": impact.get("target"),
            "direction": impact.get("direction"),
            "strength": impact.get("strength"),
            "evidenceStatus": evidence_status_from_refs(unique) if unique else impact.get("evidenceStatus"),
        },
        "evidenceRefs": unique,
        "researchCandidate": {
            "eligible": result["researchCandidate"].get("eligible"),
            "reason": result["researchCandidate"].get("reason"),
            "researchQuestion": result["researchCandidate"].get("researchQuestion"),
            "stance": result["researchCandidate"].get("stance"),
            "eventRef": event["eventId"],
        },
    }
    return evaluation


def integrate(raw):
    if not isinstance(raw, dict):
        fail("input must be an object with two or more News Objects")
    linker = load_module("link-news-events.py", "link_news_events")
    evaluate = load_module("evaluate-news-intelligence.py", "evaluate_news_intelligence")
    linked = linker.link(raw)
    news = linked.get("news") or []
    events = linked.get("events") or []
    links = linked.get("links") or []
    if len(news) < 2:
        fail("integration requires two or more News Objects")
    by_event = {}
    for item in news:
        by_event.setdefault(item.get("eventRef"), []).append(item)
    evaluations = []
    research_candidates = []
    for event in events:
        group = by_event.get(event["eventId"]) or []
        if not group:
            continue
        evaluation = evaluate_event(event, group, evaluate, raw)
        evaluations.append(evaluation)
        candidate = evaluation["researchCandidate"]
        if candidate.get("eligible") is True:
            research_candidates.append({
                "eventRef": event["eventId"],
                "eligible": True,
                "reason": candidate.get("reason"),
                "researchQuestion": candidate.get("researchQuestion"),
                "stance": candidate.get("stance"),
            })
    result = {
        "news": news,
        "events": events,
        "links": links,
        "evaluations": evaluations,
        "researchCandidates": research_candidates,
    }
    leaked = [word for word in RECOMMENDATION_WORDS if word in json.dumps(result, ensure_ascii=False).lower()]
    if leaked:
        fail("integration leaked recommendation language: " + ", ".join(leaked))
    return result


def main(argv):
    raw = None
    publish_handoff_path = None
    i = 1
    while i < len(argv):
        if argv[i] == "--input" and i + 1 < len(argv):
            path = os.path.abspath(argv[i + 1])
            unix = path.replace("\\", "/")
            if "/data/" in unix or unix.endswith("/data") or "/research/" in unix:
                fail("integration may not read production data/ or research/ as --input")
            with open(path, encoding="utf-8") as handle:
                raw = json.load(handle)
            i += 2
            continue
        if argv[i] == "--publish-handoff" and i + 1 < len(argv):
            # Explicit opt-in only (Sprint 009). Default remains stdout-only.
            publish_handoff_path = os.path.abspath(argv[i + 1])
            i += 2
            continue
        fail("unknown argument: " + argv[i])
    if raw is None:
        raw = json.load(sys.stdin)
    result = integrate(raw)
    if publish_handoff_path:
        publisher = load_module(
            "publish-research-candidates-handoff.py",
            "publish_research_candidates_handoff",
        )
        publisher.publish_handoff(result, publish_handoff_path)
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
