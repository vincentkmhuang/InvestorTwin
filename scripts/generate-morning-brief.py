# Investor Twin 031-B — Morning Brief generator with Evidence selection.
# Reads data/evidence/. Writes data/morning-brief.json only.
# Never creates Research Cards, Queue, Thesis, Case, Decision, or Playbook.
import datetime
import json
import os
import re
import shutil
import sys

DATE_RE = re.compile(r"^(\d{4})-(\d{2})-(\d{2})$")
CANONICAL_FIELDS = (
    "date",
    "executiveSummary",
    "macroDecisionLens",
    "marketTemperature",
    "globalMarketAndNews",
    "taiwanMarketAndNews",
    "aiIndustryHighlights",
    "upcomingEvents",
    "today3Things",
    "opportunityRadar",
    "opportunityRadarException",
)
# Handbook Market Temperature instruments (Detect).
# Gold omitted: no reliable daily FRED USD spot series in current Evidence catalog.
TEMPERATURE_KEYS = {
    "Nasdaq": "Nasdaq",
    "SPX": "S&P 500",
    "DJI": "Dow",
    "SOX": "SOX",
    "Bitcoin": "Bitcoin",
    "WTI": "WTI",
    "Brent": "Brent",
    "VIX": "VIX",
}
MAX_EXEC_SIGNALS = 3
MAX_TODAY_THINGS = 3
MATERIAL_FLOW = 50.0
MARKET_STATUS_PREFIX = "市場狀態｜"
EVENT_PREFIX = "事件｜"
MAX_BRIEF_EVENTS = 3
MIN_EVENT_IMPORTANCE = 3
EVENT_RELEVANCE_OK = ("High", "Medium")
# Event freshness (P2-022 Step 2): keep Brief date-honest; never treat stale as "yesterday".
MAX_BRIEF_EVENT_AGE_DAYS = 7
ELEVATE_EVENT_MAX_AGE_DAYS = 2
HANDOFF_REL = os.path.join("data", "research-candidates-handoff.json")
TAIWAN_MARKERS = (
    "taiwan", "taiex", "twse", "tpex", "mops",
    "台股", "台灣", "臺灣", "台北", "臺北",
)


def relevance_ok(value):
    """Accept High/Medium; reject Low and Medium-Low compounds from existing NI labels."""
    text = str(value or "").strip()
    if text in EVENT_RELEVANCE_OK:
        return True
    lowered = text.lower()
    if "medium-low" in lowered or lowered.startswith("low"):
        return False
    if "high" in lowered:
        return True
    if "medium" in lowered and "low" not in lowered:
        return True
    return False

# Canonical Research Card ids only. Unmapped instruments stay unselected.
INSTRUMENT_MAP = {
    "US10Y": {
        "sections": ["macroDecisionLens", "globalMarketAndNews"],
        "priority": 100,
        "theme": "macro",
        "researchId": None,
    },
    "US30Y": {
        "sections": ["macroDecisionLens", "globalMarketAndNews"],
        "priority": 95,
        "theme": "macro",
        "researchId": None,
    },
    "SPX": {
        "sections": ["marketTemperature"],
        "priority": 72,
        "theme": "global",
        "researchId": None,
    },
    "Nasdaq": {
        "sections": ["marketTemperature"],
        "priority": 70,
        "theme": "global",
        "researchId": None,
    },
    "DJI": {
        "sections": ["marketTemperature"],
        "priority": 60,
        "theme": "global",
        "researchId": None,
    },
    "Brent": {
        "sections": ["marketTemperature"],
        "priority": 58,
        "theme": "commodity",
        "researchId": None,
    },
    "WTI": {
        "sections": ["marketTemperature"],
        "priority": 57,
        "theme": "commodity",
        "researchId": None,
    },
    "VIX": {
        "sections": ["marketTemperature"],
        "priority": 56,
        "theme": "commodity",
        "researchId": None,
    },
    "Bitcoin": {
        "sections": ["marketTemperature"],
        "priority": 54,
        "theme": "commodity",
        "researchId": None,
    },
    "SOX": {
        "sections": ["marketTemperature", "aiIndustryHighlights"],
        "priority": 90,
        "theme": "ai",
        "researchId": "hbm",
    },
    "TAIEX": {
        "sections": ["taiwanMarketAndNews", "macroDecisionLens"],
        "priority": 88,
        "theme": "taiwan",
        "researchId": None,
    },
    "TW_FOREIGN_NET": {
        "sections": ["taiwanMarketAndNews"],
        "priority": 80,
        "theme": "taiwan",
        "researchId": None,
    },
    "TW_TRUST_NET": {
        "sections": ["taiwanMarketAndNews"],
        "priority": 40,
        "theme": "taiwan",
        "researchId": None,
        "noise": True,
    },
    "TW_DEALER_NET": {
        "sections": ["taiwanMarketAndNews"],
        "priority": 25,
        "theme": "taiwan",
        "researchId": None,
        "noise": True,
    },
}
THEME_WHY = {
    # Legacy labels retained for tests that may still reference keys; not used as FACT.
    "macro": "長債利率是高估值與 AI 資產的估值約束。",
    "global": "美股指數反映全球風險偏好，不是個股研究結論。",
    "taiwan": "台股水位與外資流向會改變台灣半導體風險偏好。",
    "ai": "SOX 是半導體風險偏好，對既有 HBM 研究主題有關。",
    "commodity": "油價、波動率與 Bitcoin 是全球風險與通膨預期的市場狀態訊號。",
}
THEME_INFERENCE = {
    "macro": "在其他條件不變下，較高長債殖利率可能增加高估值／AI 資產的估值壓力。",
    "global": "美股指數水位反映風險偏好變化，但不等於個股或產業結論。",
    "taiwan": "台股水位與外資流向可能改變台灣半導體風險偏好，仍需對照個股與基本面。",
    "ai": "SOX 變動可能反映半導體風險偏好，與既有 HBM 研究主題相關但非因果證明。",
    "commodity": "油價／波動率／Bitcoin 變動可能反映風險與通膨預期，但不單獨決定投資結論。",
}
THEME_UNKNOWN = {
    "macro": "尚不足以確認殖利率變動是否導致 AI 資本支出週期轉弱。",
    "global": "尚不足以由指數 alone 推導個股或主題盈虧。",
    "taiwan": "尚不足以確認法人流向是否持續或已定調半導體週期。",
    "ai": "尚不足以由 SOX 單日／近期水位確認 HBM 供需轉折。",
    "commodity": "尚不足以由單一商品／波動指標推導總體政策路徑。",
}
THEME_LABEL = {
    "macro": "美債",
    "global": "美股",
    "taiwan": "台股",
    "ai": "半導體",
    "commodity": "商品／波動",
}


def fail(message):
    sys.stderr.write("BRIEF_GEN_FAIL\n" + message + "\n")
    raise SystemExit(2)


def load_json(path):
    with open(path, encoding="utf-8") as handle:
        return json.load(handle)


