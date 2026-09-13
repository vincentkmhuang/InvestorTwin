# P2-024 — Event Understanding (News Intelligence Phase 3). Isolated.
# Reuses evaluate / link / integrate. No News Collect / Meaning Gate / Today / Queue / Gold.
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
SCRIPTS = os.path.join(ROOT, "scripts")


def load_py(name, filename):
    path = os.path.join(SCRIPTS, filename)
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


fails = []


def record(name, ok, detail=""):
    status = "PASS" if ok else "FAIL"
    print(status + " " + name + ((" " + detail) if (detail and not ok) else ""))
    if not ok:
        fails.append(name + ": " + (detail or "failed"))


evaluate = load_py("evaluate_ni", "evaluate-news-intelligence.py")
link = load_py("link_ni", "link-news-events.py")
integrate = load_py("integrate_ni", "integrate-news-event-evaluation.py")


def news(title, summary, published="2026-09-12T00:30:01Z", nid="n1", subject=None):
    return {
        "id": nid,
        "source": "CNA Finance RSS",
        "title": title,
        "publishedTime": published,
        "url": "https://example.test/" + nid,
        "summary": summary,
        "subject": subject,
    }


def classify_one(title, summary):
    filler = news("其他財經消息", "無特定主題的例行報導。", nid="filler")
    target = news(title, summary, nid="target")
    linked = link.link({"news": [target, filler]})
    for event in linked.get("events") or []:
        if "target" in (event.get("newsRefs") or []):
            return event
    return (linked.get("events") or [None])[0]


# --- T1 Company ---
ev = classify_one("台積電公布上季財報 EPS 優於預期", "公司公布季報與 EPS 數字。")
record("T1-company-earnings", ev and ev.get("eventType") in ("Company / Earnings", "Earnings"), str(ev))

# --- T2 AI / Compute or Server ---
live_title = "輝達與ASIC雙引擎催動 奇鋐雙鴻年底再拉新成長曲線"
live_summary = (
    "散熱雙雄奇鋐、雙鴻今年以來營運動能強勁，上半年獲利皆呈倍數成長。"
    "第4季起隨著輝達（NVIDIA）Vera Rubin，以及ASIC（特殊應用積體電路）"
    "AI伺服器新品將陸續出貨，雙引擎催動奇鋐、雙鴻營運，可望再拉出新一波成長曲線。"
)
ev2 = classify_one(live_title, live_summary)
record(
    "T2-ai-server",
    ev2 and ev2.get("eventType") == "AI / Server" and "nvidia:other" not in str(ev2.get("eventId") or "").lower()
    and "evt:other/nvidia/other" != ev2.get("eventId"),
    str(ev2),
)

# --- T3 Semiconductor ---
ev3 = classify_one("半導體需求回溫 晶片需求升溫", "產業報告指出半導體需求與 chip demand 回升。")
record(
    "T3-semiconductor",
    ev3 and str(ev3.get("eventType") or "").startswith("Semiconductor /"),
    str(ev3),
)

# --- T4 Macro ---
ev4 = classify_one("美債殖利率升溫 US10Y 走高", "市場關注公債與升息路徑。")
record("T4-macro-rates", ev4 and ev4.get("eventType") in ("Macro / Rates", "Policy"), str(ev4))

# --- T5 Subject normalization ---
record(
    "T5-subject-normalization",
    ev2 and "NVIDIA" in str(ev2.get("subject") or "") and "ASIC" in str(ev2.get("subject") or "")
    and "Taiwan Cooling" in str(ev2.get("subject") or ""),
    str(ev2.get("subject") if ev2 else None),
)

# --- T6 What Changed ---
wc = (ev2 or {}).get("whatChanged") or {}
record(
    "T6-what-changed",
    isinstance(wc, dict) and wc.get("summary") and live_title not in str(wc.get("summary"))
    and "非營收或訂單確認" in str(wc.get("summary")),
    str(wc),
)

# --- T7 FACT / INFERENCE / UNKNOWN ---
record(
    "T7-labels",
    bool(wc.get("FACT")) and bool(wc.get("INFERENCE")) and bool(wc.get("UNKNOWN")),
    str(wc),
)

# --- T8 headline growth not FACT ---
fact_blob = " ".join(str(x) for x in (wc.get("FACT") or []))
unk_blob = " ".join(str(x) for x in (wc.get("UNKNOWN") or []))
record(
    "T8-no-headline-growth-as-fact",
    "成長曲線" not in fact_blob and "倍數成長" not in fact_blob and "成長" in unk_blob,
    "FACT=" + fact_blob + " UNKNOWN=" + unk_blob,
)

# --- T9 insufficient → UNKNOWN ---
empty = evaluate.what_changed_bundle(
    {"title": "", "summary": ""},
    {"eventType": "Other", "what": None, "subject": None},
)
record("T9-insufficient-unknown", "UNKNOWN" in json.dumps(empty, ensure_ascii=False), str(empty))

# --- T10 Position ≠ automatic relevance ---
ordinary = evaluate.evaluate(
    {
        "source": "Local",
        "title": "台塑宣布例行維修",
        "publishedTime": "2026-09-12",
        "summary": "台塑企業進行例行歲修，無重大意外。",
        "subject": "台塑",
    },
    context={"positions": ["台塑", "2330"], "holdings": ["台塑"]},
)
record(
    "T10-position-not-auto-high",
    ordinary.get("relevance") != "High" and "Position" in str(ordinary.get("relevanceBasis") or ""),
    str(ordinary.get("relevance")) + " " + str(ordinary.get("relevanceBasis")),
)

# Live article evaluate path
live_eval = evaluate.evaluate({
    "source": "CNA Finance RSS",
    "title": live_title,
    "publishedTime": "2026-09-12T00:30:01Z",
    "summary": live_summary,
})
record(
    "live-article-type",
    live_eval["event"]["eventType"] == "AI / Server",
    str(live_eval["event"]),
)
record(
    "live-article-importance-not-other1",
    int(live_eval.get("importance") or 0) >= 3,
    str(live_eval.get("importance")),
)


def run_py(path):
    proc = subprocess.run([sys.executable, path], cwd=ROOT, capture_output=True, text=True)
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


code11, out11 = run_py(os.path.join(ROOT, "tests", "p2-023-phase2-cross-evidence.py"))
record("T11-p2-023-phase2-regression", code11 == 0, out11[-500:])

code12, out12 = run_py(os.path.join(ROOT, "tests", "p2-022-step2-ni-brief.py"))
record("T12-p2-022-step2-regression", code12 == 0, out12[-500:])

if fails:
    sys.stderr.write("FAIL " + "; ".join(fails) + "\n")
    raise SystemExit(1)
print("P2-024 EVENT UNDERSTANDING UNIT OK")
raise SystemExit(0)
