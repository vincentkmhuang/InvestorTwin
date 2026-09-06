# Phase 2 Sprint 005 — News → Event → Evaluation Integration
**Draft SPEC 1.0**

| 欄位 | 內容 |
|---|---|
| Status | Draft SPEC 1.0 |
| Source of Truth | Investor Twin Handbook V2.0 |
| 上位文件 | Handbook Ch.2、Ch.3 H3–H5、Ch.5.1–5.5、Ch.7、Ch.11 Phase 2 |
| Builds on | Sprint 001 News Intelligence Foundation；Sprint 004 News Dedup & Event Linking |
| Target architecture | `docs/Phase 2 Event Evaluation Integration Design.md` |
| Governance | `docs/Phase 2 Event Evaluation Governance Audit.md` |
| 本 SPEC 不是 | 05 Event Model、Source Registry、News Collector、Brief / Today integration、完整 NI 大文件 |
| 本 Sprint 交付 | Integration SPEC + acceptance definition。**本文件寫作當下不做 implementation** |

**Subordinate to Investor Twin Handbook V2.0.**  
**Builds on Sprint 001 and Sprint 004.**  
**Target architecture follows Event × Evaluation Integration Design.**  
**This is integration scope only** — wire existing Dedup + Evaluation capabilities into one Event-level path. Do not rebuild News Intelligence.

---

## 1. Mission

建立最小的：

```
News[] → Dedup / Event Linking → Event[] → Evaluation → Research Candidate
```

成功標準：同一 Event 的多則 News 只得到 **一份** canonical Evaluation 與 **最多一個** Research Candidate；News / Evidence / Source 仍可追溯。

不是新的 News Intelligence framework。  
不是 production News / Event database。  
不是 Brief / Queue / Card / Decision 自動化。

---

## 2. Reuse boundary

| Capability | Reuse |
|---|---|
| News Object | Sprint 001 §2 — do not redesign |
| Evaluation fields / gates | Sprint 001 §5–§9 + `evaluate-news-intelligence.py` — do not redesign scoring |
| Dedup / Event linking | Sprint 004 + `link-news-events.py` — do not rebuild |
| NVIDIA Official Adapter | Sprint 002 — do not modify for this Sprint |
| Federal Reserve Official Adapter | Sprint 003 — do not modify for this Sprint |
| Presentation Dedup / 031-B | Out of scope — do not touch |

**Reuse > Modify > Add.**  
Prefer a thin integration entrypoint that calls Dedup then Event-level Evaluation. Do not copy two engines into a third duplicate logic tree.

**Sprint 001 compatibility (Governance Audit):**  
Sprint 001 per-News evaluation remains a **transitional** path for a single unlinked News. Sprint 005 target for **linked** News is Event-level Evaluation. Do not rewrite Sprint 001 SPEC semantics.

---

## 3. Target architecture

```
News[]
   ↓
Dedup / Event Linking   (Sprint 004 engine)
   ↓
Event[]
   ↓
Evaluation              (Sprint 001 fields; Event as unit)
   ↓
Research Candidate      (at most one per Event)
```

Object separation (Design §3):

| Object | Meaning | Owns | Does not own |
|---|---|---|---|
| News | Who reported / how | source, title, publishedTime, url, summary/content, subject, eventRef | Importance, Relevance, Impact judgment, Candidate |
| Event | What happened | what, when, subject, eventType, newsRefs, relatedEventRefs | Evaluation fields, full Evidence dump, Queue |
| Evidence item | Source-backed claim | claim, class (FACT/ESTIMATE/INFERENCE/UNKNOWN), newsRef, source | Importance, Candidate |
| Evaluation | Assessment of an Event | eventRef, importance, relevance, relevanceBasis, impact.judgment, evidenceRefs, researchCandidate | Original article body, Buy/Sell |
| Research Candidate | Worth research time? | eligible, reason, researchQuestion, stance; **eventRef** | Queue / Card / Decision |
| Decision | Change investment judgment? | Human only | Not produced here |

**Principle (Design):** Event is the deduped event unit, **not** the sole information store.

---

## 4. Evaluation ownership

Evaluation is **Event-level**.

Same Event with News A / B / C → **one** canonical Evaluation.

Forbidden:

```
News A → Evaluation A
News B → Evaluation B
News C → Evaluation C
```

when those News share one Event.

Evaluation identity binds to **Event**, not to a primary News:

```
News.eventRef → Event → Evaluation.eventRef
```

Do **not** use `Evaluation.newsRef` as the canonical identity.  
`evidenceRefs[]` may point at News-sourced claims; that is evidence linkage, not Evaluation identity.

Do **not** write Importance / Relevance / Impact / Candidate onto News or into the Event body.

---

## 5. Evaluation fields

Reuse Sprint 001 — **no new scoring system**:

