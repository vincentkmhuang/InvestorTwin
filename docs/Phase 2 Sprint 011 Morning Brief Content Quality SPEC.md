# Phase 2 Sprint 011 — Morning Brief Content Quality
**Draft SPEC 1.0**

| 欄位 | 內容 |
|---|---|
| Status | Draft SPEC 1.0 |
| Source of Truth | Investor Twin Handbook V2.0 |
| 上位文件 | Handbook Ch.2、Ch.3、Ch.6 Morning Brief & Today Workspace、Ch.7、Ch.11 Phase 2 |
| 沿用 SPEC | Sprint 001 News Intelligence Foundation；Sprint 008 Candidate Attention；Sprint 009 Handoff Publish；Sprint 010 Today Workspace Readability |
| 分析依據 | Sprint 011 READ / ANALYZE / DESIGN（Brief content quality；quote-as-news；Temperature mapping；Upcoming lifecycle） |
| 本 SPEC 不是 | Today 重設計、News Intelligence 擴張、News/Event/Candidate DB、Bitcoin/Gold collectors、自動 Queue/Card/Decision、複雜評分、監控迴圈 |
| 本 Sprint 交付 | SPEC + acceptance definition。**本文件寫作當下不做 implementation** |

**Subordinate to Investor Twin Handbook V2.0.**  
**Builds on Sprint 001–010.**  
**Reuse > Modify > Add.**  
**Content-first only** — improve what Morning Brief **writes/derives** into canonical `data/morning-brief.json`; do not redesign Today, expand News Intelligence, or invent News/Event objects.

---

## 1. Mission

提升 **Morning Brief 內容品質與語意誠實性**，使 Brief 真正服務每日投資注意力／決策支援，而非報價牆的複讀。

> 「讓 Morning Brief 誠實地告訴投資人：市場狀態是什麼、什麼值得注意、為什麼值得注意——在既有 Evidence 與既有 Brief 契約內完成。」

成功標準：
- Global／Taiwan 不以純報價偽裝成新聞標題。
- 昨日／Executive 能回答「什麼重要／為什麼重要」，不是第三份報價複本。
- 今日三件事是主要 daily attention／judgment 表面；`whyItMatters` 為主。
- Upcoming 相對 Brief `date` 不把已過期事件當「即將」。
- Market Temperature 在既有 Evidence 存在時正確顯示 WTI／Brent／VIX。
- 跨區塊明顯報價複讀下降；數值狀態與注意力語意分家。
- Canonical Brief path／schema／Today architecture／Sprint 008–009 行為不變。

**不是**擴張 News Intelligence。  
**不是**重做 Today。  
**不是**新建 DB／必填 schema／自動研究。

---

## 2. Problem statement

Sprint 010 已解決 **Today presentation／readability** 瓶頸。剩餘瓶頸在 **Morning Brief content／generator（031-B）**：

| Problem | Nature | Sprint 011? |
|---|---|---|
| Today hierarchy / presentation dedup collapse | UI／renderer（Sprint 010） | **No — already done** |
| Global／Taiwan `news_item()` 把報價寫成「新聞」標題 | Brief **content／generator** | **Yes** |
| Executive／昨日 ≈ 報價複讀，缺 why | Brief content／generator | **Yes** |
| 今日三件事有 `whyItMatters`，但標題／主導仍偏報價 | Brief content／generator | **Yes** |
| Upcoming `carry_linked` 保留過期事件 | Brief content／lifecycle | **Yes** |
| Handbook 9 instruments；Temperature 僅 4；WTI／Brent／VIX Evidence 存在卻未入 Temperature | Generator **mapping** | **Yes（僅既有 Evidence）** |
| Bitcoin／Gold 無 Evidence／collector | Missing **data sources** | **No — remain `--`** |
| NI → Brief 真實新聞契約 | Missing NI capability（Sprint 001 deferred） | **No — later** |

**Root cause separation must not collapse into “add more news” or “rebuild Today.”**

---

## 3. Current production reality

Canonical path（必須維持）：

```
data/evidence/
  → scripts/generate-morning-brief.py   (031-B)
  → data/morning-brief.json
  → DataEngine.loadMorningBrief / renderMorningBrief
  → Today Workspace (Sprint 010 presentation layer)
  + CandidateGate.renderAttention (Sprint 008; derived handoff + ledger)
```

Observed generator／data facts（implementation truth）：

