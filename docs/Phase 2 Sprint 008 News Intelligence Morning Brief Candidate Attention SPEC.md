# Phase 2 Sprint 008 — News Intelligence → Morning Brief Candidate Attention
**Draft SPEC 1.0**

| 欄位 | 內容 |
|---|---|
| Status | Draft SPEC 1.0 |
| Source of Truth | Investor Twin Handbook V2.0 |
| 上位文件 | Handbook Ch.2、Ch.3 H3–H5、Ch.5.1–5.5、Ch.6、Ch.7、Ch.11 Phase 2 |
| 沿用 SPEC | Phase 2 Sprint 001 News Intelligence Foundation SPEC（尤其 §9–§11）；Sprint 005 Integration；Sprint 006 Human Gate；Sprint 007 Card Candidate Surface |
| 本 SPEC 不是 | News Collector、News/Event/Candidate DB、05 Event Model、Source Registry、Brief/Today 重設計、自動 Queue/Card/Conclusion/Decision |
| 本 Sprint 交付 | SPEC + acceptance definition。**本文件寫作當下不做 implementation** |

**Subordinate to Investor Twin Handbook V2.0.**  
**Builds on Sprint 001–007.**  
**Reuse > Modify > Add.**  
**This is Attention-surface scope only** — surface pending Research Candidates on Morning Brief / Today; do not rebuild News Intelligence, Human Gate, or Research Cards.

---

## 1. Mission

建立最小產品橋：

```
Research Candidate
    ↓
Morning Brief / Today Attention
    ↓
既有 Human Gate（#queue）
```

使投資人打開 Morning Brief / Today 時能理解：

> 「這些事情可能值得我花時間研究。」

成功標準：
- Pending（與 Watching）Research Candidate 出現在 Brief/Today 的 Candidate Attention 區塊。
- researchQuestion 為主要內容（不是新聞標題）。
- 點選導向既有 `#queue` Human Gate；Disposition 仍由人決定。
- 不自動寫入 Queue / Card / Conclusion / Thesis / Decision / Playbook。

不是新聞網站。  
不是 Research Queue。  
不是 Decision surface。  
不是自動研究引擎。

---

## 2. Product position

Handbook 核心流程：

```
External World
→ News Intelligence
→ Morning Brief
→ Research Queue
→ Research Card
→ …
```

Sprint 001–007 已使下列鏈路在產品中可用（Candidate 輸入為 handoff）：

```
News / Event → Evaluation → Research Candidate → Human Gate → Research Card
```

**本 Sprint 補上的缺口：**

```
Research Candidate → Morning Brief / Today Attention
```

本 Sprint 意圖流程：

```
External World
→ News Intelligence
→ Evaluation
→ Research Candidate
→ Morning Brief / Today Attention
→ Human Gate
→ Research Card
→ Human Research
→ Conclusion
→ Decision
```

| Surface | Role |
|---|---|
| Morning Brief / Today Attention | World Events / Candidates → Investor Attention |
| Human Gate (`#queue`) | Ignore / Watch / Link / Queue（人決定） |
| Research Card | 研究單位；Sprint 007 已可 surface `candidateLinks[]` |
| Conclusion / Decision | 人研究後才寫；Candidate ≠ Conclusion |

---

## 3. Reuse boundary

| Capability | Reuse | Do not |
|---|---|---|
| Candidate handoff | `data/research-candidates-handoff.json` | 新建 Candidate DB / `data/news/` / `data/events/` |
| Disposition ledger | `data/candidate-gate.json`（Pending / Watching / Ignored / Linked / Queued） | 發明新 status model |
| Gate API / view | `serve.ps1` `Build-CandidateGateView`、`GET/POST /api/candidate-gate` | 平行第二套 Gate |
| Gate UI | `js/candidate-gate.js`、`#queueResearchCandidates` | 新 News Center / 新導航 |
| Brief canonical | `data/morning-brief.json` | 第二 Brief 檔、Today 獨立 data model |
| Brief / Today render | `js/data-engine.js` `loadMorningBrief` / `normalizeMorningBrief` / `renderMorningBrief`；`index.html` `#today` | 重寫市場溫度／全球／台灣／即將事件／今日三件事結構 |
| Card surface | Sprint 007 `renderLinkedResearchCandidates` | 改寫 Conclusion / Thesis |
| 031-B Evidence → Brief | `scripts/generate-morning-brief.py` | 把 NI 塞進 Evidence 選題邏輯 |

Sprint 001 §11 約束仍然有效：
- NI **提供 Attention**，不取代 031-B。
- 不把未契約化的 NI 新聞塞進 `globalMarketAndNews.items`。
- Today 與 Morning Brief 共享同一 Brief canonical 與同一渲染路徑；本 Sprint 只 **加薄 Attention 區塊**。

