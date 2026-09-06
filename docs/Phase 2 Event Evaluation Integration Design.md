# Phase 2 — Event × Evaluation Integration Design
**Design 1.0 — Architecture / Acceptance Definition only**

| 欄位 | 內容 |
|---|---|
| Status | Design 1.0 |
| Source of Truth | Investor Twin Handbook V2.0 |
| 上位文件 | Handbook Ch.2、Ch.3 H3–H5、Ch.5.1–5.5、Ch.7 |
| 沿用 SPEC | Sprint 001 News Intelligence Foundation；Sprint 004 News Dedup & Event Linking |
| 本文件不是 | 05 Event Model、Sprint 005 SPEC、implementation、production schema |
| 本文件不做 | 改 engine、改 SPEC、改 data/、commit / push |

---

## 1. Problem Statement

Phase 2 已有兩條獨立能力：

| 線 | 現況 | 產出 |
|---|---|---|
| A | `evaluate-news-intelligence.py` | 一則 News → Importance / Relevance / Impact / Research Candidate |
| B | `link-news-events.py` | 多則 News → Same / Related / Separate Event + `eventRef` |

問題：兩條線還沒接上。

若繼續「每則 News 各評一次」，同一 Event 有 NVIDIA Official、Reuters、Bloomberg、CNBC 四則報導時，會得到 4 份 Importance、4 份 Relevance、4 份 Impact、4 個 Candidate。那違反：

- Handbook 5.3：先 Deduplicate / Identify Event，再 Assess Importance / Relevance / Impact / Candidate
- Handbook 5.4：Importance 是**事件本身**有多重要
- Sprint 001 §9：不是自動對每則新聞各建一筆 Candidate
- Sprint 004：去重的是理解，不是刪來源；News 不得被寫入 evaluation 欄位

本 Design 只回答：**Event 與 Evaluation 如何連接**。不改現有 engine，不建 production store。

---

## 2. Design Decision

### 2.1 Question 1 — 評估 News 還是 Event？

| 方案 | 做法 | 四則同 Event 新聞 | 問題 |
|---|---|---|---|
| A. 評估 News | 維持現況：一則 News 一份 Evaluation | 4 份 Importance / Relevance / Impact / Candidate | 來源不同會假裝成四件不同的事；Candidate 重複 |
| B. 評估 Event | Event 評完就結束，News 只當附件 | 1 份 Evaluation | 若把 Evidence 也 fold 進 Event，來源細節會被覆蓋 |
| **C. 評估 Event，Evidence 仍掛 News（建議）** | Dedup 先成立 Event；Evaluation 對 Event 做一次；各則 News 的 FACT/新資訊分開保留 | 1 份 Event Evaluation；N 則 News / N 組 sourced evidence | 符合 Handbook 5.3，且不讓 Event 吞掉來源 |

**建議：C。**

理由：

1. Handbook 5.3 順序已是 Identify Event → Assess Importance → … → Candidate。
2. Importance / Relevance 問的是「這件事」，不是「這篇報導」。
3. Sprint 001 已寫「不要對每則新聞各建一筆」。
4. Sprint 001 engine 以單則 News 為 input，是 Dedup 尚未存在時的 stopgap，不是目標 ownership。
5. 不得選純 B：Event 不能成為萬能物件。

因此最終管線是：

```
News (多則，全部保留)
    ↓  Dedup / Event Linking
Event (發生了什麼)
    ↓  Evaluation Object（一次）
Importance + Relevance + Impact judgment
    ↓
Research Candidate（一個）
```

Evidence 從各則 News / Source 收集，**不**因 Same Event 而合併成一句話。

### 2.2 原則句

**Event 是去重後的事件單位，但不是資訊唯一儲存單位。**

本句成立，並納入本 Design。

同一 Event 可以有多則 News、多條 sourced evidence。Evaluation 只對 Event 做一次。News 與 Evidence 不被 Event 取代。

---

## 3. News vs Event ownership

不要把 Importance / Relevance / Candidate 塞進 Event 本體。也不要留在 News 上。

