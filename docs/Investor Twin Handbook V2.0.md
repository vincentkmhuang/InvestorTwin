# Investor Twin Handbook V2.0

Version：V2.0
Status：Source of Truth

Draft 1.0｜2026-09-03

Mission：讓 AI 成為第二個自己，而不是第二個分析師。

## Chapter 1｜Mission & Product Identity

### 1.1 Mission

讓 AI 成為第二個自己，而不是第二個分析師。Investor Twin 的目的不是代替投資人做決策，而是逐漸理解投資人的思考方式、投資假設、研究脈絡與決策歷史，成為投資人的第二個思考系統。

### 1.2 Product Identity

Investor Twin 是投資決策支援系統（Decision Support System），而非財經新聞摘要或資訊彙整系統。

### 1.3 What Investor Twin Is Not

Investor Twin 不是財經新聞網站、新聞摘要工具、股票推薦引擎、單純研究筆記工具、單純投資組合追蹤工具，也不是取代投資人的 AI 分析師。最終投資決策永遠由投資人掌握。

## Chapter 2｜Core Loop & Product Philosophy

### 2.1 Core Loop

Observation → Understanding → Decision Support → Learning（觀察 → 理解 → 決策支援 → 學習）。

### 2.2 Core Product Flow

External World → News Intelligence → Morning Brief → Research Queue → Research Card → Decision Framework → Position Playbook → Decision History → Learning。

### 2.3 Product Philosophy

Investor Twin 不追求收集最多資訊，而是把有限的投資時間花在真正值得理解、研究與判斷的事情上。News ≠ Research ≠ Decision。

## Chapter 3｜Project Constitution

### 3.1 Purpose

Project Constitution 定義 Investor Twin 不應輕易改變的核心原則。

### 3.2 Human Owns Decisions

Investor Twin 可以蒐集、整理、連結資訊並協助判斷，但不擁有最終投資決策權。

### 3.3 H1｜Product Identity｜產品定位原則

Investor Twin 是投資決策支援系統（Decision Support System），而非財經新聞摘要或資訊彙整系統。

### 3.4 H2｜Core Loop｜核心循環

Investor Twin 以 Observation → Understanding → Decision Support → Learning（觀察 → 理解 → 決策支援 → 學習）形成持續循環，將外部資訊轉化為投資理解、決策與經驗累積。

### 3.5 H3｜News Intelligence Position｜財經情報定位

News Intelligence 是 Investor Twin 位於 Observation 與 Understanding 之間的資訊理解層，負責從外部財經資訊中辨識值得注意的事件與影響，而非以資訊蒐集或新聞摘要本身為目的。

### 3.6 H4｜Evidence Separation｜證據分離原則

Investor Twin 必須區分 FACT（事實）、ESTIMATE（估計）、INFERENCE（推論）與 UNKNOWN（未知），並以可追溯的證據支持重要主張。

### 3.7 H5｜Research Queue Principle｜研究佇列原則

Research Queue 不是 News Queue。只有具備足夠重要性、關聯性或投資影響可能性，且值得投入研究時間的事項，才應進入 Research Queue。

### 3.8 Cross-Conversation Continuity｜跨對話連續性原則

Investor Twin 的正式 Handbook、Constitution 及已確認的產品決策，是跨對話的共同基礎。新的 Investor Twin 對話、功能討論或開發工作，不應重新定義已確認的產品原則；應先檢視既有正式文件與決策，再處理新的需求。

## Chapter 4｜Investor DNA

### 4.1 Investment Identity

Growth-oriented（成長型）、Left-side trading（左側交易），以台股為主要投資市場，美股為較小比例的投資市場。

### 4.2 Portfolio Structure

Core Holdings：8–10 年；Satellite Holdings：3–5 年。

### 4.3 Fundamental Selection Framework

