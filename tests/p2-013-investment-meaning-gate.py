# Phase 2 / Today V2 Phase 3 — Investment Meaning Gate unit fixtures (Python mirror of JS rules).
# Keep in sync with js/investment-meaning-gate.js (rule-based, no LLM).

from __future__ import annotations

import json
import sys
from pathlib import Path


def evidence_fingerprint(candidate: dict) -> str:
    parts = []
    for row in candidate.get("evidenceRefs") or []:
        parts.append("|".join([
            str(row.get("class") or "").upper(),
            str(row.get("newsRef") or "").strip(),
            str(row.get("claim") or "").strip(),
        ]))
    status = (candidate.get("impact") or {}).get("evidenceStatus") or {}
    for cls in ("FACT", "ESTIMATE", "INFERENCE", "UNKNOWN"):
        for row in status.get(cls) or []:
            parts.append("|".join([
                cls,
                str(row.get("newsRef") or "").strip(),
                str(row.get("claim") or "").strip(),
            ]))
    return ";;".join(sorted(p for p in parts if p))


def has_material_evidence(candidate: dict) -> bool:
    for row in candidate.get("evidenceRefs") or []:
        cls = str(row.get("class") or "").upper()
        if cls in ("FACT", "ESTIMATE") and str(row.get("claim") or "").strip():
            return True
    status = (candidate.get("impact") or {}).get("evidenceStatus") or {}
    for cls in ("FACT", "ESTIMATE"):
        for row in status.get(cls) or []:
            if str(row.get("claim") or "").strip():
                return True
    return False


def detect_meaning(candidate: dict):
    explicit = str(
        candidate.get("meaningType")
        or candidate.get("investmentMeaning")
        or candidate.get("meaning")
        or ""
    ).strip().replace(" ", "")
    mapping = {
        "Supported": "Supported",
        "Challenged": "Challenged",
        "Shift": "Shift",
        "NewQuestion": "NewQuestion",
        "New_Question": "NewQuestion",
        "Opportunity": "Opportunity",
    }
    for key, val in mapping.items():
        if explicit.lower() == key.lower():
            return val

    relevance = str(candidate.get("relevance") or "").strip()
    question = str(candidate.get("researchQuestion") or "").strip()
    impact = candidate.get("impact") or {}
    direction = str(impact.get("direction") or "").strip()
    strength = str(impact.get("strength") or "").strip()
    strength_ok = strength in ("High", "Medium")
    relevance_ok = relevance in ("High", "Medium")
    if direction == "Negative" and strength_ok:
        return "Challenged"
    if direction == "Positive" and strength_ok:
        return "Supported"
    if direction == "Mixed" and strength == "High":
        return "Shift"
    if question and relevance_ok:
        return "NewQuestion"
    return None


def evaluate(candidate: dict, ctx: dict) -> dict:
    reasons = []
    event_ref = str(candidate.get("eventRef") or "").strip()
    status = str(candidate.get("status") or "Pending")
    fp = evidence_fingerprint(candidate)

    if not has_material_evidence(candidate):
        return {"passed": False, "reason": ["change_fail:no_material_evidence"]}

    if status == "Watching":
        seen = (ctx.get("seen") or {}).get(event_ref) or {}
        prev = str(seen.get("evidenceFingerprint") or "")
        watch_noise = event_ref in (ctx.get("watchNoiseEventRefs") or set())
        if not watch_noise and prev and prev == fp:
            return {"passed": False, "reason": ["change_fail:watching_without_new_evidence"]}

    links = []
    if event_ref in (ctx.get("watchEventRefs") or set()):
        links.append("InvestorWatch")
    if event_ref in (ctx.get("checkEventRefs") or set()):
        links.append("InvestmentCheck")
    if event_ref in (ctx.get("cardEventRefs") or set()):
        links.append("ResearchCard")
    if candidate.get("cardId"):
        links.append("GateCardId")
    if not links:
        return {"passed": False, "reason": ["personal_relevance_fail:no_explicit_link"]}

    meaning = detect_meaning(candidate)
    if not meaning:
        return {"passed": False, "reason": ["meaning_fail:no_explicit_investment_meaning"]}

    return {"passed": True, "reason": reasons + [f"meaning:{meaning}"], "meaningType": meaning, "personalLinks": links}


def case(name, candidate, ctx, expect_pass):
    decision = evaluate(candidate, ctx)
    ok = bool(decision["passed"]) == bool(expect_pass)
    return {
        "name": name,
        "ok": ok,
        "expect_pass": expect_pass,
        "passed": decision["passed"],
        "reason": decision.get("reason"),
    }


