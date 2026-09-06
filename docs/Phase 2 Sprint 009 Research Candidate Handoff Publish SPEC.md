# Phase 2 Sprint 009 — Research Candidate Handoff Publish
**Draft SPEC 1.0**

| 欄位 | 內容 |
|---|---|
| Status | Draft SPEC 1.0 |
| Source of Truth | Investor Twin Handbook V2.0 |
| 上位文件 | Handbook Ch.2、Ch.3 H3–H5、Ch.5、Ch.6、Ch.7、Ch.11 Phase 2 |
| 沿用 SPEC | Sprint 001 News Intelligence Foundation；Sprint 005 Integration；Sprint 006 Human Gate；Sprint 008 Morning Brief Candidate Attention |
| 本 SPEC 不是 | News Collector、News/Event/Candidate DB、05 Event Model、Source Registry、Brief/Today 重設計、自動 Queue/Card/Conclusion/Decision、監控／再觀察迴圈 |
| 本 Sprint 交付 | SPEC + acceptance definition。**本文件寫作當下不做 implementation** |

**Subordinate to Investor Twin Handbook V2.0.**  
**Builds on Sprint 001–008.**  
**Reuse > Modify > Add.**  
**This is plumbing scope only** — publish existing integrate output into the existing handoff file so Attention / Gate can receive Candidates without manual JSON copy.

---

## 1. Mission

關閉目前唯一的手動斷點：

```
News → Event → Evaluation → Research Candidate
        ↓
scripts/integrate-news-event-evaluation.py  （stdout）
        ↓
❌ MANUAL COPY
        ↓
data/research-candidates-handoff.json
        ↓
Morning Brief / Today Attention（Sprint 008）
        ↓
Human Gate（Sprint 006）
```

Sprint 009 建立最小、安全的 **Handoff Publish**：

```
integrate output
    ↓
publish（thin）
    ↓
data/research-candidates-handoff.json
```

成功標準：
- 既有 integrate 結果可被 publish 進既有 handoff，無需手改 JSON。
- Publish 後，既有 Attention / Gate 能看到 eligible Pending Candidates（若 ledger 無相反 disposition）。
- 既有 dispositions 不被重置；Ignored 不會因 republish 變回 Pending。
- 重複 publish 不產生重複 Candidate（同一 `eventRef`）。
- 不自動執行 Human Gate 動作；不建卡；不寫 Queue / Conclusion / Thesis / Decision / Playbook。

不是新的 News Intelligence 引擎。  
不是新聞蒐集。  
不是 Brief / Gate / Card 重設計。

---

## 2. Product position

Handbook 流程：

```
External World → News Intelligence → Morning Brief → Research Queue → Research Card → …
```

Sprint 005–008 已使：

```
integrate →（手動）handoff → Attention → Gate → Card
```

在產品 UI 可用。

**本 Sprint 只補：**

```
integrate → publish → handoff
```

之後投資人仍透過既有 Human Gate 決定：

- Ignore
- Watch
- Link Research Card
- Add to Queue

Candidate ≠ Conclusion。  
Candidate 不自動變成 Queue / Card / Decision。

---

## 3. Reuse boundary

| Capability | Reuse | Do not |
|---|---|---|
| Integrate output | `scripts/integrate-news-event-evaluation.py` → `news[]` / `events[]` / `links[]` / `evaluations[]` / `researchCandidates[]` | 重寫 evaluate / link / scoring |
| Handoff file | `data/research-candidates-handoff.json` | 第二 Candidate store / `data/news/` / `data/events/` |
| Gate ledger | `data/candidate-gate.json` dispositions（`eventRef` + status） | publish 寫入 ledger 或重置 status |
| Gate API / UI | `serve.ps1` `/api/candidate-gate`；`js/candidate-gate.js` | 平行 Gate |
| Attention | Sprint 008 derived Attention | Brief redesign；塞入 `globalMarketAndNews.items` |
| Production File Guard | Sprint 001–008 測試模式 | 改寫 production Card conclusions |

---

## 4. Canonical identity（既有欄位，不建 DB）

Candidate / Evaluation / Event 的穩定身分使用既有欄位：

| Object | Identity field | Notes |
|---|---|---|
| Research Candidate | `eventRef` | Gate ledger、Attention、Card `candidateLinks` 皆以此鍵 |
| Evaluation | `eventRef` | 與 Candidate 對齊 |
| Event | `eventId`（= Candidate `eventRef`） | 與 Sprint 005 一致 |
| News | `id`（fallback：既有 integrate/`news_id` 規則） | 用於 upsert，非新建 DB |

**禁止**為 publish 另建 Candidate ID registry 或資料庫。

若缺少 `eventRef` / `eventId`，該 Candidate **不得**被 publish（fail closed，不虛構身分）。

---

## 5. Publish semantics

### 5.1 Input