| 物件 | 是什麼 | 擁有 | 不擁有 |
|---|---|---|---|
| **Source** | 誰說的 | 來源識別 | 判斷 |
| **News** | 誰、在哪裡、怎麼報導 | source, title, publishedTime, url, summary/content, subject, eventRef | importance, relevance, impact, candidate |
| **Event** | 發生了什麼 | what, when, subject, eventType, newsRefs, relatedEventRefs | evaluation 欄位、完整證據全文、Queue |
| **Evidence item** | 哪一條可追溯主張 | claim, class (FACT/ESTIMATE/INFERENCE/UNKNOWN), newsRef, source | Importance、Candidate |
| **Evaluation** | Investor Twin 如何評估這個 Event | eventRef, importance, relevance, impact judgment, evidenceRefs | 原始正文、Buy/Sell |
| **Research Candidate** | 這件事是否值得花研究時間 | 掛在 Evaluation 上；指向 Event | 自動進 Queue / 建卡 |
| **Decision** | 是否改變投資判斷 | 人擁有 | 本層不產出 |

Sprint 001 / 004 的 News 最小欄位保持不變。  
Sprint 004 的 Event 最小欄位保持不變。  
Evaluation 是**獨立物件**，用 `eventRef` 連到 Event，用 `evidenceRefs` 連回各則 News 的主張。

---

## 4. Importance ownership — **Event（經 Evaluation Object）**

Importance = 這個**事件**對市場／產業／公司有多重要。

| 判斷 | 結論 |
|---|---|
| 屬於 News？ | 否。同一收購不該因 Reuters vs Official 變成 ★3 與 ★5 |
| 屬於 Event？ | 是。問的是「這件事」 |
| 存在哪裡？ | Evaluation.importance，指向 Event。不寫回 News，也不寫進 Event 本體 |

同一 Event、四個來源 → **一份** canonical Importance。

若後續出現 Related Event（監管開始審查、交易完成），那是另一個 Event，可另有一份 Importance。

---

## 5. Relevance ownership — **Event（經 Evaluation Object）**

Relevance = 這件事與 Investor DNA、Portfolio、Research Card、Queue、Thesis、Strategy 的關聯。

NVIDIA Official 與 Reuters 報同一收購，與投資人的關聯是同一條（例如既有 AI / NVIDIA 研究方向）。不該出現兩個 Relevance band。

| 判斷 | 結論 |
|---|---|
| 屬於 News？ | 否 |
| 屬於 Event？ | 是 |
| 存在哪裡？ | Evaluation.relevance + relevanceBasis，指向 Event |

同一 Event → **一份** canonical Relevance。  
缺 Portfolio 時標 UNKNOWN，不發明持股。沿用 Sprint 001 §6。

---

## 6. Impact ownership — **判斷在 Event；證據在 News**

Impact 有兩層，必須拆開：

| 層 | 內容 | Ownership |
|---|---|---|
| **Impact judgment** | Target, Direction, Strength | Evaluation（對 Event 一次） |
| **Evidence Status items** | 各條 FACT / ESTIMATE / INFERENCE / UNKNOWN | 每條綁 `newsRef` + `source`。不得覆蓋 |

同一收購的 Target / Direction / Strength 只應有一份 canonical 判斷（例如 Target = NVIDIA / AI developer ecosystem，Direction = Mixed，Strength = High）。

Reuters 多出來、Official 沒有的資訊：

- **不**改 Event identity（仍是同一收購宣告）
- **不**覆蓋 Official 的 FACT
- **新增**一條 evidence item，標明來自 Reuters 那則 News
- 若該資訊只是市場疑慮／報導，標 ESTIMATE 或 INFERENCE，不是把 Official FACT 改掉
- 若該資訊構成新的事件狀態（開始審查、完成交易），依 Sprint 004 應是 **Related Event**，另立 Event + 另一次 Evaluation

不能因為 Event 相同就把不同來源的 information merge 成單一摘要。

---

## 7. Research Candidate ownership — **Event（方案 C）**

| 方案 | 結果 | 裁決 |
|---|---|---|
| A. News → Candidate | 5 則 News = 5 個 Candidate | 否。違反 Sprint 001 §9 |
| B. Event → Candidate（欄位長在 Event 上） | 1 個 Candidate，但 Event 開始變萬能 | 否 |
| **C. News → Event → Evaluation → Candidate** | 5 則 News、1 個 Event、1 次 Evaluation、1 個 Candidate | **是** |

