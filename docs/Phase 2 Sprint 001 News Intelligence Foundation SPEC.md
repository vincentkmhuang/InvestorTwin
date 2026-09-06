# Phase 2 Sprint 001 — News Intelligence Foundation
**Draft SPEC 1.0**

| 欄位 | 內容 |
|---|---|
| Status | Draft SPEC 1.0 |
| Source of Truth | Investor Twin Handbook V2.0 |
| 上位文件 | Handbook Ch.2、Ch.3 H3–H5、Ch.5、Ch.6、Ch.7、Ch.11 Phase 2 |
| 本 SPEC 不是 | 02 Constitution、03 Architecture、04 SPEC Index、05 Event Model、完整 NI 大文件 |
| 沿用前提 | 031-B = Morning Brief Evidence Selection，**不是**完整 News Intelligence |

---

## 1. 目的與角色

News Intelligence 位於 **Observation → Understanding** 之間。

- **Observation：** 外部世界進來（新聞、資訊、既有市場 Evidence）。
- **Understanding：** 辨識「發生了什麼、重不重要、與我有沒有關、可能影響什麼」。
- **不是** Decision Support，更不是 Learning。
- **不是** 財經新聞網站或摘要產品（H1）。

成功標準（Handbook 5.5）：
不是「今天有幾則重要新聞」，而是「其中哪些事值得花時間研究」。

產品位置（Handbook 2.2）：
`External World → News Intelligence → Morning Brief → Research Queue → …`

031-B 繼續負責：**市場 Evidence → Brief 區塊**。
Sprint 001 只定義 NI 最小物件與規則，讓以後能餵 Brief，**不改** Brief schema / Today renderer。

---

## 2. News Object（最小）

一則外部資訊的標準化單位。一則 News ≠ 一個 Event ≠ 一項研究。

| 欄位 | 必填 | 含義 |
|---|---|---|
| source | 是 | 來源識別（媒體／機構／既有 `sourceId` 慣例可對齊，但不綁死實作） |
| title | 是 | 標題 |
| publishedTime | 是 | 發布時間（未知則標 UNKNOWN，不臆造） |
| url | 否 | 原文連結 |
| content / summary | 二擇一 | 原文摘要或精簡內容 |
| subject | 否 | 主要主體（公司／產業／市場／政策） |
| eventRef | 否 | 若已對到 Event，放參考；沒有就空著 |

不做：全文索引、多語言管線、情緒分數、自動標籤體系。

---

## 3. Event（最小概念，非正式 Event Model）

Event = 「世界上發生的一件事」，可由多則 News 指向。
**本 Sprint 不宣稱這是 05_Event Model。** 正式模型日後另立。

最低要能回答：

| 概念 | 問題 |
|---|---|
| What | 發生了什麼（一句話） |
| When | 何時發生／何時被觀察到 |
| Subject / Entity | 關於誰或什麼 |
| Event Type | 粗分類即可，例如：Earnings、Guidance、Policy、Price-move、Corporate action、Industry、Other |

規則：
- 沒有 Event 也可以先存 News。
- 市場報價（US10Y、SOX…）**不是** Event；那是 031-B Evidence。
- `upcomingEvents` 沿用欄不是 Event 辨識結果。

---

## 4. News Dedup

去重的是**理解**，不是刪來源。

| 關係 | 含義 | 處理 |
|---|---|---|
| Same Event | 同一件事的不同報導 | 保留每則 News；指向同一個 Event |
| Related Event | 相關但不是同一件 | 分開 Event，可互連 |
| Separate Event | 獨立事件 | 完全分開 |

禁止：為了畫面乾淨刪掉原始 News。
既有 `briefDedupText` 是 **Presentation Dedup**，不算本條。
031-B 的 `(title, researchId)` 去重也不算 News Dedup。

---

## 5. Importance（★1–5）

問：**這件事本身有多重要？** 不問「與我有多相關」。

暫不設公式。判斷原則：

| 星等 | 原則 |
|---|---|
| ★1 | 噪音、例行、幾乎無新資訊 |
| ★2 | 局部、可忽略 |
| ★3 | 值得知道，尚不必研究 |
| ★4 | 可能改變產業、估值約束或主線敘事 |
| ★5 | 可能改寫重大假設或市場結構 |

原則：先判 Importance，再判 Relevance。重要 ≠ 與我相關。
031-B 的 `priority`（US10Y=100 等）**不是** Importance。

---

## 6. Relevance

問：**與這個投資人有多相關？**

對照（能連多少就連多少，缺資料則 UNKNOWN，不假裝有持股檔）：

| 對象 | 本 Sprint 怎麼用 |
|---|---|
| Investor DNA | Handbook Ch.4：成長／左側／台股為主、美股為輔、選股與限制 |
| Portfolio | 若尚無正式持股檔，標 UNKNOWN，不發明部位 |
| Research Card | 對既有 `research/*/card.json` |
| Research Queue | 是否已在佇列主題上 |
| Thesis | 對 `data/theses` / card.thesisId |
| Strategy | 成長、左側、Core/Satellite 持有年限 |

031-B 的 SOX→`hbm` 是**靜態對應**，可當「連既有卡」參考，不是 Relevance 模型。

---

## 7. Impact

Impact = 這件事**可能怎樣影響誰**。
**Impact ≠ Recommendation。** 不產出買／賣／加減碼。