Large Cap：上市≥20年、資本額≥300億、連續15年 EPS≥1元、股利≥1元。Mid Cap：上市≥12年、資本額100–300億、連續10年 EPS≥2元、股利≥1.5元。Small Cap：上市≥8年、資本額<100億、連續6年 EPS≥3元、股利≥2元。

### 4.4 Research Metrics

10年 EPS、股利、本益比、P/E River、P/B、P/B River、股利殖利率、營收與成長、市場地位；技術面主要觀察 Bollinger Bands ±2。

### 4.5 Investment Constraints

原則上不投資興櫃／未上市新興股票、沒有實際營收的公司、沒有實際營收的新藥／生技公司，以及 KY 股票。已知例外：臻鼎-KY、中租-KY。

## Chapter 5｜Information Intelligence & Evidence

### 5.1 Information Hierarchy

Source → News / Information → Event → Impact → Research → Decision。詳細 Event 結構由 05_Event Model 定義。

### 5.2 Impact

Impact 應能表達 Target、Direction（Positive/Negative/Mixed/Unclear）、Strength（Low/Medium/High）、Evidence Status（FACT/ESTIMATE/INFERENCE/UNKNOWN）。Impact ≠ Recommendation。

### 5.3 News Intelligence Flow

Collect → Normalize → Deduplicate → Identify Event → Assess Importance → Assess Relevance → Assess Impact → Research Candidate。

### 5.4 Importance vs Relevance

Importance 回答事件本身有多重要，以 ★1–5 表示；Relevance 回答事件與投資人的持股、Research Cards、Research Queue、Thesis、策略有多相關。重要不等於與我相關。

### 5.5 News ≠ Research

News Intelligence 最終不是回答今天有幾則重要新聞，而是辨識其中哪些事情值得投資人花時間研究。

## Chapter 6｜Morning Brief & Today Workspace

### 6.1 Morning Brief Role

Morning Brief 將 World Events 轉化為 Investor Attention，回答今天什麼值得投資人注意。

### 6.2 Morning Brief Structure

昨日最重要3件事 → 市場溫度 → 全球市場與新聞 → 台灣市場與新聞 → 即將事件 → 今日三件事。

### 6.3 Market Temperature

負責 Detect，不負責 Decide。核心監測：Nasdaq、S&P 500、Dow、SOX、Bitcoin、WTI、Brent、Gold、VIX。

### 6.4 Today Workspace

Today Workspace 是 Morning Brief 的每日工作介面，不是另一套獨立系統；Today 與 Morning Brief 應共享 Canonical Data、Data Structure、Renderer。

### 6.5 Opportunity Radar

Opportunity Radar 不應是每日固定區塊。週一提供「Opportunity Radar｜上週機會變化」；特殊且具時效性的重大機會可例外即時提醒。

## Chapter 7｜Research System

### 7.1 Research Queue

Research Queue 管理值得投入研究時間的問題與任務，不是新聞。

### 7.2 Research Card

Research Card 是完整研究主題的基本單位，包含 Research Question、My Thinking / Thesis、Evidence、Related Companies / Industries、Research Conclusion、Conclusion History、Decision Framework、Related Research Cards。

### 7.3 Research Loop

Research Queue → Research Card → Evidence → Understanding → Conclusion → Decision → Continuous Update。

### 7.4 Thesis Evolution

新的 Evidence 可以 Support、Challenge、Change 既有 Thesis；Conclusion History 必須保留。

### 7.5 Non-linear Research

Investor Twin 不強迫使用者採固定線性流程；可從 Queue、既有 Card、新聞／事件或 Thesis 任一處開始。

## Chapter 8｜Decision System

### 8.1 Decision Framework

Evidence → Thesis → Decision。核心問題是研究結果是否改變投資判斷，而不是直接給出買賣建議。

### 8.2 Decision Trigger

當新的 Evidence 支持、挑戰或改變 Thesis 時，重新檢視投資判斷；不要求每天機械式重新判斷。

### 8.3 Position Playbook

What must be true? What invalidates it? What evidence should I monitor? What action follows? Position Playbook 不是自動交易系統。