- `TEMPERATURE_KEYS` 目前僅 Nasdaq／SPX／DJI／SOX。
- `INSTRUMENT_MAP` 將 WTI／Brent／VIX 放在 `globalMarketAndNews`，**未**放入 `marketTemperature`。
- Bitcoin／Gold 不在 map；無對應 Evidence 時 UI 顯示 `--`（允許保留）。
- `news_item()` 將報價組裝進 Global／Taiwan `items`（quote-as-news）。
- Executive／`macroDecisionLens` 以報價為主；`THEME_WHY` 主要用於 `today3Things.whyItMatters`。
- `upcomingEvents`／部分 `aiIndustryHighlights` 來自 `carry_linked_items(previous)`，可攜帶相對 Brief `date` 已過期的項目。
- Sprint 001：**不**把 NI 新聞寫進 `globalMarketAndNews.items` 而無契約——本 Sprint 延續此邊界。
- Sprint 008／009：Candidate Attention／handoff publish **獨立於** Brief JSON 寫入——本 Sprint 不重設計。

---

## 4. User-visible outcome

實作完成後，投資人打開 Today（仍讀同一 Brief）應能更快誠實地回答：

1. 昨天／最近最重要的發展是什麼？**為什麼重要？**  
2. 市場溫度（Detect）——既有 Evidence 的主要工具是否齊（含油價／VIX）？  
3. 全球／台灣區塊裡，哪些是**市場狀態**，哪些（若有）才是敘事／事件？  
4. 即將事件是否真的是「即將」？  
5. 今天最該注意什麼？為什麼？  
6. （不變）有沒有值得研究的 Candidate？（Sprint 008）

閱讀語意目標：
- **Market Temperature** 擁有數值市場狀態（Detect）。  
- **昨日／今日三件事** 擁有注意力／why（decision-support，非買賣建議）。  
- **Global／Taiwan** 誠實呈現市場脈絡；無真實新聞時不偽裝成新聞牆。  
- **Upcoming** 只保留相對 Brief `date` 仍為未來的事件。

---

## 5. MUST FIX NOW

### 5.1 Quote-as-News repair（語意誠實）

Global Market & News／Taiwan Market & News **不得**把純市場報價呈現為真正的新聞標題。

當沒有真實 news／event 內容時：
- 以 **market status／market context** 誠實呈現既有有用資料。  
- **不**虛構新聞。  
- **不**建立 News／Event objects。  
- **不**新增必填 schema 欄位。  
- **保留**有用既有 Evidence 資訊（可縮短、改組、改 framing，不可刪光成空殼除非資料本身缺失）。

允許實作手段（擇最小足夠者）：
- 調整 `news_item()`／section packing，使 items／summary 語意為市場狀態而非新聞 headline。  
- 或在既有 optional 顯示欄位／文字中標明 market-status 角色（不強制改 Today 架構）。  
- 不得用「隱藏整段」假裝修好 quote-as-news。

### 5.2 Executive／Yesterday quality

改善 `executiveSummary`／昨日最重要語意：
- **不是**第三份 raw quote 複本。  
- 應回答：**What mattered?** 與 **Why does it matter?**  
- 使用既有 Evidence-backed 敘事／既有 `whyItMatters`／`THEME_WHY`-type 內容。  
- **不**新建 AI reasoning engine；**不**發明事實；**不**產出買賣建議。

報價可作 supporting evidence，但不得作為該區塊的唯一主內容（當 why 類內容已可由既有 theme／today 路徑取得時）。

### 5.3 Today's 3 Things quality

強化 `today3Things` 為主要每日 attention／judgment 表面：
- 主導閱讀應是 **whyItMatters／attention meaning**。  
- 既有 quotes 可保留為 supporting evidence（title／evidence／source）。  
- 回答：**What deserves my attention today, and why?**  
- 必須維持 decision-support／attention，**不是** buy／sell advice。

### 5.4 Upcoming lifecycle

相對 Brief `date`：
- **過去**事件不得再出現為 Upcoming。  
- **優先丟棄**過期／stale past events，而非僅改標籤繼續佔位。  
- 保留有效未來事件。  
- **不**建立 formal Event lifecycle／database。

比較規則以 Brief `date` 與 item `when`（或等價既有日期欄）為準；無法解析日期且無法證明為未來者，不得當作 Upcoming 保留（寧可丟棄，不可假裝即將）。

### 5.5 Market Temperature mapping

Handbook 九項：Nasdaq、S&P 500、Dow、SOX、Bitcoin、WTI、Brent、Gold、VIX。

本 Sprint：
- 當 Evidence 有值時，**正確將既有 WTI／Brent／VIX 映入** `marketTemperature`。  
- **不**新增 Bitcoin collector。  
- **不**新增 Gold collector。  
- **不**發明缺失數值。  
- 無 Evidence 時 Bitcoin／Gold 可維持 `--`。

既有 Nasdaq／S&P 500／Dow／SOX 行為維持（有 Evidence 則顯示）。

### 5.6 Cross-section duplication