既有 integrate 輸出（stdin、檔案、或 integrate 行程內直接物件），形狀：

```json
{
  "news": [ … ],
  "events": [ … ],
  "links": [ … ],
  "evaluations": [ … ],
  "researchCandidates": [ … ]
}
```

來源：`scripts/integrate-news-event-evaluation.py`（Sprint 005）。  
**不要求**真實外部蒐集；fixtures / adapter stdout 即可作為 acceptance 輸入。

### 5.2 Output

唯一寫入目標（本 Sprint）：

`data/research-candidates-handoff.json`

可選：在實作中允許經明確參數指定 root（測試 temp root）。  
**不得**寫入：

- `data/candidate-gate.json`（ledger）
- `data/morning-brief.json`（031-B）
- `data/research-queue.json`
- `research/*/card.json`（或任何 Conclusion / Thesis / Decision / Playbook）
- `data/news/`、`data/events/`（不得建立）

### 5.3 Schema preservation

Publish **必須**維持既有 handoff 契約欄位（可空陣列，不可改名／改語意）：

- `news`
- `events`
- `links`（若 integrate 有提供則保留／合併）
- `evaluations`
- `researchCandidates`

不新增必填頂層欄位。  
不把 Importance / Relevance / Impact 寫回 News 物件。  
不把 disposition status 寫進 handoff（status 仍只在 ledger）。

### 5.4 Eligible Candidates

- 僅 publish `researchCandidates[]` 中 `eligible === true` 的項目（與 Gate view 一致）。
- `evaluations[]` / `events[]` / `news[]` 應足以支撐 Attention／Gate 顯示（Imp/Rel/Impact、evidenceRefs、researchQuestion、eventRef）。
- 不虛構 missing evaluation 欄位。

### 5.5 Merge / idempotency（最小安全規則）

預設策略：**依 identity upsert，additive merge**。

| Array | Upsert key | Rule |
|---|---|---|
| `researchCandidates` | `eventRef` | 同鍵 → 更新該列；不同鍵 → 附加；禁止同鍵兩列 |
| `evaluations` | `eventRef` | 同上 |
| `events` | `eventId` | 同上 |
| `news` | `id` | 同上 |
| `links` | 最小既有可解釋鍵（建議 `newsA` + `newsB` + `relation`） | upsert；避免無意義重複 |

重複執行同一 integrate 輸出：
- handoff 中同一 `eventRef` **仍只有一筆** Candidate。
- 不產生「第二個 Pending 複本」。

**Additive：** 本次 publish 未包含的既有 `eventRef` **預設保留**（不因另一次較小的 integrate 輸入而靜默刪除），除非實作提供明確、文件化的 `--replace-handoff` 危險選項（**非預設**；acceptance 以 merge 為準）。

### 5.6 Disposition / ledger preservation

| Rule | Behavior |
|---|---|
| Publish **不得**讀寫改變 ledger 語意以外的副作用 | 預設 **完全不寫** `data/candidate-gate.json` |
| Ignored / Linked / Queued / Watching | 維持 ledger 原狀 |
| Republish 同一 `eventRef` | **不得**把 Ignored 變回 Pending |
| Attention 可見性 | 仍完全遵循 Sprint 008：Pending + Watching 可見；Ignored / Linked / Queued 不可見為 pending attention |

說明：handoff 內可仍含該 Candidate 列（供追溯）；**可見性由 ledger status 決定**，不是由刪除 handoff 列決定。

### 5.7 Non-automation（硬邊界）

Publish **不得**自動：

- Ignore / Watch / Link / Queue
- 建立 Research Card
- 寫入 Research Queue
- 修改 `researchConclusion` / `researchConclusionHistory`
- 修改 Thesis / Decision / Position Playbook
- 產出 Buy/Sell
- 重跑或改寫 031-B Evidence → Brief 選題

### 5.8 Invocation shape（實作選一，保持最薄）

允許其一（prefer 更薄者）：

1. **Thin publisher script**（例如讀 integrate JSON → 寫 handoff），或  
2. **Opt-in flag on integrate**（例如 `--publish-handoff`），預設仍維持 stdout-only 行為以相容 Sprint 005。

無論哪種：
- 必須是 **明確 opt-in**（不可在一般 evaluate/integrate 測試路徑默默寫 production handoff）。
- 測試必須使用 temp root / fixtures。
- Production File Guard 必須覆蓋「未授權路徑不得被改寫」。

---

## 6. Downstream behavior（不改語意，只接通）

Publish 成功後，既有鏈路應無需手拷 JSON：

```
handoff
→ Sprint 008 Attention（Pending/Watching）
→ Sprint 006 Human Gate（#queue）
→（人決定）Link / Queue → Card candidateLinks（006/007）
```

