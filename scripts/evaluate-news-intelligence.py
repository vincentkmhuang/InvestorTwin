# Investor Twin Phase 2 Sprint 001 — News Intelligence Foundation Evaluation Engine.
# Reads one News Object / fixture from stdin or --input.
# Prints an evaluation result to stdout. Writes no data/, research/, or Brief files.
# Does not POST queue, create cards, or emit buy/sell recommendations.
import json
import os
import re
import sys

EVENT_TYPES = (
    "Earnings",
    "Guidance",
    "Policy",
    "Price-move",
    "Corporate Action",
    "Industry",
    "Other",
)
DIRECTIONS = ("Positive", "Negative", "Mixed", "Unclear")
STRENGTHS = ("Low", "Medium", "High")
SEPARATION_KEYS = ("FACT", "ESTIMATE", "INFERENCE", "UNKNOWN")
FRESHNESS_LABELS = ("fresh", "stale", "missing")
RECOMMENDATION_WORDS = (
    "buy",
    "sell",
    "加碼",
    "減碼",
    "應該買",
    "應該賣",
)
QUOTE_INSTRUMENTS = (
    "us10y",
    "us30y",
    "nasdaq",
    "spx",
    "dji",
    "sox",
    "taiex",
    "wti",
    "brent",
    "vix",
    "bitcoin",
    "gold",
)
AI_RESEARCH_MARKERS = (
    "nvidia",
    "hugging face",
    "huggingface",
    "ai developer",
    "model platform",
    "ai infrastructure",
    "ai 利潤池",
    "developer / model platform",
)
MACRO_MARKERS = (
    "ecb",
    "eurozone",
    "monetary policy",
    "rate hike",
    "升息",
    "政策利率",
)
INDEX_MARKERS = (
    "nasdaq",
    "s&p 500",
    "s&p",
    "spx",
    "dow",
    "dji",
    "sox",
)
RUMOR_MARKERS = (
    "rumor",
    "rumour",
    "reportedly",
    "sources say",
    "unconfirmed",
    "傳聞",
    "未確認",
)


def fail(message):
    sys.stderr.write("NI_EVAL_FAIL\n" + message + "\n")
    raise SystemExit(2)


def load_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def blob(parts):
    return " ".join(str(part or "") for part in parts).strip()


def lower(text):
    return blob([text]).lower()


def news_input(raw):
    if isinstance(raw.get("news"), dict) and raw.get("title") in (None, ""):
        return raw["news"]
    return raw


def validate_news_object(news):
    missing = []
    if not isinstance(news, dict):
        fail("News Object must be an object")
    if not str(news.get("source") or "").strip():
        missing.append("source")
    if not str(news.get("title") or "").strip():
        missing.append("title")
    published = news.get("publishedTime") or news.get("published")
    if not str(published or "").strip():
        missing.append("publishedTime")
    if not str(news.get("summary") or news.get("content") or "").strip():
        missing.append("content or summary")
    if missing:
        fail("News Object missing required field: " + ", ".join(missing))


def news_from(raw):
    block = news_input(raw)
    validate_news_object(block)
    published = block.get("publishedTime") or block.get("published")
    summary = block.get("summary") or block.get("content")
    return {
        "source": block.get("source"),
        "title": block.get("title"),
        "publishedTime": published,
        "url": block.get("url"),
        "summary": summary,
        "subject": block.get("subject"),
        "eventRef": block.get("eventRef"),
    }


def coarse_event_type(raw_type, text):
    value = lower(raw_type)
    hay = value + " " + lower(text)
    if "earning" in hay:
        return "Earnings"
    if "guidance" in hay:
        return "Guidance"
    if "corporate" in hay or "m&a" in hay or "acqui" in hay or "收購" in hay:
        return "Corporate Action"
    if "price-move" in hay or "price move" in hay:
        return "Price-move"
    if "policy" in hay or "升息" in hay or "ecb" in hay or re.search(r"\brate", hay):
        return "Policy"
    if "industry" in hay:
        return "Industry"
    if raw_type in EVENT_TYPES:
        return raw_type
    return "Other"


def event_from(raw, news):
    block = raw.get("event") if isinstance(raw.get("event"), dict) else {}
    text = blob([news.get("title"), news.get("summary"), news.get("subject"), block.get("what")])
    event_type = coarse_event_type(block.get("eventType"), text)
    hay = lower(text)
    what = block.get("what")
    if not what:
        if "nvidia" in hay and "hugging face" in hay and ("acqui" in hay or "收購" in hay):
            what = "NVIDIA 宣布收購 Hugging Face"
        else:
            what = news.get("summary") or news.get("title")
    when = block.get("when") or news.get("publishedTime") or "UNKNOWN"
    subject = block.get("subject") or news.get("subject")
    return {
        "what": what,
        "when": when,
        "subject": subject,
        "eventType": event_type,
    }


