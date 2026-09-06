# Phase 2 — Event Evaluation Governance Audit
**Audit 1.0 — Governance / Documentation only**

| 欄位 | 內容 |
|---|---|
| Status | Audit 1.0 |
| Source of Truth | Investor Twin Handbook V2.0 |
| Inputs | Handbook V2.0；Sprint 001 SPEC；Sprint 004 SPEC；Event Evaluation Integration Design |
| 本文件不是 | Constitution、Architecture、05 Event Model、Sprint 005 SPEC、implementation |
| 本文件不做 | 修改 Handbook / SPEC / production；建立 02–09 文件；寫 code；commit / push |

---

## 1. Existing Documentation

### 1.1 Present in `docs/` (repo check)

| Document | Path | Status |
|---|---|---|
| Handbook V2.0 | `docs/Investor Twin Handbook V2.0.md` | Present — Source of Truth |
| Sprint 001 SPEC | `docs/Phase 2 Sprint 001 News Intelligence Foundation SPEC.md` | Present |
| Sprint 004 SPEC | `docs/Phase 2 Sprint 004 News Dedup & Event Linking SPEC.md` | Present |
| Event × Evaluation Design | `docs/Phase 2 Event Evaluation Integration Design.md` | Present |

### 1.2 Named in Handbook Appendix A, but **not** present as standalone files

| Named layer | Separate file in repo? | Where it lives today |
|---|---|---|
| Project Constitution | **No** | Embedded as Handbook Ch.3 (H1–H5 + Human Owns Decisions) |
| System Architecture | **No** | Embedded summary as Handbook Ch.10；not a `03 Architecture` file |
| SPEC Index | **No** | Absent |
| Event Model (`05_Event Model`) | **No** | Referenced by Handbook 5.1；Sprint 001/004 explicitly not that model |
| Decision Framework | **No** | Embedded as Handbook Ch.8；not a standalone DF file |
| Knowledge Graph (`07_`) | **No** | Referenced by Handbook 9.2；not present |
| Morning Brief Spec | **No** | Embedded as Handbook Ch.6；sprint/legacy SPECs live outside this audit set |
| Roadmap | **No** | Embedded as Handbook Ch.11 |

**Audit finding：** Handbook Appendix A describes a full hierarchy. The repo currently carries **Handbook + Phase 2 SPECs + one Design**. Lower-layer 02–09 files are **planned / referenced**, not missing blockers for this Design. Do **not** create them for completeness.

---

## 2. Decision Classification

Classification key:

| Code | Layer |
|---|---|
| A | Handbook principle |
| B | Constitution principle (today: Handbook Ch.3) |
| C | Architecture rule |
| D | Event Model |
| E | Sprint SPEC |
| F | Design-only decision |

| Confirmed Design decision | Primary layer | Notes |
|---|---|---|
| News = who reported / how reported | **E + F** | Sprint 001 §2 News Object；Design §3 |
| Event = what happened | **A + E + F** | Handbook 5.1 / 5.3；Sprint 001 §3；Sprint 004；Design |
| Evidence = source-backed claims (FACT/ESTIMATE/INFERENCE/UNKNOWN) | **A + B + E** | Handbook H4 / 5.2；Sprint 001 §8；Design splits items from judgment |
| Evaluation = Investor Twin’s assessment of an Event | **F** (target)；partially **E** | Sprint 001 defines fields；Design makes Evaluation an independent object on Event |
| Research Candidate = filter for research time | **A + E + F** | Handbook 5.5 / H5；Sprint 001 §9；Design: one Candidate per Event |
| Decision = human changes investment judgment | **A + B** | Handbook 1.3 / 3.2 / Ch.8；Design non-goal |
| News → Event → Evaluation → Candidate | **A** (flow order) + **F** (object wiring) | Handbook 5.3 already Dedup → Identify Event → Assess…；Design names Evaluation Object |
| One Event → one Importance / Relevance / Candidate | **A + F** | Handbook 5.4 Importance is of the event；Design AC-01–05 |
| Evidence stays on News；not folded into Event | **F** (+ aligns with Sprint 004 preserve News) | Design principle；not yet Architecture file |
| Event must not become a catch-all object | **F** | Design；future Architecture / Event Model candidate |
| Event is deduped unit, not sole information store | **F** | See §4 |