---

## 4. Candidate Attention visibility

### 4.1 Status model（沿用 Sprint 006，不新建）

| Status | Meaning（既有） |
|---|---|
| `Pending` | 尚未 disposition |
| `Watching` | 人選擇持續關注 |
| `Ignored` | 人選擇忽略 |
| `Linked` | 已連結既有 Research Card |
| `Queued` | 已以既有 Card 進入 Research Queue（card-centric） |

預設（無 ledger 紀錄）= `Pending`（與 `Build-CandidateGateView` 一致）。

### 4.2 Brief / Today Attention visibility

| Status | Appear in Candidate Attention? |
|---|---|
| `Pending` | **Yes** |
| `Watching` | **Yes**（仍值得注意；可繼續在 Gate 操作） |
| `Ignored` | **No** |
| `Linked` | **No**（不再作為 pending attention） |
| `Queued` | **No**（不再作為 pending attention） |

說明：
- Linked / Queued 的研究延續在 Research Card / Queue；Brief Attention 不再重複催促。
- Watching 保留在 Attention，因為投資人明確要求持續注意。
- Gate 頁面既有「非 Ignored 仍顯示 Linked/Queued 狀態列」的行為 **可維持不變**；本規則只約束 **Brief/Today Attention**。

### 4.3 Eligibility

僅顯示 handoff 中 `researchCandidates[]` 且 `eligible === true`（或缺省視為 true，與 Gate view 一致）的項目。  
不虛構 Candidate。handoff 空或缺檔 → Attention 為空狀態，不補假資料。

---

## 5. Content rules

每個 Attention item 至少顯示：

| Field | Rule |
|---|---|
| `researchQuestion` | **主要文字**（研究面向） |
| `status` | Pending / Watching |
| `importance` | 來自 evaluation（若有） |
| `relevance` | 來自 evaluation（若有） |
| `impact` | Target / Direction / Strength 摘要（若有）；Impact ≠ Recommendation |
| `eventRef` | 可追溯 |
| evidence/source | 可選、精簡（例如 source + newsRef）；來自 evaluation `evidenceRefs[]` |
| navigation | 明確導向既有 `#queue` Human Gate |

禁止：
- 以新聞 headline 作為主要任務文字。
- 在 Attention 上直接執行 Ignore / Watch / Link / Queue（那些動作留在 Gate）。
- 顯示 Buy/Sell 或自動 Decision 語言。

文案目標：

> What may deserve my research time?

不是：

> What news happened?

中文 UI 標籤建議（實作可擇一，需與現有 UI 語氣一致）：
- `Research Candidates｜值得研究的候選`
- 或等價簡潔中文

---

## 6. Brief / Today integration

### 6.1 Canonical data split

| Concern | Canonical source | Notes |
|---|---|---|
| Evidence Brief sections（市場溫度、全球／台灣、即將事件、今日三件事等） | `data/morning-brief.json` | 031-B 繼續只寫此檔；**不改必填欄契約** |
| Research Candidate Attention | **Derived** from `data/research-candidates-handoff.json` + `data/candidate-gate.json` | Prefer live derive via existing Gate view (`/api/candidate-gate` 或等價共用函式) |

**Derived（推薦，本 SPEC 預設）：**
- Attention 不持久化成第二 Brief 檔。
- Disposition 變更後，下次／當次重新載入 Attention 即反映（Ignore 後不再出現），不需重跑 031-B。
- 不引入 `data/morning-brief-candidates.json` 或任何第二 Brief data source。

**Persisted snapshot（不採用為預設）：**
- 若未來實作堅持寫入 `morning-brief.json`，僅允許 **additive optional** 欄位（見 §7.2），且必須定義與 ledger 的 freshness 規則。  
- Sprint 008 **預設不採用**，以避免 Ignore 後 Brief 快照過期，以及避免擴張 031-B `CANONICAL_FIELDS`。

### 6.2 UI placement

在既有 `#today` Morning Brief / Today Workspace **增加一個薄區塊**（additive section），例如放在：
- 「即將事件」與「今日三件事」之間，或
- 「今日三件事」之前／之後的單一 Attention 區

不新增 top-level nav。  
不重排既有：
- 昨日最重要 3 件事
- 市場溫度
- 全球市場與新聞
- 台灣市場與新聞
- 即將事件
- 今日三件事  
的資料結構與既有語意（除非實作發現 DOM hook 絕對必要，仍禁止改其 schema 語意）。

### 6.3 Rendering path

Today 繼續由既有 Brief 載入／渲染路徑驅動 Evidence 區塊：
- `DataEngine.loadMorningBrief()` → `data/morning-brief.json`
- `DataEngine.renderMorningBrief(...)`