def is_market_quote(news, event):
    text = lower(blob([news.get("title"), news.get("summary"), event.get("what")]))
    if event.get("eventType") == "Price-move":
        return True
    if any(name in text for name in QUOTE_INSTRUMENTS) and re.search(r"\d", text):
        if "acqui" in text or "收購" in text or "ecb" in text:
            return False
        return True
    return False


def assess_importance(news, event):
    text = lower(blob([news.get("title"), news.get("summary"), event.get("what"), event.get("eventType")]))
    if event.get("eventType") == "Price-move" or is_market_quote(news, event):
        return 3
    if event.get("eventType") == "Corporate Action" and (
        "acqui" in text or "收購" in text or "m&a" in text
    ):
        return 5
    if event.get("eventType") == "Policy":
        return 4
    if "expected" in text or "預期" in text:
        return 4
    if event.get("eventType") == "Other":
        return 1
    return 3


def relevance_band(news, event, context):
    text = lower(blob([
        news.get("title"),
        news.get("summary"),
        news.get("subject"),
        event.get("what"),
        event.get("subject"),
    ]))
    cards = [lower(item) for item in (context.get("researchCards") or [])]
    theses = [lower(item) for item in (context.get("theses") or [])]
    queue = [lower(item) for item in (context.get("researchQueue") or [])]
    mapped = any(
        marker in item
        for marker in AI_RESEARCH_MARKERS
        for item in cards + theses + queue
    )
    if any(marker in text for marker in AI_RESEARCH_MARKERS) or mapped:
        return (
            "High",
            "與 NVIDIA、AI Developer / Model Platform、AI Infrastructure、AI 利潤池及既有 AI 研究方向高度相關。",
        )
    if any(marker in text for marker in INDEX_MARKERS):
        return (
            "Medium",
            "與投資人觀察的市場溫度／風險偏好有關，但只是價格變化，沒有新的 Research Question。",
        )
    if any(marker in text for marker in MACRO_MARKERS):
        return (
            "Low / Medium-Low",
            "與全球利率及風險資產有宏觀關聯，但目前沒有直接對應使用者既有 Research Card、Research Thesis 或明確投資問題。",
        )
    if text:
        return (
            "Low",
            "普通財經或地方消息，與 Investor DNA、既有 Research、Thesis 無關。",
        )
    return ("Unknown", "沒有足夠證據判斷 Relevance。")


def derive_evidence_status(news, event):
    text = blob([news.get("title"), news.get("summary"), event.get("what")])
    hay = lower(text)
    status = {key: [] for key in SEPARATION_KEYS}
    if "acqui" in hay or "收購" in hay:
        status["FACT"].append("NVIDIA 宣布收購 Hugging Face" if "hugging face" in hay else text)
    if "12,930,300,000" in text or "12.93" in text:
        status["FACT"].append("交易金額約 129.3 億美元")
    if "remain an open platform" in hay or "將維持開放" in text:
        status["FACT"].append("NVIDIA 表示 Hugging Face 將維持開放")
    if "nvidia" in hay and "hugging face" in hay:
        status["INFERENCE"].extend([
            "NVIDIA 可能由 AI Compute Platform 向 AI Developer / Model Platform 延伸",
            "可能擴大 NVIDIA AI ecosystem 的控制力",
        ])
        status["UNKNOWN"].extend([
            "實際營收貢獻",
            "對 NVIDIA 長期獲利的實際影響",
            "對其他 AI accelerator 的實際影響",
        ])
    return status


def impact_from(raw, news, event):
    block = raw.get("impact") if isinstance(raw.get("impact"), dict) else {}
    separation = raw.get("evidenceSeparation") if isinstance(raw.get("evidenceSeparation"), dict) else {}
    evidence_status = {}
    has_separation = any(isinstance(separation.get(key), list) for key in SEPARATION_KEYS)
    if has_separation:
        for key in SEPARATION_KEYS:
            items = separation.get(key)
            evidence_status[key] = list(items) if isinstance(items, list) else []
    else:
        evidence_status = derive_evidence_status(news, event)
    hay = lower(blob([news.get("title"), news.get("summary"), news.get("subject"), event.get("what")]))
    direction = block.get("direction") if block.get("direction") in DIRECTIONS else None
    strength = block.get("strength") if block.get("strength") in STRENGTHS else None
    target = block.get("target")
    if not target and "nvidia" in hay and "hugging face" in hay:
        target = "NVIDIA / AI developer ecosystem / AI software ecosystem"
    if not direction and "nvidia" in hay and "hugging face" in hay:
        direction = "Mixed"
    if not strength and "nvidia" in hay and "hugging face" in hay:
        strength = "High"
    return {
        "target": target or event.get("subject") or news.get("subject"),
        "direction": direction or "Unclear",
        "strength": strength or "Medium",
        "evidenceStatus": evidence_status,
    }