| 欄位 | 取值 |
|---|---|
| Target | 誰被影響（公司／產業／市場／既有 Thesis） |
| Direction | Positive / Negative / Mixed / Unclear |
| Strength | Low / Medium / High |
| Evidence Status | FACT / ESTIMATE / INFERENCE / UNKNOWN |

`whyItMatters` 主題套話不是 Impact。
人擁有決策（H3.2）：Impact 到此為止。

---

## 8. Evidence Separation

每則重要主張必須標一類：

| 類 | 含義 |
|---|---|
| FACT | 可追溯來源的已發生事實 |
| ESTIMATE | 估計、指引、市場定價、非確認數字 |
| INFERENCE | 由事實／估計推出的判斷 |
| UNKNOWN | 不知道、未證實、不臆造 |

與 Evidence `status`（fresh/stale/missing）分開：後者是資料新鮮度，不是證據種類。
`conclusionImpact: "UNKNOWN"` 寫死，不當作本模型已落地。

---

## 9. News → Research Candidate

News / Event **不得**直接寫入 Research Queue。

**Research Candidate** = 「這件事可能值得研究」的候選，還不是 Queue item。

Research Candidate 是篩選結果，不代表自動進入 Research Queue。
Candidate 產生後仍需由投資人判斷，可選擇 Ignore、Watch、
加入既有 Research Card，或進入 Research Queue。

可產生 Candidate 的最低條件（同時）：
1. Importance ≥ ★3，或 Relevance 明顯對到既有 Card / Thesis / DNA；且
2. 不是純行情複述；且
3. 還有未回答的研究問題（不是已結案的同一句話）；且
4. 不是自動對每則新聞各建一筆。

與 Queue 的關係：
- Candidate → **人決定**是否進 Queue 或掛到既有 Card。
- 進 Queue 的是研究問題／任務，不是新聞標題。
- 沿用 012：`researchId` 可選、必須已有卡、**不自動建卡**。
- 沿用 031-B：generator / NI **不** POST `/api/queue`、不建卡。

點 Brief 把已有卡 `ensureInQueue`：那是既有導航，不是 Candidate 管線。

---

## 10. Source Traceability

Sprint 001 最低鏈：

`Source → News → Event → Evidence`

- Source：誰說的
- News：哪一則
- Event：哪一件事（可空）
- Evidence：若用到市場數據，連既有 Evidence instrument / `sourceId`

預留、本 Sprint 不實作：`→ Research → Decision`。
禁止：只有結論、沒有 Source/News。
AI 產出 ≠ Original Evidence（Handbook 10.2）。

---

## 11. Morning Brief Integration

NI **提供資訊給 Brief**，不取代 031-B。

| 現況（必須保持） | Sprint 001 約束 |
|---|---|
| Canonical：`data/morning-brief.json` | 不改路徑、不引入 `latest.json` |
| 012 schema 欄位 | 不增刪必填欄、不改 Today renderer |
| 031-B 只寫 Brief | NI 不改 031-B 寫入邊界 |
| 市場溫度 / 指數區塊 | 仍由 Evidence + 031-B 產生 |

以後（Out of Scope）Brief 的「全球／台灣新聞」才可引用 NI 已評估過的 News/Event。
Sprint 001 **不**把新聞寫進 `globalMarketAndNews.items`，以免把報價項與新聞項混成同一 schema 卻無契約。

Today 繼續只 bind Morning Brief。

---

## 12. 031-B Reuse Boundary

**直接沿用**
- 只讀 `data/evidence/`，只寫 `data/morning-brief.json`
- 不建卡、不寫 Queue / Thesis / Case / Decision / Playbook
- 只連已存在 Research Card
- 不虛構新聞、不補 missing
- 012 Brief schema、Today 同一 renderer
- Evidence collect / normalize / history（FRED、指數、TWSE）
- Source → Evidence 追溯

**只當參考，不當 NI 能力**
- `INSTRUMENT_MAP.priority` / theme
- `THEME_WHY`
- SOX → hbm 靜態連卡
- `news_item()` 把報價寫成新聞標題
- `upcomingEvents` 沿用
- Radar 複製 `opportunity-radar.json`
- Presentation Dedup

**Phase 2 新能力（本 Sprint 只定義，不實作）**
- News Object、最小 Event 概念
- Same / Related / Separate Dedup
- ★Importance、Relevance、Impact
- FACT / ESTIMATE / INFERENCE / UNKNOWN
- Research Candidate（尚未進 Queue）
- Source → News → Event → Evidence

---

## 13. Sprint 001 Scope

**In Scope**
- 本 Draft SPEC（概念與邊界）
- 確認不破壞 031-B / 012 / Today / Evidence
- 用現有 1–2 則手寫新聞（例如 Brief 裡已有的 NVIDIA 相關 highlight）做**紙上**走查：News / Event / Dedup / Importance / Relevance / Impact / Candidate

**Out of Scope**
- 寫程式、改 `data/`、改 Brief schema、改 renderer
- 新的新聞 collector / RSS
- 正式 05_Event Model
- 自動進 Queue、自動建卡
- 複雜評分公式、完整 Source Registry
- Bitcoin / Gold collector、Radar 產品爭議
- Constitution / Architecture / SPEC Index

**Future**
- Collect 真實新聞
- 正式 Event Model
- NI → Brief 欄位契約
- Candidate → 人工進 Queue
- 接到 Research / Decision 追溯
- Phase 2 後續 sprint
