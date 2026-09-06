# Investor Twin 031-B — Morning Brief generator with Evidence selection.
# Reads data/evidence/. Writes data/morning-brief.json only.
# Never creates Research Cards, Queue, Thesis, Case, Decision, or Playbook.
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
# Handbook Market Temperature instruments (Detect). Bitcoin/Gold omitted until Evidence exists.
TEMPERATURE_KEYS = {
    "Nasdaq": "Nasdaq",
    "SPX": "S&P 500",
    "DJI": "Dow",
    "SOX": "SOX",
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
HANDOFF_REL = os.path.join("data", "research-candidates-handoff.json")
TAIWAN_MARKERS = (
    "taiwan", "taiex", "twse", "tpex", "mops",
    "台股", "台灣", "臺灣", "台北", "臺北",
)

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
    "macro": "長債利率是高估值與 AI 資產的估值約束。",
    "global": "美股指數反映全球風險偏好，不是個股研究結論。",
    "taiwan": "台股水位與外資流向會改變台灣半導體風險偏好。",
    "ai": "SOX 是半導體風險偏好，對既有 HBM 研究主題有關。",
    "commodity": "油價與波動率是全球風險與通膨預期的市場狀態訊號。",
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
        current = merged.get(instrument)
        if current is None or not is_valued(current):
            merged[instrument] = row
        elif is_valued(row) and str(row.get("asOf") or "") > str(current.get("asOf") or ""):
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
            if not isinstance(row, dict):
                continue
            claim = str(row.get("claim") or "").strip()
            if claim:
                return claim, str(row.get("source") or "").strip()
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
        try:
            importance = int(evaluation.get("importance"))
        except (TypeError, ValueError):
            continue
        relevance = str(evaluation.get("relevance") or "").strip()
        if importance < MIN_EVENT_IMPORTANCE:
            continue
        if relevance not in EVENT_RELEVANCE_OK:
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
        if fact_claim:
            fact_title = fact_claim
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

        # Candidate eligibility is intentionally ignored — Event ≠ Candidate.
        packets.append({
            "eventId": event_ref,
            "when": when,
            "subject": subject,
            "what": what,
            "eventType": event_type,
            "importance": importance,
            "relevance": relevance,
            "why": why,
            "factTitle": fact_title,
            "source": source,
            "region": _event_region(event, news_rows, source),
            "impact": evaluation.get("impact") if isinstance(evaluation.get("impact"), dict) else {},
        })

    packets.sort(key=lambda row: (-row["importance"], row["when"], row["eventId"]))
    return packets[:MAX_BRIEF_EVENTS]


def event_brief_item(packet):
    """Honest Event item — never quote-as-news; never Candidate researchQuestion as what."""
    return {
        "title": EVENT_PREFIX + packet["factTitle"],
        "source": packet["source"],
        "researchId": None,
        "eventRef": packet["eventId"],
        "kind": "event",
        "when": packet["when"],
        "whyItMatters": packet["why"],
        "importance": packet["importance"],
        "relevance": packet["relevance"],
    }


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


def today_item(title, why, source, evidence_ids, research_id, evidence_note=""):
    # Attention-first: why is primary; quotes are supporting evidence.
    primary = (why or title or "").strip()
    support = (evidence_note or title or "").strip()
    text = primary
    if support and support != primary:
        text = primary.rstrip("。") + "。" + "證據：" + support
    return {
        "title": primary,
        "text": text,
        "whyItMatters": why or primary,
        "source": source,
        "evidence": evidence_ids,
        "researchId": research_id,
    }


def build_executive_summary(selected):
    signals = []
    groups = [
        ("macro", theme_items(selected, "macro"), "percent"),
        ("taiwan", theme_items(selected, "taiwan"), None),
        ("ai", theme_items(selected, "ai"), "index"),
        ("global", theme_items(selected, "global"), "index"),
    ]
    for theme, items, unit in groups:
        if len(signals) >= MAX_EXEC_SIGNALS:
            break
        if not items:
            continue
        why = THEME_WHY.get(theme) or ""
        if not why:
            continue
        fallback = unit or (items[0]["row"].get("unit") or "index")
        stamp = evidence_stamp(items, fallback, max_bits=2)
        ids = "/".join(item["instrument"] for item in items)
        label = THEME_LABEL.get(theme) or theme
        rid = None
        for item in items:
            if item.get("researchId"):
                rid = item["researchId"]
                break
        link = f" 對既有研究卡 {rid}。" if rid else ""
        evidence_bit = f"Evidence {ids}"
        if stamp:
            line = f"{label}：{why}{link}（{evidence_bit}；{stamp}）。"
        else:
            line = f"{label}：{why}{link}（{evidence_bit}）。"
        signals.append(line)

    signals = signals[:MAX_EXEC_SIGNALS]
    if not signals:
        return "今日沒有足夠的 investment-relevant Evidence。", []
    lines = [f"{index}. {text}" for index, text in enumerate(signals, start=1)]
    return "\n".join(lines), signals


def build_today_things(selected):
    things = []
    groups = [
        ("macro", theme_items(selected, "macro"), "percent"),
        ("taiwan", theme_items(selected, "taiwan"), None),
        ("ai", theme_items(selected, "ai"), "index"),
        ("global", theme_items(selected, "global"), "index"),
    ]
    for theme, items, unit in groups:
        if len(things) >= MAX_TODAY_THINGS:
            break
        if not items:
            continue
        why = THEME_WHY.get(theme) or ""
        if not why:
            continue
        fallback = unit or (items[0]["row"].get("unit") or "index")
        stamp = evidence_stamp(items, fallback, max_bits=2)
        sources = []
        for item in items:
            source_id = item["row"].get("sourceId")
            if source_id and source_id not in sources:
                sources.append(source_id)
        rid = None
        for item in items:
            if item.get("researchId"):
                rid = item["researchId"]
                break
        things.append(today_item(
            why,
            why,
            "；".join(sources),
            [item["instrument"] for item in items],
            rid,
            evidence_note=stamp,
        ))
    return things[:MAX_TODAY_THINGS]


def build_macro_lens(selected):
    """Why-oriented lens with Evidence ids — not a third raw-quote wall."""
    lens = []
    groups = [
        ("macro", theme_items(selected, "macro")),
        ("taiwan", theme_items(selected, "taiwan")),
        ("ai", theme_items(selected, "ai")),
    ]
    for theme, items in groups:
        if not items:
            continue
        why = THEME_WHY.get(theme) or ""
        if not why:
            continue
        ids = [item["instrument"] for item in items]
        label = THEME_LABEL.get(theme) or theme
        lens.append(f"{label}｜{why}（Evidence {'/'.join(ids)}）。")
    return lens[:MAX_EXEC_SIGNALS]


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

    lens = build_macro_lens(selected)

    # Sprint 012: thin read-only evaluated Event adapter (handoff). Candidate not required.
    event_packets = collect_evaluated_events(root, date)
    elevated_ids = set()
    if event_packets:
        elevated_ids.add(event_packets[0]["eventId"])

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
    temp_owned = [label for label in ("Nasdaq", "S&P 500", "Dow", "SOX", "WTI", "Brent", "VIX") if label in temperature]
    if temp_owned:
        global_items.append(market_status_item(
            "指數／油價／波動詳見市場溫度（" + "、".join(temp_owned) + "）",
            "Global",
            None,
        ))
    for packet in event_packets:
        if packet["region"] != "global":
            continue
        if packet["eventId"] in elevated_ids:
            # Elevated into Yesterday/exec — avoid full duplicate in Global.
            continue
        global_items.append(event_brief_item(packet))
    if macro_hits:
        global_summary = MARKET_STATUS_PREFIX + "；".join(format_group(macro_hits, "percent"))
        if temp_owned:
            global_summary += "；數值市場狀態見市場溫度。"
    elif temp_owned:
        global_summary = MARKET_STATUS_PREFIX + "美股／油價／波動數值見市場溫度。"
    else:
        global_summary = "全球市場沒有可選入 Brief 的最新 Evidence。"
    if any(packet["region"] == "global" for packet in event_packets):
        global_summary = (global_summary.rstrip("。") + "；含已評估事件。"
                          if global_summary else "含已評估全球事件。")

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
        if packet["eventId"] in elevated_ids:
            continue
        taiwan_items.append(event_brief_item(packet))
    taiwan_bits = format_group(taiwan_hits, "index")
    taiwan_summary = (
        MARKET_STATUS_PREFIX + "；".join(taiwan_bits)
        if taiwan_bits else "台股沒有可選入 Brief 的 Evidence。"
    )
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
    carried_ai = carry_linked_items(prev.get("aiIndustryHighlights"), root)
    # Prefer non-quote narrative leftovers when available.
    narrative_ai = [
        item for item in carried_ai
        if not str(item.get("title") or "").strip().startswith("SOX ")
    ]
    if narrative_ai:
        ai_items.extend(narrative_ai)
    else:
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

    things = build_today_things(selected)
    # Event attention for Today's 3 Things (why-first; what happened as evidence note).
    event_things = []
    for packet in event_packets:
        event_things.append(today_item(
            packet["why"],
            packet["why"],
            packet["source"],
            [packet["eventId"]],
            None,
            evidence_note=EVENT_PREFIX + packet["factTitle"],
        ))
    if event_things:
        merged = []
        seen_why = set()
        for item in event_things + things:
            key = str(item.get("whyItMatters") or item.get("title") or "")
            if key in seen_why:
                continue
            seen_why.add(key)
            merged.append(item)
        things = merged[:MAX_TODAY_THINGS]

    summary, signals = build_executive_summary(selected)
    if event_packets:
        top = event_packets[0]
        # Executive = what happened + why important (factTitle + why).
        event_line = (
            f"{EVENT_PREFIX}{top['factTitle']}。"
            f"注意理由：{top['why']}"
            f"（Event {top['eventId']}；when {top['when']}）。"
        )
        combined = [event_line] + list(signals)
        combined = combined[:MAX_EXEC_SIGNALS]
        summary = "\n".join(f"{index}. {text}" for index, text in enumerate(combined, start=1))
        # Macro Decision Lens = distinct investment observation; omit if not distinct.
        lens_event = event_macro_lens_line(top)
        kept_lens = [
            line for line in lens
            if "事件｜" not in str(line) and not str(line).startswith("觀察角度：")
        ]
        if lens_event:
            lens = [lens_event] + kept_lens
        else:
            lens = kept_lens
        lens = lens[:MAX_EXEC_SIGNALS]

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