本 Sprint **不修改**：
- Attention 顯示規則（008）
- Gate 動作與狀態機（006）
- Card surface（007）
- `Build-CandidateGateView` 的 eligible / disposition 合併邏輯（除非 publish 暴露既有 bug；預設不改）

---

## 7. Implementation boundary（證據導向；本 SPEC 不實作）

依目前 repository，實作時**最可能**觸及：

| File | Why |
|---|---|
| `scripts/integrate-news-event-evaluation.py` **或** 新 thin `scripts/publish-research-candidates-handoff.py`（擇一最薄） | publish 入口 |
| `tests/p2-009-*.ps1` + `tests/p2-009-*.md` | acceptance |
| 既有 fixtures（reuse `tests/fixtures/p2-005-*` / `p2-006-handoff-case-a.json`） | prefer 不改 fixture；必要時只加新 fixture |

預設 **不**修改：
- `js/candidate-gate.js` / Attention UI（除非測試 hook 絕對必要）
- `serve.ps1` Gate API 契約
- `scripts/generate-morning-brief.py`
- Handbook、Sprint 001–008 SPEC 本文
- production `research/*/card.json` conclusions/theses

若實作發現必須擴張架構（新 DB、新 schema、改 Gate 狀態機），**停止並回報**，不得自行發明。

---

## 8. Test plan

Acceptance（建議編號自 TEST 102 起；語意不可縮水）：

| ID | Case |
|---|---|
| A | 既有 integrate 輸出可被 publish 進 handoff |
| B | Publish 後 eligible Candidate 可被既有 Attention 路徑看見（Pending，且無相反 disposition） |
| C | Pending / Watching 行為維持（ledger Watching 仍可視為 Attention） |
| D | Ignored Candidate 在 Attention 仍隱藏（republish 後仍隱藏） |
| E | 重複 publish 不產生重複 `eventRef` Candidate |
| F | Publish 不觸發任何自動 Gate action |
| G | Publish 不自動寫 Card / Queue / Conclusion / Thesis / Decision / Playbook |
| H | Sprint 001–008 regression PASS |
| I | Production File Guard PASS |
| J | Production Card conclusions / theses 不變 |

補充建議：
- 驗證 ledger 檔在預設 publish 路徑下 hash 不變。
- 驗證未建立 `data/news/`、`data/events/`。
- temp root；還原任何臨時寫入。

---

## 9. Explicit non-goals

Sprint 009 **不得**包含：

- real crawler / RSS / news collection / source expansion  
- formal Event Model / Source Registry / Knowledge Graph rebuild  
- News DB / Event DB / Candidate DB / second Evidence DB  
- Importance / Relevance / Impact / scoring redesign  
- monitoring / re-observation loop  
- automatic research / conclusion / thesis / decision / buy-sell  
- Brief / Today redesign；News Center；新導航  
- 把 NI 塞進 `globalMarketAndNews.items`  
- 預設覆寫／清空整個 handoff（除非明確非預設危險選項且有測試）

---

## 10. Production safety

- 不得刪除既有 production Research Cards。  
- 不得改寫既有 Conclusion / Thesis / Decision / Playbook。  
- Queue 僅能經既有 Human Gate 明示動作變更。  
- Publish 預設不得改寫 `data/candidate-gate.json`。  
- 不得建立 `data/news/`、`data/events/`。  
- 測試使用 fixtures / temp roots；臨時寫入必須還原。  
- 無關 dirty leftovers 保持不提交。  
- 本 SPEC 寫作除本檔外不修改其他 repository 內容。

---

## 11. Dependencies

| Dependency | Required? |
|---|---|
| Sprint 005 integrate output shape | Yes |
| Sprint 006 Gate + ledger | Yes（consume only） |
| Sprint 008 Attention | Yes（consume only） |
| Real external collection | **No** |
| 031-B generator changes | **No** |

---

## 12. Complexity / risk

**Complexity:** Low  
**Risk:** Low  

主要風險：錯誤的 overwrite 策略誤刪其他 Candidates，或誤寫 ledger。以 **opt-in publish + eventRef upsert + ledger untouched** 降低風險。

---

## 13. Success definition

Sprint 009 完成當且僅當：

1. 可用既有 integrate 輸出 publish 至 `data/research-candidates-handoff.json`（測試環境驗證）。  
2. 無需手動拷貝 JSON，Attention / Gate 能接收 eligible Candidates。  
3. 重複 publish idempotent；Ignored 不回 Pending。  
4. 無自動 Gate / Card / Queue / Conclusion / Decision 寫入。  
5. §8 tests PASS；Production File Guard PASS。  
6. Sprint 001–008 regression PASS。

---

## 14. Out of scope → later

- integrate 排程／每日自動跑  
- multi-source live collection  
- NI monitoring / thesis revisit  
- post-Link research session UX  
- Brief snapshot 契約  

---

**SPEC READY FOR REVIEW**
