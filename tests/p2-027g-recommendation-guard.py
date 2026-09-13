# P2-027G — Recommendation guard false-positive fix (context-aware).
# Does not modify eventType / subject / event identity / Brief / Meaning Gate.
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
link_mod = load_py("link_ni", "link-news-events.py")
integrate = load_py("integrate_ni", "integrate-news-event-evaluation.py")


def news_pair(title_a, summary_a, title_b=" unrelated market note", summary_b="macro update without advice"):
    """Link/integrate require >=2 news objects."""
    return {
        "news": [
            {
                "id": "https://example.test/a",
                "source": "Test Source A",
                "title": title_a,
                "publishedTime": "2026-09-13T00:00:00Z",
                "url": "https://example.test/a",
                "summary": summary_a,
                "subject": None,
                "eventRef": None,
            },
            {
                "id": "https://example.test/b",
                "source": "Test Source B",
                "title": title_b,
                "publishedTime": "2026-09-13T01:00:00Z",
                "url": "https://example.test/b",
                "summary": summary_b,
                "subject": None,
                "eventRef": None,
            },
        ]
    }


def expect_no_leak(label, title, summary):
    leaks = evaluate.recommendation_leak({"title": title, "summary": summary})
    record(label + "-leak-empty", leaks == [], str(leaks))
    try:
        integrate.integrate(news_pair(title, summary))
        record(label + "-integrate-ok", True)
    except SystemExit as exc:
        record(label + "-integrate-ok", False, "SystemExit " + str(exc))


def expect_leak(label, title, summary, expect_tokens=None):
    leaks = evaluate.recommendation_leak({"title": title, "summary": summary})
    ok = len(leaks) >= 1
    if expect_tokens:
        ok = ok and any(any(tok in item for tok in expect_tokens) for item in leaks)
    record(label + "-leak-hit", ok, str(leaks))
    raised = False
    try:
        integrate.integrate(news_pair(title, summary))
    except SystemExit:
        raised = True
    record(label + "-integrate-blocked", raised)


# Case 1–3: policy / budget 加碼 — NOT recommendation
expect_no_leak("C1", "政府教育預算加碼", "行政院宣布教育預算加碼以支持托育。")
expect_no_leak("C2", "政策補助加碼", "政府對育兒政策補助加碼。")
expect_no_leak("C3", "建設投資加碼", "地方政府建設投資加碼推動公共工程。")

# Case 4–6: true recommendation
expect_leak("C4", "分析師建議加碼", "券商分析師建議加碼半導體權值股。", expect_tokens=["加碼"])
expect_leak("C5", "法人建議減碼", "外資法人建議減碼部分電子股。", expect_tokens=["減碼"])
expect_leak("C6", "評級升至買進", "大型投顧將該股評級升至買進。", expect_tokens=["買進", "評級"])

# Case 7–8: normal CNA / MOPS shaped objects from the failed production batch
cna_ok = {
    "id": "https://www.cna.com.tw/news/afe/202609130024.aspx",
    "source": "CNA Finance RSS",
    "sourceId": "cna-finance-rss",
    "title": "AI熱潮推升借款需求 銀行看資金緊俏現象或成新常態",
    "publishedTime": "2026-09-13T01:46:28Z",
    "url": "https://www.cna.com.tw/news/afe/202609130024.aspx",
    "summary": "銀行業者觀察企業借款需求上升。",
    "subject": None,
    "eventRef": None,
}
mops_ok = {
    "id": "https://mops.twse.com.tw/material/listed/1721/1150912/070003/6757e97414345792",
    "source": "MOPS 重大訊息 OpenAPI",
    "sourceId": "mops-material-openapi",
    "title": "公告本公司名稱由「三晃股份有限公司」更名為「國慶科技股份有限公司」",
    "publishedTime": "2026-09-12T07:00:03Z",
    "url": "https://mops.twse.com.tw/material/listed/1721/1150912/070003/6757e97414345792",
    "summary": "公司更名公告。",
    "subject": "[上市] [1721] [國慶科技]",
    "eventRef": None,
}
try:
    link_mod.link({"news": [cna_ok, mops_ok]})
    record("C7-C8-cna-mops-link-ok", True)
except SystemExit as exc:
    record("C7-C8-cna-mops-link-ok", False, str(exc))

