# Phase 2 Sprint 004 — News Dedup & Event Linking
**Draft SPEC 1.0**

| 欄位 | 內容 |
|---|---|
| Status | Draft SPEC 1.0 |
| Source of Truth | Investor Twin Handbook V2.0 |
| 上位文件 | Handbook Ch.2、Ch.3 H3、Ch.5.1 / 5.3 / 5.5、Ch.11 Phase 2 |
| 沿用 SPEC | Phase 2 Sprint 001 News Intelligence Foundation SPEC §2–§4、§10 |
| 本 SPEC 不是 | 05 Event Model、Source Registry、News Collector、Presentation Dedup、完整 NI 大文件 |
| 本 Sprint 交付 | SPEC + Acceptance Cases only。**不**做 production implementation |

---

## 1. 目的

建立最小、可解釋的 **News Dedup & Event Linking**。

```
多篇 News
    ↓
判斷是否描述同一個 Event
    ↓
Same Event / Related Event / Separate Event
```

核心目標：不同來源的 News 能否指到同一件「世界上發生的事」。

本 Sprint **不**建立 News / Event production database，**不**寫 Brief / Queue / Card / Decision。

---

## 2. 與 Handbook / Sprint 001 的關係

Handbook 5.1：`Source → News / Information → Event → Impact → Research → Decision`  
Handbook 5.3：`Collect → Normalize → Deduplicate → Identify Event → …`  
Sprint 001 §4 已定義三種關係，並禁止為畫面乾淨刪原始 News。

本 SPEC **闡述** Sprint 001 §4，**不取代、不修改** Sprint 001 SPEC。  
本 Sprint **不宣稱**這是 05_Event Model。`Event-001` 只是 acceptance identity，不是 production Event store。

未發現與 Handbook / Sprint 001 SPEC 的正式衝突。

---

## 3. 兩個不同的 Dedup

| 種類 | 問題 | 既有位置 | 本 Sprint |
|---|---|---|---|
| **News Dedup** | 多則 News 是否描述同一 Event | 尚未實作（Sprint 001 只定義） | **本 SPEC 範圍** |
| **Presentation Dedup** | 畫面上不要重複顯示相同資訊 | `briefDedupText`；031-B `(title, researchId)` | **禁止當成 News Dedup** |

不得修改：`briefDedupText`、031-B、Morning Brief renderer、Today。

---

## 4. 物件邊界

沿用 Sprint 001：

- **News** = 誰報導了這件事（保留 `source` / `title` / `publishedTime` / `url` / `summary` 或 `content` / `subject` / `eventRef`）
- **Event** = 發生了什麼事（What / When / Subject / Event Type）
- 一則 News ≠ 一個 Event ≠ 一項研究

Dedup 的輸出只允許：

| 輸出 | 含義 |
|---|---|
| `relation` | `Same Event` / `Related Event` / `Separate Event` |
| `eventRef` | News 指向的 Event identity |
| `relatedEventRef` | Related 時可指向另一 Event；Same / Separate 可省略 |
| `reason` | 可解釋依據（哪些欄位相同、哪裡有新資訊） |

News Object **不得**因 Dedup 被刪除。  
News Object **不得**被寫入 `importance` / `relevance` / `impact` / `researchCandidate`。  
Evaluation 仍由 Sprint 001 engine 負責，本 Sprint 不重做。

---

## 5. 三種關係

### 5.1 Same Event

不同來源描述**同一件事**。

```
News A ─┐
        ├── Event-001
News B ─┘
```

規則：兩則都保留；`eventRef` 相同；不得刪 Reuters 或 Official 任一則。

### 5.2 Related Event

有關聯，但後者是**新的事件或新的事件狀態**。

```
News A → Event-001
News B → Event-002
Event-001 ─related→ Event-002
```

可建 `relatedEvent` / relation。**不得 merge** 成同一個 Event。

### 5.3 Separate Event

沒有足夠證據顯示是同一件事。

即使同一公司、同一產業、同一天，也**不能**因此視為 Same Event。

預設：證據不足 → Separate Event。不因不確定而 merge。

---

## 6. Event Identity（最小、可解釋）

Event identity 回答「發生了什麼」，不是「誰先報」。

判斷 **至少**同時看：

| 維度 | 問 | 不得單獨當成 Same Event |
|---|---|---|
| subject / entity | 關於誰 | subject 相同 |
| event type | 哪一類事（沿用 Sprint 001 粗分類） | type 相同 |
| event time | 事件何時發生（不是只看 publishedTime） | 同一天發布 |
| core fact / what | 核心事實是否同一件 | 標題很像 |
| new information | B 是否帶來新的事件狀態 | 用詞不同 |

**禁止：** title similarity only。  
**禁止：** subject + date → Same Event。  
**禁止：** embedding / vector DB / ML classifier / LLM autonomous dedup。  
**禁止：** 複雜 similarity score。