def main() -> int:
    base_evidence = {
        "evidenceRefs": [{"class": "FACT", "newsRef": "news-1", "claim": "Company announced X", "source": "IR"}],
        "impact": {
            "direction": "Mixed",
            "strength": "High",
            "evidenceStatus": {"FACT": [{"claim": "Company announced X", "newsRef": "news-1"}]},
        },
        "relevance": "High",
        "researchQuestion": "Does this change the platform thesis?",
    }

    # Fingerprint for Watching quiet rule must match evidenceFingerprint() output exactly.
    watching_candidate = {
        "eventRef": "evt:watch-stale",
        "status": "Watching",
        "evidenceRefs": [{"class": "FACT", "newsRef": "news-1", "claim": "Company announced X"}],
        "impact": {
            "direction": "Mixed",
            "strength": "High",
            "evidenceStatus": {"FACT": [{"claim": "Company announced X", "newsRef": "news-1"}]},
        },
        "relevance": "High",
        "researchQuestion": "Still watching?",
    }
    watching_fp = evidence_fingerprint(watching_candidate)

    ctx_linked = {
        "watchEventRefs": {"evt:ai/platform", "evt:watch-stale"},
        "watchNoiseEventRefs": set(),
        "checkEventRefs": set(),
        "cardEventRefs": {"evt:rates/us10y-ai"},
        "seen": {
            "evt:watch-stale": {"evidenceFingerprint": watching_fp},
        },
    }

    results = []
    # TEST 1
    results.append(case(
        "TEST1_pass_new_evidence_personal_meaning",
        {
            "eventRef": "evt:ai/platform",
            "status": "Pending",
            **base_evidence,
        },
        ctx_linked,
        True,
    ))
    # TEST 2 — Watching + same evidence fingerprint must fail on Change, not Personal Relevance
    results.append(case(
        "TEST2_fail_watching_no_new_evidence",
        watching_candidate,
        ctx_linked,
        False,
    ))
    # Assert specific fail reason for TEST2
    d2 = evaluate(watching_candidate, ctx_linked)
    if not any("watching_without_new_evidence" in str(r) for r in (d2.get("reason") or [])):
        results.append({
            "name": "TEST2_reason_watching_without_new_evidence",
            "ok": False,
            "expect_pass": False,
            "passed": d2.get("passed"),
            "reason": d2.get("reason"),
        })
    else:
        results.append({
            "name": "TEST2_reason_watching_without_new_evidence",
            "ok": True,
            "expect_pass": False,
            "passed": d2.get("passed"),
            "reason": d2.get("reason"),
        })
    # TEST 3
    results.append(case(
        "TEST3_fail_no_personal_relevance",
        {
            "eventRef": "evt:market/general-news",
            "status": "Pending",
            **base_evidence,
        },
        {**ctx_linked, "watchEventRefs": set(), "checkEventRefs": set(), "cardEventRefs": set()},
        False,
    ))
    # TEST 4
    results.append(case(
        "TEST4_fail_price_up_no_investment_evidence",
        {
            "eventRef": "evt:equity/price-up-8",
            "status": "Pending",
            "evidenceRefs": [{"class": "INFERENCE", "newsRef": "px-1", "claim": "Stock rose 8% today"}],
            "impact": {"direction": "Positive", "strength": "Low", "evidenceStatus": {"INFERENCE": [{"claim": "Stock rose 8% today"}]}},
            "relevance": "Low",
            "researchQuestion": "",
            "cardId": "some-card",
        },
        ctx_linked,
        False,
    ))
    # TEST 5
    results.append(case(
        "TEST5_fail_us10y_no_personal_link",
        {
            "eventRef": "evt:rates/us10y-orphan",
            "status": "Pending",
            "evidenceRefs": [{"class": "FACT", "newsRef": "fred-1", "claim": "US10Y closed higher"}],
            "impact": {"direction": "Mixed", "strength": "Medium", "evidenceStatus": {"FACT": [{"claim": "US10Y closed higher"}]}},
            "relevance": "High",
            "researchQuestion": "Do higher yields pressure AI valuations?",
        },
        {**ctx_linked, "watchEventRefs": set(), "checkEventRefs": set(), "cardEventRefs": set()},
        False,
    ))
    # TEST 6
    results.append(case(
        "TEST6_pass_us10y_linked_ai_growth",
        {
            "eventRef": "evt:rates/us10y-ai",
            "status": "Pending",
            "evidenceRefs": [{"class": "FACT", "newsRef": "fred-2", "claim": "US10Y rise continues"}],
            "impact": {"direction": "Negative", "strength": "High", "evidenceStatus": {"FACT": [{"claim": "US10Y rise continues"}]}},
            "relevance": "High",
            "researchQuestion": "Does sustained higher long rates challenge AI growth valuation assumptions?",
        },
        ctx_linked,
        True,
    ))

    failed = [r for r in results if not r["ok"]]
    print(json.dumps({"results": results, "failed": len(failed)}, ensure_ascii=False, indent=2))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