def write_json(path, payload):
    unix = os.path.normpath(path).replace("\\", "/")
    if not unix.endswith("data/morning-brief.json"):
        fail("generator may only write data/morning-brief.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    backup = os.path.join(os.path.dirname(path), "morning-brief.backup.json")
    try:
        with open(tmp, "w", encoding="utf-8", newline="\n") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
        loaded = load_json(tmp)
        for key in CANONICAL_FIELDS:
            if key not in loaded:
                fail("temp brief omitted canonical field: " + key)
        if os.path.isfile(path):
            shutil.copy2(path, backup)
        os.replace(tmp, path)
    finally:
        if os.path.isfile(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


def card_exists(root, research_id):
    if not research_id or not isinstance(research_id, str):
        return False
    rid = research_id.strip()
    if not rid or any(part in rid for part in ("\\", "/", "..")):
        return False
    return os.path.isfile(os.path.join(root, "research", rid, "card.json"))


def resolve_research_id(root, candidate=None, existing_id=None):
    rid = existing_id if existing_id else candidate
    if rid and card_exists(root, rid):
        return rid
    return None


def is_valued(item):
    if not isinstance(item, dict):
        return False
    if item.get("value") is None:
        return False
    as_of = item.get("asOf")
    return isinstance(as_of, str) and DATE_RE.match(as_of.strip()) is not None


def is_latest(item, brief_date):
    if not is_valued(item):
        return False
    status = item.get("status")
    if status in ("unavailable", "missing"):
        return False
    if status == "stale":
        return False
    return item.get("asOf") == brief_date


def is_material_flow(item):
    try:
        value = abs(float(item.get("value")))
    except (TypeError, ValueError):
        value = 0.0
    try:
        change = abs(float(item.get("changeDoD"))) if item.get("changeDoD") is not None else 0.0
    except (TypeError, ValueError):
        change = 0.0
    return value >= MATERIAL_FLOW or change >= MATERIAL_FLOW


def latest_history_item(history_dir):
    if not os.path.isdir(history_dir):
        return None
    dated = []
    for name in os.listdir(history_dir):
        if not name.endswith(".json"):
            continue
        stamp = name[:-5]
        if DATE_RE.match(stamp):
            dated.append(stamp)
    if not dated:
        return None
    stamp = sorted(dated)[-1]
    path = os.path.join(history_dir, stamp + ".json")
    try:
        return load_json(path)
    except Exception:
        return None


def latest_run_dir(root):
    runs = os.path.join(root, "data", "evidence", "runs")
    if not os.path.isdir(runs):
        return None
    names = sorted(
        name for name in os.listdir(runs)
        if name.startswith("run-") and os.path.isdir(os.path.join(runs, name))
    )
    if not names:
        return None
    return os.path.join(runs, names[-1])


def load_run_normalized(run_dir):
    out = {}
    if not run_dir:
        return out
    folder = os.path.join(run_dir, "normalized")
    if not os.path.isdir(folder):
        return out
    for name in os.listdir(folder):
        if not name.endswith(".json"):
            continue
        try:
            row = load_json(os.path.join(folder, name))
        except Exception:
            continue
        instrument = str(row.get("instrument") or name[:-5]).strip()
        if instrument:
            out[instrument] = row
    return out


def load_evidence(root):
    history_root = os.path.join(root, "data", "evidence", "history")
    merged = {}
    if os.path.isdir(history_root):
        for instrument in os.listdir(history_root):
            item = latest_history_item(os.path.join(history_root, instrument))
            if isinstance(item, dict):
                item.setdefault("instrument", instrument)
                merged[str(item.get("instrument") or instrument)] = item
    run_items = load_run_normalized(latest_run_dir(root))
    for instrument, row in run_items.items():
        status = str(row.get("status") or "")
        # Latest collect unavailable/missing must not keep older history as "current".
        if status in ("unavailable", "missing"):
            merged[instrument] = row
            continue
        current = merged.get(instrument)
        if current is None or not is_valued(current):
            merged[instrument] = row
        elif is_valued(row) and str(row.get("asOf") or "") >= str(current.get("asOf") or ""):
            merged[instrument] = row
    return merged


def fmt_number(value, unit):
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if unit == "percent":
        return f"{number:.2f}%"
    if unit == "TWD_hundred_million":
        return f"{number:.1f}億"
    if unit == "USD_per_barrel":
        return f"{number:.2f}"
    if unit == "USD":
        return f"{number:,.2f}"
    if number >= 100:
        return f"{number:,.2f}"
    return f"{number:.2f}"


def item_as_of(item):
    kind = item.get("asOfKind") or "close"
    return f"{item.get('asOf')} {kind}"


def market_status_item(title, source, research_id):
    """Honest market-status framing — not a fabricated news headline."""
    text = str(title or "").strip()
    if text and not text.startswith(MARKET_STATUS_PREFIX):
        text = MARKET_STATUS_PREFIX + text
    return {
        "title": text,
        "source": source,
        "researchId": research_id,
    }


def parse_event_date(value):
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    match = DATE_RE.match(text[:10])
    if match:
        return match.group(0)
    return None


def event_age_days(when, brief_date):
    """Calendar days between event when and Brief date. None if unparseable."""
    when_day = parse_event_date(when)
    brief_day = parse_event_date(brief_date)
    if when_day is None or brief_day is None:
        return None
    start = datetime.date.fromisoformat(when_day)
    end = datetime.date.fromisoformat(brief_day)
    return (end - start).days


def filter_upcoming_events(events, brief_date):
    """Keep only events on/after Brief date. Drop past and unparseable when."""
    kept = []
    for item in events or []:
        if not isinstance(item, dict):
            continue
        when = parse_event_date(item.get("when"))
        if when is None:
            continue
        if when < brief_date:
            continue
        kept.append(item)
    return kept


def load_handoff_payload(root):
    path = os.path.join(root, HANDOFF_REL)
    if not os.path.isfile(path):
        return None
    try:
        raw = load_json(path)
    except Exception:
        return None
    return raw if isinstance(raw, dict) else None


def _first_fact_claim(evaluation):
    impact = evaluation.get("impact") if isinstance(evaluation, dict) else None
    status = impact.get("evidenceStatus") if isinstance(impact, dict) else None
    facts = status.get("FACT") if isinstance(status, dict) else None
    if isinstance(facts, list):
        for row in facts:
            if isinstance(row, dict):
                claim = str(row.get("claim") or "").strip()
                if claim:
                    return claim, str(row.get("source") or "").strip()
            else:
                claim = str(row or "").strip()
                if claim:
                    return claim, ""
    refs = evaluation.get("evidenceRefs") if isinstance(evaluation, dict) else None
    if isinstance(refs, list):
        for row in refs:
            if not isinstance(row, dict):
                continue
            if str(row.get("class") or "").upper() != "FACT":
                continue
            claim = str(row.get("claim") or "").strip()
            if claim:
                return claim, str(row.get("source") or "").strip()
    return "", ""


def _what_changed_from(evaluation, event):
    for source in (evaluation, event):
        if not isinstance(source, dict):
            continue
        block = source.get("whatChanged")
        if isinstance(block, dict) and block:
            return block
    return {}


def _claim_texts(rows):
    out = []
    for row in rows or []:
        if isinstance(row, dict):
            claim = str(row.get("claim") or "").strip()
        else:
            claim = str(row or "").strip()
        if claim:
            out.append(claim)
    return out


def _event_region(event, news_rows, source):
    blob = " ".join([
        str(event.get("subject") or ""),
        str(event.get("eventType") or ""),
        str(event.get("what") or ""),
        str(source or ""),
    ]).lower()
    for row in news_rows or []:
        if not isinstance(row, dict):
            continue
        blob += " " + str(row.get("source") or "").lower()
        blob += " " + str(row.get("subject") or "").lower()
        blob += " " + str(row.get("title") or "").lower()
    for marker in TAIWAN_MARKERS:
        if marker.lower() in blob or marker in blob:
            return "taiwan"
    return "global"


def collect_evaluated_events(root, brief_date):
    """Read-only handoff adapter: evaluated Events only (Candidate not required)."""
    payload = load_handoff_payload(root)
    if not payload:
        return []
    events = [row for row in (payload.get("events") or []) if isinstance(row, dict)]
    evaluations = [row for row in (payload.get("evaluations") or []) if isinstance(row, dict)]
    news = [row for row in (payload.get("news") or []) if isinstance(row, dict)]
    events_by_id = {}
    for row in events:
        eid = str(row.get("eventId") or "").strip()
        if eid:
            events_by_id[eid] = row
    news_by_id = {}
    for row in news:
        nid = str(row.get("id") or "").strip()
        if nid:
            news_by_id[nid] = row

    packets = []
    for evaluation in evaluations:
        event_ref = str(evaluation.get("eventRef") or "").strip()
        if not event_ref:
            continue
        event = events_by_id.get(event_ref)
        if not event:
            continue
        when = parse_event_date(event.get("when"))
        if when is None:
            continue
        # Future events must not appear as Yesterday / historical Brief events.
        if when > brief_date:
            continue
        age = event_age_days(when, brief_date)
        if age is None or age > MAX_BRIEF_EVENT_AGE_DAYS:
            # Stale vs Brief date: do not hard-insert old fixture/events as current news.
            continue
        try:
            importance = int(evaluation.get("importance"))
        except (TypeError, ValueError):
            continue
        relevance = str(evaluation.get("relevance") or "").strip()
        # High-relevance events may still have thin importance from evaluate heuristics.
        if importance < MIN_EVENT_IMPORTANCE and "high" not in relevance.lower():
            continue
        if not relevance_ok(relevance):
            continue

        news_rows = []
        for ref in event.get("newsRefs") or []:
            item = news_by_id.get(str(ref).strip())
            if item:
                news_rows.append(item)
        fact_claim, fact_source = _first_fact_claim(evaluation)
        subject = str(event.get("subject") or "").strip()
        what = str(event.get("what") or "").strip()
        event_type = str(event.get("eventType") or "").strip()
        what_changed = _what_changed_from(evaluation, event)
        wc_summary = str(what_changed.get("summary") or "").strip()
        # Prefer structured understanding over subject:other.
        if subject and event_type and wc_summary:
            fact_title = f"{subject}｜{event_type}｜{wc_summary}"
        elif subject and event_type and what and what.lower() not in ("other", "unknown"):
            fact_title = f"{subject}｜{event_type}｜{what}"
        elif fact_claim:
            fact_title = fact_claim
            if subject and event_type and fact_claim == what:
                fact_title = f"{subject}｜{event_type}｜{fact_claim}"
        elif subject and what:
            fact_title = f"{subject}：{what}"
            if event_type:
                fact_title = f"{fact_title}（{event_type}）"
        else:
            continue

        why = str(evaluation.get("relevanceBasis") or "").strip()
        if not why:
            impact = evaluation.get("impact") if isinstance(evaluation.get("impact"), dict) else {}
            target = str(impact.get("target") or "").strip()
            direction = str(impact.get("direction") or "").strip()
            strength = str(impact.get("strength") or "").strip()
            bits = [bit for bit in (target, direction, strength) if bit]
            why = "／".join(bits)
        if not why:
            continue

        source = fact_source
        if not source and news_rows:
            source = str(news_rows[0].get("source") or "").strip()
        if not source:
            source = "Event"
        # Production must not promote Acceptance Fixture rows as live news.
        if source.strip().lower() == "acceptance fixture":
            continue

        url = ""
        published_time = ""
        news_title = ""
        if news_rows:
            url = str(news_rows[0].get("url") or "").strip()
            published_time = str(news_rows[0].get("publishedTime") or "").strip()
            news_title = str(news_rows[0].get("title") or "").strip()

        # Candidate eligibility is intentionally ignored — Event ≠ Candidate.
        packets.append({
            "eventId": event_ref,
            "when": when,
            "ageDays": age,
            "subject": subject,
            "what": what,
            "eventType": event_type,
            "whatChanged": what_changed,
            "importance": importance,
            "relevance": relevance,
            "why": why,
            "factTitle": fact_title,
            "newsTitle": news_title or None,
            "source": source,
            "url": url or None,
            "publishedTime": published_time or None,
            "region": _event_region(event, news_rows, source),
            "impact": evaluation.get("impact") if isinstance(evaluation.get("impact"), dict) else {},
        })

    packets.sort(key=lambda row: (
        -_event_rank_score(row),
        -int(row.get("importance") or 0),
        row.get("when") or "",
        row.get("eventId") or "",
    ))
    return packets[:MAX_BRIEF_EVENTS]


def _event_rank_score(packet):
    """Investment relevance × evidence strength × freshness for Brief selection."""
    importance = int(packet.get("importance") or 0)
    relevance = str(packet.get("relevance") or "").strip().lower()
    rel_w = 3 if "high" in relevance else (2 if "medium" in relevance else 1)
    age = int(packet.get("ageDays") if packet.get("ageDays") is not None else 99)
    fresh_w = 3 if age <= 1 else (2 if age <= 3 else 1)
    return importance * rel_w * fresh_w


def _reportage_fact(claim):
    """Downgrade outcome-sounding claims to reportage FACT (media said X)."""
    text = str(claim or "").strip()
    if not text:
        return None
    lower = text.lower()
    outcome_markers = (
        "已經", "已確認", "營收", "訂單", "成長", "需求增加", "confirm", "confirmed",
        "revenue", "order", "grew", "growth",
    )
    if any(marker in text or marker in lower for marker in outcome_markers):
        return f"該報導提及／主張：{text}（屬報導內容，非已驗證商業結果）"
    if text.startswith("報導") or text.startswith("該報導") or "新聞提及" in text:
        return text
    return f"該報導提及：{text}"


def build_event_intelligence(packet, brief_date, by_id=None):
    """Structured event interpretation for Brief (Event ≠ Candidate)."""
    by_id = by_id or {}
    what_changed = packet.get("whatChanged") if isinstance(packet.get("whatChanged"), dict) else {}
    impact = packet.get("impact") if isinstance(packet.get("impact"), dict) else {}
    status = impact.get("evidenceStatus") if isinstance(impact.get("evidenceStatus"), dict) else {}

    evidence_rows = []
    source = str(packet.get("source") or "").strip() or None
    if source:
        evidence_rows.append({"type": "FACT", "text": f"來源為 {source} 的已評估新聞事件。"})
    title = str(packet.get("newsTitle") or "").strip()
    if title:
        evidence_rows.append({
            "type": "FACT",
            "text": f"報導標題為「{title}」（標題本身不是投資結論）。",
        })
    if packet.get("url"):
        evidence_rows.append({"type": "FACT", "text": f"url={packet.get('url')}"})
    else:
        evidence_rows.append({"type": "UNKNOWN", "text": "url 未知。"})
    if packet.get("publishedTime"):
        evidence_rows.append({"type": "FACT", "text": f"publishedTime={packet.get('publishedTime')}"})
    else:
        evidence_rows.append({"type": "UNKNOWN", "text": "publishedTime 未知。"})

    for claim in (_claim_texts(what_changed.get("FACT")) or _claim_texts(status.get("FACT")) or [])[:2]:
        framed = _reportage_fact(claim)
        if framed:
            evidence_rows.append({"type": "FACT", "text": framed})
    wc_summary = str(what_changed.get("summary") or "").strip()
    if wc_summary:
        evidence_rows.append({
            "type": "FACT",
            "text": f"報導所稱的變化：{wc_summary}（非已驗證營收／訂單結果）。",
        })

    inferences = []
    why = str(packet.get("why") or "").strip()
    if why:
        inferences.append(f"為什麼值得注意：{why}")
    target = str(impact.get("target") or "").strip()
    direction = str(impact.get("direction") or "").strip()
    strength = str(impact.get("strength") or "").strip()
    investment = None
    if target and direction:
        strength_bit = strength or "UNKNOWN"
        investment = (
            f"對「{target}」方向 {direction}（強度 {strength_bit}）；非買賣建議。"
        )
        inferences.append(f"投資意涵：{investment}")
    for claim in (_claim_texts(what_changed.get("INFERENCE")) or _claim_texts(status.get("INFERENCE")) or [])[:1]:
        inferences.append(claim)

    unknowns = []
    for claim in (_claim_texts(what_changed.get("UNKNOWN")) or _claim_texts(status.get("UNKNOWN")) or [])[:2]:
        unknowns.append(claim)
    if not unknowns:
        unknowns.append("目前尚無營收／訂單／財報資料確認實際商業結果。")
    if not why:
        unknowns.append("缺少 relevanceBasis，無法完整說明投資相關性。")

    related_ids = []
    related = pick_items(by_id, ["SOX", "Nasdaq", "US10Y", "TAIEX"])
    if related:
        for item in related[:3]:
            line = fact_instrument_line(item)
            if line:
                evidence_rows.append({"type": "FACT", "text": line[5:] if line.startswith("FACT｜") else line})
                related_ids.append(item.get("instrument"))
        inferences.append(
            "事件與相關 Market Evidence 並陳，僅作背景；不得視為已證實因果。"
        )
        unknowns.append("事件與市場數值之間的穩定因果仍 UNKNOWN。")

    when_note = when_relative_note(packet.get("when"), brief_date)
    return {
        "event": {
            "eventId": packet.get("eventId"),
            "source": source,
            "title": title or None,
            "url": packet.get("url"),
            "publishedTime": packet.get("publishedTime"),
            "eventType": packet.get("eventType") or None,
            "subject": packet.get("subject") or None,
            "importance": packet.get("importance"),
            "relevance": packet.get("relevance"),
            "when": packet.get("when"),
            "whenNote": when_note,
        },
        "whatChanged": wc_summary or None,
        "evidence": evidence_rows,
        "inference": inferences,
        "unknown": unknowns,
        "investmentRelevance": investment,
        "relatedEvidence": related_ids,
    }


def event_brief_item(packet, compact=False, intelligence=None):
    """Honest Event item — never quote-as-news; never Candidate researchQuestion as what."""
    title = str(packet.get("newsTitle") or "").strip()
    fact_title = str(packet.get("factTitle") or "").strip()
    display = title or fact_title or "UNKNOWN"
    why = str(packet.get("why") or "").strip()
    if compact:
        # Compact section reference: what + why, not full executive narrative.
        item_title = EVENT_PREFIX + display
        if why:
            item_title = f"{EVENT_PREFIX}{display}｜為何注意：{why}"
    else:
        item_title = EVENT_PREFIX + (fact_title or display)
    item = {
        "title": item_title,
        "source": packet.get("source"),
        "researchId": None,
        "eventRef": packet.get("eventId"),
        "kind": "event",
        "when": packet.get("when"),
        "whyItMatters": why or None,
        "importance": packet.get("importance"),
        "relevance": packet.get("relevance"),
        "eventType": packet.get("eventType") or None,
        "subject": packet.get("subject") or None,
        "newsTitle": packet.get("newsTitle"),
    }
    if packet.get("url"):
        item["url"] = packet["url"]
    if packet.get("publishedTime"):
        item["publishedTime"] = packet["publishedTime"]
    if intelligence:
        item["intelligence"] = intelligence
    return item


def event_macro_lens_line(packet):
    """Investment observation for Macro Decision Lens — distinct from Executive what+why.

    Uses impact target/direction/strength plus relevance/subject/eventType already on the
    Event packet. Never restates factTitle+why. Never emits researchQuestion as Event fact.
    Returns None to omit when a honest distinct lens cannot be formed.
    """
    impact = packet.get("impact") if isinstance(packet.get("impact"), dict) else {}
    target = str(impact.get("target") or "").strip()
    direction = str(impact.get("direction") or "").strip()
    strength = str(impact.get("strength") or "").strip()
    relevance = str(packet.get("relevance") or "").strip()
    event_type = str(packet.get("eventType") or "").strip()
    subject = str(packet.get("subject") or "").strip()
    fact_title = str(packet.get("factTitle") or "").strip()
    why = str(packet.get("why") or "").strip()

    # Need a real observation angle; otherwise omit rather than duplicate Executive.
    if not target or not direction:
        return None

    core = f"對「{target}」的影響方向為 {direction}"
    qualifiers = []
    if strength:
        qualifiers.append(f"強度 {strength}")
    if relevance:
        qualifiers.append(f"relevance {relevance}")
    if qualifiers:
        core += "（" + "；".join(qualifiers) + "）"

    ctx_bits = []
    if subject:
        ctx_bits.append(subject)
    if event_type:
        ctx_bits.append(event_type)

    line = "觀察角度：" + core
    if ctx_bits:
        line += "；標的脈絡 " + "／".join(ctx_bits)
    line += "。此為投資觀察角度，非結論、非買賣建議。"

    # Dedup / honesty: must not collapse into Executive factTitle + why.
    if fact_title and fact_title in line:
        return None
    if why and why in line:
        return None
    return line


def evidence_stamp(items, unit_fallback="index", max_bits=3):
    bits = format_group(items, unit_fallback)[:max_bits]
    if not bits:
        return ""
    return "；".join(bits)


def carry_linked_items(raw_items, root):
    kept = []
    for item in raw_items or []:
        if not isinstance(item, dict):
            continue
        rid = item.get("researchId")
        if isinstance(rid, str):
            rid = rid.strip() or None
        else:
            rid = None
        if not rid or not card_exists(root, rid):
            continue
        title = str(item.get("title") or "")
        if "unavailable" in title.lower() or "missing" in title.lower():
            continue
        out = {key: value for key, value in item.items() if key != "cardRef"}
        out["researchId"] = rid
        kept.append(out)
    return kept


def radar_ids(root):
    path = os.path.join(root, "data", "opportunity-radar.json")
    ids = []
    if os.path.isfile(path):
        try:
            raw = load_json(path)
        except Exception:
            raw = None
        items = raw.get("items") if isinstance(raw, dict) else raw
        for item in items or []:
            if isinstance(item, str):
                rid = item.strip()
            elif isinstance(item, dict):
                rid = str(item.get("id") or item.get("researchId") or "").strip()
            else:
                rid = ""
            if card_exists(root, rid) and rid not in ids:
                ids.append(rid)
    return ids


def classify_evidence(root, instrument, row, brief_date):
    mapping = INSTRUMENT_MAP.get(instrument)
    decision = {
        "instrument": instrument,
        "selected": False,
        "priority": 0,
        "sections": [],
        "theme": None,
        "researchId": None,
        "latest": False,
        "reason": None,
        "row": row if isinstance(row, dict) else {},
    }
    if mapping is None:
        decision["reason"] = "unmapped"
        return decision
    if not is_valued(row):
        decision["reason"] = "not_valued"
        return decision
    status = row.get("status")
    if status in ("unavailable", "missing"):
        decision["reason"] = status
        return decision
    if mapping.get("noise") and not is_material_flow(row):
        decision["reason"] = "noise"
        return decision

    latest = is_latest(row, brief_date)
    decision["selected"] = True
    decision["priority"] = mapping["priority"]
    decision["sections"] = list(mapping["sections"])
    decision["theme"] = mapping["theme"]
    decision["researchId"] = resolve_research_id(root, mapping.get("researchId"))
    decision["latest"] = latest
    decision["reason"] = "selected" if latest else "dated"
    return decision


def select_evidence(root, evidence, brief_date):
    selected = []
    excluded = []
    for instrument in sorted(evidence.keys()):
        decision = classify_evidence(root, instrument, evidence.get(instrument) or {}, brief_date)
        if decision["selected"]:
            selected.append(decision)
        else:
            excluded.append(decision)
    selected.sort(key=lambda item: (-item["priority"], item["instrument"]))
    return selected, excluded


def selected_map(selected):
    return {item["instrument"]: item for item in selected}


def in_section(decision, section):
    return section in (decision.get("sections") or [])


def theme_items(selected, theme, latest_only=False):
    out = []
    for item in selected:
        if item.get("theme") != theme:
            continue
        if latest_only and not item.get("latest"):
            continue
        out.append(item)
    return out


def format_group(items, unit_fallback="index"):
    bits = []
    for item in items:
        row = item["row"]
        unit = row.get("unit") or unit_fallback
        number = fmt_number(row.get("value"), unit)
        if number is None:
            continue
        label = item["instrument"]
        bits.append(f"{label} {number}（{as_of_stamp(item)}）")
    return bits


def as_of_stamp(item):
    as_of = item["row"].get("asOf")
    if item.get("latest"):
        return f"asOf {as_of}"
    return f"asOf {as_of}，非最新"


def fact_instrument_line(item):
    """FACT line for one Evidence instrument — value + asOf + source only."""
    row = item.get("row") if isinstance(item.get("row"), dict) else {}
    instrument = item.get("instrument") or row.get("instrument") or "UNKNOWN"
    unit = row.get("unit") or "index"
    number = fmt_number(row.get("value"), unit)
    if number is None:
        return None
    source = str(row.get("sourceId") or "UNKNOWN").strip() or "UNKNOWN"
    as_of = str(row.get("asOf") or "UNKNOWN").strip() or "UNKNOWN"
    line = f"FACT｜{instrument}={number}（asOf {as_of}；source {source}"
    if not item.get("latest"):
        line += "；非 Brief 日最新"
    line += "）"
    change = row.get("changeDoD")
    if change is not None:
        try:
            line += f"；changeDoD={float(change):.4g}"
        except (TypeError, ValueError):
            pass
    return line


def item_change_dod(item):
    row = item.get("row") if isinstance(item.get("row"), dict) else {}
    try:
        return float(row.get("changeDoD"))
    except (TypeError, ValueError):
        return None


def change_direction(item):
    value = item_change_dod(item)
    if value is None:
        return "unknown"
    if value > 0:
        return "up"
    if value < 0:
        return "down"
    return "flat"


def pick_items(by_id, instruments):
    out = []
    for name in instruments:
        hit = by_id.get(name)
        if hit and is_valued(hit.get("row") or {}):
            out.append(hit)
    return out


def relationship_score(left_items, right_items):
    if not left_items or not right_items:
        return 0.0
    total = 0.0
    any_change = False
    for item in list(left_items) + list(right_items):
        change = item_change_dod(item)
        if change is None:
            continue
        any_change = True
        total += abs(change)
    return total if any_change else 0.5


def describe_dirs(items):
    dirs = [change_direction(item) for item in items]
    if not dirs or all(d == "unknown" for d in dirs):
        return "方向 UNKNOWN"
    known = [d for d in dirs if d != "unknown"]
    if known and all(d == "up" for d in known):
        return "上升"
    if known and all(d == "down" for d in known):
        return "回落"
    if "up" in dirs and "down" in dirs:
        return "分化"
    return "持平／混合"


def interpret_cross_relationship(name, left_items, right_items, left_label, right_label):
    """FACT/INFERENCE/UNKNOWN for paired Evidence. Never asserts unproven causation."""
    if not left_items or not right_items:
        return {
            "id": name,
            "score": 0.0,
            "text": f"UNKNOWN｜{left_label}×{right_label} 缺少一側 Evidence，無法建立關係解讀。",
            "ok": False,
        }
    facts = []
    for item in list(left_items) + list(right_items):
        line = fact_instrument_line(item)
        if line:
            facts.append(line)
    score = relationship_score(left_items, right_items)
    left_dir = describe_dirs(left_items)
    right_dir = describe_dirs(right_items)
    if left_dir == "上升" and right_dir == "上升":
        inference = (
            f"INFERENCE｜{left_label}與{right_label}同期皆偏強／上升；"
            f"目前資料未顯示一方主導另一方全面惡化，因果未證。"
        )
    elif left_dir == "上升" and right_dir == "回落":
        inference = (
            f"INFERENCE｜{left_label}上升與{right_label}回落同期出現；"
            f"可能存在壓力並陳，但不足以證明因果。"
        )
    elif left_dir == "回落" and right_dir == "上升":
        inference = (
            f"INFERENCE｜{left_label}回落與{right_label}上升同期出現；"
            f"市場尚未呈現單向一致的風險偏好惡化，因果未證。"
        )
    elif left_dir == "回落" and right_dir == "回落":
        inference = (
            f"INFERENCE｜{left_label}與{right_label}同期偏弱；"
            f"風險偏好可能同步降溫，仍非因果證明。"
        )
    else:
        inference = (
            f"INFERENCE｜{left_label}（{left_dir}）與{right_label}（{right_dir}）並陳；"
            f"關係可觀察，因果未證。"
        )
    unknown = (
        f"UNKNOWN｜尚不足以確認{left_label}與{right_label}之間是否存在穩定因果，"
        f"亦不足以判定市場 regime 已改變。"
    )
    text = f"{left_label}×{right_label}：" + "；".join(facts) + "。" + inference + unknown
    return {"id": name, "score": score, "text": text, "ok": True, "facts": facts}


def build_cross_relationships(by_id):
    specs = [
        ("rates_equity", ["US10Y", "US30Y"], ["Nasdaq", "SPX", "SOX"], "美債利率", "美股／半導體"),
        ("sox_rates", ["SOX", "Nasdaq"], ["US10Y", "US30Y"], "半導體／Nasdaq", "美債利率"),
        ("taiwan_sox", ["TAIEX"], ["SOX"], "台股", "SOX"),
        ("oil_rates", ["WTI", "Brent"], ["US10Y"], "油價", "美債利率"),
        ("vix_equity", ["VIX"], ["Nasdaq", "SPX"], "VIX", "美股"),
        ("btc_risk", ["Bitcoin"], ["VIX", "Nasdaq"], "Bitcoin", "風險偏好（VIX／Nasdaq）"),
    ]
    out = []
    for name, left_names, right_names, left_label, right_label in specs:
        left = pick_items(by_id, left_names)[:2]
        right = pick_items(by_id, right_names)[:2]
        out.append(interpret_cross_relationship(name, left, right, left_label, right_label))
    return out


def interpret_taiwan_cross(by_id):
    taiex = pick_items(by_id, ["TAIEX"])
    sox = pick_items(by_id, ["SOX"])
    flow = pick_items(by_id, ["TW_FOREIGN_NET"])
    if not taiex:
        return "UNKNOWN｜缺少 TAIEX Evidence，無法形成台股關係解讀。"
    if not sox:
        facts = [fact_instrument_line(item) for item in taiex + flow]
        facts = [line for line in facts if line]
        return "；".join(facts) + "。UNKNOWN｜缺少 SOX Evidence，無法判斷台股與全球半導體同步程度。"
    text = interpret_cross_relationship("taiwan_sox", taiex, sox, "台股", "SOX")["text"]
    if flow:
        flow_facts = [fact_instrument_line(item) for item in flow]
        flow_facts = [line for line in flow_facts if line]
        flow_dir = describe_dirs(flow)
        if flow_facts:
            text += " " + "；".join(flow_facts) + "。"
        text += (
            f"INFERENCE｜外資流向（{flow_dir}）可作為台股風險偏好的輔助訊號，非持續性證明。"
            f"UNKNOWN｜外資單日／近期淨額是否代表持續風險偏好變化仍不明。"
        )
    else:
        text += "UNKNOWN｜缺少外資／三大法人 Evidence，流向解讀不可用。"
    return text


def interpret_global_cross(relationships):
    preferred = ["rates_equity", "vix_equity", "oil_rates", "btc_risk"]
    by_name = {row["id"]: row for row in relationships if row.get("ok")}
    bits = []
    for name in preferred:
        row = by_name.get(name)
        if row:
            bits.append(row["text"])
        if len(bits) >= 2:
            break
    if not bits:
        return "UNKNOWN｜全球跨 Evidence 關係不足，僅能參考市場狀態數值。"
    return " ".join(bits)


def interpret_constraint_lens(by_id, relationships):
    rates = pick_items(by_id, ["US10Y", "US30Y"])
    equity = pick_items(by_id, ["Nasdaq", "SPX", "SOX"])
    oil = pick_items(by_id, ["WTI", "Brent"])
    vix = pick_items(by_id, ["VIX"])
    facts = []
    for item in rates[:2] + equity[:2] + oil[:1] + vix[:1]:
        line = fact_instrument_line(item)
        if line:
            facts.append(line[5:] if line.startswith("FACT｜") else line)
    if not facts:
        return ["UNKNOWN｜缺少 Rates／Equity／Oil／VIX Evidence，無法判斷主要 constraint。"]
    rates_dir = describe_dirs(rates) if rates else "UNKNOWN"
    equity_dir = describe_dirs(equity) if equity else "UNKNOWN"
    vix_dir = describe_dirs(vix) if vix else "UNKNOWN"
    oil_dir = describe_dirs(oil) if oil else "UNKNOWN"
    if rates and equity and rates_dir == "上升" and equity_dir == "上升":
        constraint = (
            "INFERENCE｜目前最大 constraint 傾向為高／上升的長債利率；"
            "但美股／半導體同期仍偏強，顯示約束存在卻未必已主導風險偏好。"
        )
    elif rates and equity and rates_dir == "上升" and equity_dir == "回落":
        constraint = (
            "INFERENCE｜長債上升與股市回落同期，利率約束可能正在被定價；"
            "仍不足以稱為已確認的 regime 切換。"
        )
    elif rates:
        constraint = (
            "INFERENCE｜目前最清晰的估值約束來自長債利率水準"
            f"（美債方向 {rates_dir}）；這是約束條件，不是已實現的全面殺估值證明。"
        )
    else:
        constraint = "UNKNOWN｜尚不足以指出單一最大 constraint。"
    regime = (
        "UNKNOWN｜目前 Evidence 不足以確認市場 regime 是否已改變"
        f"（VIX {vix_dir}；油價 {oil_dir}）。"
    )
    lens = [
        "FACT｜Constraint 檢視：" + "；".join(facts[:6]) + "。",
        constraint,
        regime,
    ]
    return lens


def when_relative_note(when, brief_date):
    """Honest relative timing from Brief date + when. Never invent 昨天 for old events."""
    age = event_age_days(when, brief_date)
    when_day = parse_event_date(when) or "UNKNOWN"
    if age is None:
        return f"when {when_day}"
    if age == 0:
        return f"when {when_day}（Brief 當日／Today）"
    if age == 1:
        return f"when {when_day}（Brief 前一日／Previous trading day）"
    if age <= 3:
        return f"when {when_day}（Recent；距 Brief {age} 日）"
    return f"when {when_day}（Background；距 Brief {age} 日）"


def interpret_market_block(theme, items):
    """Evidence-based market interpretation with explicit labels."""
    label = THEME_LABEL.get(theme) or theme
    facts = []
    for item in items[:2]:
        line = fact_instrument_line(item)
        if line:
            facts.append(line)
    if not facts:
        return (
            f"{label}｜UNKNOWN｜沒有可用數值 Evidence 可形成市場解讀。",
            "UNKNOWN",
        )
    inference = THEME_INFERENCE.get(theme) or "市場狀態可能影響風險偏好，但因果未證。"
    unknown = THEME_UNKNOWN.get(theme) or "尚不足以形成投資結論。"
    rid = None
    for item in items:
        if item.get("researchId"):
            rid = item["researchId"]
            break
    link = f" 既有研究卡 {rid}。" if rid else ""
    text = (
        f"{label}重要變化：{'；'.join(facts)}。"
        f"INFERENCE｜{inference}{link}"
        f"UNKNOWN｜{unknown}"
    )
    return text, "INFERENCE"


def interpret_event_block(packet, brief_date, by_id=None):
    """Event interpretation prose: reportage FACT + INFERENCE + UNKNOWN (no outcome FACT)."""
    intel = build_event_intelligence(packet, brief_date, by_id=by_id)
    ev = intel.get("event") or {}
    when_note = ev.get("whenNote") or when_relative_note(packet.get("when"), brief_date)
    subject = str(ev.get("subject") or "").strip()
    event_type = str(ev.get("eventType") or "").strip()
    display = str(ev.get("title") or packet.get("factTitle") or "UNKNOWN").strip()
    bits = [
        f"重要變化：{EVENT_PREFIX}{display}（{when_note}；Event {ev.get('eventId')}）。",
    ]
    for row in intel.get("evidence") or []:
        kind = str(row.get("type") or "FACT").upper()
        text = str(row.get("text") or "").strip()
        if not text:
            continue
        if kind == "UNKNOWN":
            bits.append(f"UNKNOWN｜{text}")
        elif kind == "INFERENCE":
            bits.append(f"INFERENCE｜{text}")
        else:
            bits.append(f"FACT｜{text}")
    if subject:
        bits.append(f"FACT｜subject {subject}")
    if event_type:
        bits.append(f"FACT｜eventType {event_type}")
    for claim in intel.get("inference") or []:
        bits.append(f"INFERENCE｜{claim}")
    for claim in intel.get("unknown") or []:
        bits.append(f"UNKNOWN｜{claim}")
    return " ".join(bits)


def today_item(title, why, source, evidence_ids, research_id, evidence_note="", intelligence=None):
    # Attention-first: why is primary; quotes are supporting evidence.
    primary = (why or title or "").strip()
    support = (evidence_note or title or "").strip()
    text = primary
    if support and support != primary:
        text = primary.rstrip("。") + "。" + "證據：" + support
    item = {
        "title": primary,
        "text": text,
        "whyItMatters": why or primary,
        "source": source,
        "evidence": evidence_ids,
        "researchId": research_id,
    }
    if intelligence:
        item["intelligence"] = intelligence
        # Next research implication without buy/sell.
        next_bits = []
        for claim in intelligence.get("unknown") or []:
            next_bits.append(claim)
        if intelligence.get("investmentRelevance"):
            next_bits.append("下一步：核對相關 Evidence 是否同方向，非買賣訊號。")
        if next_bits:
            item["nextResearchImplication"] = next_bits[0]
    return item


def build_executive_summary(selected, elevate_packets=None, brief_date=None, relationships=None):
    """At most 3 messages; do not pad. Rank by relevance × evidence × impact × freshness."""
    blocks = []
    elevate_packets = elevate_packets or []
    relationships = relationships or []
    by_id = selected_map(selected)

    ranked_events = sorted(
        elevate_packets,
        key=lambda row: (-_event_rank_score(row), -int(row.get("importance") or 0)),
    )
    if ranked_events and brief_date:
        blocks.append(interpret_event_block(ranked_events[0], brief_date, by_id=by_id))

    ok_rows = [row for row in relationships if row.get("ok") and float(row.get("score") or 0) > 0]
    ok_rows.sort(key=lambda row: -float(row.get("score") or 0))
    seen_ids = set()
    for row in ok_rows:
        if len(blocks) >= MAX_EXEC_SIGNALS:
            break
        if row["id"] in seen_ids:
            continue
        if row["id"] == "sox_rates" and "rates_equity" in seen_ids:
            continue
        if row["id"] == "rates_equity" and "sox_rates" in seen_ids:
            continue
        seen_ids.add(row["id"])
        blocks.append(row["text"])

    blocks = blocks[:MAX_EXEC_SIGNALS]
    if not blocks:
        return "UNKNOWN｜今日沒有足夠的 investment-relevant Evidence 可形成跨資料解讀。", []
    lines = [f"{index}. {text}" for index, text in enumerate(blocks, start=1)]
    return "\n".join(lines), blocks


def build_today_things(selected, elevate_packets=None, brief_date=None, interpretation_blocks=None):
    """Reuse Executive / cross interpretations — no second engine. No padding to 3."""
    things = []
    by_id = selected_map(selected)
    elevate_packets = elevate_packets or []
    elevate_by_id = {p.get("eventId"): p for p in elevate_packets}

    for block in interpretation_blocks or []:
        if len(things) >= MAX_TODAY_THINGS:
            break
        text = str(block or "").strip()
        if not text:
            continue
        evidence_ids = []
        intelligence = None
        source = "Morning Brief interpretation"
        # Prefer linking the primary elevated event when exec block is event prose.
        for eid, packet in elevate_by_id.items():
            if eid and eid in text:
                evidence_ids.append(eid)
                source = packet.get("source") or source
                if brief_date:
                    intelligence = build_event_intelligence(packet, brief_date, by_id=by_id)
                    evidence_ids.extend(intelligence.get("relatedEvidence") or [])
                break
        # Cross-evidence blocks: attach mentioned instruments when present.
        for instrument in ("SOX", "Nasdaq", "US10Y", "US30Y", "TAIEX", "SPX", "VIX", "WTI"):
            if instrument in text and instrument not in evidence_ids:
                evidence_ids.append(instrument)
        things.append(today_item(
            text, text, source, evidence_ids, None,
            evidence_note="", intelligence=intelligence,
        ))
    if things:
        return things[:MAX_TODAY_THINGS]
    if elevate_packets and brief_date:
        packet = elevate_packets[0]
        intelligence = build_event_intelligence(packet, brief_date, by_id=by_id)
        text = interpret_event_block(packet, brief_date, by_id=by_id)
        evidence_ids = [packet.get("eventId")] + list(intelligence.get("relatedEvidence") or [])
        things.append(today_item(
            text, text, packet.get("source") or "Event",
            [eid for eid in evidence_ids if eid], None,
            evidence_note="", intelligence=intelligence,
        ))
    return things[:MAX_TODAY_THINGS]


def build_macro_lens(selected, elevate_packets=None, brief_date=None, relationships=None):
    """Constraint-focused lens from Rates×Equity×Oil×VIX — not fixed THEME_WHY."""
    by_id = selected_map(selected)
    relationships = relationships or build_cross_relationships(by_id)
    # Always keep FACT + constraint answer + regime UNKNOWN (do not truncate for exec cap).
    lens = list(interpret_constraint_lens(by_id, relationships))
    elevate_packets = elevate_packets or []
    if elevate_packets and brief_date:
        packet = elevate_packets[0]
        when_note = when_relative_note(packet.get("when"), brief_date)
        lens.insert(
            0,
            f"INFERENCE｜事件背景（{when_note}；{packet.get('eventId')}）"
            f"可納入觀察，但不可單獨定義 regime。"
            f"UNKNOWN｜事件與利率／股市關係的因果未證。",
        )
    return lens


def load_latest_run_meta(root):
    run_dir = latest_run_dir(root)
    if not run_dir:
        return None
    path = os.path.join(run_dir, "run.json")
    if not os.path.isfile(path):
        return None
    try:
        raw = load_json(path)
    except Exception:
        return None
    return raw if isinstance(raw, dict) else None


def resolve_run_date(root):
    meta = load_latest_run_meta(root)
    if not meta:
        fail("no Evidence run found; Brief date must come from this run, not max Evidence asOf")
    expected = meta.get("expectedAsOf")
    if isinstance(expected, str) and DATE_RE.match(expected.strip()):
        return expected.strip()
    fail("Evidence run missing expectedAsOf")


def build_brief(root, evidence, previous):
    date = resolve_run_date(root)
    valued = [item for item in evidence.values() if is_valued(item)]
    if not valued:
        fail("no valued Evidence asOf found")
    selected, excluded = select_evidence(root, evidence, date)
    by_id = selected_map(selected)

    temperature = {}
    for instrument, label in TEMPERATURE_KEYS.items():
        hit = by_id.get(instrument)
        if hit and in_section(hit, "marketTemperature"):
            number = fmt_number(hit["row"].get("value"), hit["row"].get("unit") or "index")
            if number is None:
                continue
            as_of = item_as_of(hit["row"])
            if not hit.get("latest"):
                as_of = as_of + "，非最新"
            temperature[label] = {
                "value": number,
                "asOf": as_of,
            }

    # Sprint 012 / P2-022 / P2-023 / P2-036: events + cross-evidence relationships.
    event_packets = collect_evaluated_events(root, date)
    elevate_packets = [
        packet for packet in event_packets
        if int(packet.get("ageDays") or 999) <= ELEVATE_EVENT_MAX_AGE_DAYS
    ]
    elevate_packets = sorted(
        elevate_packets,
        key=lambda row: (-_event_rank_score(row), -int(row.get("importance") or 0)),
    )
    elevated_ids = set()
    if elevate_packets:
        elevated_ids.add(elevate_packets[0]["eventId"])

    relationships = build_cross_relationships(by_id)
    lens = build_macro_lens(
        selected,
        elevate_packets=elevate_packets,
        brief_date=date,
        relationships=relationships,
    )

    # Global: rates remain market-status context; equities/oil/VIX live in Temperature.
    global_hits = [item for item in selected if in_section(item, "globalMarketAndNews")]
    macro_hits = [item for item in global_hits if item.get("theme") == "macro"]
    global_items = []
    if macro_hits:
        global_items.append(market_status_item(
            "美債：" + "、".join(format_group(macro_hits, "percent")),
            "Global",
            None,
        ))
    temp_owned = [label for label in ("Nasdaq", "S&P 500", "Dow", "SOX", "Bitcoin", "WTI", "Brent", "VIX") if label in temperature]
    if temp_owned:
        global_items.append(market_status_item(
            "指數／油價／波動詳見市場溫度（" + "、".join(temp_owned) + "）",
            "Global",
            None,
        ))
    for packet in event_packets:
        if packet["region"] != "global":
            continue
        intel = build_event_intelligence(packet, date, by_id=by_id)
        # Elevated events also appear here as compact refs (not full exec narrative).
        global_items.append(event_brief_item(
            packet,
            compact=(packet["eventId"] in elevated_ids),
            intelligence=intel if packet["eventId"] in elevated_ids else None,
        ))
    if macro_hits:
        global_summary = MARKET_STATUS_PREFIX + "；".join(format_group(macro_hits, "percent"))
        if temp_owned:
            global_summary += "；數值市場狀態見市場溫度。"
    elif temp_owned:
        global_summary = MARKET_STATUS_PREFIX + "美股／油價／波動數值見市場溫度。"
    else:
        global_summary = "全球市場沒有可選入 Brief 的最新 Evidence。"
    cross_global = interpret_global_cross(relationships)
    global_summary = (global_summary.rstrip("。") + "。" + cross_global) if global_summary else cross_global
    if any(packet["region"] == "global" for packet in event_packets):
        global_summary = global_summary.rstrip("。") + "；含已評估事件。"

    taiwan_hits = [item for item in selected if in_section(item, "taiwanMarketAndNews")]
    taiwan_items = []
    taiex = by_id.get("TAIEX")
    if taiex and in_section(taiex, "taiwanMarketAndNews"):
        number = fmt_number(taiex["row"].get("value"), "index")
        if number is not None:
            taiwan_items.append(market_status_item(
                f"TAIEX {number}（{as_of_stamp(taiex)}）",
                "台股",
                None,
            ))
    flow = [item for item in taiwan_hits if item["instrument"].startswith("TW_")]
    if flow:
        taiwan_items.append(market_status_item(
            "三大法人：" + "、".join(format_group(flow, "TWD_hundred_million")),
            "台股",
            None,
        ))
    for packet in event_packets:
        if packet["region"] != "taiwan":
            continue
        intel = build_event_intelligence(packet, date, by_id=by_id)
        taiwan_items.append(event_brief_item(
            packet,
            compact=(packet["eventId"] in elevated_ids),
            intelligence=intel if packet["eventId"] in elevated_ids else None,
        ))
    taiwan_bits = format_group(taiwan_hits, "index")
    taiwan_summary = (
        MARKET_STATUS_PREFIX + "；".join(taiwan_bits)
        if taiwan_bits else "台股沒有可選入 Brief 的 Evidence。"
    )
    taiwan_summary = taiwan_summary.rstrip("。") + "。" + interpret_taiwan_cross(by_id)
    if any(packet["region"] == "taiwan" for packet in event_packets):
        taiwan_summary = taiwan_summary.rstrip("。") + "；含已評估事件。"

    sox = by_id.get("SOX")
    ai_items = []
    # Prefer narrative carry-forward; keep one SOX Evidence link for 031-B, not a quote wall.
    if sox and in_section(sox, "aiIndustryHighlights"):
        number = fmt_number(sox["row"].get("value"), "index")
        if number is not None:
            ai_items.append({
                "title": f"SOX {number}（{as_of_stamp(sox)}）",
                "researchId": sox.get("researchId"),
            })

    prev = previous if isinstance(previous, dict) else {}
    # P2-023: do not carry stale narrative AI stories as if they were today's evidence.
    # Keep only current SOX Evidence line already added above.
    carried_ai = []
    ai_items.extend(carried_ai)

    events = filter_upcoming_events(
        carry_linked_items(prev.get("upcomingEvents"), root),
        date,
    )
    seen_titles = set()
    deduped_ai = []
    for item in ai_items:
        key = (item.get("title"), item.get("researchId"))
        if key in seen_titles:
            continue
        seen_titles.add(key)
        deduped_ai.append(item)

    summary, exec_blocks = build_executive_summary(
        selected,
        elevate_packets=elevate_packets,
        brief_date=date,
        relationships=relationships,
    )
    things = build_today_things(
        selected,
        elevate_packets=elevate_packets,
        brief_date=date,
        interpretation_blocks=exec_blocks,
    )

    return {
        "date": date,
        "executiveSummary": summary,
        "macroDecisionLens": lens,
        "marketTemperature": temperature,
        "globalMarketAndNews": {"summary": global_summary, "items": global_items},
        "taiwanMarketAndNews": {"summary": taiwan_summary, "items": taiwan_items},
        "aiIndustryHighlights": deduped_ai,
        "upcomingEvents": events,
        "today3Things": things,
        "opportunityRadar": radar_ids(root),
        "opportunityRadarException": False,
        "_selection": {
            "selected": [item["instrument"] for item in selected],
            "excluded": [item["instrument"] for item in excluded],
            "events": [packet["eventId"] for packet in event_packets],
        },
    }


def main(argv):
    root = os.getcwd()
    args = argv[1:]
    i = 0
    while i < len(args):
        if args[i] == "--root" and i + 1 < len(args):
            root = args[i + 1]
            i += 2
            continue
        fail("unknown argument: " + args[i])
    root = os.path.abspath(root)
    dest = os.path.join(root, "data", "morning-brief.json")
    previous = load_json(dest) if os.path.isfile(dest) else {}
    evidence = load_evidence(root)
    brief = build_brief(root, evidence, previous)
    selection = brief.pop("_selection", {})
    for key in CANONICAL_FIELDS:
        if key not in brief:
            fail("generator omitted canonical field: " + key)
    write_json(dest, brief)
    print("BRIEF_GEN_OK")
    print("date=" + brief["date"])
    print("runDate=" + brief["date"])
    print("dest=" + dest)
    print("instruments=" + ",".join(sorted(evidence.keys())))
    print("selected=" + ",".join(selection.get("selected") or []))
    print("excluded=" + ",".join(selection.get("excluded") or []))
    print("events=" + ",".join(selection.get("events") or []))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
