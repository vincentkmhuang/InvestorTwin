# Investor Twin 031-A — Morning Brief generator.
# Reads data/evidence/ only. Writes data/morning-brief.json.
# Never creates Research Cards, Queue, Thesis, Case, or Decision.
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
TEMPERATURE_KEYS = {
    "Nasdaq": "Nasdaq",
    "SPX": "S&P 500",
    "DJI": "Dow",
    "SOX": "SOX",
}
INSTRUMENT_RESEARCH_ID = {
    "SOX": "hbm",
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
    with open(path, "w", encoding="utf-8", newline="\n") as handle:
        json.dump(payload, handle, ensure_ascii=False, indent=2)
        handle.write("\n")


def card_exists(root, research_id):
    if not research_id or not isinstance(research_id, str):
        return False
    rid = research_id.strip()
    if not rid or any(part in rid for part in ("\\", "/", "..")):
        return False
    return os.path.isfile(os.path.join(root, "research", rid, "card.json"))


def resolve_research_id(root, instrument=None, existing_id=None):
    rid = existing_id if existing_id else INSTRUMENT_RESEARCH_ID.get(instrument)
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
        return "--"
    if unit == "percent":
        return f"{number:.2f}%"
    if unit == "TWD_hundred_million":
        return f"{number:.1f}億"
    if number >= 100:
        return f"{number:,.2f}"
    return f"{number:.2f}"


def item_as_of(item):
    if not is_valued(item):
        status = item.get("status") if isinstance(item, dict) else None
        return "unavailable" if status == "unavailable" else "--"
    kind = item.get("asOfKind") or "close"
    return f"{item.get('asOf')} {kind}"


def news_item(title, source, research_id):
    return {
        "title": title,
        "source": source,
        "researchId": research_id,
    }


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


def build_brief(root, evidence, previous):
    valued_dates = [item.get("asOf") for item in evidence.values() if is_valued(item)]
    if not valued_dates:
        fail("no valued Evidence asOf found")
    date = sorted(valued_dates)[-1]

    def get(name):
        return evidence.get(name) or {}

    us10 = get("US10Y")
    us30 = get("US30Y")
    nasdaq = get("Nasdaq")
    spx = get("SPX")
    dji = get("DJI")
    sox = get("SOX")
    taiex = get("TAIEX")
    foreign = get("TW_FOREIGN_NET")
    trust = get("TW_TRUST_NET")
    dealer = get("TW_DEALER_NET")

    temperature = {}
    for instrument, label in TEMPERATURE_KEYS.items():
        row = get(instrument)
        if is_valued(row):
            temperature[label] = {
                "value": fmt_number(row.get("value"), row.get("unit") or "index"),
                "asOf": item_as_of(row),
            }
        elif isinstance(row, dict) and row.get("status") == "unavailable":
            temperature[label] = {"value": "--", "asOf": "unavailable"}

    lens = []
    if is_valued(us10):
        lens.append(f"US 10Y｜{fmt_number(us10.get('value'), 'percent')}：asOf {us10.get('asOf')}（Evidence {us10.get('sourceId') or 'fred-dgs10'}）。")
    if is_valued(us30):
        lens.append(f"US 30Y｜{fmt_number(us30.get('value'), 'percent')}：asOf {us30.get('asOf')}（Evidence {us30.get('sourceId') or 'fred-dgs30'}）。")
    if is_valued(taiex):
        lens.append(f"TAIEX｜{fmt_number(taiex.get('value'), 'index')}：asOf {taiex.get('asOf')}。")
    if not lens:
        lens.append("今日 Evidence 尚未提供足夠的宏觀數值。")

    global_bits = []
    if is_valued(us10):
        global_bits.append(f"US10Y {fmt_number(us10.get('value'), 'percent')}（{us10.get('asOf')}）")
    if is_valued(us30):
        global_bits.append(f"US30Y {fmt_number(us30.get('value'), 'percent')}（{us30.get('asOf')}）")
    for row, label in ((nasdaq, "Nasdaq"), (spx, "S&P 500"), (dji, "Dow"), (sox, "SOX")):
        if is_valued(row):
            global_bits.append(f"{label} {fmt_number(row.get('value'), 'index')}（{row.get('asOf')}）")
        elif row.get("status") == "unavailable":
            global_bits.append(f"{label} unavailable")
    global_summary = "；".join(global_bits) if global_bits else "全球市場 Evidence 不足。"

    global_items = []
    if is_valued(us10) or is_valued(us30):
        global_items.append(news_item(
            f"美債：US10Y {fmt_number(us10.get('value'), 'percent') if is_valued(us10) else '--'}、US30Y {fmt_number(us30.get('value'), 'percent') if is_valued(us30) else '--'}",
            "Global",
            None,
        ))
    if any(is_valued(row) or row.get("status") == "unavailable" for row in (nasdaq, spx, dji)):
        global_items.append(news_item(
            f"美股指數 Evidence：Nasdaq {fmt_number(nasdaq.get('value'), 'index') if is_valued(nasdaq) else '--'}、S&P 500 {fmt_number(spx.get('value'), 'index') if is_valued(spx) else '--'}、Dow {fmt_number(dji.get('value'), 'index') if is_valued(dji) else '--'}",
            "Global",
            None,
        ))

    taiwan_bits = []
    if is_valued(taiex):
        taiwan_bits.append(f"TAIEX {fmt_number(taiex.get('value'), 'index')}（{taiex.get('asOf')}）")
    if is_valued(foreign):
        taiwan_bits.append(f"外資淨買超 {fmt_number(foreign.get('value'), 'TWD_hundred_million')}（{foreign.get('asOf')}）")
    if is_valued(trust):
        taiwan_bits.append(f"投信 {fmt_number(trust.get('value'), 'TWD_hundred_million')}")
    if is_valued(dealer):
        taiwan_bits.append(f"自營 {fmt_number(dealer.get('value'), 'TWD_hundred_million')}")
    taiwan_summary = "；".join(taiwan_bits) if taiwan_bits else "台股 Evidence 不足。"
    taiwan_items = []
    if is_valued(taiex):
        taiwan_items.append(news_item(
            f"台股加權 {fmt_number(taiex.get('value'), 'index')}（{taiex.get('asOf')}）",
            "台股",
            None,
        ))
    if is_valued(foreign) or is_valued(trust) or is_valued(dealer):
        taiwan_items.append(news_item(
            f"三大法人：外資 {fmt_number(foreign.get('value'), 'TWD_hundred_million') if is_valued(foreign) else '--'}、投信 {fmt_number(trust.get('value'), 'TWD_hundred_million') if is_valued(trust) else '--'}、自營 {fmt_number(dealer.get('value'), 'TWD_hundred_million') if is_valued(dealer) else '--'}",
            "台股",
            None,
        ))

    sox_rid = resolve_research_id(root, "SOX")
    ai_items = []
    if is_valued(sox) or sox.get("status") == "unavailable":
        title = (
            f"SOX {fmt_number(sox.get('value'), 'index')}（{sox.get('asOf')}）"
            if is_valued(sox)
            else "SOX Evidence unavailable"
        )
        ai_items.append({"title": title, "researchId": sox_rid})

    prev = previous if isinstance(previous, dict) else {}
    ai_items.extend(carry_linked_items(prev.get("aiIndustryHighlights"), root))
    events = carry_linked_items(prev.get("upcomingEvents"), root)
    seen_titles = set()
    deduped_ai = []
    for item in ai_items:
        key = (item.get("title"), item.get("researchId"))
        if key in seen_titles:
            continue
        seen_titles.add(key)
        deduped_ai.append(item)

    things = []
    if is_valued(us10) or is_valued(us30):
        things.append({
            "text": f"美債 Evidence：US10Y {fmt_number(us10.get('value'), 'percent') if is_valued(us10) else '--'}、US30Y {fmt_number(us30.get('value'), 'percent') if is_valued(us30) else '--'}。",
            "researchId": None,
        })
    if is_valued(taiex) or is_valued(foreign):
        things.append({
            "text": f"台股 Evidence：{taiwan_summary}",
            "researchId": None,
        })
    if is_valued(sox) or sox.get("status") == "unavailable":
        things.append({
            "text": (
                f"半導體指數 SOX {fmt_number(sox.get('value'), 'index')}（{sox.get('asOf')}）。"
                if is_valued(sox)
                else "SOX Evidence unavailable。"
            ),
            "researchId": sox_rid,
        })
    while len(things) < 3:
        things.append({"text": "今日其餘 Evidence 欄位不足，不虛構新聞。", "researchId": None})
    things = things[:3]

    summary = (
        f"Evidence Brief asOf {date}。"
        + global_summary
        + "。"
        + taiwan_summary
        + "。本 Brief 由 data/evidence 產生，不虛構未出現在 Evidence 的新聞。"
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
    for key in CANONICAL_FIELDS:
        if key not in brief:
            fail("generator omitted canonical field: " + key)
    backup = os.path.join(root, "data", "morning-brief.backup.json")
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if os.path.isfile(dest):
        shutil.copy2(dest, backup)
    write_json(dest, brief)
    print("BRIEF_GEN_OK")
    print("date=" + brief["date"])
    print("dest=" + dest)
    print("instruments=" + ",".join(sorted(evidence.keys())))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