### 8.4 Decision History

保留 Thesis、Evidence、Decision、Position / Action、Outcome、正確之處、錯誤之處與 Learning。

## Chapter 9｜Knowledge & Learning System

### 9.1 Knowledge Base

主要目的為避免重複研究，讓研究結果、重要 Evidence、Conclusion 與 Decision 成為未來可重新利用的資產。

### 9.2 Knowledge Graph

連接 Event、Company、Industry、Research、Thesis、Decision；詳細結構由 07_Knowledge Graph 定義。

### 9.3 Learning Loop

Observation → Understanding → Decision Support → Decision → Outcome → Learning → Knowledge → Next Observation。

### 9.4 What Learning Means

Learning 是累積可重複使用的知識與投資經驗，不是自動修改底層 AI 模型。

## Chapter 10｜System Architecture & Data Governance

### 10.1 Local-first

採 Local-first Architecture；投資資料的主要 Source of Truth 位於使用者自己的環境。

### 10.2 Data Ownership

Investment Data ≠ Code；Deployment ≠ Data Source of Truth；AI Output ≠ Original Evidence。

### 10.3 Canonical Data

相同資訊應只有一個 Canonical Source；Morning Brief 與 Today Workspace 應共享相同 Canonical Data。

### 10.4 Evidence Traceability

重要投資主張應盡可能形成 Decision → Inference → Evidence → Event → Source。

### 10.5 Source Architecture

外部資訊來源透過 Source Registry / Adapter 與系統解耦；目前使用既定 Source Set，暫不擴張。

### 10.6 Implementation Boundary

Handbook 不鎖定 React、Next.js、Python package、Git command、API implementation 或 UI component implementation；這些由下層文件管理。

## Chapter 11｜Roadmap & Product Governance

### 11.1 Development Principle

Handbook → Constitution → Architecture → SPEC → Implementation → Test。

### 11.2 Change Governance

Review 最新 Handbook → 確認既有原則與決策 → Reuse / Modify / Add → 若涉及正式原則改變，先更新 Handbook / Constitution → 再修改 SPEC → 最後 Implementation。

### 11.3 Product Phases

Phase 1 Core Decision Loop；Phase 2 News Intelligence；Phase 3 UI / UX；Phase 4 Parking Lot Review。

### 11.4 Feature Gate

任何新功能先問：是否符合 Mission？是否強化 Core Loop？是否已有現有能力？是否增加不必要複雜度？現在是否真的需要？若不清楚，先 Parking Lot。

### 11.5 Version Governance

正式文件變更記錄 Version、Date、Changes、Rationale；正式版本即為 Source of Truth。

## Appendix A｜Document Hierarchy

### A.1 Hierarchy

Handbook → Project Constitution → Architecture / Event Model / Decision Framework / Knowledge Graph → SPEC → Implementation → Test。

### A.2 Document Responsibility

Handbook：最高層 Mission、Philosophy、Governance。Project Constitution：不可違反的產品原則。Investor DNA：投資人的思考與限制。System Architecture：系統架構。Event Model：Event 詳細模型。Decision Framework：投資決策框架。Knowledge Graph：知識關係模型。Morning Brief Spec：Morning Brief 詳細規格。Roadmap：開發路線。SPEC：功能詳細規格。Implementation：實際程式。Test：驗證實作是否符合規格。

### A.3 Conflict Rule

不同文件衝突時，以較高層級文件為準。若高層級原則需要改變，必須先修改高層級文件，再修改下層文件。

## Document Status

Version：V2.0｜Draft 1.0

Date：2026-09-03

Purpose：Investor Twin 最高層產品與治理文件。

Change Note：整合既有已確認產品原則；新增正式 Cross-Conversation Continuity 原則。

Scope Boundary：本文件定義產品使命、哲學、原則與治理，不取代下層 Architecture、Event Model、Decision Framework、Knowledge Graph、Morning Brief Spec、Roadmap 與其他詳細 SPEC。