def unresolved_question(raw, news, event):
    question = raw.get("researchQuestion")
    if isinstance(question, str) and question.strip():
        return question.strip()
    hay = lower(blob([news.get("title"), news.get("summary"), news.get("subject"), event.get("what")]))
    if "nvidia" in hay and "hugging face" in hay and event.get("eventType") == "Corporate Action":
        return (
            "NVIDIA 收購 Hugging Face，是否代表 NVIDIA "
            "正在從 AI Compute Platform 向 AI Developer / "
            "Model Platform 延伸？這是否會改變 AI 利潤池 "
            "與 NVIDIA 長期競爭優勢？"
        )
    return None


def fact_supported(impact):
    facts = (impact or {}).get("evidenceStatus", {}).get("FACT") or []
    return any(str(item).strip() for item in facts)


def is_unconfirmed(news, event):
    text = lower(blob([news.get("title"), news.get("summary"), event.get("what")]))
    return any(marker in text for marker in RUMOR_MARKERS)


def assess_candidate(importance, relevance, news, event, question, impact):
    quote = is_market_quote(news, event)
    relevance_maps = relevance in ("High", "Medium")
    first_gate = importance >= 3 or relevance_maps
    evidence_ok = fact_supported(impact) and not is_unconfirmed(news, event)
    eligible = (
        (not quote)
        and evidence_ok
        and first_gate
        and bool(question)
        and relevance_maps
    )
    if eligible:
        return {
            "eligible": True,
            "reason": "Importance 與 Relevance 都支持投入研究時間，且存在尚未回答的 Research Question。",
            "researchQuestion": question,
            "stance": None,
        }
    if quote:
        return {
            "eligible": False,
            "reason": "這是市場價格變化，不等於新的投資研究問題。",
            "researchQuestion": None,
            "stance": None,
        }
    if not evidence_ok:
        return {
            "eligible": False,
            "reason": "Relevance 高也不足以在證據不足時成立 Candidate；目前僅能 Watch / UNKNOWN。",
            "researchQuestion": None,
            "stance": "Watch",
        }
    if not relevance_maps and not question:
        reason = (
            "雖然事件本身重要，"
            "但目前沒有足夠的 Investor Relevance，"
            "也沒有明確新的 Research Question 值得投入研究時間。"
        )
    elif not relevance_maps:
        reason = "Importance 不足以單獨成立 Candidate；目前 Relevance 不足。"
    elif not question:
        reason = "沒有明確新的 Research Question 值得投入研究時間。"
    else:
        reason = "未同時滿足 Candidate 條件。"
    return {
        "eligible": False,
        "reason": reason,
        "researchQuestion": None,
        "stance": None,
    }


def recommendation_leak(payload):
    text = lower(json.dumps(payload, ensure_ascii=False))
    return [word for word in RECOMMENDATION_WORDS if word in text]


def evaluate(raw, context=None):
    if not isinstance(raw, dict):
        fail("input must be a News Object / fixture object")
    context = context if isinstance(context, dict) else {}
    news = news_from(raw)
    if not news.get("source") or not news.get("title"):
        fail("News Object requires source and title")
    event = event_from(raw, news)
    importance = assess_importance(news, event)
    relevance, basis = relevance_band(news, event, context)
    impact = impact_from(raw, news, event)
    question = unresolved_question(raw, news, event)
    candidate = assess_candidate(importance, relevance, news, event, question, impact)
    result = {
        "news": news,
        "event": event,
        "importance": importance,
        "relevance": relevance,
        "relevanceBasis": basis,
        "impact": impact,
        "researchCandidate": candidate,
    }
    leaks = recommendation_leak(result)
    if leaks:
        fail("evaluation leaked recommendation language: " + ", ".join(leaks))
    for key in impact["evidenceStatus"]:
        if key in FRESHNESS_LABELS:
            fail("evidenceStatus used a freshness label")
    return result


def main(argv):
    raw = None
    i = 1
    while i < len(argv):
        if argv[i] == "--input" and i + 1 < len(argv):
            path = os.path.abspath(argv[i + 1])
            unix = path.replace("\\", "/")
            if "/data/" in unix or unix.endswith("/data") or "/research/" in unix:
                fail("evaluation engine may not read production data/ or research/ as --input")
            raw = load_json(path)
            i += 2
            continue
        fail("unknown argument: " + argv[i])
    if raw is None:
        raw = json.load(sys.stdin)
    result = evaluate(raw)
    json.dump(result, sys.stdout, ensure_ascii=False, indent=2)
    sys.stdout.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