# Case 9: classic English buy/sell still blocked
expect_leak("C9a", "Desk note", "Analysts say buy the dip on semiconductors.", expect_tokens=["buy"])
expect_leak("C9b", "Desk note", "Traders may sell into strength.", expect_tokens=["sell"])
expect_leak("C9c", "投顧觀點", "投顧認為投資人應該買這檔股票。", expect_tokens=["應該買"])

# Actual production offender: 教育加碼 in CNA summary
prod_title = "政府推人口對策新戰略 卓榮泰籲國營事業辦集團婚禮"
prod_summary = (
    "（中央社記者何秀玲台北13日電）行政院長卓榮泰今天出席中華電信員眷集團婚禮時表示，"
    "政府推動人口對策新戰略，從安心生養、強化托育、教育加碼、友善職場及居住減壓等5大面向支持家庭；"
    "他也期盼各家國營事業響應舉辦集團婚禮，參加人數越多，企業提供的福利也應隨之增加。"
)
record(
    "PROD-cna-education-jiama-no-leak",
    evaluate.recommendation_leak({"title": prod_title, "summary": prod_summary}) == [],
    str(evaluate.recommendation_leak({"title": prod_title, "summary": prod_summary})),
)

# Load real batch from P2-027E runs if present
batch = []
for rid in ("run-20260913T054822798Z-0001", "run-20260913T054827043Z-0004"):
    nd = os.path.join(ROOT, "data", "news", "runs", rid, "normalized")
    if not os.path.isdir(nd):
        continue
    for name in sorted(os.listdir(nd)):
        if name.endswith(".json"):
            with open(os.path.join(nd, name), encoding="utf-8-sig") as handle:
                batch.append(json.load(handle))

if len(batch) >= 2:
    try:
        result = integrate.integrate({"news": batch})
        record(
            "PROD-batch-integrate-ok",
            isinstance(result.get("events"), list) and len(result.get("news") or []) >= 2,
            str({
                "news": len(result.get("news") or []),
                "events": len(result.get("events") or []),
                "evaluations": len(result.get("evaluations") or []),
            }),
        )
        print("PROD_BATCH_INTEGRATE " + json.dumps({
            "news": len(result.get("news") or []),
            "events": len(result.get("events") or []),
            "evaluations": len(result.get("evaluations") or []),
            "researchCandidates": len(result.get("researchCandidates") or []),
        }, ensure_ascii=False))
        # handoff to temp path only
        publisher = load_py("pub", "publish-research-candidates-handoff.py")
        tmp = tempfile.mkdtemp(prefix="InvestorTwin-P2027G-handoff-")
        out_path = os.path.join(tmp, "research-candidates-handoff.json")
        try:
            publisher.publish_handoff(result, out_path)
            record("PROD-batch-handoff-tmp-ok", os.path.isfile(out_path), out_path)
        except Exception as exc:
            record("PROD-batch-handoff-tmp-ok", False, str(exc))
    except SystemExit as exc:
        record("PROD-batch-integrate-ok", False, "SystemExit " + str(exc))
        record("PROD-batch-handoff-tmp-ok", False, "skipped")
else:
    record("PROD-batch-integrate-ok", False, "production run normalized files missing")
    record("PROD-batch-handoff-tmp-ok", False, "skipped")


def run_py(path):
    proc = subprocess.run(
        [sys.executable, path],
        cwd=ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )
    return proc.returncode, (proc.stdout or "") + (proc.stderr or "")


for label, rel in (
    ("T-p2-024", "tests/p2-024-event-understanding.py"),
    ("T-p2-023", "tests/p2-023-phase2-cross-evidence.py"),
    ("T-p2-026", "tests/p2-026-fed-press-rss.py"),
    ("T-p2-027", "tests/p2-027-nvidia-newsroom-rss.py"),
):
    code, out = run_py(os.path.join(ROOT, rel))
    record(label, code == 0, out[-500:])

# sources unchanged expectations
sources = json.load(open(os.path.join(ROOT, "data", "news", "sources.json"), encoding="utf-8-sig"))
by_id = {row.get("sourceId"): row for row in sources.get("sources") or []}
record("registry-nvidia-enabled", by_id.get("nvidia-newsroom-rss", {}).get("enabled") is True)
record("registry-fed-enabled", by_id.get("fed-press-rss", {}).get("enabled") is True)

if fails:
    sys.stderr.write("FAIL " + "; ".join(fails) + "\n")
    raise SystemExit(1)
print("P2-027G RECOMMENDATION GUARD UNIT OK")
raise SystemExit(0)