| Field | Rule |
|---|---|
| Importance | ★1–5 (integer 1–5 as engine already emits) |
| Relevance | Reuse existing engine bands (e.g. High / Medium / Low / Low / Medium-Low / Unknown) |
| Relevance Basis | Explainable text |
| Impact | Target, Direction (Positive/Negative/Mixed/Unclear), Strength (Low/Medium/High) |
| Evidence Status | FACT / ESTIMATE / INFERENCE / UNKNOWN — items must keep newsRef + source |
| Research Candidate | `{ eligible, reason, researchQuestion, stance }` |

Forbidden:

- Importance × Relevance formula
- `Importance >= 4 → Candidate = YES`
- `Relevance = High → Candidate = YES`
- Buy / Sell / 加減碼 language

Candidate gates remain Sprint 001 §9 (Importance ≥ 3 **or** meaningful Relevance; not market-quote-only; unresolved question; etc.). Implementation must not invent new gates that break Sprint 001 Cases A–E semantics when the same facts are evaluated at Event level.

---

## 6. Evidence rule

Evaluation may **reference** Evidence. Event must **not swallow** Evidence.

For Same Event:

| Must keep | Must not |
|---|---|
| Each News object | Delete Reuters because Official exists |
| Each Source | Drop url / source after linking |
| Per-News FACT / ESTIMATE / INFERENCE / UNKNOWN items | Merge into one untraceable blob |
| New information from News B as new items | Overwrite Official FACT with third-party ESTIMATE |

Example:

- News A (Official): announce acquisition → FACT  
- News B (Reuters): market concerns → ESTIMATE / INFERENCE  
- Same Event; one Evaluation; both evidence streams retained with `newsRef` + `source`

If News B is a **new event state** (regulatory review begins, deal completes), Sprint 004 **Related Event** applies: separate Event + separate Evaluation. That is not “new evidence on Same Event.”

---

## 7. Research Candidate

| Rule | Requirement |
|---|---|
| Level | Event-level Evaluation only |
| Cardinality | Same Event, N News → **at most 1** Candidate |
| Identity | `ResearchCandidate.eventRef` → Event |
| Meaning | Worth research time — filter result |
| Not | Queue item, Card, Decision, Buy/Sell |

When `eligible = false`, still emit reason / stance as Sprint 001 does; do not invent a Queue entry.

---

## 8. Human gate

After Candidate:

**Must not** automatically:

- POST `/api/queue`
- Write `data/research-queue.json`
- Create Research Card
- Create Decision / Position Playbook
- Emit Buy / Sell recommendation

Human may later: Ignore / Watch / link existing Card / add to Queue — **out of Sprint 005 automation**.

---

## 9. Input

Integration entrypoint (future implementation):

| Input | Allowed |
|---|---|
| 2+ News Objects | Required for Same/Related/Separate paths |
| `--input` fixture path | Yes — under `tests/` only |
| stdin JSON | Yes |

Must refuse production `--input` under `data/` or `research/` (same guard pattern as Sprint 001 / 004 engines).

Call order:

1. Reuse `link-news-events.py` (or shared module) for Dedup  
2. For each distinct Event, produce one Evaluation using Sprint 001 field semantics over that Event’s newsRefs  
3. Emit Candidate only via Sprint 001 gates at Event level  

Do not fork scoring logic into a second incompatible Importance model.

---

## 10. Output

Stdout-only (or test fixture capture). Minimal shape:

```
news[]
events[]
evaluations[]
researchCandidates[]
```

| Array | Rule |
|---|---|
| `news[]` | All input News preserved; each has `eventRef` |
| `events[]` | Canonical Events from Dedup |
| `evaluations[]` | **One per Event** assessed; `eventRef` required |
| `researchCandidates[]` | Only Events that pass Candidate gates; each has `eventRef`; cardinality ≤ number of Events |

Forbidden writes:

- `data/`
- `research/`
- `data/news/`
- `data/events/`
- Brief / Queue / Card / Decision files

---

## 11. Critical relationship

```
News.eventRef
    ↓
Event
    ↓
Evaluation.eventRef
    ↓
ResearchCandidate.eventRef
```

| Identity | Binds to |
|---|---|
| Evaluation canonical identity | Event |
| Research Candidate canonical identity | Event |
| Evidence item identity | claim + newsRef + source |

`Evaluation.newsRef` is **not** the primary identity.

---

## 12. Acceptance Cases

Fixtures for implementation may extend Sprint 001/004 cases; this SPEC defines expected behavior only.

### Case A — NVIDIA / Hugging Face (Same Event)

**Input:** News A NVIDIA Official + News B Reuters (Sprint 004 Case A / Design walkthrough).

| Expect | Value |
|---|---|
| Events | 1 |
| Evaluations | 1 |
| Importance | 5 |
| Relevance | High |
| Impact | Mixed / High (target NVIDIA / AI developer ecosystem class) |
| Candidate | YES (1) |
| Research Question | 「NVIDIA 收購 Hugging Face，是否代表 NVIDIA 正在從 AI Compute Platform 向 AI Developer / Model Platform 延伸？這是否會改變 AI 利潤池與 NVIDIA 長期競爭優勢？」 |
| Forbidden | 2 Evaluations; 2 Candidates; dropped News |

