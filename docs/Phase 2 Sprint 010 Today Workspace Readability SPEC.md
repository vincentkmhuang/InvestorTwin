# Phase 2 Sprint 010 — Today Workspace Readability
**Draft SPEC 1.0**

| 欄位 | 內容 |
|---|---|
| Status | Draft SPEC 1.0 |
| Source of Truth | Investor Twin Handbook V2.0 |
| 上位文件 | Handbook Ch.2、Ch.3、Ch.6 Morning Brief & Today Workspace、Ch.7、Ch.11 Phase 2 |
| 沿用 SPEC | Sprint 001 News Intelligence Foundation；Sprint 008 Candidate Attention；Sprint 009 Handoff Publish |
| 分析依據 | Sprint 010 READ / ANALYZE / DESIGN（Today presentation collapse + Brief quote-as-news 分離） |
| 本 SPEC 不是 | Morning Brief 內容／生成器重設計、News Collector、News/Event/Candidate DB、自動 Queue/Card/Decision、一般性美化 UI |
| 本 Sprint 交付 | SPEC + acceptance definition。**本文件寫作當下不做 implementation** |

**Subordinate to Investor Twin Handbook V2.0.**  
**Builds on Sprint 001–009.**  
**Reuse > Modify > Add.**  
**Presentation-first only** — fix how Today presents existing Brief + Candidate Attention; do not redesign Morning Brief data generation or News Intelligence.

---

## 1. Mission

讓 **Today Workspace** 成為可在約 **30 秒** 內完成第一輪理解的每日投資閱讀介面：

> 「讓投資人可以快速讀懂 Today，並知道什麼值得進一步研究。」

成功標準：
- 清楚的 primary vs secondary 層級。
- 減少同一資訊在多區塊重複佔版。
- 區塊語意誠實（「新聞」不暗示每條報價都是新聞事件）。
- 重要區塊不會僅因 presentation dedup 而變成空白 `--`。
- Candidate Attention 仍是注意力層，不是第二個新聞牆。
- 不改 canonical Brief schema；不自動寫 Queue / Card / Conclusion / Decision。

**不是**把 UI 做漂亮。  
**不是**重做 Morning Brief。  
**不是**發明 News objects 來掩蓋 quote-as-news。

---

## 2. Problem statement

Sprint 010 分析確認兩個**不同**問題：

| Problem | Nature | Sprint 010? |
|---|---|---|
| Today presentation collapse / weak hierarchy | UI / renderer / presentation dedup | **Yes — this sprint** |
| Brief 「全球／台灣市場與新聞」多為 quote-as-news | Morning Brief **content / generator** | **No — document as follow-up** |

實際症狀（repository evidence）：
- `#today` 區塊齊全，但全球／台灣列表常因 shared presentation-dedup（市場溫度先標記 instruments）而塌成 `--`。
- `macroDecisionLens` → `#morningTopThings` 可被同一機制清空。
- 真正較像敘事的內容常在 `aiIndustryHighlights`，而 DOM 為 `hidden`。
- 投資人 30 秒內難以回答「全球／台灣真正重要的新聞是什麼？」；相對地，「今日三件事 why」與 Candidate Attention（handoff 有資料時）較可讀。

**Root cause separation must not be collapsed into one CSS-only or one data-model rewrite.**

---

## 3. User-visible outcome

實作完成後，投資人打開 Today 應能更快回答：

1. 昨天最重要的事情是什麼？  
2. 市場現在是什麼狀態？  
3. 全球／台灣區塊裡**目前能誠實呈現**的重要資訊是什麼？（即使底層仍是報價摘要，也不應被 presentation 洗成空白）  
4. 接下來有什麼事件？  
5. 今天最該注意什麼？  
6. 有沒有值得花研究時間的 Candidate？

閱讀行為目標：
- **第一閱讀路徑（~30s）**取得 primary：昨日重點 → 市場溫度 → 今日三件事 → Candidates（§9.1 / §9.1a）。  
- **第二輪**再掃 supporting：全球／台灣／即將事件，且不被重複報價牆淹沒。  
- Supporting 區塊不得把 primary 推離第一閱讀路徑；必要時必須 elevation / reorder / equivalent（非僅 CSS）。  
- **不需要**為了找「值得研究什麼」而讀完整頁長文。

---

## 4. Current Today structure（必須先承認現況）

實際 DOM 順序（`index.html` `#today`）：

1. 昨日最重要 3 件事  
2. 市場溫度  
3. 全球市場與新聞  
4. 台灣市場與新聞  
5. 即將事件  
6. Research Candidates｜值得研究的候選（Sprint 008 additive）  
7. 今日三件事  