減少下列區塊之間的**明顯重複報價主內容**：
- Executive／Yesterday  
- Market Temperature  
- Global Market & News  
- Taiwan Market & News  
- Today's 3 Things  

分工原則：
- **Market Temperature** 擁有數值市場狀態。  
- **Attention sections**（昨日／今日三件事）擁有意義／why。  
- Global／Taiwan 提供市場脈絡摘要，不以與 Temperature 同等完整的報價長文重複主導。  

同一報價不得在多區塊同時作為**主內容**重複，除非作為必要 supporting evidence（短 residual／引用層級）。

---

## 6. SHOULD FIX LATER

| Item | Why later |
|---|---|
| Bitcoin／Gold collectors + Temperature 補齊 | 新資料來源；超出 content／mapping |
| NI → Brief 真實新聞／事件契約 | Sprint 001 deferred；需獨立契約 |
| 更豐富的台灣事件／敘事（超出法人流向） | 常需 NI 或新來源 |
| Brief 上明確 FACT／ESTIMATE／INFERENCE／UNKNOWN 標籤 | 新契約；本 Sprint 只遵守原則不發明標籤架構 |
| 更深層跨區塊去重與 primary-home 模型 | 可在本 Sprint 最小去重之後迭代 |
| Quote-as-news 根因若需完整 News objects | 超出「語意誠實」最小修法 |

---

## 7. Explicit non-goals

明確拒絕：

- 重設計 Today；Brief／Today fork；新 Today data model／renderer  
- 改動 canonical `data/morning-brief.json` 路徑  
- 引入**必填** schema 欄位；新建 Morning Brief file  
- News／Event／Candidate databases；formal Event Model  
- Source Set／Registry 擴張；真實外部新聞收集／爬蟲  
- Bitcoin／Gold collectors  
- 自動 Queue／Card／Conclusion／Thesis／Decision／Buy-Sell  
- 重設計 Sprint 008 Candidate Attention  
- 重設計 Sprint 009 Handoff Publish  
- 複雜 scoring；monitoring／re-observation loop  
- 改寫 production Research Card conclusions／theses  
- 提交無關 dirty leftovers  
- 用「多抓一點報價」假裝修好新聞語意  

---

## 8. Files likely to change

**Likely（實作時）：**
- `scripts/generate-morning-brief.py`（031-B content／mapping／lifecycle／packing）  
- `tests/p2-011-*`（新 acceptance harness）  
- 必要時最小觸及：Brief 正規化／顯示輔助（**僅當**為消費既有欄位、且不改變 Today 架構所必需）  

**Possibly（僅當 blocker 證明必要）：**
- `js/data-engine.js` — display-only 配合語意誠實（例如不把 market-status 當 news clickbait）；**不得**成為第二套 Brief 資料模型  

**Must NOT change unless blocker proven and STOP reported：**
- Handbook  
- Sprint 001／008／009／010 SPECs  
- `scripts/integrate-news-event-evaluation.py`  
- `scripts/publish-research-candidates-handoff.py`  
- NI engines／adapters  
- production Card conclusions／theses  
- Today DOM architecture（Sprint 010 成果）  

本 SPEC 寫作當下**只建立本檔**；不修改其他 repository 內容。

---

## 9. Data／schema impact

| 項目 | Sprint 011 規則 |
|---|---|
| Canonical path | 仍為 `data/morning-brief.json` |
| Required schema fields | **不增刪必填欄**（沿用既有 012／031-B 契約欄位集合） |
| Optional field use | 允許更充分使用既有欄位（如 `whyItMatters`、summary／items 文字） |
| New News／Event DB | **禁止** |
| Invented values | **禁止**；缺 Evidence 維持缺失／`--` |
| Epistemic labels | 遵守 Handbook FACT／ESTIMATE／INFERENCE／UNKNOWN 原則；**不**把 AI／theme 解釋標成 verified FACT；**不**新建完整標籤架構 |
| Freshness vs epistemology | `非最新`／asOf freshness ≠ FACT／UNKNOWN 分類 |
| Today binding | 繼續只 bind Morning Brief + 既有 Attention derive |

若實作發現必須新增必填 schema 或新建 DB → **STOP and report**，不得 silently expand scope。

---

## 10. Acceptance tests

建議編號自 TEST 124 起；語意不可縮水。