### Case B — High Importance / Low Relevance (ECB)

**Input:** Sprint 001 Case B (ECB rate-hike) or equivalent Event-level fixture.

| Expect | Value |
|---|---|
| Importance | High band (Sprint 001: 4) |
| Relevance | Low / Medium-Low |
| Candidate | NO |
| Proof | Importance ≠ Relevance; `Importance >= 4` must not imply YES |

### Case C — Same Event + new evidence

**Input:** Official announce + third-party market concern (Design Second Case); not a new event state.

| Expect | Value |
|---|---|
| Relation | Same Event |
| News A / B | Both preserved |
| Evidence A / B | Both preserved with newsRef + source |
| Evaluations | 1 |
| Candidates | ≤ 1 |
| Forbidden | Destructive merge of B’s new information |

### Case D — Related Event

**Input:** Sprint 004 Case B (announce vs regulatory review).

| Expect | Value |
|---|---|
| Events | Event A ≠ Event B |
| Relation | Related Event |
| Evaluations | Evaluation A + Evaluation B |
| Candidates | Independently judged per Event |
| Forbidden | Merge into one Event / one Evaluation |

---

## 13. Acceptance Tests (definition)

Implementation Sprint must add executable tests starting at **TEST 53+** without changing Sprint 001–004 acceptance semantics.

| ID | Assertion |
|---|---|
| TEST 53 | Same Event multi-News → exactly one Evaluation |
| TEST 54 | Same Event → at most one Research Candidate |
| TEST 55 | Evaluation.eventRef equals shared Event id |
| TEST 56 | Candidate.eventRef equals Event id |
| TEST 57 | Official + Reuters sources / urls preserved |
| TEST 58 | Case C retains News B evidence items |
| TEST 59 | Importance and Relevance remain separate (Case B) |
| TEST 60 | No Queue / Card / Decision / Playbook side effect |
| TEST 61 | Related Events get separate Evaluations (Case D) |
| TEST 62 | Production File Guard PASS |

Regression (must all PASS):

- Sprint 001 TEST 1–20  
- Sprint 002 TEST 21–30  
- Sprint 003 TEST 31–41  
- Sprint 004 TEST 42–52  

---

## 14. Production File Guard

Must not modify:

- `data/` / `research/`
- Morning Brief / Today / Queue / Research Card / Decision / Position Playbook
- Handbook V2.0
- Sprint 001 SPEC
- Sprint 004 SPEC
- Event Evaluation Integration Design (unless a later explicit doc task)
- 031-B / Evidence collector
- NVIDIA / Fed adapters (unless a proven integration bug requires a minimal fix — report first)

Must not create:

- `data/news/`
- `data/events/`

---

## 15. Out of scope

- News crawler / RSS / Reuters / Bloomberg / CNBC connectors  
- Source Registry / Adapter Framework  
- Formal `05_Event Model` document  
- Production News / Event persistence  
- Morning Brief / Today integration  
- Queue / Card / Decision automation  
- Buy / Sell recommendation  
- AI / ML scoring; Importance × Relevance formula  
- Portfolio recommendation  
- Rewriting Sprint 001–004 engines’ acceptance semantics  

---

## 16. Acceptance Criteria (product)

| ID | Assertion |
|---|---|
| AC-01 | Multiple News → Same Event → one Evaluation |
| AC-02 | Multiple News → Same Event → maximum one Research Candidate |
| AC-03 | Evaluation identity is Event-level |
| AC-04 | Research Candidate identity is Event-level |
| AC-05 | News source traceability remains intact |
| AC-06 | Different News evidence is not merged destructively |
| AC-07 | Importance and Relevance remain separate |
| AC-08 | Candidate does not automatically enter Queue |
| AC-09 | No Card / Decision / Playbook side effect |
| AC-10 | Related Events remain separate |
| AC-11 | Sprint 001–004 regression remains PASS |
| AC-12 | No production data changes |

---

## 17. Sprint 005 Scope

**In Scope (when implementation is authorized)**

- Thin integration entrypoint: Dedup → Event-level Evaluation → Candidate  
- Fixtures for Cases A–D  
- TEST 53–62 (+ regression harness)  
- Stdout-only integration output  

**Out of Scope (this SPEC document task)**

- Writing production code now  
- Commit / push  
- Changing Handbook / Sprint 001 / Sprint 004  

---

## 18. Future implementation note

When implementing:

1. Prefer invoking existing `link-news-events.py` and reusing `evaluate-news-intelligence.py` helpers / validation rather than rewriting Importance / Relevance.  
2. If the per-News evaluator cannot take an Event bag without a small adapter layer, add the **minimum** adapter in a new script; report before modifying Sprint 001 engine semantics.  
3. Orphan single News without linking may still use Sprint 001 path; Same Event path must use this SPEC.