Canonical path（必須維持）：

```
data/morning-brief.json
  → DataEngine.loadMorningBrief / normalizeMorningBrief
  → DataEngine.renderMorningBrief
  → CandidateGate.renderAttention（derived handoff + ledger）
```

確認邊界：
- Today **不是**獨立資料模型。  
- Research Queue **不是** Today 固定區塊。  
- Opportunity Radar **不是**每日固定 Today 區塊。  
- Candidate Attention **是**注意力層，不取代 Brief 結構。

---

## 5. Readability principles

### A. Presentation-first
先修呈現與掃描路徑；不以改 Brief 架構代替。

### B. Primary vs Secondary
不是每個欄位都值得同等視覺權重。

**Primary（第一輪必讀）：**
- 昨日最重要 3 件事  
- 市場溫度（Detect，不 Decide）  
- 今日三件事（優先注意）  
- Research Candidates（值得研究？）

**Secondary（第二輪掃讀）：**
- 全球市場與新聞  
- 台灣市場與新聞  
- 即將事件  

### C. One fact, one primary home
同一市場報價／instrument 不應在多個區塊以同等長度重複主導版面。  
Presentation 可縮短或降權 secondary 重複；**不得**用錯誤 dedup 把整段區塊洗空。

### D. Section honesty
「全球／台灣市場與新聞」若底層仍是報價摘要，呈現上不得假裝每條都是新聞事件。  
允許以較誠實的顯示語氣／層級區分 **market status** vs **news/event-like** vs **why it matters**（仍用既有欄位，不新建 News DB）。

### E. Candidate Attention is attention
researchQuestion 為主；不是 headline feed；動作仍只導向既有 Human Gate。

### F. Today remains Morning Brief-derived
繼續共享 canonical Brief data + renderer path。

### G. Human decision remains human
不自動 Ignore / Watch / Link / Queue / Card / Conclusion / Thesis / Decision / Buy-Sell。

### H. Preserve traceability
不丟棄既有 source / evidence 參考；不把追溯壓平成不可回溯口號。

---

## 6. In scope

薄範圍，僅 Today presentation / scanability：

- visual hierarchy（primary vs secondary）  
- section hierarchy / grouping / spacing（服務可讀，非裝飾）  
- 減少重複顯示文字（display-level）  
- 改善 Candidate Attention 可掃描性  
- 在**不改 schema**前提下，露出 Brief 中已有、有助閱讀的欄位（例如目前 hidden 的有用 highlights，若證據支持）  
- 修正 presentation dedup / render 行為，避免重要區塊僅因 dedup 變空  
- 更清楚區分：market status / news-or-event-like / why it matters / upcoming / research candidate  
- 若可讀性稽核證明需要，允許**有限**調整區塊閱讀順序（須寫進 acceptance；預設保留現有概念結構）  
- 對應 tests  

**不**新增資訊來源。  
**不**新增 News/Event/Candidate storage。

---

## 7. Out of scope

明確拒絕：

- real external news collection / crawler / RSS / Source Registry  
- formal Event Model；News / Event / Candidate DB；second Evidence DB  
- new scoring / complex relevance  
- new Today data model；new Morning Brief file；new navigation / top-level page  
- automatic Queue / Card / Conclusion / Thesis / Decision / Buy-Sell  
- Knowledge Graph rebuild；monitoring / re-observation loop  
- 與可讀性無關的大型視覺改版  
- 把 NI Candidates 塞進 `globalMarketAndNews.items` 而無契約  

---

## 8. Morning Brief boundary（硬邊界）

Sprint 010 **不得**重設計 Morning Brief 資料生成。

**Do not rewrite：**
- `scripts/generate-morning-brief.py`  
- 031-B Evidence selection semantics  
- News Intelligence engines / Sprint 009 publish pipeline  
- Sprint 001 NI→Brief 欄位契約（仍 deferred）  

**Keep：**
- `data/morning-brief.json` 為 canonical Brief source  
- 既有 Brief schema（無 blocker 不得增刪必填欄）  

### Follow-up（本 Sprint 只記錄，不實作）

**「Quote-as-News」**（全球／台灣區塊以報價組裝成「新聞」項）是 **Morning Brief content problem**，應由後續獨立 sprint 處理。  

它**不是** Sprint 010 改 Today 資料架構或發明 News objects 的理由。  
Sprint 010 最多做到：誠實呈現、減少重複、避免 presentation 自毀區塊。

---

## 9. Proposed presentation hierarchy（行為，非 CSS 數值）

描述閱讀行為與資訊層級；**不**在本 SPEC 規定具體 px / 色碼。