**Governance stop line for Event × Evaluation today：**  
**Design-level (F)**, constrained by Handbook principles (A/B) and Sprint SPECs (E).  
It is **not** yet Constitution text, **not** a separate Architecture file, **not** `05_Event Model`.

---

## 3. Handbook Coverage

| Topic | Covered in Handbook V2.0? | Location | Action |
|---|---|---|---|
| News Intelligence positioning | **Yes** | 3.5 H3；5.3；5.5 | Do not duplicate |
| Evidence Separation | **Yes** | 3.6 H4；5.2 | Do not duplicate |
| Research Queue Principle | **Yes** | 3.7 H5；7.1 | Do not duplicate |
| Source → News → Event → … flow | **Yes (hierarchy)** | 5.1；10.4 | Handbook says Source → News → Event → Impact → Research → Decision. Design inserts Evaluation / Candidate without contradicting that hierarchy |
| Human owns decision | **Yes** | 1.3；3.2；8.1 | Do not duplicate |
| Dedup before Importance / Relevance / Impact / Candidate | **Yes** | 5.3 | Design implements that order |
| Importance vs Relevance | **Yes** | 5.4 | Design ownership follows this |
| Evaluation as named independent object | **No** | — | Intentionally Design-only for now |
| “Event is not the sole information store” | **No as that sentence** | — | Design-only；see §4 |

**Conclusion：** Handbook already carries the product principles. Do **not** add Design ownership detail into Handbook now.

---

## 4. Event Principle Classification

**Sentence：**  
「Event 是去重後的事件單位，但不是資訊唯一儲存單位。」

| Option | Fit? |
|---|---|
| Handbook principle | **Not yet.** Handbook already says Event is in the hierarchy and Dedup precedes assessment； it does not need this sentence to stay consistent |
| Event Model rule | **Premature.** No `05_Event Model` file； Sprint 001/004 refuse to claim that model |
| Architecture rule | **Future candidate**, when a standalone Architecture doc exists and Event×Evaluation is implemented |
| **Design-level rule** | **Yes — current home** |

**Reason：** The sentence is an **anti-collapse** rule for implementation: after Same Event linking, News and Evidence must still exist. Sprint 004 already forbids deleting News. The Design extends that to Evaluation / Evidence ownership. Elevating it to Handbook now would add detail without changing Mission, H3–H5, or Core Loop. Elevating it to Event Model would invent a file that Handbook says exists but the repo correctly has not opened yet.

**Keep as Design-level rule** until either:

1. Event×Evaluation implementation needs an Architecture acceptance rule, or  
2. A real `05_Event Model` is opened for production Event schema.

---

## 5. Ownership Classification

| Ownership | Current layer | Upgrade to formal Architecture rule now? |
|---|---|---|
| News → news information | Sprint SPEC + Design | **No** — already enough for Phase 2 |
| Event → identity / occurrence | Handbook + Sprint 001/004 + Design | **No** — wait for Architecture or Event Model when schema hardens |
| Evidence → source-backed evidence | Handbook H4 + Sprint 001 + Design | **No** — principle already constitutional; item wiring is Design |
| Evaluation → Importance / Relevance / Impact judgment | Design (target)；Sprint 001 fields | **Not yet** — upgrade when implementation Sprint SPEC exists |
| Research Candidate → research opportunity filter | Handbook + Sprint 001 + Design | **No** — one-Candidate-per-Event is Design refinement of existing principle |

**Do not upgrade ownership into Constitution.** Constitution already has H3–H5 and Human Owns Decisions. Ownership tables are object design, not irrevocable product identity.

---

## 6. Sprint 001 Compatibility

| Sprint 001 | Event Integration Design | Conflict? |
|---|---|---|
| Engine input: one News Object | Target input: Event + newsRefs | **No formal conflict** — Sprint 001 scope was foundation before Dedup existed |
| Output: Evaluation Result with news + event + scores | Evaluation Object points at Event；News preserved separately | Compatible direction |
| §9: not one Candidate per article | Design: one Candidate per Event | **Aligned** |
| §4: Same Event keeps all News | Design: Event not sole store | **Aligned** |
| News must not hold Importance in Sprint 004 | Design: Evaluation independent | **Aligned** |
| Title “News → Research Candidate” | Target “News → Event → Evaluation → Candidate” | **Naming transitional**, not a product contradiction |