同一 Event、5 則 News → **1 個** Research Candidate。

Candidate 仍只是篩選結果。人選擇 Ignore / Watch / 加入既有 Card / 進 Queue。  
進 Queue 的是研究問題，不是新聞標題。不自動建卡、不 POST `/api/queue`。

---

## 8. Evidence traceability

必須保留：

```
Source → News → Event → Evaluation → Research Candidate
```

Event **不取代** News / Source / Evidence。

例：

| | Official | Reuters |
|---|---|---|
| Event | 同一：NVIDIA 宣布收購 Hugging Face | 同一 |
| News | 保留 | 保留 |
| Source | NVIDIA Official Blog | Reuters |
| Evidence | 「已同意收購」= FACT（Official） | 「市場對交易有疑慮」= ESTIMATE / INFERENCE（Reuters） |

禁止：只留下 Event 結論、丟掉是誰說的。  
禁止：AI 產出當成 Original Evidence（Handbook 10.2）。

市場數據若被引用，仍連既有 031-B Evidence instrument / `sourceId`。那是另一條 Source → Evidence，不是 News。

---

## 9. Canonical relationship

檢查過「把 importance / relevance / impact[] / candidate 都掛在 Event 上」的草案：**不接受。**  
那樣會讓 Event 吞掉 Evaluation 與 Evidence。

最小正式關係：

```
Source
  └── News                    ← 報導單位（保留全文／摘要／URL）
        └── eventRef
              └── Event       ← 事件單位（what / when / subject / type / newsRefs）
                    └── Evaluation   ← 評估單位（一次）
                          ├── importance
                          ├── relevance
                          ├── impact.judgment
                          ├── evidenceRefs[]  → 各 News 上的 sourced claims
                          └── researchCandidate
```

| 建議欄位 | 放哪 | 正式存在？ |
|---|---|---|
| source, title, publishedTime, url, summary, subject, eventRef | News | 是（已有） |
| what, when, subject, eventType, newsRefs, relatedEventRefs | Event | 是（已有最小概念） |
| importance, relevance, relevanceBasis | Evaluation | 是（從 News 上移走，不寫進 Event 本體） |
| impact.judgment (target / direction / strength) | Evaluation | 是 |
| evidence items (FACT/…) | Evaluation.evidenceRefs，每條含 newsRef + source | 是；不覆蓋 |
| researchCandidate | Evaluation | 是（一個 Event 一個） |
| Buy / Sell / Queue / Card / Decision | — | 否 |

---

## 10. NVIDIA / Hugging Face walkthrough（Same Event）

沿用 Sprint 002 / 004 Case A。

**News A — NVIDIA Official Blog**  
`https://blogs.nvidia.com/blog/nvidia-to-acquire-hugging-face/`  
2026-09-03  
NVIDIA has agreed to acquire Hugging Face.…

**News B — Reuters（acceptance fixture，不是 Reuters connector）**  
NVIDIA to acquire Hugging Face  
同一宣告。

```
News A ─┐
        ├── Event X = evt:corporate-action/hugging-face,nvidia/acquire
News B ─┘
            ↓
        Evaluation X  （一次）
            ├── Importance = 5
            ├── Relevance  = High
            ├── Impact judgment = Mixed / High / NVIDIA–AI ecosystem
            └── Candidate = YES（一個）
```

| 資料 | 來自 |
|---|---|
| 官方標題、URL、原文摘要 | News A only |
| Reuters 標題與轉述 | News B only |
| Event identity（收購宣告） | A + B 共同指向，只建一次 |
| FACT：已同意收購 | 主要來自 A；B 可再掛一條同義 FACT，source=Reuters，不覆蓋 A |
| Importance / Relevance / Impact judgment / Candidate | **只產生一次**，掛 Evaluation X |

兩則 News 都保留。Source traceability 都保留。不進 Queue / 不建卡 / 不出買賣。

---

## 11. Second Case — Same Event，第三方加入新資訊

**News A — Official**  
交易宣布（同上）。FACT：已同意收購；Hugging Face 維持開放。