### 9.1 First-pass scan path（~30s）— REQUIRED

Intended **primary** first-pass hierarchy（必須能被快速取得）:

1. **昨日最重要 3 件事** — 能讀到「昨天什麼最重要」（不得只剩空白 list）。  
2. **市場溫度** — Detect：主要市場狀態一眼可掃。  
3. **今日三件事** — 「今天最該注意什麼 / why it matters」。  
4. **Research Candidates｜值得研究的候選** — 「有沒有值得研究的問題？」（Pending/Watching）。  

### 9.1a Primary elevation principle（REQUIRED ACCEPTANCE PRINCIPLE）

> Today 的主要資訊必須能在第一閱讀路徑中被快速取得。  
> 如果目前 section order 使「今日三件事」或「Research Candidates」  
> 被全球／台灣／即將事件等次要資訊推離主要閱讀路徑，  
> Sprint 010 必須透過合理的 section elevation / reorder / equivalent  
> presentation hierarchy 解決，而不能只靠 CSS 美化。

Rules:
- Does **not** mandate one exact visual layout.  
- **Does** make primary-information elevation **mandatory when needed**.  
- Implementer may use **reorder** OR an **equivalent** presentation mechanism (e.g. primary band / sticky first-pass cluster) that keeps §9.1 in the first reading path.  
- **Forbidden:** CSS-only interpretation that leaves the primary ~30s path buried below the fold while secondary Global / Taiwan / Upcoming still dominate the first viewport.

### 9.2 Second-pass / supporting scan path

Supporting sections（重要，但不得阻擋 §9.1）:

5. **全球市場與新聞** — 次要脈絡；重複報價降權或縮短；**不得**因 dedup 變空殼。  
6. **台灣市場與新聞** — 同上。  
7. **即將事件** — 時間相關事件可掃；過期／陳舊應可辨識（若既有資料含 asOf/when）。  

These may remain on the same page. Exact placement is implementation-chosen **provided** the primary reading path (§9.1) is preserved and quickly understood.

### 9.3 Information roles（顯示層）

| Role | Meaning | Typical homes |
|---|---|---|
| Market status | Detect quotes / temperature | 市場溫度；必要時全球／台灣摘要降權 |
| News / event-like | 事件或敘事（若 Brief 已有） | 全球／台灣；或既有 highlights 之露出 |
| Why it matters | Judgment / attention priority | 今日三件事 |
| Upcoming | Future/timed item | 即將事件 |
| Research candidate | Worth research time? | Candidate Attention |

### 9.4 Dedup safety rule（本 Sprint 關鍵）

Presentation dedup 的目的是減少重複噪音，**不是**刪光區塊。

Acceptance 必須禁止：
- 僅因 market temperature 已標記同一 instrument，就使「昨日 list / 全球 items / 台灣 items」整段只剩 `--` 且無替代可讀內容。

允許：
- 縮短 secondary 重複文字  
- 以 primary home 保留完整資訊、secondary 顯示 residual / reference-level 資訊  

### 9.5 Candidate Attention

- 維持 Sprint 008 可見性：Pending + Watching；Ignored / Linked / Queued 不作 pending attention。  
- researchQuestion 為主。  
- 導航仍至既有 `#queue` Human Gate。  
- 改善掃描：更短卡片層級、更清楚 CTA；不變成新聞列表。

### 9.6 Ordering / elevation

- 預設**保留**現有**概念區塊集合**（§4 所列七類資訊仍存在於 Today）。  
- **概念結構 ≠ 鎖定目前 DOM 順序。** 目前 DOM 將全球／台灣／即將事件放在「今日三件事／Candidates」之前；若該順序使 §9.1 離開第一閱讀路徑，則 §9.1a **要求** elevation / reorder / equivalent hierarchy（不是可選美化）。  
- 不得新增 top-level nav / 第二 Today 頁。  
- 不得刪除 Sprint 008 Candidate Attention 區塊。

---

## 10. Acceptance tests

建議編號自 TEST 112 起；語意不可縮水。