Candidate Attention 在 **同一 Today 頁面渲染流程中** 附加載入／過濾／繪製（例如延伸 `renderMorningBrief`，或在同一 `app.js` Today render 呼叫中並排呼叫共用 Gate view helper）。

禁止：
- 另做獨立 Today data model
- 另做 News Center 頁
- 把 Candidate Attention items 寫進 `globalMarketAndNews.items` / `taiwanMarketAndNews.items` 而無獨立契約

### 6.4 Navigation to Human Gate

Attention item 的主要 CTA / click：
- 導向既有 Queue 頁 Human Gate（`showPage('queue')` 或等價既有導航）
- 可選擇 scroll／focus 既有 `#queueResearchCandidates`
- **不**在 Brief 上直接 POST Gate action

人到達 Gate 後，沿用 Sprint 006：
- Ignore
- Watch
- Link Research Card
- Add to Queue

---

## 7. Data design

### 7.1 Sources of truth

```
handoff:  data/research-candidates-handoff.json
  - researchCandidates[]
  - evaluations[]   (importance / relevance / impact / evidenceRefs)
  - events[] / news[] (traceability; not Attention primary text)

ledger:   data/candidate-gate.json
  - dispositions[]: { eventRef, status, updatedAt, researchQuestion?, cardId? }

brief:    data/morning-brief.json
  - Evidence Brief only for Sprint 008 default path
```

### 7.2 Attention item（derived view shape）

Attention item 為 **derived projection**（不必新檔持久化）。最小欄位：

```json
{
  "eventRef": "evt:…",
  "status": "Pending",
  "researchQuestion": "…",
  "importance": 5,
  "relevance": "High",
  "impact": {
    "target": "…",
    "direction": "Mixed",
    "strength": "High"
  },
  "evidenceRefs": [
    { "newsRef": "news-a", "source": "NVIDIA Official Blog", "class": "FACT" }
  ]
}
```

欄位來源：
- 與 `Build-CandidateGateView` row 對齊（reuse，不平行發明第二 schema）。
- `researchQuestion`：candidate → evaluation.researchCandidate → disposition 後備（與 Gate 一致）。

可選（非必須）若實作選擇 Brief snapshot：

| Field on `morning-brief.json` | Required? | Notes |
|---|---|---|
| `researchCandidateAttention` | **No（預設不做）** | 若未來採用，必須是 optional array；不得成為 031-B 必填；不得混入 `globalMarketAndNews.items` |

### 7.3 Explicitly forbidden persistence

- `data/news/`
- `data/events/`
- Candidate DB / News DB / Event DB
- Second Evidence DB
- Second Morning Brief file

### 7.4 Stale / Missing / UNKNOWN（勿混淆）

| Concept | Domain | Sprint 008 rule |
|---|---|---|
| Evidence freshness `fresh` / `stale` / `missing` | 031-B / market Evidence | 不因 Candidate Attention 改寫；不把 freshness 標成 FACT/UNKNOWN |
| Claim class `FACT` / `ESTIMATE` / `INFERENCE` / `UNKNOWN` | NI evaluation evidenceRefs | 可精簡顯示；不虛構缺失 claim |
| Missing handoff / empty eligible set | Candidate pipeline | 顯示空狀態；不捏造 Candidate |
| Missing evaluation fields | NI | 顯示 `--`；不補假 Importance/Relevance |

---

## 8. Human boundary

Candidate Attention **只**提供注意力與導航。

系統 **不得**因顯示 Attention 而自動：

- 建立 Research Card
- 寫入 Research Queue
- 修改 `researchConclusion` / `researchConclusionHistory`
- 修改 `investmentThesis` / `thesisId`
- 建立或修改 Decision / Position Playbook
- 產出 Buy/Sell

Candidate ≠ Conclusion。  
Evaluation ≠ Fact。  
人研究仍是 Candidate/Evidence → Conclusion/Thesis/Decision 的橋。

既有 Human Gate 的 Link / Queue 行為維持 Sprint 006 契約（含 `candidateLinks[]`、questions dedupe、card-centric Queue）。本 Sprint 不改該契約。

---

## 9. Implementation boundary（證據導向；本 SPEC 不實作）

依目前 repository，實作時**最可能**觸及的最小檔案集合：

| File | Why |
|---|---|
| `index.html` | `#today` 增加 Attention section container；必要時 script cache-bust |
| `js/data-engine.js` | Today/Brief 渲染路徑附加 Attention；`emptyMorningBrief` / `normalizeMorningBrief` 僅在若採 optional Brief field 時才動 |
| `js/candidate-gate.js` 與／或 `app.js` | reuse Gate load／visibility filter；導航至 `#queue` |
| `style.css` | 最小 Attention 樣式（若需要） |
| `tests/p2-008-*.ps1` + `tests/p2-008-*.md` | 新 acceptance harness |
| fixtures（僅測試需要時） | 優先 reuse `tests/fixtures/p2-006-handoff-case-a.json` 等；**prefer 不改既有 fixture** |