**Compatible reading：**

- **Sprint 001** = transitional **per-News** evaluation path (valid for unlinked / single News； engine still useful as stopgap).  
- **Event Integration Design** = **target** architecture for linked Events.  
- Do **not** rewrite Sprint 001 SPEC solely to rename the pipeline. Future implementation SPEC should state: Same Event uses Event evaluation； orphan News may still use per-News evaluation until linked.

---

## 7. Need for Event Model?

**Answer: Not now.**

Sprint 001 and Sprint 004 already say they are **not** `05_Event Model`. Current Event needs are met by:

- Handbook 5.1 minimal hierarchy  
- Sprint 001 coarse Event fields (what / when / subject / type)  
- Sprint 004 linking + canonical identity  
- Design ownership boundaries  

**Minimum contents if / when `05_Event Model` is opened later：**

1. Event identity / canonical key rules  
2. Same / Related / Separate semantics (may cite Sprint 004)  
3. Field schema for Event (not Evaluation fields)  
4. Relation to News (`newsRefs`) and Related Events  
5. Explicit non-ownership: no Importance / Relevance / Candidate / full Evidence dump on Event  
6. Boundary vs 031-B market quotes (quotes ≠ Events)

**Open `05_Event Model` only when at least one is true：**

- Production Event store / schema is required  
- Multiple SPECs disagree on Event fields  
- Architecture doc needs a normative Event chapter  
- Event×Evaluation implementation cannot cite a single Event contract  

Until then: Reuse > Add.

---

## 8. Need for Handbook update?

**Answer: No — not required now.**

Current Design is carried by:

| Layer | Carries |
|---|---|
| Handbook V2.0 | Mission, H3–H5, hierarchy, NI flow order, Importance≠Relevance, Human owns Decision |
| Sprint 001 SPEC | News Object, minimal Event, Candidate gates, Evidence separation |
| Sprint 004 SPEC | Dedup / linking / preserve News |
| Event Evaluation Integration Design | Evaluation Object, one evaluation per Event, Evidence not folded into Event |

**Would be “must modify Handbook” only if：**

- Mission or H3–H5 needed to change, or  
- Handbook 5.3 order were wrong (it is not), or  
- Design required Event to own Decision / Recommendation (it does not)

**No Handbook edit for this audit.**

---

## 9. Minimal required future documentation

| When | Document | Why |
|---|---|---|
| Before / with Event×Evaluation implementation | Sprint SPEC (e.g. Sprint 005) | Acceptance: one Evaluation per Event； evidenceRefs； no production writes |
| If implementation spans engines + UI + data contracts | Architecture note or section | Only if a real Architecture file is opened； do not invent one for this Design alone |
| If production Event schema appears | `05_Event Model` | See §7 triggers |
| Not now | Constitution file split、SPEC Index、Knowledge Graph、Roadmap file | Handbook chapters already cover enough |

**Do not create 02–09 files for completeness.**

---

## 10. Recommended next step

1. **Keep** Event × Evaluation Integration Design as the ownership SoT for this topic.  
2. **Do not** modify Handbook, Sprint 001, or Sprint 004.  
3. **Do not** open Constitution / Architecture / Event Model files yet.  
4. When ready for implementation: open a **Sprint SPEC** that cites Handbook 5.3 + Sprint 004 + this Design； implement Evaluation-on-Event without production News/Event DBs unless explicitly in scope.  
5. Treat Sprint 001 per-News engine as transitional until that Sprint lands.  
6. **Do not** start Sprint 005 in this audit.

---

## Acceptance (this Audit)

| ID | Result |
|---|---|
| AC-01 | Handbook not modified |
| AC-02 | No existing SPEC modified |
| AC-03 | No production modified |
| AC-04 | No 02–09 documents added |
| AC-05 | No production code |
| AC-06 | Event / Evaluation governance stop: **Design-level**, under Handbook + Sprint SPECs |
| AC-07 | Formal `05_Event Model`: **not needed now** |
| AC-08 | Handbook V2.0 update: **not needed now** |