| ID | Case |
|---|---|
| A | **30-second primary path**：投資人能識別 §9.1 四項 primary（昨日重點、市場狀態、今日三件事、Candidates—在 handoff 有 Pending/Watching 時），**不必**先讀完整個全球／台灣／即將事件區塊 |
| A2 | **Primary elevation**：若目前 section order 把「今日三件事」或 Candidates 推離主要閱讀路徑，必須有 elevation / reorder / equivalent；**FAIL** if supporting sections push them out of first-pass path |
| B | **Hierarchy**：primary 視覺／閱讀權重大於 secondary；**FAIL** if first viewport gives disproportionate weight to secondary Global/Taiwan/Upcoming while primary path remains buried |
| B2 | **Not cosmetic-only**：**FAIL** if “readability” is only cosmetic CSS while reading hierarchy / first-pass path is unchanged |
| C | **Repetition**：同一 quote 不在多區塊以同等完整長文重複主導 |
| D | **Section integrity**：全球／台灣（與昨日 list，若適用）不因 presentation dedup 單獨變空；supporting sections remain accessible and understandable |
| E | **Candidate Attention**：Pending/Watching 可見且可掃；researchQuestion 為主 |
| F | **Human Gate**：Candidate 動作仍只經既有 Gate |
| G | **No automation**：無自動 Queue / Card / Conclusion / Thesis / Decision 寫入 |
| H | **Canonical data**：仍讀 `data/morning-brief.json`；無第二 Today/Brief 資料模型；**PASS** does not require canonical data-model change |
| I | **Regression**：Sprint 001–009 PASS |
| J | **Production File Guard**：production Cards / conclusions / theses 不變；無 `data/news/` / `data/events/` |

補充：
- `generate-morning-brief.py` 預設不被本 Sprint 修改（若例外修改須先 STOP 並證明 blocker）。  
- Sprint 008/009 契約不變。  
- Supporting Global / Taiwan / Upcoming 仍須可達、可理解，但不得阻擋 §9.1。

---

## 11. Production safety

- 不得刪除 production Research Cards。  
- 不得改寫 Conclusion / Thesis / Decision / Playbook。  
- 測試用 fixtures / temp roots；臨時寫入須還原。  
- 不建立 News/Event/Candidate DB。  
- 無關 dirty leftovers 不提交。  
- 本 SPEC 寫作除本檔外不修改其他 repository 內容。

---

## 12. Regression requirements

必須通過：
- Sprint 001–009 regression suite（既有入口鏈）  
- Production File Guard  
- Sprint 008 Attention 可見性  
- Sprint 009 publish 行為不受破壞（本 Sprint 不改 publish）  

---

## 13. Expected files（實作時；本 SPEC 不修改）

**Likely：**
- `style.css`  
- `index.html`（最小 DOM／標籤調整）  
- `js/data-engine.js`（僅當 display-only / dedup-safety 確實必要）  
- `app.js`（僅當綁定／順序確實必要）  
- `tests/p2-010-*`  

**Possibly touch：** `js/candidate-gate.js`（Attention 可掃描性，不改 disposition 語意）

**Must NOT change unless blocker proven：**
- Handbook  
- Sprint 001 / 008 / 009 SPECs  
- `scripts/generate-morning-brief.py` / 031-B semantics  
- NI engines / Sprint 009 publish  
- production Card conclusions / theses  

若實作發現必須改 Brief generator 或新建資料模型 → **STOP and report**，不得 silently expand scope。

---

## 14. Non-goals

- 一般 UI beautification  
- Morning Brief content redesign / quote-as-news 根治  
- News object invention  
- architecture rebuild  
- Sprint 011 任何工作  

---

## 15. Follow-up parking（explicit）

| Item | Why later |
|---|---|
| Quote-as-News → real Brief news/event contract | Content/generator；Sprint 001 deferred NI→Brief |
| Market Temperature 補齊 Handbook instruments | Brief/Evidence 內容，非純 presentation |
| NI Candidates 進入 Brief 契約化欄位 | 超出 presentation-first |
| Monitoring / re-observation | 非可讀性 sprint |

---

## 16. Complexity / risk

**Complexity:** Medium-Low（presentation + dedup-safety；無新 DB）  
**Risk:** Medium-Low（共享 Brief renderer；需 regression）  

---

## 17. Success definition

Sprint 010 完成當且僅當：

1. Today 第一輪掃描明顯優於現況（§10 A–D，含 A2 / B2）。  
2. §9.1 primary path 可在約 30 秒內取得；必要時已做 elevation（§9.1a），非僅 CSS 美化。  
3. 重要區塊不因 presentation dedup 自毀；supporting sections 仍可達。  
4. Candidate Attention 仍符合 Sprint 008。  
5. Brief canonical path / schema 維持。  
6. 無自動化寫入；Production File Guard PASS。  
7. Sprint 001–009 regression PASS。  
8. Quote-as-News 根因仍標記為 follow-up，未被假裝已解決。

---

## 18. Final verdict

**SPEC READY FOR REVIEW**

Sprint 010 = **Today Workspace Readability（presentation-first）**.  
Morning Brief content / quote-as-news = **later, separate**.  
Do not implement in the SPEC-writing turn.