可能但非預設必要：
- `serve.ps1` — 僅當需要共用 server-side Attention filter；否則 client filter `GET /api/candidate-gate` 即可。

預設 **不**修改：
- `scripts/generate-morning-brief.py`（031-B）
- `scripts/integrate-news-event-evaluation.py` / evaluate / link / adapters
- Handbook、Sprint 001–007 SPEC 本文
- production `research/*/card.json` conclusions/theses
- Sprint 006 persistence contract

---

## 10. Test plan

Acceptance tests（建議編號自 TEST 89 起；實作時可調整，但語意不可縮水）：

| ID | Case |
|---|---|
| A | Pending Candidate 出現在 Brief / Today Attention |
| B | Ignored Candidate 不出現 |
| C | Linked Candidate 不作為 pending attention 出現 |
| D | Queued Candidate 不作為 pending attention 出現 |
| E | `researchQuestion` 為主要顯示文字（不是 news headline） |
| F | Importance / Relevance / Impact 可見 |
| G | `eventRef` 可追溯 |
| H | 導航到達既有 `#queue` Human Gate |
| I | 僅顯示 Attention **不**自動寫 Queue / Card / Conclusion / Decision |
| J | 031-B Evidence → Brief 既有區塊仍可運作（回歸既有 Brief 結構） |
| K | Sprint 001–007 regression PASS |
| L | Production File Guard PASS |

補充建議：
- Watching Candidate **應**出現在 Attention（與 §4.2 一致）。
- 測試優先 temp root + fixtures；不得改寫 production Card conclusions。

---

## 11. Explicit non-goals

Sprint 008 **不得**包含：

- external news crawler / RSS expansion
- new News DB / Event DB / Candidate DB
- formal Event Model / Source Registry rebuild
- automatic Research Queue creation
- automatic Research Card creation
- automatic Conclusion / Thesis / Decision
- Buy/Sell recommendation
- Knowledge Graph rebuild
- complex Importance×Relevance scoring formula
- new News Center / new top-level navigation
- Today redesign / Brief redesign
- stuffing NI into `globalMarketAndNews.items` without schema contract
- handoff publisher / real collection（可列為後續；非本 Sprint）

---

## 12. Production safety

- 不得刪除既有 production Research Cards。
- 不得改寫既有 Conclusion / Thesis / Decision / Playbook。
- Queue 僅能透過既有 Human Gate 明示動作變更；Attention 顯示本身不寫 Queue。
- 不得建立 `data/news/`、`data/events/`。
- 測試使用 fixtures / temp roots；臨時寫入必須還原。
- 無關 dirty leftovers（Draft DOCX、evidence runs、既有 `data/*` / `research/*/notes|sources|timeline` 髒檔等）保持不提交。
- 本 SPEC 文件寫作不修改 production data、fixtures、Handbook、既有 SPEC 本文。

---

## 13. Dependencies

| Dependency | Status |
|---|---|
| Sprint 005 integrate Candidate shape | Required（handoff payload） |
| Sprint 006 Human Gate + ledger | Required |
| Sprint 007 Card surface | Required for post-Gate continuity；本 Sprint 不改 |
| Populated `research-candidates-handoff.json` | Required for non-empty Attention（fixture OK for acceptance） |
| Real external collection | **Not required** |
| 031-B generator changes | **Not required**（預設 derived path） |

---

## 14. Complexity

**Medium-Low**（UI additive section + derived filter + tests；無新 DB、無 collection、無 Brief schema 必改）。

---

## 15. Success definition

Sprint 008 完成當且僅當：

1. 投資人在 Morning Brief / Today 看到符合 §4–§5 的 Candidate Attention。
2. 能從 Attention 到達既有 Human Gate。
3. Disposition 後 Attention 可見性符合 §4.2。
4. 031-B Evidence Brief 區塊未遭破壞。
5. §10 tests PASS；Production File Guard PASS。
6. 無自動 Queue/Card/Conclusion/Decision 寫入。

---

## 16. Out of scope → later

- integrate stdout → handoff 自動 publish
- real multi-source collection
- NI → Brief 欄位 snapshot 契約（若未來需要 offline Brief）
- Relevance 對 live portfolio/DNA 強化
- Watchlist 專用工作流（超出 Gate Watching）
- Formal Event Model / Source Registry

---

**SPEC READY FOR REVIEW**