Sprint 004 只允許 deterministic / explainable 規則。

### 6.1 Same Event 必要條件（全部成立）

1. Subject / entity 指向同一組主體（含明顯別名，例如 NVIDIA / NVDA；不得靠模糊公司名猜測）。
2. Event type 相同（Sprint 001 粗分類）。
3. Event time 相容（同一事件日或同一宣告窗口；未知則標 UNKNOWN，不臆造後再 merge）。
4. Core fact / what 相同（同一件已發生的事，不是「同一主題下的下一階段」）。
5. B **沒有**構成新事件狀態的新資訊（例如開始審查、交易完成、另一項交易）。

### 6.2 Related Event 條件（在不是 Same 的前提下）

同時：

1. 共享 subject，或明確指向同一先前 Event；且
2. Core fact **不同**，或 B 是 A 的新事件狀態（announce → review / complete / terminate）；且
3. 存在可指出的關聯（同一交易的後續、同一政策路徑的下一步）。

### 6.3 Separate Event

下列任一即 Separate：

- 無法同時滿足 Same Event 五條件
- 同一 subject + 同一天，但 what 不同
- 無法解釋為何是同一件或相關件
- 只有標題相似

---

## 7. Source Traceability

必須保留：

```
Source → News → Event
```

Same Event 時：

- News A.source 與 News B.source 都保留
- 各自 `url` 保留（若有）
- 只是 `eventRef` 相同

本 Sprint **不**實作：`Event → Evidence → Research → Decision`。

---

## 8. Original News Preservation

Dedup 是理解層 linking，不是刪檔。

Reuters + NVIDIA Official 判為 Same Event 之後：

- News A 仍在
- News B 仍在
- `eventRef(A) = eventRef(B) = Event-001`

禁止：為了 Brief 乾淨、Today 乾淨、或「已經有官方稿」而丟棄任一則 News。

---

## 9. 不做

- production `data/news/`、`data/events/`
- News Collector / RSS / Reuters 或 Bloomberg connector / crawler
- embedding / vector database / ML / LLM autonomous dedup
- 自動 Queue / Card / Decision / Buy-Sell
- 修改 Handbook、Sprint 001 SPEC、031-B、Brief、Today
- Scheduler、Source Registry、Adapter Framework

Reuters 只允許出現在 **acceptance fixture** 中，用來證明跨來源 linking。  
本 Sprint **不**建立 Reuters adapter。

---

## 10. Acceptance Cases A–F

案例是紙上／fixture 契約，不是 live collector。  
News A 盡量沿用 Sprint 002 已確立的 NVIDIA Official Hugging Face 事實。

見 `tests/fixtures/p2-004-case-*.json`。

| Case | 關係 | 重點 |
|---|---|---|
| A | Same Event | Official + Reuters，同一收購宣告 |
| B | Related Event | 宣告收購 vs 監管開始審查 |
| C | Separate Event | 收購 vs 另一家公司的新 partnership |
| D | Separate Event | 同一 subject + 同一天，兩件不同 corporate action |
| E | Same Event | 標題完全不同，core fact 相同（證明不能只靠 title） |
| F | Related Event | 宣告收購 vs 宣布完成收購（新事件狀態） |

---

## 11. Acceptance Tests（定義；本 Sprint 不跑 production engine）

| ID | 斷言 |
|---|---|
| TEST 42 | Same Event 可把多則 News link 到同一 Event |
| TEST 43 | 原始 News 不被刪除 |
| TEST 44 | Related Event 不會 merge |
| TEST 45 | Separate Event 不會 merge |
| TEST 46 | 不能只靠 title similarity |
| TEST 47 | Same subject + same date 不能直接判定 Same Event |
| TEST 48 | Same Event 的不同來源仍保留 Source traceability |
| TEST 49 | News Dedup 不修改 Presentation Dedup（`briefDedupText` 行為不變） |
| TEST 50 | 不修改 031-B / Brief / Today |
| TEST 51 | 不建立 Research Queue / Research Card / Decision side effect |
| TEST 52 | 不建立 Recommendation（無 Buy / Sell / 加減碼） |

本 Draft 只定義測試語義。**不**新增可執行 engine，也**不**要求本 Sprint 修改 Sprint 001–003 已通過的 TEST 1–41。

---

## 12. Sprint 004 Scope

**In Scope**
- 本 Draft SPEC
- Acceptance Cases A–F
- TEST 42–52 定義
- 確認與 Presentation Dedup / 031-B / Brief / Today 的邊界

**Out of Scope**
- 寫 Dedup engine / 改 adapters / 改 evaluation engine
- 改 `data/`、`research/`、Brief schema、renderer
- 正式 05_Event Model
- 跨來源 collector
- Candidate / Queue / Card / Decision