**News B — 第三方**  
同一收購宣告，但加上市場／競爭疑慮（例如交易對其他 AI 平台的壓力）。  
這不是新的事件狀態（不是開始審查、不是完成交割）→ 依 Sprint 004 仍是 **Same Event**。

「新資訊」≠ Related Event。Related Event 只用於新的事件狀態。新的報導細節是 **新 Evidence**。

```
News A ─┐
        ├── Event X（同一收購宣告）
News B ─┘
            ↓
        Evaluation X  （仍是一次）
            ├── Importance / Relevance / Candidate：仍一份
            ├── Impact judgment：仍一份（可因新 evidence 而更完整，例如 UNKNOWN 減少）
            └── evidenceRefs:
                  [A] FACT  已同意收購
                  [A] FACT  維持開放平台
                  [B] ESTIMATE / INFERENCE  市場對競爭影響的疑慮
```

規則：

- Event 不 merge 兩則正文
- B 的新資訊以新 evidence item 存在，source = B
- A 的 FACT 不被 B 覆蓋
- 不因 B 多寫了疑慮就複製第二個 Candidate
- 若 B 其實是「監管開始審查」，則改走 Sprint 004 Related Event：Event Y + Evaluation Y

---

## 12. Non-goals

本 Design **不**做、也**不要求現在改**：

- 修改 `evaluate-news-intelligence.py` / `link-news-events.py`
- 修改 News Object 或 Sprint 004 Event identity
- 修改 Handbook、Sprint 001 SPEC、Sprint 004 SPEC
- production `data/news/`、`data/events/`
- Reuters / Bloomberg connector、collector、RSS
- 自動 Queue / Card / Decision / Buy-Sell
- 031-B、Morning Brief、Today
- 正式 05_Event Model
- embedding / ML / LLM autonomous evaluation

與正式文件的關係：沒有必須立刻改 Handbook / SPEC 的衝突。  
Sprint 001 engine 以單則 News 為 input，應視為過渡；本 Design 說明目標 ownership。若日後 implementation 要改 engine 契約，另立 Sprint SPEC，不在本次改文件。

---

## 13. Future implementation boundary

以後若做 Event × Evaluation implementation，最小範圍應是：

1. 先 Dedup（已有）得到 Event + newsRefs
2. 新的 Evaluation 步驟讀 **Event + 其 News**，輸出 **一個** Evaluation Object
3. Importance / Relevance / Candidate 對 Event 各一份
4. Evidence items 帶 newsRef，禁止覆蓋
5. 不寫 `data/`、`research/`、Brief、Queue
6. 不把 evaluation 欄位寫回 News
7. 不把 evaluation 欄位寫進 Event 本體
8. Sprint 001 單則 News 評估可留作「尚未 link 的孤立 News」後備，不得再當 Same Event 的正式路徑

本文件不是 Sprint 005 kickoff，也不授權開始寫 code。

---

## 14. Acceptance Criteria

| ID | 斷言 |
|---|---|
| AC-01 | 同一 Event 多篇 News 不產生多份 Event Evaluation |
| AC-02 | Importance 對同一 Event 只有一份 canonical evaluation |
| AC-03 | Relevance 對同一 Event 只有一份 canonical evaluation |
| AC-04 | 不同 News 提供的新 Evidence 不因 Event linking 而遺失或覆蓋 |
| AC-05 | Research Candidate 不因多篇 News 重複產生 |
| AC-06 | News / Event / Evidence / Evaluation / Candidate ownership 分離；Event 不是萬能物件 |
| AC-07 | Source → News → Event → Evaluation → Candidate 可追溯 |
| AC-08 | 不產生 Queue / Card / Decision / Recommendation side effect |

---

## 15. 現況 vs 目標（不在本次改 code）

| 現況 | 目標 |
|---|---|
| Evaluation engine 吃一則 News | Evaluation 吃已 link 的 Event + newsRefs |
| 每則 News 可得到一份 Importance | 每 Event 一份 |
| News 上不寫 evaluation（004 已守） | 繼續守 |
| Event 只有 identity + newsRefs | 維持；評價放 Evaluation Object |
| Candidate 語意已是「不要每則新聞一筆」 | 實作上改對齊 Event |