| ID | Case |
|---|---|
| A | **Quote-as-news honesty**：Global／Taiwan 在無真實新聞時不以純報價偽裝成新聞標題；市場狀態可讀且誠實 |
| B | **Yesterday／Executive why-quality**：昨日／exec 能呈現 what＋why；不得僅為 raw quote 第三複本 |
| C | **Today's 3 Things attention quality**：主導為 why／attention；quotes 可為 supporting；無 buy／sell 建議語言作為產出目標 |
| D | **Upcoming stale removal**：相對 Brief `date`，過去事件不出現在 Upcoming（優先丟棄） |
| E | **WTI／Brent／VIX mapping**：當 fixture／Evidence 有值時，Market Temperature 顯示對應項 |
| F | **Bitcoin／Gold**：無 Evidence 時維持 `--`；本 Sprint 不新增 collector、不發明數值 |
| G | **Duplication reduction**：同一報價不在多區塊同時作為同等完整主內容重複主導 |
| H | **Canonical schema**：仍讀寫 `morning-brief.json`；無第二 Brief／Today 資料模型；無必填欄新增要求 |
| I | **Sprint 008**：Candidate Attention 可見性／Gate-only CTA 契約不變 |
| J | **Sprint 009**：handoff publish 行為不受破壞（本 Sprint 不改 publish） |
| K | **Regression**：Sprint 001–010 PASS |
| L | **Production File Guard**：production Cards／conclusions／theses 不變；無 `data/news/`／`data/events/` |

補充：
- 測試使用 fixtures／temp roots；臨時寫入須還原。  
- `generate-morning-brief.py` 為本 Sprint 預期修改面；修改須由上表 acceptance 覆蓋。  
- Today 仍為共享 renderer；不得為修 Brief 而 fork Today。

---

## 11. Regression／production safety

必須通過：
- Sprint 001–010 regression suite（既有入口鏈）  
- Production File Guard  
- Sprint 008 Attention 可見性契約  
- Sprint 009 publish 契約不受破壞  
- Sprint 010 Today primary path／elevation **不被本 Sprint 回退**（若觸及 renderer，僅允許配合語意誠實的最小顯示調整）

Production safety：
- 不得刪除 production Research Cards。  
- 不得改寫 Conclusion／Thesis／Decision／Playbook。  
- 不得建立 `data/news/`／`data/events/`。  
- 無關 dirty leftovers 不提交。  
- Generator 寫入邊界維持：只寫 `data/morning-brief.json`（既有 031-B 硬規則）。

---

## 12. Implementation constraints

1. **Reuse > Modify > Add** — 優先改 `generate-morning-brief.py` 的 selection／packing／mapping／lifecycle。  
2. Sprint 010 = Today presentation layer；Sprint 011 = Brief content layer；**二者不可互換職責**。  
3. 不擴張 News Intelligence；不把 NI Candidates 塞進 Global／Taiwan items 而無契約。  
4. 不發明 Evidence；不補 missing 為假數值。  
5. Theme／why 類文字是 **INFERENCE／judgment aid**，不得包裝成已驗證 FACT。  
6. 發現必須改 Brief 必填 schema、新建 DB、或重做 Today → **STOP and report**。  
7. 最小檔案集合；不修改無關檔。

---

## 13. Success criteria

Sprint 011 完成當且僅當：

1. Quote-as-news 語意誠實達成（§5.1／§10 A）。  
2. 昨日／exec 具 what＋why，非純報價複本（§5.2／§10 B）。  
3. 今日三件事為主導 attention／why 表面（§5.3／§10 C）。  
4. Upcoming 無相對 Brief date 的過去事件假「即將」（§5.4／§10 D）。  
5. WTI／Brent／VIX 在有 Evidence 時進入 Market Temperature；Bitcoin／Gold 無 Evidence 可為 `--`（§5.5／§10 E–F）。  
6. 跨區塊明顯報價主內容複讀下降（§5.6／§10 G）。  
7. Canonical path／schema／Today／008／009 邊界維持（§10 H–J）。  
8. Regression＋Production File Guard PASS（§10 K–L）。  
9. NI 擴張、Bitcoin／Gold collectors、News DB 等仍標記為 later／non-goals，未被假裝完成。

---

## 14. Verdict

**READY FOR IMPLEMENTATION**

Sprint 011 = **Morning Brief Content Quality（content／generator-first）**.  
Today readability = **Sprint 010（done；do not reopen）**.  
News Intelligence expansion／Bitcoin／Gold collectors／NI→Brief news contract = **later, separate**.  

Do not implement in the SPEC-writing turn.

---

## Appendix — Relationship to prior sprints

| Sprint | Role relative to 011 |
|---|---|
| 001 | NI foundation；NI→Brief news **deferred** — 011 does not implement it |
| 008 | Candidate Attention — unchanged companion surface |
| 009 | Handoff publish — unchanged plumbing |
| 010 | Today presentation／elevation — unchanged layer； consumes improved Brief |
| 011 | Brief content honesty／attention quality／Temperature mapping／Upcoming lifecycle |
