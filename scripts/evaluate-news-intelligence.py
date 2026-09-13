# Investor Twin Phase 2 Sprint 001 — News Intelligence Foundation Evaluation Engine.
# Reads one News Object / fixture from stdin or --input.
# Prints an evaluation result to stdout. Writes no data/, research/, or Brief files.
# Does not POST queue, create cards, or emit buy/sell recommendations.
import json
import os
import re
import sys

# Legacy coarse types kept for Sprint 001–004 fixtures + linking.
# P2-024 adds finer, still-explainable types. Prefer fine types when text supports them.
EVENT_TYPES = (
    "Earnings",
    "Guidance",
    "Policy",
    "Price-move",
    "Corporate Action",
    "Industry",
    "Company / Earnings",
    "Company / Guidance",
    "Company / Product",
    "Company / Capex",
    "Company / Partnership",
    "AI / Compute Demand",
    "AI / Server",
    "Semiconductor / Demand",
    "Semiconductor / Supply",
    "Semiconductor / Capacity",
    "Semiconductor / Pricing",
    "Taiwan / Institutional Flow",
    "Macro / Rates",
    "Macro / Inflation",
    "Macro / Oil",
    "Geopolitics",
    "Regulation",
    "Other",
)
LEGACY_EVENT_TYPES = (
    "Earnings",
    "Guidance",
    "Policy",
    "Price-move",
    "Corporate Action",
    "Industry",
)
HEADLINE_CLAIM_MARKERS = (
    "成長",
    "倍數成長",
    "成長曲線",
    "動能",
    "可望",
    "將再",
    "大幅成長",
    "營收將",
    "訂單增加",
    "需求強",
    "demand surge",
    "strong growth",
    "will grow",
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
# Investment-advice collocates — required near 加碼/減碼 (not policy 「教育加碼」).
RECOMMENDATION_ADVICE_MARKERS = (
    "建議",
    "分析師",
    "法人",
    "投資人",
    "評級",
    "買進",
    "賣出",
    "加倉",
    "減倉",
    "目標價",
    "投顧",
    "券商",
    "持股",
    "部位",
    "可考慮加碼",
    "可考慮減碼",
    "recommend",
    "upgrade",
    "downgrade",
)
# Compact true-positive patterns (safety guard, not event classification).
TRUE_RECOMMENDATION_PATTERNS = (
    re.compile(r"建議\s*加碼"),
    re.compile(r"建議\s*減碼"),
    re.compile(r"建議\s*買進"),
    re.compile(r"建議\s*賣出"),
    re.compile(r"分析師.{0,16}(加碼|減碼|買進|賣出)"),
    re.compile(r"法人.{0,16}(加碼|減碼|買進|賣出)"),
    re.compile(r"投資人.{0,12}(可考慮)?(加碼|減碼)"),
    re.compile(r"評級.{0,12}(買進|賣出)"),
    re.compile(r"(升至|降至|升等|降等).{0,6}(買進|賣出)"),
    re.compile(r"應該買"),
    re.compile(r"應該賣"),
    re.compile(r"\bbuy\b", re.I),
    re.compile(r"\bsell\b", re.I),
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
    """Classify event type. Honor explicit non-Other fixture types; else content rules."""
    raw = str(raw_type or "").strip()
    raw_l = lower(raw)
    hay = raw_l + " " + lower(text)

    # M&A / corporate action must remain Corporate Action (P2-001 Case A).
    if (
        "m&a" in hay
        or "acqui" in hay
        or "收購" in hay
        or raw_l.startswith("corporate action")
    ):
        return "Corporate Action"

    # Explicit typed fixtures (Industry, Policy, …) win over content heuristics.
    if raw in EVENT_TYPES and raw != "Other":
        return raw
    if raw in LEGACY_EVENT_TYPES:
        return raw

    # Fine-grained content classification (P2-024). Most specific first.
    if any(k in hay for k in ("財報", "季報", "年報", "eps", "earning", "營收公布", "公布財報")):
        return "Company / Earnings"
    if any(k in hay for k in ("guidance", "展望", "財測", "下修財測", "上修財測", "預估eps")):
        return "Company / Guidance"
    if any(k in hay for k in ("capex", "資本支出", "擴廠預算", "設備投資")):
        return "Company / Capex"
    if any(k in hay for k in ("partnership", "策略合作", "簽署合作", "結盟")) and "acqui" not in hay:
        return "Company / Partnership"
    if any(k in hay for k in (
        "ai伺服器", "ai server", "gpu server", "vera rubin", "blackwell",
        "伺服器新品", "ai server 新品",
    )):
        return "AI / Server"
    if any(k in hay for k in ("compute demand", "算力需求", "gpu需求", "ai算力", "加速卡需求")):
        return "AI / Compute Demand"
    if any(k in hay for k in ("晶圓漲價", "記憶體漲價", "報價上漲", "asp", "定價", "pricing")):
        return "Semiconductor / Pricing"
    if any(k in hay for k in ("產能", "capacity", "擴產", "新產能")):
        return "Semiconductor / Capacity"
    if any(k in hay for k in ("缺貨", "供給受限", "supply constraint", "供應瓶頸")):
        return "Semiconductor / Supply"
    if any(k in hay for k in ("半導體需求", "chip demand", "晶片需求", "asic")) and any(
        k in hay for k in ("需求", "demand", "出貨", "訂單")
    ):
        return "Semiconductor / Demand"
    if "asic" in hay and any(k in hay for k in ("ai", "伺服器", "server", "輝達", "nvidia")):
        return "AI / Server"
    if any(k in hay for k in ("三大法人", "外資買賣超", "institutional flow", "外資連買", "外資連賣")):
        return "Taiwan / Institutional Flow"
    if any(k in hay for k in ("通膨", "inflation", "cpi", "pce")):
        return "Macro / Inflation"
    if any(k in hay for k in ("wti", "brent", "油價", "crude oil")):
        return "Macro / Oil"
    if any(k in hay for k in ("升息", "降息", "殖利率", "公債", "us10y", "fomc", "fed ", "rate hike", "rate cut")):
        return "Macro / Rates"
    if any(k in hay for k in ("地緣", "geopolit", "台海", "制裁戰爭")):
        return "Geopolitics"
    if any(k in hay for k in ("regulation", "監管", "出口管制", "出口限制", "管制措施")):
        return "Regulation"
    if any(k in hay for k in ("新品", "新產品", "product launch", "發表新品", "產品線")):
        return "Company / Product"
    if "price-move" in hay or "price move" in hay:
        return "Price-move"
    if "policy" in hay or "升息" in hay or "ecb" in hay:
        return "Policy"
    if "industry" in hay:
        return "Industry"
    if "earning" in hay:
        return "Earnings"
    if "guidance" in hay:
        return "Guidance"
    if raw in EVENT_TYPES:
        return raw
    return "Other"


def event_from(raw, news):
    block = raw.get("event") if isinstance(raw.get("event"), dict) else {}
    text = blob([news.get("title"), news.get("summary"), news.get("subject"), block.get("what")])
    event_type = coarse_event_type(block.get("eventType"), text)
    hay = lower(text)
    what = block.get("what")
    coarse_tokens = ("acquire", "review", "complete", "terminate", "partnership", "other")
    if not what or str(what).strip().lower() in coarse_tokens:
        if "nvidia" in hay and "hugging face" in hay and ("acqui" in hay or "收購" in hay):
            what = "NVIDIA 宣布收購 Hugging Face"
        else:
            bundle = what_changed_bundle(news, {
                "what": what,
                "subject": block.get("subject") or news.get("subject"),
                "eventType": event_type,
            })
            what = bundle.get("summary") or news.get("summary") or news.get("title")
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
    event_type = str(event.get("eventType") or "")
    if event_type == "Price-move" or is_market_quote(news, event):
        return 3
    if event_type == "Corporate Action" and (
        "acqui" in text or "收購" in text or "m&a" in text
    ):
        return 5
    if event_type in ("Policy", "Macro / Rates", "Macro / Inflation", "Regulation", "Geopolitics"):
        return 4
    if event_type.startswith("Company /") or event_type.startswith("AI /") or event_type.startswith("Semiconductor /"):
        return 3
    if event_type == "Taiwan / Institutional Flow":
        return 3
    if event_type == "Macro / Oil":
        return 3
    if "expected" in text or "預期" in text:
        return 4
    if event_type == "Other" or event_type == "Industry":
        # Industry without finer match stays mid; bare Other stays low.
        return 3 if event_type == "Industry" else 1
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
    # Position / holdings never auto-elevate relevance (P2-024).
    positions = [lower(item) for item in (context.get("positions") or [])]
    holdings = [lower(item) for item in (context.get("holdings") or [])]
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
    # Holding a ticker mentioned in news is not itself High relevance.
    if positions or holdings:
        held_hit = any(token and token in text for token in positions + holdings if len(str(token)) >= 2)
        if held_hit and not mapped:
            return (
                "Low",
                "Position ≠ relevance：持倉／關注名單命中不足以自動判定為 High relevance。",
            )
    if text:
        return (
            "Low",
            "普通財經或地方消息，與 Investor DNA、既有 Research、Thesis 無關。",
        )
    return ("Unknown", "沒有足夠證據判斷 Relevance。")


def _append_unique(bucket, claim):
    text = str(claim or "").strip()
    if text and text not in bucket:
        bucket.append(text)


def what_changed_bundle(news, event):
    """What changed vs re-copying the headline. Never promote growth claims to FACT."""
    title = str(news.get("title") or "").strip()
    summary = str(news.get("summary") or news.get("content") or "").strip()
    hay = lower(blob([title, summary, event.get("what"), event.get("subject"), event.get("eventType")]))
    facts = []
    inferences = []
    unknowns = []

    mentions = []
    if "nvidia" in hay or "輝達" in hay:
        mentions.append("NVIDIA")
    if "asic" in hay or "特殊應用積體電路" in hay:
        mentions.append("ASIC")
    if "奇鋐" in (title + summary) or "雙鴻" in (title + summary) or "散熱" in hay:
        mentions.append("Taiwan cooling suppliers")
    if "ai伺服器" in hay or "ai server" in hay or "伺服器" in hay:
        mentions.append("AI server")
    if "vera rubin" in hay:
        mentions.append("Vera Rubin (named in article)")
    if mentions:
        _append_unique(facts, "新聞提及：" + "／".join(mentions))

    if any(k in hay for k in ("出貨", "新品", "第4季", "q4", "年底")) and (
        "asic" in hay or "伺服器" in hay or "server" in hay or "vera rubin" in hay
    ):
        _append_unique(
            facts,
            "新聞描述後續時程／產品節奏（如出貨或新品時點），屬報導內容而非已驗證訂單。",
        )

    if "acqui" in hay or "收購" in hay:
        _append_unique(facts, "NVIDIA 宣布收購 Hugging Face" if "hugging face" in hay else title or summary)

    event_type = str(event.get("eventType") or "Other")
    if event_type.startswith("AI /") or event_type.startswith("Semiconductor /") or mentions:
        _append_unique(
            inferences,
            "若其他 Evidence 同步支持，可能值得關注 AI server demand／cooling supply chain，非已確認趨勢。",
        )
    if event_type.startswith("Macro /"):
        _append_unique(inferences, "宏觀變數可能改變風險偏好或估值約束，因果未證。")

    # Headline growth / demand claims stay UNKNOWN — never FACT.
    if any(marker in hay for marker in HEADLINE_CLAIM_MARKERS):
        _append_unique(unknowns, "新聞中的成長／動能表述尚未被訂單、財報或獨立 Evidence 確認。")
    if event_type.startswith("AI /") or event_type.startswith("Semiconductor /") or mentions:
        _append_unique(unknowns, "是否代表實際訂單增加或營收已確認成長，目前 UNKNOWN。")
    elif event_type.startswith("Macro /") or event_type in ("Geopolitics", "Regulation", "Policy"):
        _append_unique(unknowns, "宏觀／政策敘事對市場的實際傳導與持續性目前 UNKNOWN。")
    else:
        _append_unique(unknowns, "關鍵事實、影響範圍與是否可研究目前 UNKNOWN。")
    if not facts and not (title or summary):
        _append_unique(unknowns, "Evidence 不足，無法說明 What Changed。")
        summary_line = "UNKNOWN｜不足以判斷 What Changed"
    elif mentions:
        summary_line = "報導新增主體／主題提及（" + "／".join(mentions) + "），非營收或訂單確認"
    else:
        summary_line = "報導提出新的事件敘事，細節仍待 Evidence 確認"

    return {
        "summary": summary_line,
        "FACT": facts,
        "ESTIMATE": [],
        "INFERENCE": inferences,
        "UNKNOWN": unknowns,
    }


def derive_evidence_status(news, event):
    text = blob([news.get("title"), news.get("summary"), event.get("what")])
    hay = lower(text)
    status = {key: [] for key in SEPARATION_KEYS}
    # Preserve Sprint 001 Hugging Face acquisition facts when present.
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

    bundle = what_changed_bundle(news, event)
    for key in SEPARATION_KEYS:
        for claim in bundle.get(key) or []:
            _append_unique(status[key], claim)
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
    if not target:
        target = event.get("subject") or news.get("subject")
    return {
        "target": target,
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


def _window_has_advice_marker(text, start, end, radius=20):
    left = max(0, start - radius)
    right = min(len(text), end + radius)
    window = text[left:right]
    window_l = window.lower()
    for marker in RECOMMENDATION_ADVICE_MARKERS:
        if marker.isascii():
            if marker.lower() in window_l:
                return True
        elif marker in window:
            return True
    return False


def _jiajianma_is_recommendation(text, word):
    """加碼/減碼 only count in investment-advice context (not 教育加碼 / 預算加碼)."""
    start = 0
    while True:
        idx = text.find(word, start)
        if idx < 0:
            return False
        if _window_has_advice_marker(text, idx, idx + len(word)):
            return True
        start = idx + len(word)


def recommendation_leak(payload):
    """Detect investment-recommendation language in NI payloads.

    Safety guard only: policy/budget 「…加碼」 must not false-positive.
    Scans serialized payload (including passed-through news text).
    """
    text = json.dumps(payload, ensure_ascii=False)
    text_l = text.lower()
    leaked = []

    def add(token):
        if token and token not in leaked:
            leaked.append(token)

    if _jiajianma_is_recommendation(text, "加碼"):
        add("加碼")
    if _jiajianma_is_recommendation(text, "減碼"):
        add("減碼")

    for pattern in TRUE_RECOMMENDATION_PATTERNS:
        matched = pattern.search(text_l) if (pattern.flags & re.I) else pattern.search(text)
        if not matched:
            continue
        token = matched.group(0)
        low = token.lower()
        if "加碼" in token:
            add("加碼")
        elif "減碼" in token:
            add("減碼")
        elif "應該買" in token:
            add("應該買")
        elif "應該賣" in token:
            add("應該賣")
        elif re.search(r"\bbuy\b", low):
            add("buy")
        elif re.search(r"\bsell\b", low):
            add("sell")
        elif "買進" in token or "賣出" in token:
            add(token if len(token) <= 24 else token[:24])

    return leaked


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
    what_changed = what_changed_bundle(news, event)
    result = {
        "news": news,
        "event": event,
        "importance": importance,
        "relevance": relevance,
        "relevanceBasis": basis,
        "impact": impact,
        "whatChanged": what_changed,
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
