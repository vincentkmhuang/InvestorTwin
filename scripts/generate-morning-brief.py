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
    if macro_hits:
        global_summary = MARKET_STATUS_PREFIX + "；".join(format_group(macro_hits, "percent"))
        if temp_owned:
            global_summary += "；數值市場狀態見市場溫度。"
    elif temp_owned:
        global_summary = MARKET_STATUS_PREFIX + "美股／油價／波動數值見市場溫度。"
    else:
        global_summary = "全球市場沒有可選入 Brief 的最新 Evidence。"

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
    taiwan_bits = format_group(taiwan_hits, "index")
    taiwan_summary = (
        MARKET_STATUS_PREFIX + "；".join(taiwan_bits)
        if taiwan_bits else "台股沒有可選入 Brief 的 Evidence。"
    )

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
    summary, _signals = build_executive_summary(selected)

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
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
