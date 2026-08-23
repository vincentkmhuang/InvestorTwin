const WorkflowEngine = {
  queue: null,
  states: null,
  researchCache: {},

  async init() {
    const [queue, states] = await Promise.all([
      fetch('data/research-queue.json').then(r => r.json()),
      fetch('data/workflow-states.json').then(r => r.json())
    ]);
    this.queue = queue;
    this.states = states;
  },

  getQueueIds() {
    return this.queue.items.map(item => item.id);
  },

  isInQueue(id) {
    return this.queue.items.some(item => item.id === id);
  },

  addToQueue(id, source = 'Manual') {
    if (!this.isInQueue(id)) {
      this.queue.items.push({ id, addedFrom: source });
      return true;
    }
    return false;
  },

  async ensureInQueue(id, source) {
    if (this.isInQueue(id)) return false;
    try {
      const res = await fetch('/api/queue', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id, addedFrom: source })
      });
      if (res.ok) {
        const data = await res.json();
        this.queue.items = data.items;
        return data.added;
      }
    } catch (_) {}
    return this.addToQueue(id, source);
  },

  resolveResearchId(id) {
    const briefItem = DataEngine.morningBrief?.items?.find(item => item.id === id);
    if (briefItem?.cardRef) return briefItem.cardRef;

    const thesisCard = DataEngine.investmentThesis?.cards?.[id];
    if (thesisCard?.cardRef) return thesisCard.cardRef;

    return id.toLowerCase().replace(/\s+/g, '-');
  },

  resolveTitle(id) {
    const briefItem = DataEngine.morningBrief?.items?.find(item =>
      item.id === id || item.cardRef === id
    );
    if (briefItem) return briefItem.title;

    const radarItem = DataEngine.opportunityRadar?.items?.find(item => item.id === id);
    if (radarItem) return radarItem.name;

    const thesisCard = DataEngine.investmentThesis?.cards?.[id];
    if (thesisCard) return thesisCard.title;

    return id;
  },

  resolveSummary(id) {
    const briefItem = DataEngine.morningBrief?.items?.find(item =>
      item.id === id || item.cardRef === id
    );
    if (briefItem?.summary) return briefItem.summary;

    const thesisCard = DataEngine.investmentThesis?.cards?.[id];
    if (thesisCard?.related && thesisCard.related !== '--') {
      return `相關：${thesisCard.related}`;
    }
    return '';
  },

  resolveInvestmentThesis(id) {
    const thesisCard = DataEngine.investmentThesis?.cards?.[id];
    if (thesisCard?.investmentThesis) return thesisCard.investmentThesis;
    if (thesisCard?.related && thesisCard.related !== '--') {
      return `追蹤 ${thesisCard.related} 相關標的與供應鏈動態。`;
    }
    return '';
  },

  resolveQuestions(id) {
    const briefItem = DataEngine.morningBrief?.items?.find(item =>
      item.id === id || item.cardRef === id
    );
    if (briefItem?.summary?.includes('？') || briefItem?.summary?.includes('?')) {
      return [briefItem.summary];
    }
    return [];
  },

  resolveReason(id) {
    const queueItem = this.queue?.items?.find(item => item.id === id);
    if (queueItem?.addedFrom) return queueItem.addedFrom;

    const thesisCard = DataEngine.investmentThesis?.cards?.[id];
    if (thesisCard?.source) return thesisCard.source;

    return 'Unknown';
  },

  resolveRelated(id) {
    const thesisCard = DataEngine.investmentThesis?.cards?.[id];
    if (!thesisCard?.related || thesisCard.related === '--') return [];
    return String(thesisCard.related).split(/[、,]/).map(s => s.trim()).filter(Boolean);
  },

  normalizeCard(card) {
    if (!card) return card;

    if (card.reason == null || card.reason === '') {
      card.reason = card.source || 'Unknown';
    }

    if (!Array.isArray(card.tags)) {
      card.tags = [];
    }

    if (card.related == null) {
      card.related = [];
    } else if (!Array.isArray(card.related)) {
      const legacy = String(card.related).trim();
      card.related = (!legacy || legacy === '--')
        ? []
        : legacy.split(/[、,]/).map(s => s.trim()).filter(Boolean);
    }

    return card;
  },

  createDefaultResearch(id) {
    const card = this.normalizeCard({
      id,
      title: this.resolveTitle(id),
      summary: this.resolveSummary(id),
      investmentThesis: this.resolveInvestmentThesis(id),
      questions: this.resolveQuestions(id),
      reason: this.resolveReason(id),
      tags: [],
      related: this.resolveRelated(id),
      status: 'researching',
      updated: new Date().toISOString().slice(0, 10)
    });
    return { id, card, timeline: [], sources: [], notes: [] };
  },

  async persistResearch(id, bundle) {
    try {
      const res = await fetch(`/api/research/${encodeURIComponent(id)}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ card: bundle.card })
      });
      return res.ok && (await res.json()).created;
    } catch (_) {
      return false;
    }
  },

  async appendResearchNote(id, text, question) {
    const appendNote = (text || '').trim();
    if (!appendNote) return { ok: false, error: 'invalid_payload' };

    const payload = { appendNote };
    const q = (question || '').trim();
    if (q) payload.question = q;

    try {
      const res = await fetch(`/api/research/${encodeURIComponent(id)}`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) {
        return { ok: false, error: data.error || 'persistence_failure', message: data.message };
      }
      delete this.researchCache[id];
      return { ok: true, updated: data.updated === true, id: data.id || id };
    } catch (_) {
      return { ok: false, error: 'persistence_failure' };
    }
  },

  parseJsonArray(data, key) {
    if (Array.isArray(data)) return data;
    if (data && Array.isArray(data[key])) return data[key];
    return [];
  },

  async loadResearch(id) {
    if (this.researchCache[id]) return this.researchCache[id];

    const base = `research/${id}`;
    let card = null;
    let timeline = [];
    let sources = [];
    let notes = [];

    try {
      const cardRes = await fetch(`${base}/card.json`);
      if (cardRes.ok) card = await cardRes.json();
    } catch (_) {}

    if (card) {
      card = this.normalizeCard(card);
      const [timelineData, sourcesData, notesData] = await Promise.all([
        fetch(`${base}/timeline.json`).then(r => r.ok ? r.json() : null).catch(() => null),
        fetch(`${base}/sources.json`).then(r => r.ok ? r.json() : null).catch(() => null),
        fetch(`${base}/notes.json`).then(r => r.ok ? r.json() : null).catch(() => null)
      ]);
      timeline = this.parseJsonArray(timelineData, 'timeline');
      sources = this.parseJsonArray(sourcesData, 'sources');
      notes = this.parseJsonArray(notesData, 'notes');
    } else {
      const bundle = this.createDefaultResearch(id);
      await this.persistResearch(id, bundle);
      this.researchCache[id] = bundle;
      return bundle;
    }

    const bundle = { id, card, timeline, sources, notes };
    this.researchCache[id] = bundle;
    return bundle;
  },

  nextStatus(current) {
    return this.states?.transitions?.[current] ?? null;
  },

  async renderResearch(bundle, container) {
    if (!bundle?.card) {
      container.innerHTML = '找不到研究卡';
      return;
    }

    const { card, timeline, sources, notes } = bundle;
    const questions = Array.isArray(card.questions) ? card.questions : [];
    const tags = Array.isArray(card.tags) ? card.tags : [];
    const related = await KnowledgeEngine.getResolvedRelated(card.id);
    const linkedCases = DataEngine.findCasesByResearchId(card.id);

    let html = `<h3>${card.title}</h3>`;
    html += `<p><b>Summary</b></p><p>${card.summary || '--'}</p>`;
    html += `<p><b>Research Origin</b></p><p>${card.reason || 'Unknown'}</p>`;
    html += '<p><b>Tags</b></p>';
    html += tags.length
      ? `<ul>${tags.map(tag => `<li>${tag}</li>`).join('')}</ul>`
      : '<p>--</p>';
    html += '<p><b>Related Research</b></p>';
    html += related.length
      ? `<ul>${related.map(relatedId => {
          const label = this.cardTitle(relatedId);
          return `<li data-related-id="${relatedId}">${label}</li>`;
        }).join('')}</ul>`
      : '<p>--</p>';
    html += `<p><b>Investment Thesis</b></p><p>${card.investmentThesis || '--'}</p>`;
    const researchConclusion = card.researchConclusion;
    if (researchConclusion && typeof researchConclusion === 'object') {
      html += '<p><b>Research Conclusion</b></p>';
      html += `<p>${this.escapeHtml(researchConclusion.conclusion || '--')}</p>`;
      html += `<p>Status: ${this.escapeHtml(researchConclusion.status || '--')}</p>`;
      html += `<p>As of: ${this.escapeHtml(researchConclusion.asOf || '--')}</p>`;
      if (linkedCases.length) {
        html += '<p><b>加入 Investment Case 證據</b></p>';
        html += `<p>${linkedCases.map(item => this.escapeHtml(item.title || item.id)).join('、')}</p>`;
        html += '<p><button type="button" data-case-evidence="supporting">支持投資假設</button> ';
        html += '<button type="button" data-case-evidence="counter">反對投資假設</button></p>';
      }
    }
    html += '<p><b>Questions</b></p>';
    html += questions.length
      ? `<ul>${questions.map(q => `<li>${q}</li>`).join('')}</ul>`
      : '<p>--</p>';
    html += '<p><b>Timeline</b></p>';
    html += timeline.length
      ? `<ul>${timeline.map(entry => `<li>${entry.date} — ${entry.event}</li>`).join('')}</ul>`
      : '<p>--</p>';
    html += '<p><b>Sources</b></p>';
    html += sources.length
      ? `<ul>${sources.map(entry => `<li>${entry.title}</li>`).join('')}</ul>`
      : '<p>--</p>';
    html += '<p><b>Notes</b></p>';
    html += notes.length
      ? `<ul>${notes.map(entry => `<li>${entry.date} — ${entry.text}</li>`).join('')}</ul>`
      : '<p>--</p>';
    html += '<p><b>Append Note</b></p>';
    html += '<textarea data-append-note rows="3" style="width:100%;box-sizing:border-box"></textarea>';
    html += '<p><input data-append-question placeholder="Optional question" style="width:100%;box-sizing:border-box"></p>';
    html += '<p><button type="button" data-append-save>Save</button></p>';
    html += '<p><button type="button" data-queue-follow-up>Queue for follow-up</button></p>';

    html += '<p><b>Investment Case</b></p>';
    html += linkedCases.length
      ? `<ul>${linkedCases.map(item =>
          `<li data-open-case-id="${this.escapeHtml(item.id)}">${this.escapeHtml(item.title || item.id)}</li>`
        ).join('')}</ul>`
      : '<p>--</p>';
    html += '<p><input data-case-company placeholder="Company" style="width:40%;box-sizing:border-box;margin-right:8px">';
    html += '<input data-case-ticker placeholder="Ticker" style="width:25%;box-sizing:border-box;margin-right:8px">';
    html += '<button type="button" data-case-create>建立 Investment Case</button></p>';

    container.innerHTML = html;

    container.querySelectorAll('[data-related-id]').forEach(li => {
      li.onclick = () => {
        if (typeof openResearchCard === 'function') {
          openResearchCard(li.dataset.relatedId, container);
        }
      };
    });

    const saveBtn = container.querySelector('[data-append-save]');
    const noteInput = container.querySelector('[data-append-note]');
    const questionInput = container.querySelector('[data-append-question]');
    if (saveBtn && noteInput) {
      saveBtn.onclick = async () => {
        const result = await this.appendResearchNote(
          card.id,
          noteInput.value,
          questionInput?.value
        );
        if (!result.ok) {
          window.alert(result.message || 'Failed to save note');
          return;
        }
        if (typeof openResearchCard === 'function') {
          await openResearchCard(card.id, container, { fromNavigation: true });
        } else {
          const fresh = await this.loadResearch(card.id);
          await this.renderResearch(fresh, container);
        }
      };
    }

    const queueBtn = container.querySelector('[data-queue-follow-up]');
    if (queueBtn) {
      queueBtn.onclick = async () => {
        const added = await this.ensureInQueue(card.id, 'Follow-up');
        if (!added) {
          window.alert('Already in queue');
          return;
        }
        if (typeof render === 'function') render();
      };
    }

    container.querySelectorAll('[data-open-case-id]').forEach(li => {
      li.onclick = () => {
        if (typeof openInvestmentCase === 'function') {
          openInvestmentCase(li.dataset.openCaseId);
        }
      };
    });

    const createCaseBtn = container.querySelector('[data-case-create]');
    const companyInput = container.querySelector('[data-case-company]');
    const tickerInput = container.querySelector('[data-case-ticker]');
    if (createCaseBtn) {
      createCaseBtn.onclick = async () => {
        const result = await this.createCaseFromResearch(
          card.id,
          companyInput?.value,
          tickerInput?.value
        );
        if (!result.ok) {
          window.alert(result.message || 'Failed to create Investment Case');
          return;
        }
        if (typeof render === 'function') render();
        if (typeof openInvestmentCase === 'function') {
          await openInvestmentCase(result.id);
        }
      };
    }

    container.querySelectorAll('[data-case-evidence]').forEach(btn => {
      btn.onclick = async () => {
        const side = btn.dataset.caseEvidence === 'counter' ? 'counter' : 'supporting';
        const evidenceLabel = side === 'counter' ? 'Counter Evidence' : 'Supporting Evidence';
        const confirmed = window.confirm(
          `確定將此研究結論加入 ${evidenceLabel}？\n按「確定」後才會寫入 Investment Case。\n按「取消」則不會寫入。`
        );
        if (!confirmed) {
          window.alert('已取消，未寫入 Investment Case');
          return;
        }

        const result = await this.addResearchConclusionToCase(card, side);
        if (!result.ok) {
          window.alert(result.message || '寫入 Investment Case 失敗');
          return;
        }
        if (result.duplicate) {
          const existing = result.duplicateSide === 'counter' ? 'Counter Evidence' : 'Supporting Evidence';
          window.alert(`此結論已存在於 ${existing}`);
          return;
        }

        window.alert(`已加入 ${evidenceLabel}`);
        await DataEngine.loadInvestmentCases();
        const caseContainer = document.getElementById('caseView');
        if (typeof openInvestmentCase === 'function' && result.id) {
          await openInvestmentCase(result.id);
        } else if (caseContainer) {
          await this.renderInvestmentCase(DataEngine.getCase(result.id), caseContainer);
        }
      };
    });
  },

  escapeHtml(value) {
    return String(value ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  },

  today() {
    return new Date().toISOString().slice(0, 10);
  },

  emptyValuation() {
    return {
      bear: null,
      base: null,
      bull: null,
      marginOfSafety: null,
      buyUnder: null,
      currentPrice: null,
      currentDiscount: null,
      methodInputs: this.emptyMethodInputs(),
      methodFairValues: this.emptyMethodFairValues()
    };
  },

  fairValueMethods: ['Forward PE', 'Historical PE', 'PB / ROE'],

  fairValueFormulas: {
    'Forward PE': 'forwardEPS × reasonablePE',
    'Historical PE': 'referenceEPS × historicalPEBear / historicalPEBase / historicalPEBull',
    'PB / ROE': 'BVPS × reasonablePB'
  },

  methodInputModels: {
    'Forward PE': [
      { key: 'forwardEPS', required: true, source: 'system', unit: '元/股', inputKind: 'number', purpose: '前瞻 EPS，作為 Forward PE 的盈餘基準' },
      { key: 'reasonablePE', required: true, source: 'user', unit: '倍', inputKind: 'number', purpose: '使用者認為合理的本益比' }
    ],
    'Historical PE': [
      { key: 'referenceEPS', required: true, source: 'system', unit: '元/股', inputKind: 'number', purpose: '用來回推歷史本益比帶的參考 EPS' },
      { key: 'historicalPEBear', required: true, source: 'user', unit: '倍', inputKind: 'number', purpose: '歷史本益比空頭倍數' },
      { key: 'historicalPEBase', required: true, source: 'user', unit: '倍', inputKind: 'number', purpose: '歷史本益比基準倍數' },
      { key: 'historicalPEBull', required: true, source: 'user', unit: '倍', inputKind: 'number', purpose: '歷史本益比多頭倍數' }
    ],
    'PB / ROE': [
      { key: 'BVPS', required: true, source: 'system', unit: '元/股', inputKind: 'number', purpose: '每股淨值，作為 PB 估值的帳面基準' },
      { key: 'ROE', required: true, source: 'system', unit: '%', inputKind: 'percent', purpose: '用來判斷合理 PB 是否與獲利能力相符' },
      { key: 'reasonablePB', required: true, source: 'user', unit: '倍', inputKind: 'number', purpose: '使用者認為合理的股價淨值比' }
    ],
    'DCF': [
      { key: 'freeCashFlow', required: true, source: 'system', unit: '億元', inputKind: 'number', purpose: '自由現金流起點，尚未折現' },
      { key: 'growthRate', required: true, source: 'user', unit: '%', inputKind: 'percent', purpose: '明確成長期的現金流成長率' },
      { key: 'discountRate', required: true, source: 'user', unit: '%', inputKind: 'percent', purpose: '把未來現金流折回現值的折現率' },
      { key: 'terminalGrowthRate', required: true, source: 'user', unit: '%', inputKind: 'percent', purpose: '終值階段的長期成長率' }
    ],
    'EV/EBITDA': [
      { key: 'EBITDA', required: true, source: 'system', unit: '億元', inputKind: 'number', purpose: '企業價值對 EBITDA 的營運獲利基準' },
      { key: 'reasonableEVEBITDA', required: true, source: 'user', unit: '倍', inputKind: 'number', purpose: '使用者認為合理的 EV/EBITDA 倍數' },
      { key: 'netDebt', required: true, source: 'system', unit: '億元', inputKind: 'number', purpose: '把企業價值轉成股權價值時扣除的淨負債' },
      { key: 'sharesOutstanding', required: true, source: 'system', unit: '股', inputKind: 'number', purpose: '把股權價值換成每股價值' }
    ],
    'EV/Sales': [
      { key: 'revenue', required: true, source: 'system', unit: '億元', inputKind: 'number', purpose: '企業價值對營收的銷售基準' },
      { key: 'reasonableEVSales', required: true, source: 'user', unit: '倍', inputKind: 'number', purpose: '使用者認為合理的 EV/Sales 倍數' },
      { key: 'netDebt', required: true, source: 'system', unit: '億元', inputKind: 'number', purpose: '把企業價值轉成股權價值時扣除的淨負債' },
      { key: 'sharesOutstanding', required: true, source: 'system', unit: '股', inputKind: 'number', purpose: '把股權價值換成每股價值' }
    ],
    'Dividend Discount': [
      { key: 'DPS', required: true, source: 'system', unit: '元/股', inputKind: 'number', purpose: '每股股利，作為股利折現的起點' },
      { key: 'dividendGrowthRate', required: true, source: 'user', unit: '%', inputKind: 'percent', purpose: '股利成長率' },
      { key: 'requiredReturn', required: true, source: 'user', unit: '%', inputKind: 'percent', purpose: '投資人要求報酬率' }
    ],
    'NAV': [
      { key: 'assetValue', required: true, source: 'user', unit: '億元', inputKind: 'number', purpose: '資產價值，作為淨資產估值的分子' },
      { key: 'liabilities', required: true, source: 'system', unit: '億元', inputKind: 'number', purpose: '負債，用來從資產得到淨資產' },
      { key: 'sharesOutstanding', required: true, source: 'system', unit: '股', inputKind: 'number', purpose: '把淨資產換成每股 NAV' }
    ]
  },

  emptyMethodInput() {
    return {
      value: null,
      sourceType: null,
      researchId: null,
      period: null,
      asOf: null
    };
  },

  methodInputSourceTypes: ['user', 'research', 'external', 'system'],

  normalizeMethodInput(raw) {
    const leaf = this.emptyMethodInput();
    if (raw == null || raw === '') return leaf;
    if (typeof raw === 'number') {
      leaf.value = Number.isFinite(raw) ? raw : null;
      return leaf;
    }
    if (typeof raw !== 'object') return leaf;

    if (raw.value != null && raw.value !== '') {
      const n = Number(raw.value);
      leaf.value = Number.isFinite(n) ? n : null;
    }
    if (this.methodInputSourceTypes.includes(raw.sourceType)) {
      leaf.sourceType = raw.sourceType;
    }
    const researchId = (raw.researchId || '').trim();
    leaf.researchId = researchId || null;
    const period = (raw.period || '').trim();
    leaf.period = period || null;
    const asOf = (raw.asOf || '').trim();
    leaf.asOf = asOf || null;
    return leaf;
  },

  validateMethodInput(input, researchIds) {
    const leaf = this.normalizeMethodInput(input);
    const linked = Array.isArray(researchIds) ? researchIds : [];
    const errors = [];

    if (leaf.sourceType != null && !this.methodInputSourceTypes.includes(leaf.sourceType)) {
      errors.push('invalid_sourceType');
    }
    if (leaf.researchId && !linked.includes(leaf.researchId)) {
      errors.push('researchId_not_linked');
    }
    if (leaf.sourceType === 'research' && !leaf.researchId) {
      errors.push('research_requires_researchId');
    }

    return { ok: errors.length === 0, errors, input: leaf };
  },

  emptyMethodInputs() {
    const inputs = {};
    Object.keys(this.methodInputModels).forEach(method => {
      inputs[method] = {};
      this.methodInputModels[method].forEach(field => {
        inputs[method][field.key] = this.emptyMethodInput();
      });
    });
    return inputs;
  },

  ensureMethodInputs(valuation) {
    const current = valuation || this.emptyValuation();
    const reserved = this.emptyMethodInputs();
    const existing = current.methodInputs && typeof current.methodInputs === 'object'
      ? current.methodInputs
      : {};

    Object.keys(reserved).forEach(method => {
      const src = existing[method] && typeof existing[method] === 'object' ? existing[method] : {};
      Object.keys(reserved[method]).forEach(key => {
        reserved[method][key] = this.normalizeMethodInput(src[key]);
      });
    });

    current.methodInputs = reserved;
    return current;
  },

  emptyMethodFairValue() {
    return {
      bear: null,
      base: null,
      bull: null,
      asOf: null
    };
  },

  emptyMethodFairValues() {
    const values = {};
    this.fairValueMethods.forEach(method => {
      values[method] = this.emptyMethodFairValue();
    });
    return values;
  },

  methodInputNumber(methodInputs, method, field) {
    const raw = methodInputs?.[method]?.[field]?.value;
    if (raw == null || raw === '') return null;
    const n = Number(raw);
    return Number.isFinite(n) ? n : null;
  },

  productOrNull(left, right) {
    if (left == null || right == null) return null;
    const n = Number(left) * Number(right);
    return Number.isFinite(n) ? n : null;
  },

  withFairValueAsOf(result) {
    const leaf = {
      bear: result?.bear ?? null,
      base: result?.base ?? null,
      bull: result?.bull ?? null,
      asOf: null
    };
    if (leaf.bear != null || leaf.base != null || leaf.bull != null) {
      leaf.asOf = this.today();
    }
    return leaf;
  },

  computeOneMethodFairValue(method, methodInputs) {
    if (method === 'Forward PE') {
      return this.withFairValueAsOf({
        bear: null,
        base: this.productOrNull(
          this.methodInputNumber(methodInputs, method, 'forwardEPS'),
          this.methodInputNumber(methodInputs, method, 'reasonablePE')
        ),
        bull: null
      });
    }
    if (method === 'Historical PE') {
      const eps = this.methodInputNumber(methodInputs, method, 'referenceEPS');
      return this.withFairValueAsOf({
        bear: this.productOrNull(eps, this.methodInputNumber(methodInputs, method, 'historicalPEBear')),
        base: this.productOrNull(eps, this.methodInputNumber(methodInputs, method, 'historicalPEBase')),
        bull: this.productOrNull(eps, this.methodInputNumber(methodInputs, method, 'historicalPEBull'))
      });
    }
    if (method === 'PB / ROE') {
      return this.withFairValueAsOf({
        bear: null,
        base: this.productOrNull(
          this.methodInputNumber(methodInputs, method, 'BVPS'),
          this.methodInputNumber(methodInputs, method, 'reasonablePB')
        ),
        bull: null
      });
    }
    return this.emptyMethodFairValue();
  },

  computeMethodFairValues(valuation, userConfirmed) {
    const ensured = this.ensureMethodInputs(valuation || this.emptyValuation());
    if (!userConfirmed) return this.emptyMethodFairValues();
    const values = {};
    this.fairValueMethods.forEach(method => {
      values[method] = this.computeOneMethodFairValue(method, ensured.methodInputs);
    });
    return values;
  },

  applyMethodFairValues(valuation, profile) {
    const current = valuation || this.emptyValuation();
    current.methodFairValues = this.computeMethodFairValues(current, profile?.userConfirmed === true);
    this.applyCaseLevelValuation(current, profile);
    return current;
  },

  fairValueNumber(value) {
    if (value == null || value === '') return null;
    const n = Number(value);
    return Number.isFinite(n) ? n : null;
  },

  applyCaseLevelValuation(valuation, profile) {
    const current = valuation || this.emptyValuation();
    const primary = profile?.primaryMethod || null;
    if (profile?.userConfirmed !== true || !primary) {
      current.bear = null;
      current.base = null;
      current.bull = null;
      current.buyUnder = null;
      return current;
    }
    const fv = current.methodFairValues?.[primary];
    current.base = this.fairValueNumber(fv?.base);
    current.bear = this.fairValueNumber(fv?.bear);
    current.bull = this.fairValueNumber(fv?.bull);
    current.buyUnder = this.computeBuyUnder(current.base, current.marginOfSafety);
    return current;
  },

  caseLevelMissingNote(profile, valuation) {
    if (!profile?.userConfirmed) return '尚未確認 valuationProfile';
    if (!profile.primaryMethod) return '尚未判定 Primary Method';
    if (!this.fairValueMethods.includes(profile.primaryMethod)) {
      return `Primary Method ${profile.primaryMethod} 本階段不計算`;
    }
    const missing = this.missingFairValueInputs(profile.primaryMethod, valuation?.methodInputs);
    if (missing.length) return `缺少 ${missing.join('、')}`;
    return '';
  },

  formatCaseLevelValue(value) {
    if (value == null || value === '') return '尚未計算';
    return `${this.formatNumber(value)} 元/股`;
  },

  ensureMethodFairValues(valuation) {
    const current = valuation || this.emptyValuation();
    const reserved = this.emptyMethodFairValues();
    const existing = current.methodFairValues && typeof current.methodFairValues === 'object'
      ? current.methodFairValues
      : {};
    this.fairValueMethods.forEach(method => {
      const src = existing[method] && typeof existing[method] === 'object' ? existing[method] : {};
      const leaf = this.emptyMethodFairValue();
      ['bear', 'base', 'bull'].forEach(key => {
        if (src[key] != null && src[key] !== '') {
          const n = Number(src[key]);
          leaf[key] = Number.isFinite(n) ? n : null;
        }
      });
      const asOf = (src.asOf || '').trim();
      leaf.asOf = (leaf.bear != null || leaf.base != null || leaf.bull != null)
        ? (asOf || null)
        : null;
      reserved[method] = leaf;
    });
    current.methodFairValues = reserved;
    return current;
  },

  missingFairValueInputs(method, methodInputs) {
    const missing = [];
    const addIfMissing = field => {
      if (this.methodInputNumber(methodInputs, method, field) == null) missing.push(field);
    };
    if (method === 'Forward PE') {
      addIfMissing('forwardEPS');
      addIfMissing('reasonablePE');
    } else if (method === 'Historical PE') {
      addIfMissing('referenceEPS');
      addIfMissing('historicalPEBear');
      addIfMissing('historicalPEBase');
      addIfMissing('historicalPEBull');
    } else if (method === 'PB / ROE') {
      addIfMissing('BVPS');
      addIfMissing('reasonablePB');
    }
    return missing;
  },

  formatFairValue(value) {
    return value == null || value === '' ? '--' : `${this.formatNumber(value)} 元/股`;
  },

  renderMethodFairValue(method, methodInputs, role) {
    if (!this.fairValueMethods.includes(method)) return '';
    const title = role ? `Fair Value（${role}：${method}）` : `Fair Value（${method}）`;
    const result = this.computeOneMethodFairValue(method, methodInputs);
    const missing = this.missingFairValueInputs(method, methodInputs);
    let html = `<p><b>${this.escapeHtml(title)}</b></p>`;
    html += `<p>公式：${this.escapeHtml(this.fairValueFormulas[method] || '')}</p>`;
    html += `<p>Bear：${this.escapeHtml(this.formatFairValue(result.bear))}</p>`;
    html += `<p>Base：${this.escapeHtml(this.formatFairValue(result.base))}</p>`;
    html += `<p>Bull：${this.escapeHtml(this.formatFairValue(result.bull))}</p>`;
    if (missing.length) {
      html += `<p>尚未計算：缺少 ${this.escapeHtml(missing.join('、'))}</p>`;
    }
    return html;
  },

  formatInputValue(value) {
    return value == null || value === '' ? '尚未提供' : String(value);
  },

  formatSourceType(sourceType) {
    if (sourceType === 'user') return '使用者輸入';
    if (sourceType === 'research') return '直接引用研究卡';
    if (sourceType === 'external') return '外部資料';
    if (sourceType === 'system') return '系統';
    return '尚未提供';
  },

  formatResearchBasis(leaf) {
    if (!leaf?.researchId) return '尚未提供';
    if (leaf.sourceType === 'research') {
      return `直接引用：${leaf.researchId}`;
    }
    if (leaf.sourceType === 'user') {
      return `研究依據：${leaf.researchId}`;
    }
    return leaf.researchId;
  },

  selectedValuationMethods(profile) {
    const current = profile || this.emptyValuationProfile();
    return [
      { role: 'Primary Method', method: current.primaryMethod },
      { role: 'Secondary Method', method: current.secondaryMethod },
      { role: 'Cross-check Method', method: current.crossCheckMethod }
    ].filter(item => item.method);
  },

  renderValuationInputs(profile, valuation, researchIds) {
    if (!profile?.userConfirmed) return '';

    const ensured = this.ensureMethodInputs(valuation);
    const selected = this.selectedValuationMethods(profile);
    const linkedIds = Array.isArray(researchIds) ? researchIds : [];
    let html = '<p><b>估值輸入</b></p>';
    html += '<p>本階段只計算 Forward PE、Historical PE、PB / ROE 的 Fair Value。Case 層級 Bear / Base / Bull 尚未指定。</p>';
    html += '<p>researchId 是此數值或判斷的依據，不是原始提供者。</p>';
    html += '<p>空白會存成 null。無效文字不會寫入。合理性 warning 仍可保存假設。</p>';

    const roleByMethod = {};
    selected.forEach(item => { roleByMethod[item.method] = item.role; });

    Object.keys(this.methodInputModels).forEach(method => {
      const fields = this.methodInputModels[method] || [];
      const values = ensured.methodInputs[method] || {};
      const role = roleByMethod[method];
      const title = role ? `${role}：${method}` : method;
      html += `<p><b>${this.escapeHtml(title)}</b></p>`;
      html += '<ul>';
      fields.forEach(field => {
        const checked = this.validateMethodInput(values[field.key], linkedIds);
        const leaf = checked.input;
        const status = field.required ? '必要' : '可選';
        const currentValue = this.toUiInputValue(method, field.key, leaf.value);
        const token = `${method}::${field.key}`;
        const unit = field.unit || '';
        html += `<li>${this.escapeHtml(field.key)}（${status}，${this.escapeHtml(unit)}）：`;
        html += `<input data-method-value="${this.escapeHtml(token)}" type="number" step="0.01" value="${currentValue === '' ? '' : this.escapeHtml(currentValue)}" style="width:6em"> `;
        html += `${this.escapeHtml(unit)} `;
        html += `<button type="button" data-method-save="${this.escapeHtml(token)}">Save</button>`;
        html += ` — ${this.escapeHtml(field.purpose)}`;
        html += `<br>sourceType：${this.escapeHtml(this.formatSourceType(leaf.sourceType))}`;
        html += `<br>researchId：${this.escapeHtml(this.formatResearchBasis(leaf))}`;
        html += `<br>period：${this.escapeHtml(this.formatInputValue(leaf.period))}`;
        html += `<br>asOf：${this.escapeHtml(this.formatInputValue(leaf.asOf))}`;
        this.getMethodInputWarnings(method, field.key, leaf.value).forEach(warning => {
          html += `<br><span style="color:#b45309">Warning：${this.escapeHtml(warning)}。仍可保存此假設。</span>`;
        });
        html += '</li>';
      });
      html += '</ul>';
      html += this.renderMethodFairValue(method, ensured.methodInputs, role);
    });

    return html;
  },

  valuationMethods: [
    'Forward PE',
    'Historical PE',
    'PB / ROE',
    'DCF',
    'EV/EBITDA',
    'EV/Sales',
    'Dividend Discount',
    'NAV'
  ],

  companyTypes: [
    'Growth',
    'Financial / Bank',
    'Mature / Value',
    'Asset-heavy'
  ],

  valuationRecommendations: {
    'Growth': {
      primaryMethod: 'Forward PE',
      secondaryMethod: 'Historical PE',
      crossCheckMethod: 'DCF'
    },
    'Financial / Bank': {
      primaryMethod: 'PB / ROE',
      secondaryMethod: 'Historical PE',
      crossCheckMethod: 'Dividend Discount'
    },
    'Mature / Value': {
      primaryMethod: 'Historical PE',
      secondaryMethod: 'Forward PE',
      crossCheckMethod: 'DCF'
    },
    'Asset-heavy': {
      primaryMethod: 'NAV',
      secondaryMethod: 'PB / ROE',
      crossCheckMethod: 'DCF'
    }
  },

  emptyValuationProfile() {
    return {
      companyType: null,
      primaryMethod: null,
      secondaryMethod: null,
      crossCheckMethod: null,
      userConfirmed: false
    };
  },

  recommendValuationMethods(companyType) {
    if (!companyType) return null;
    return this.valuationRecommendations[companyType] || null;
  },

  profileFromCompanyType(companyType) {
    const type = (companyType || '').trim();
    if (!type) return this.emptyValuationProfile();
    const rec = this.recommendValuationMethods(type);
    if (!rec) return null;
    return {
      companyType: type,
      primaryMethod: rec.primaryMethod,
      secondaryMethod: rec.secondaryMethod,
      crossCheckMethod: rec.crossCheckMethod,
      userConfirmed: false
    };
  },

  formatProfileValue(value) {
    return value ? value : '尚未判定';
  },

  parseMarginOfSafety(raw) {
    if (raw == null || String(raw).trim() === '') {
      return { ok: false, message: 'marginOfSafety is required' };
    }
    const n = Number(raw);
    if (!Number.isFinite(n) || n < 0) {
      return { ok: false, message: 'Invalid marginOfSafety' };
    }
    const mos = n > 1 && n <= 100 ? n / 100 : n;
    if (mos > 1) {
      return { ok: false, message: 'marginOfSafety must be between 0 and 1' };
    }
    return { ok: true, value: mos };
  },

  computeBuyUnder(base, marginOfSafety) {
    if (base == null || marginOfSafety == null) return null;
    const b = Number(base);
    const m = Number(marginOfSafety);
    if (!Number.isFinite(b) || !Number.isFinite(m)) return null;
    return b * (1 - m);
  },

  formatNumber(value) {
    return value == null || value === '' ? '--' : String(value);
  },

  formatPercent(value) {
    if (value == null || value === '') return '--';
    const n = Number(value);
    if (!Number.isFinite(n)) return '--';
    return `${Math.round(n * 10000) / 100}%`;
  },

  async researchTitle(id) {
    const card = await DataEngine.getCard(id);
    return card?.title ?? this.cardTitle(id);
  },

  async createCaseFromResearch(researchId, companyName, ticker) {
    const name = (companyName || '').trim();
    const code = (ticker || '').trim();
    if (!name || !code) {
      return { ok: false, message: 'Company and ticker are required' };
    }
    if (/[\\/]/.test(code) || /[\\/]/.test(researchId)) {
      return { ok: false, message: 'Invalid company or research id' };
    }

    const id = `${code}-${researchId}`;
    const existing = DataEngine.getCase(id);
    if (existing) return { ok: true, created: false, id };

    const bundle = await this.loadResearch(researchId);
    const card = bundle?.card;
    const related = await KnowledgeEngine.getResolvedRelated(researchId);
    const researchIds = [researchId, ...related.filter(item => item !== researchId)];
    const today = this.today();
    const questions = Array.isArray(card?.questions) ? card.questions : [];
    const summary = (card?.summary || '').trim();

    const caseObj = {
      id,
      title: `${name} — ${card?.title || researchId}`,
      status: 'draft',
      company: {
        name,
        ticker: code,
        exchange: null,
        currency: null
      },
      origin: {
        source: 'Research Card',
        createdAt: today,
        updatedAt: today
      },
      researchIds,
      thesisId: null,
      thesis: {
        thesis: card?.investmentThesis || '',
        growthDrivers: [],
        competitiveAdvantage: '',
        earningsTranslation: '',
        duration: '',
        supportingEvidence: summary
          ? [{ text: summary, researchId }]
          : [],
        counterEvidence: [],
        toBeVerified: questions.map(text => ({ text, researchId })),
        killCriteria: [],
        status: 'forming'
      },
      valuationProfile: this.emptyValuationProfile(),
      valuation: this.emptyValuation(),
      decision: null,
      decisionHistory: [],
      positionPlaybook: this.emptyPositionPlaybook(),
      monitoring: null
    };

    const persisted = await this.persistCaseCreate(caseObj);
    if (!persisted.ok) return persisted;
    return { ok: true, created: persisted.created !== false, id };
  },

  async persistCaseCreate(caseObj) {
    try {
      const res = await fetch('/api/cases', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ case: caseObj })
      });
      const data = await res.json().catch(() => ({}));
      if (res.ok) {
        await DataEngine.loadInvestmentCases();
        if (!DataEngine.getCase(caseObj.id)) DataEngine.upsertCase(caseObj);
        return { ok: true, created: data.created === true, id: caseObj.id };
      }
      return { ok: false, message: data.message || 'Failed to save Investment Case' };
    } catch (_) {
      DataEngine.upsertCase(caseObj);
      return { ok: true, created: true, id: caseObj.id, fallback: true };
    }
  },

  sameCaseEvidence(item, researchId, text) {
    return !!item
      && String(item.researchId || '') === String(researchId || '')
      && String(item.text || '').trim() === String(text || '').trim();
  },

  conclusionEvidenceLocation(caseObj, researchId, text) {
    const thesis = caseObj?.thesis || {};
    const supporting = Array.isArray(thesis.supportingEvidence) ? thesis.supportingEvidence : [];
    const counter = Array.isArray(thesis.counterEvidence) ? thesis.counterEvidence : [];
    if (supporting.some(item => this.sameCaseEvidence(item, researchId, text))) return 'supporting';
    if (counter.some(item => this.sameCaseEvidence(item, researchId, text))) return 'counter';
    return null;
  },

  caseHasConclusionEvidence(caseObj, researchId, text) {
    return this.conclusionEvidenceLocation(caseObj, researchId, text) != null;
  },

  async addResearchConclusionToCase(card, side) {
    const conclusion = (card?.researchConclusion?.conclusion || '').trim();
    if (!conclusion) return { ok: false, message: 'Research Conclusion is empty' };
    if (side !== 'supporting' && side !== 'counter') {
      return { ok: false, message: 'Choose supporting or counter evidence' };
    }

    const researchId = card.id;
    const linkedCases = DataEngine.findCasesByResearchId(researchId).filter(item =>
      Array.isArray(item.researchIds) && item.researchIds.includes(researchId)
    );
    if (!linkedCases.length) {
      return { ok: false, message: 'No linked Investment Case' };
    }

    const evidence = { text: conclusion, researchId };
    let lastId = null;
    let lastDuplicateSide = null;
    let wrote = false;
    let duplicateOnly = true;

    for (const caseObj of linkedCases) {
      const result = await this.persistCaseThesisEvidence(caseObj.id, side, evidence);
      if (!result.ok) return result;
      lastId = caseObj.id;
      if (result.duplicate) {
        lastDuplicateSide = result.duplicateSide || lastDuplicateSide;
        continue;
      }
      duplicateOnly = false;
      wrote = true;
    }

    if (!wrote && duplicateOnly) {
      return { ok: true, duplicate: true, duplicateSide: lastDuplicateSide, id: lastId };
    }
    return { ok: true, id: lastId };
  },

  async persistCaseThesisEvidence(caseId, side, evidence) {
    const current = DataEngine.getCase(caseId);
    if (!current) return { ok: false, message: 'Investment Case not found' };
    const researchIds = Array.isArray(current.researchIds) ? current.researchIds : [];
    if (!researchIds.includes(evidence.researchId)) {
      return { ok: false, message: 'Research Card is not linked to this Investment Case' };
    }
    const existingSide = this.conclusionEvidenceLocation(current, evidence.researchId, evidence.text);
    if (existingSide) {
      return { ok: true, duplicate: true, duplicateSide: existingSide, id: caseId };
    }

    try {
      const res = await fetch('/api/cases', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          id: caseId,
          thesisEvidence: {
            side,
            text: evidence.text,
            researchId: evidence.researchId
          }
        })
      });
      const data = await res.json().catch(() => ({}));
      if (res.ok) {
        await DataEngine.loadInvestmentCases();
        if (data.duplicate === true) {
          const fresh = DataEngine.getCase(caseId);
          return {
            ok: true,
            duplicate: true,
            duplicateSide: this.conclusionEvidenceLocation(fresh, evidence.researchId, evidence.text),
            id: caseId
          };
        }
        return { ok: true, id: caseId };
      }
      return { ok: false, message: data.message || '寫入 Investment Case 失敗' };
    } catch (_) {
      const thesis = current.thesis || {};
      const key = side === 'counter' ? 'counterEvidence' : 'supportingEvidence';
      const list = Array.isArray(thesis[key]) ? thesis[key] : [];
      list.push({ text: evidence.text, researchId: evidence.researchId });
      thesis[key] = list;
      current.thesis = thesis;
      current.origin = current.origin || {};
      current.origin.updatedAt = this.today();
      DataEngine.upsertCase(current);
      return { ok: true, id: caseId, fallback: true };
    }
  },

  async persistValuationProfile(caseId, payload) {
    const current = DataEngine.getCase(caseId);
    if (!current) return { ok: false, message: 'Investment Case not found' };

    try {
      const res = await fetch('/api/cases', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: caseId, ...payload })
      });
      const data = await res.json().catch(() => ({}));
      if (res.ok) {
        await DataEngine.loadInvestmentCases();
        return { ok: true, id: caseId };
      }
      return { ok: false, message: data.message || 'Failed to save valuationProfile' };
    } catch (_) {
      return { ok: false, fallback: true, current };
    }
  },

  async saveCaseCompanyType(caseId, companyType) {
    const profile = this.profileFromCompanyType(companyType);
    if (companyType && !profile) {
      return { ok: false, message: 'Unsupported companyType' };
    }

    const persisted = await this.persistValuationProfile(caseId, {
      companyType: profile.companyType
    });
    if (persisted.ok) return persisted;
    if (!persisted.fallback) return persisted;

    persisted.current.valuationProfile = profile;
    persisted.current.valuation = this.applyMethodFairValues(
      persisted.current.valuation || this.emptyValuation(),
      profile
    );
    persisted.current.origin = persisted.current.origin || {};
    persisted.current.origin.updatedAt = this.today();
    DataEngine.upsertCase(persisted.current);
    return { ok: true, id: caseId, fallback: true };
  },

  async confirmCaseValuationProfile(caseId) {
    const current = DataEngine.getCase(caseId);
    if (!current) return { ok: false, message: 'Investment Case not found' };
    const profile = current.valuationProfile || this.emptyValuationProfile();
    if (!profile.companyType || !profile.primaryMethod) {
      return { ok: false, message: 'companyType 尚未判定，無法確認' };
    }

    const persisted = await this.persistValuationProfile(caseId, {
      confirmValuationProfile: true
    });
    if (persisted.ok) return persisted;
    if (!persisted.fallback) return persisted;

    persisted.current.valuationProfile = persisted.current.valuationProfile || this.emptyValuationProfile();
    persisted.current.valuationProfile.userConfirmed = true;
    persisted.current.valuation = this.applyMethodFairValues(
      persisted.current.valuation || this.emptyValuation(),
      persisted.current.valuationProfile
    );
    persisted.current.origin = persisted.current.origin || {};
    persisted.current.origin.updatedAt = this.today();
    DataEngine.upsertCase(persisted.current);
    return { ok: true, id: caseId, fallback: true };
  },

  renderValuationProfile(profile) {
    const current = profile || this.emptyValuationProfile();
    const selected = current.companyType || '';
    const options = ['<option value="">尚未判定</option>']
      .concat(this.companyTypes.map(type => {
        const mark = type === selected ? ' selected' : '';
        return `<option value="${this.escapeHtml(type)}"${mark}>${this.escapeHtml(type)}</option>`;
      }));

    let html = '<p><b>Valuation Profile</b></p>';
    html += `<p>公司類型 <select data-case-company-type>${options.join('')}</select></p>`;
    html += `<p>Investor Twin 建議的 Primary Method：${this.escapeHtml(this.formatProfileValue(current.primaryMethod))}</p>`;
    html += `<p>Secondary Method：${this.escapeHtml(this.formatProfileValue(current.secondaryMethod))}</p>`;
    html += `<p>Cross-check Method：${this.escapeHtml(this.formatProfileValue(current.crossCheckMethod))}</p>`;
    html += `<p>userConfirmed：${current.userConfirmed ? '已確認' : '尚未確認'}</p>`;
    if (current.companyType && !current.userConfirmed) {
      html += '<p><button type="button" data-case-confirm-profile>確認這組方法</button></p>';
    } else if (!current.companyType) {
      html += '<p>公司類型尚未判定，不自動填入估值方法。</p>';
    }
    return html;
  },

  getMethodField(method, field) {
    const fields = this.methodInputModels[method];
    return Array.isArray(fields) ? fields.find(item => item.key === field) : null;
  },

  isAllowedMethodField(method, field) {
    return !!this.getMethodField(method, field);
  },

  isPercentField(method, field) {
    return this.getMethodField(method, field)?.inputKind === 'percent';
  },

  toUiInputValue(method, field, storedValue) {
    if (storedValue == null || storedValue === '') return '';
    const n = Number(storedValue);
    if (!Number.isFinite(n)) return '';
    return this.isPercentField(method, field) ? n * 100 : n;
  },

  fromUiInputValue(method, field, rawValue) {
    const raw = String(rawValue ?? '').trim();
    if (raw === '') return { ok: true, value: null };
    const n = Number(raw);
    if (!Number.isFinite(n)) {
      return { ok: false, message: `${field} 必須是有效數字，未寫入 Case` };
    }
    return {
      ok: true,
      value: this.isPercentField(method, field) ? n / 100 : n
    };
  },

  getMethodInputWarnings(method, field, storedValue) {
    if (storedValue == null || storedValue === '') return [];
    const n = Number(storedValue);
    if (!Number.isFinite(n)) return [];

    const warnings = [];
    const peFields = ['reasonablePE', 'historicalPEBear', 'historicalPEBase', 'historicalPEBull'];
    const extremePercents = [
      'ROE', 'growthRate', 'discountRate', 'terminalGrowthRate',
      'dividendGrowthRate', 'requiredReturn'
    ];

    if (field === 'requiredReturn' && n < 0) {
      warnings.push('requiredReturn 為負值');
    }
    if (field === 'discountRate' && n < 0) {
      warnings.push('discountRate 為負值');
    }
    if (peFields.includes(field) && n < 0) {
      warnings.push('PE 為負值');
    }
    if (field === 'reasonablePB' && n < 0) {
      warnings.push('PB 為負值');
    }
    if ((field === 'reasonableEVEBITDA' || field === 'reasonableEVSales') && n < 0) {
      warnings.push('估值倍數為負值');
    }
    if (extremePercents.includes(field) && Math.abs(n) > 1) {
      warnings.push('百分比絕對值超過 100%，屬極端假設');
    }
    if (field === 'sharesOutstanding' && n < 0) {
      warnings.push('股數為負值');
    }

    return warnings;
  },

  async saveMethodInputValue(caseId, method, field, rawValue) {
    if (!this.isAllowedMethodField(method, field)) {
      return { ok: false, message: 'Unsupported method or field' };
    }
    const parsed = this.fromUiInputValue(method, field, rawValue);
    if (!parsed.ok) return parsed;
    const n = parsed.value;

    const current = DataEngine.getCase(caseId);
    if (!current) return { ok: false, message: 'Investment Case not found' };

    const leaf = n == null
      ? this.emptyMethodInput()
      : {
          value: n,
          sourceType: 'user',
          researchId: null,
          period: null,
          asOf: this.today()
        };

    try {
      const res = await fetch('/api/cases', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          id: caseId,
          methodInput: { method, field, value: n }
        })
      });
      const data = await res.json().catch(() => ({}));
      if (res.ok) {
        await DataEngine.loadInvestmentCases();
        return { ok: true, id: caseId };
      }
      return { ok: false, message: data.message || `Failed to save ${field}` };
    } catch (_) {
      const valuation = this.ensureMethodInputs(current.valuation || this.emptyValuation());
      valuation.methodInputs[method][field] = leaf;
      current.valuation = this.applyMethodFairValues(
        valuation,
        current.valuationProfile
      );
      current.origin = current.origin || {};
      current.origin.updatedAt = this.today();
      DataEngine.upsertCase(current);
      return { ok: true, id: caseId, fallback: true };
    }
  },

  async saveCaseMarginOfSafety(caseId, rawMos) {
    const parsed = this.parseMarginOfSafety(rawMos);
    if (!parsed.ok) return parsed;

    const current = DataEngine.getCase(caseId);
    if (!current) return { ok: false, message: 'Investment Case not found' };

    try {
      const res = await fetch('/api/cases', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: caseId, marginOfSafety: parsed.value })
      });
      const data = await res.json().catch(() => ({}));
      if (res.ok) {
        await DataEngine.loadInvestmentCases();
        return { ok: true, id: caseId };
      }
      return { ok: false, message: data.message || 'Failed to save marginOfSafety' };
    } catch (_) {
      if (!current.valuation) current.valuation = this.emptyValuation();
      current.valuation.marginOfSafety = parsed.value;
      this.applyCaseLevelValuation(current.valuation, current.valuationProfile);
      current.valuation.currentPrice = null;
      current.valuation.currentDiscount = null;
      current.origin = current.origin || {};
      current.origin.updatedAt = this.today();
      DataEngine.upsertCase(current);
      return { ok: true, id: caseId, fallback: true };
    }
  },

  allowedDecisionStances() {
    return ['watch', 'pass', 'initiate', 'hold', 'reduce', 'exit', 'review'];
  },

  isPersistedDecision(decision) {
    return !!decision
      && typeof decision === 'object'
      && this.allowedDecisionStances().includes(String(decision.stance || ''));
  },

  decisionBasedOnSnapshot(caseObj) {
    const thesis = caseObj?.thesis || {};
    const supporting = Array.isArray(thesis.supportingEvidence) ? thesis.supportingEvidence : [];
    const counter = Array.isArray(thesis.counterEvidence) ? thesis.counterEvidence : [];
    const researchIds = Array.isArray(caseObj?.researchIds) ? caseObj.researchIds.slice() : [];
    return {
      researchIds,
      supportingCount: supporting.length,
      counterCount: counter.length,
      thesisStatus: thesis.status || null
    };
  },

  buildDecision(caseObj, stance, reason) {
    return {
      stance,
      asOf: this.today(),
      reason: String(reason || '').trim(),
      basedOn: this.decisionBasedOnSnapshot(caseObj)
    };
  },

  applyDecisionLocally(caseObj, next) {
    if (this.isPersistedDecision(caseObj.decision)) {
      const history = Array.isArray(caseObj.decisionHistory) ? caseObj.decisionHistory : [];
      history.push(caseObj.decision);
      caseObj.decisionHistory = history;
    } else if (!Array.isArray(caseObj.decisionHistory)) {
      caseObj.decisionHistory = [];
    }
    caseObj.decision = next;
    caseObj.origin = caseObj.origin || {};
    caseObj.origin.updatedAt = this.today();
    return caseObj;
  },

  formatDecisionBasedOn(basedOn) {
    const src = basedOn || {};
    const ids = Array.isArray(src.researchIds) && src.researchIds.length
      ? src.researchIds.join(', ')
      : '--';
    const supporting = src.supportingCount == null ? '--' : src.supportingCount;
    const counter = src.counterCount == null ? '--' : src.counterCount;
    return `researchIds: ${ids}; supporting: ${supporting}; counter: ${counter}; thesisStatus: ${src.thesisStatus || '--'}`;
  },

  renderDecisionRecord(decision) {
    if (!this.isPersistedDecision(decision)) return '';
    let html = `<p>Stance: ${this.escapeHtml(decision.stance)}</p>`;
    html += `<p>As of: ${this.escapeHtml(decision.asOf || '--')}</p>`;
    html += `<p>Reason: ${this.escapeHtml(decision.reason || '--')}</p>`;
    html += `<p>Based on: ${this.escapeHtml(this.formatDecisionBasedOn(decision.basedOn))}</p>`;
    return html;
  },

  renderDecisionHistory(items) {
    const list = Array.isArray(items) ? items.filter(item => this.isPersistedDecision(item)) : [];
    if (!list.length) return '<p>--</p>';
    return `<ul>${list.map(item => {
      const basedOn = this.formatDecisionBasedOn(item.basedOn);
      return `<li>${this.escapeHtml(item.stance)} · ${this.escapeHtml(item.asOf || '--')} · ${this.escapeHtml(item.reason || '--')} · ${this.escapeHtml(basedOn)}</li>`;
    }).join('')}</ul>`;
  },

  renderDecisionSection(caseObj) {
    const hasDecision = this.isPersistedDecision(caseObj?.decision);
    const actionLabel = hasDecision ? '更新 Decision' : '建立 Decision';
    const options = ['<option value="">選擇 stance</option>']
      .concat(this.allowedDecisionStances().map(stance => (
        `<option value="${this.escapeHtml(stance)}">${this.escapeHtml(stance)}</option>`
      )));

    let html = '<p><b>Decision</b></p>';
    html += hasDecision ? this.renderDecisionRecord(caseObj.decision) : '<p>尚無 Decision</p>';
    html += `<p>Stance <select data-case-decision-stance>${options.join('')}</select></p>`;
    html += '<p>Reason<br><textarea data-case-decision-reason rows="3" style="width:100%;max-width:36em"></textarea></p>';
    html += `<p><button type="button" data-case-decision-save>${actionLabel}</button></p>`;
    html += '<p><b>Decision History</b></p>';
    html += this.renderDecisionHistory(caseObj?.decisionHistory);
    return html;
  },

  emptyPositionPlaybook() {
    return {
      targetPosition: null,
      initialPosition: null,
      addPosition: null,
      entryTriggers: [],
      addConditions: [],
      exitConditions: [],
      monitoringItems: []
    };
  },

  positionPlaybookView(playbook) {
    const empty = this.emptyPositionPlaybook();
    if (!playbook || typeof playbook !== 'object') return empty;
    return {
      targetPosition: playbook.targetPosition == null ? null : playbook.targetPosition,
      initialPosition: playbook.initialPosition == null ? null : playbook.initialPosition,
      addPosition: playbook.addPosition == null ? null : playbook.addPosition,
      entryTriggers: Array.isArray(playbook.entryTriggers) ? playbook.entryTriggers : [],
      addConditions: Array.isArray(playbook.addConditions) ? playbook.addConditions : [],
      exitConditions: Array.isArray(playbook.exitConditions) ? playbook.exitConditions : [],
      monitoringItems: this.normalizeMonitoringItems(playbook.monitoringItems)
    };
  },

  formatPlaybookValue(value) {
    if (value == null || value === '') return '--';
    return String(value);
  },

  formatPlaybookInput(value) {
    if (value == null) return '';
    return String(value);
  },

  formatPlaybookLines(items) {
    return Array.isArray(items) ? items.join('\n') : '';
  },

  parsePlaybookLines(text) {
    return String(text || '')
      .split(/\r?\n/)
      .map(line => line.trim())
      .filter(line => line.length > 0);
  },

  normalizePlaybookText(value) {
    const text = String(value == null ? '' : value).trim();
    return text ? text : null;
  },

  hasOwnPlaybookField(obj, name) {
    return !!obj && Object.prototype.hasOwnProperty.call(obj, name);
  },

  mergePlaybookTextField(current, patch, name) {
    if (!this.hasOwnPlaybookField(patch, name)) return current;
    return this.normalizePlaybookText(patch[name]);
  },

  mergePlaybookListField(current, patch, name) {
    if (!this.hasOwnPlaybookField(patch, name)) {
      return Array.isArray(current) ? current.slice() : [];
    }
    const raw = patch[name];
    if (raw == null) return [];
    if (name === 'monitoringItems') return this.normalizeMonitoringItems(raw);
    if (Array.isArray(raw)) return raw.slice();
    return this.parsePlaybookLines(String(raw));
  },

  monitoringItemView(item) {
    if (item == null || item === '') return null;
    if (typeof item === 'string') {
      const text = item.trim();
      return text ? { text, researchId: null, legacy: true } : null;
    }
    if (typeof item === 'object') {
      const text = String(item.text == null ? '' : item.text).trim();
      if (!text) return null;
      const researchId = item.researchId == null ? null : String(item.researchId).trim();
      return { text, researchId: researchId || null, legacy: false };
    }
    const text = String(item).trim();
    return text ? { text, researchId: null, legacy: true } : null;
  },

  normalizeMonitoringItems(raw) {
    const list = raw == null ? [] : Array.isArray(raw) ? raw : [raw];
    const out = [];
    for (const item of list) {
      const view = this.monitoringItemView(item);
      if (!view) continue;
      if (view.legacy && !view.researchId) {
        out.push(view.text);
      } else {
        out.push({ text: view.text, researchId: view.researchId });
      }
    }
    return out;
  },

  canTriggerMonitoringItem(item) {
    const view = this.monitoringItemView(item);
    return !!(view && view.text && view.researchId);
  },

  buildMonitoringTriggerPayload(caseId, item) {
    if (!this.canTriggerMonitoringItem(item)) return null;
    const view = this.monitoringItemView(item);
    return {
      id: caseId,
      monitoringTrigger: {
        text: view.text,
        researchId: view.researchId
      }
    };
  },

  monitoringTriggerSuccessMessage(researchId) {
    return '已觸發重新研究：' + researchId;
  },

  async triggerMonitoringItem(caseId, item) {
    const payload = this.buildMonitoringTriggerPayload(caseId, item);
    if (!payload) {
      return { ok: false, message: 'monitoring item researchId is required' };
    }
    try {
      const res = await fetch('/api/cases', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
      });
      const data = await res.json().catch(() => ({}));
      if (res.ok) {
        return {
          ok: true,
          message: this.monitoringTriggerSuccessMessage(payload.monitoringTrigger.researchId)
        };
      }
      return { ok: false, message: data.message || 'Failed to trigger research' };
    } catch (_) {
      return { ok: false, error: 'persistence_failure', message: 'Failed to trigger research' };
    }
  },

  renderMonitoringItems(items) {
    const list = Array.isArray(items) ? items : [];
    const rows = [];
    for (const item of list) {
      const view = this.monitoringItemView(item);
      if (!view) continue;
      const text = this.escapeHtml(view.text);
      if (!view.researchId) {
        rows.push(`<li>${text}</li>`);
        continue;
      }
      rows.push(
        `<li>${text} <span data-case-research-id="${this.escapeHtml(view.researchId)}">[${this.escapeHtml(view.researchId)}]</span> ` +
        `<button type="button" data-monitoring-trigger data-monitoring-text="${this.escapeHtml(view.text)}" data-monitoring-research-id="${this.escapeHtml(view.researchId)}">Trigger Research</button></li>`
      );
    }
    if (!rows.length) return '<p>--</p>';
    return `<ul>${rows.join('')}</ul>`;
  },

  formatMonitoringEditorLines(items) {
    const list = Array.isArray(items) ? items : [];
    return list.map(item => {
      const view = this.monitoringItemView(item);
      if (!view) return '';
      return view.researchId ? `${view.text} | ${view.researchId}` : view.text;
    }).filter(Boolean).join('\n');
  },

  parseMonitoringEditorLines(text) {
    return String(text || '')
      .split(/\r?\n/)
      .map(line => line.trim())
      .filter(line => line.length > 0)
      .map(line => {
        const sep = line.lastIndexOf('|');
        if (sep > 0) {
          const itemText = line.slice(0, sep).trim();
          const researchId = line.slice(sep + 1).trim();
          if (itemText && researchId) return { text: itemText, researchId };
        }
        return line;
      });
  },

  applyPositionPlaybookLocally(caseObj, patch) {
    const next = this.positionPlaybookView(caseObj.positionPlaybook);
    const src = patch && typeof patch === 'object' ? patch : {};
    next.targetPosition = this.mergePlaybookTextField(next.targetPosition, src, 'targetPosition');
    next.initialPosition = this.mergePlaybookTextField(next.initialPosition, src, 'initialPosition');
    next.addPosition = this.mergePlaybookTextField(next.addPosition, src, 'addPosition');
    next.entryTriggers = this.mergePlaybookListField(next.entryTriggers, src, 'entryTriggers');
    next.addConditions = this.mergePlaybookListField(next.addConditions, src, 'addConditions');
    next.exitConditions = this.mergePlaybookListField(next.exitConditions, src, 'exitConditions');
    next.monitoringItems = this.mergePlaybookListField(next.monitoringItems, src, 'monitoringItems');
    caseObj.positionPlaybook = next;
    caseObj.origin = caseObj.origin || {};
    caseObj.origin.updatedAt = this.today();
    return caseObj;
  },

  renderPositionPlaybook(playbook) {
    const view = this.positionPlaybookView(playbook);
    let html = '<p><b>Position Playbook</b></p>';
    html += `<p>Target Position: ${this.escapeHtml(this.formatPlaybookValue(view.targetPosition))}</p>`;
    html += `<p>Initial Position: ${this.escapeHtml(this.formatPlaybookValue(view.initialPosition))}</p>`;
    html += `<p>Add Position: ${this.escapeHtml(this.formatPlaybookValue(view.addPosition))}</p>`;
    html += '<p><b>Entry Triggers</b></p>';
    html += this.renderStringList(view.entryTriggers);
    html += '<p><b>Add Conditions</b></p>';
    html += this.renderStringList(view.addConditions);
    html += '<p><b>Exit Conditions</b></p>';
    html += this.renderStringList(view.exitConditions);
    html += '<p><b>Monitoring Items</b></p>';
    html += this.renderMonitoringItems(view.monitoringItems);
    html += '<p data-monitoring-trigger-status style="display:none"></p>';
    html += '<p>Target Position<br>';
    html += `<input data-case-playbook-target type="text" style="width:100%;max-width:36em" value="${this.escapeHtml(this.formatPlaybookInput(view.targetPosition))}"></p>`;
    html += '<p>Initial Position<br>';
    html += `<input data-case-playbook-initial type="text" style="width:100%;max-width:36em" value="${this.escapeHtml(this.formatPlaybookInput(view.initialPosition))}"></p>`;
    html += '<p>Entry Triggers<br>';
    html += `<textarea data-case-playbook-entry-triggers rows="4" style="width:100%;max-width:36em">${this.escapeHtml(this.formatPlaybookLines(view.entryTriggers))}</textarea></p>`;
    html += '<p>Monitoring Items<br>';
    html += `<textarea data-case-playbook-monitoring-items rows="4" style="width:100%;max-width:36em">${this.escapeHtml(this.formatMonitoringEditorLines(view.monitoringItems))}</textarea></p>`;
    html += '<p>一行一個。舊格式純文字；綁定研究卡使用：文字|researchId 或 文字 | researchId</p>';
    html += '<p><button type="button" data-case-playbook-save>Save Position Playbook</button></p>';
    html += '<p data-case-playbook-error style="display:none"></p>';
    return html;
  },

  async saveCasePositionPlaybook(caseId, targetPosition, initialPosition, entryTriggers, monitoringItems) {
    const current = DataEngine.getCase(caseId);
    if (!current) return { ok: false, message: 'Investment Case not found' };
    const payload = {
      targetPosition: this.normalizePlaybookText(targetPosition),
      initialPosition: this.normalizePlaybookText(initialPosition),
      entryTriggers: Array.isArray(entryTriggers) ? entryTriggers : [],
      monitoringItems: this.normalizeMonitoringItems(monitoringItems)
    };
    try {
      const res = await fetch('/api/cases', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: caseId, positionPlaybook: payload })
      });
      const data = await res.json().catch(() => ({}));
      if (res.ok) {
        await DataEngine.loadInvestmentCases();
        return { ok: true, id: caseId };
      }
      return { ok: false, message: data.message || 'Failed to save Position Playbook' };
    } catch (_) {
      this.applyPositionPlaybookLocally(current, payload);
      DataEngine.upsertCase(current);
      return { ok: true, id: caseId, fallback: true };
    }
  },

  async saveCaseDecision(caseId, stance, reason) {
    const current = DataEngine.getCase(caseId);
    if (!current) return { ok: false, message: 'Investment Case not found' };
    if (!this.allowedDecisionStances().includes(stance)) {
      return { ok: false, message: 'Invalid stance' };
    }
    const trimmed = String(reason || '').trim();
    if (!trimmed) return { ok: false, message: 'Reason is required' };

    const next = this.buildDecision(current, stance, trimmed);
    try {
      const res = await fetch('/api/cases', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id: caseId, decision: next })
      });
      const data = await res.json().catch(() => ({}));
      if (res.ok) {
        await DataEngine.loadInvestmentCases();
        return { ok: true, id: caseId };
      }
      return { ok: false, message: data.message || 'Failed to save Decision' };
    } catch (_) {
      this.applyDecisionLocally(current, next);
      DataEngine.upsertCase(current);
      return { ok: true, id: caseId, fallback: true };
    }
  },

  renderEvidenceList(items) {
    const list = Array.isArray(items) ? items : [];
    if (!list.length) return '<p>--</p>';
    return `<ul>${list.map(item => {
      const text = this.escapeHtml(item?.text || '--');
      const researchId = item?.researchId;
      if (!researchId) return `<li>${text}</li>`;
      return `<li>${text} <span data-case-research-id="${this.escapeHtml(researchId)}">[${this.escapeHtml(researchId)}]</span></li>`;
    }).join('')}</ul>`;
  },

  renderStringList(items) {
    const list = Array.isArray(items) ? items : [];
    if (!list.length) return '<p>--</p>';
    return `<ul>${list.map(item => `<li>${this.escapeHtml(item)}</li>`).join('')}</ul>`;
  },

  async renderInvestmentCase(caseObj, container) {
    if (!container) return;
    if (!caseObj) {
      container.innerHTML = '找不到 Investment Case';
      return;
    }

    const company = caseObj.company || {};
    const thesis = caseObj.thesis || {};
    const valuation = caseObj.valuation || this.emptyValuation();
    this.applyMethodFairValues(valuation, caseObj.valuationProfile);
    const researchIds = Array.isArray(caseObj.researchIds) ? caseObj.researchIds : [];
    const companyLine = [company.name, company.ticker && `(${company.ticker})`, company.exchange, company.currency]
      .filter(Boolean)
      .join(' ');

    const researchItems = [];
    for (const researchId of researchIds) {
      const title = await this.researchTitle(researchId);
      researchItems.push(
        `<li data-case-research-id="${this.escapeHtml(researchId)}">${this.escapeHtml(title)}</li>`
      );
    }

    let html = `<h3>${this.escapeHtml(caseObj.title || caseObj.id)}</h3>`;
    html += `<p><b>Company</b></p><p>${this.escapeHtml(companyLine || '--')}</p>`;
    html += '<p><b>Research Cards</b></p>';
    html += researchItems.length ? `<ul>${researchItems.join('')}</ul>` : '<p>--</p>';
    html += `<p><b>Investment Thesis</b></p><p>${this.escapeHtml(thesis.thesis || '--')}</p>`;
    html += '<p><b>Growth Drivers</b></p>';
    html += this.renderStringList(thesis.growthDrivers);
    html += '<p><b>Competitive Advantage</b></p>';
    html += `<p>${this.escapeHtml(thesis.competitiveAdvantage || '--')}</p>`;
    html += '<p><b>Earnings Translation</b></p>';
    html += `<p>${this.escapeHtml(thesis.earningsTranslation || '--')}</p>`;
    html += `<p><b>Duration</b></p><p>${this.escapeHtml(thesis.duration || '--')}</p>`;
    html += '<p><b>Supporting Evidence</b></p>';
    html += this.renderEvidenceList(thesis.supportingEvidence);
    html += '<p><b>Counter Evidence</b></p>';
    html += this.renderEvidenceList(thesis.counterEvidence);
    html += '<p><b>To Be Verified</b></p>';
    html += this.renderEvidenceList(thesis.toBeVerified);
    html += '<p><b>Kill Criteria</b></p>';
    html += this.renderStringList(thesis.killCriteria);
    html += `<p><b>Thesis Status</b></p><p>${this.escapeHtml(thesis.status || '--')}</p>`;
    html += this.renderValuationProfile(caseObj.valuationProfile);
    html += this.renderValuationInputs(caseObj.valuationProfile, valuation, caseObj.researchIds);
    html += '<p><b>Fair Value</b></p>';
    const caseNote = this.caseLevelMissingNote(caseObj.valuationProfile, valuation);
    if (caseNote && valuation.base == null && valuation.bear == null && valuation.bull == null) {
      html += `<p>尚未計算：${this.escapeHtml(caseNote)}</p>`;
    }
    html += `<p>Bear: ${this.escapeHtml(this.formatCaseLevelValue(valuation.bear))}</p>`;
    html += `<p>Base: ${this.escapeHtml(this.formatCaseLevelValue(valuation.base))}</p>`;
    html += `<p>Bull: ${this.escapeHtml(this.formatCaseLevelValue(valuation.bull))}</p>`;
    html += '<p>Margin of Safety: ';
    html += `<input data-case-mos type="number" min="0" max="100" step="0.01" placeholder="0.20" `;
    html += `value="${valuation.marginOfSafety == null ? '' : this.escapeHtml(valuation.marginOfSafety)}" `;
    html += 'style="width:6em"> <button type="button" data-case-mos-save>Save</button></p>';
    html += `<p>Buy Under: ${this.escapeHtml(this.formatCaseLevelValue(valuation.buyUnder))}</p>`;
    html += `<p>Current Price: ${this.escapeHtml(this.formatNumber(valuation.currentPrice))}</p>`;
    html += `<p>Current Discount: ${this.escapeHtml(this.formatPercent(valuation.currentDiscount))}</p>`;
    html += this.renderDecisionSection(caseObj);
    html += '<p data-case-decision-error style="display:none"></p>';
    html += this.renderPositionPlaybook(caseObj.positionPlaybook);

    container.innerHTML = html;

    container.querySelectorAll('[data-case-research-id]').forEach(el => {
      el.style.cursor = 'pointer';
      el.onclick = () => {
        if (typeof openResearchCard === 'function') {
          showPage('cards');
          openResearchCard(el.dataset.caseResearchId, document.getElementById('card'), {
            resetPath: true,
            fromPage: 'cases'
          });
        }
      };
    });

    const typeSelect = container.querySelector('[data-case-company-type]');
    if (typeSelect) {
      typeSelect.onchange = async () => {
        const result = await this.saveCaseCompanyType(caseObj.id, typeSelect.value);
        if (!result.ok) {
          window.alert(result.message || 'Failed to save companyType');
          return;
        }
        await this.renderInvestmentCase(DataEngine.getCase(caseObj.id), container);
      };
    }

    const confirmBtn = container.querySelector('[data-case-confirm-profile]');
    if (confirmBtn) {
      confirmBtn.onclick = async () => {
        const result = await this.confirmCaseValuationProfile(caseObj.id);
        if (!result.ok) {
          window.alert(result.message || 'Failed to confirm valuationProfile');
          return;
        }
        await this.renderInvestmentCase(DataEngine.getCase(caseObj.id), container);
      };
    }

    container.querySelectorAll('[data-method-save]').forEach(btn => {
      btn.onclick = async () => {
        const token = btn.dataset.methodSave || '';
        const sep = token.indexOf('::');
        if (sep < 0) return;
        const method = token.slice(0, sep);
        const field = token.slice(sep + 2);
        const input = container.querySelector(`[data-method-value="${token}"]`);
        const result = await this.saveMethodInputValue(caseObj.id, method, field, input?.value);
        if (!result.ok) {
          window.alert(result.message || `Failed to save ${field}`);
          return;
        }
        await this.renderInvestmentCase(DataEngine.getCase(caseObj.id), container);
      };
    });

    const saveMosBtn = container.querySelector('[data-case-mos-save]');
    const mosInput = container.querySelector('[data-case-mos]');
    if (saveMosBtn && mosInput) {
      saveMosBtn.onclick = async () => {
        const result = await this.saveCaseMarginOfSafety(caseObj.id, mosInput.value);
        if (!result.ok) {
          window.alert(result.message || 'Failed to save marginOfSafety');
          return;
        }
        await this.renderInvestmentCase(DataEngine.getCase(caseObj.id), container);
      };
    }

    const saveDecisionBtn = container.querySelector('[data-case-decision-save]');
    const stanceSelect = container.querySelector('[data-case-decision-stance]');
    const reasonInput = container.querySelector('[data-case-decision-reason]');
    const decisionError = container.querySelector('[data-case-decision-error]');
    if (saveDecisionBtn && stanceSelect && reasonInput) {
      saveDecisionBtn.onclick = async () => {
        const stance = stanceSelect.value;
        const reason = reasonInput.value;
        if (decisionError) {
          decisionError.style.display = 'none';
          decisionError.textContent = '';
        }
        if (!this.allowedDecisionStances().includes(stance)) {
          window.alert('請選擇 stance');
          return;
        }
        if (!String(reason || '').trim()) {
          if (decisionError) {
            decisionError.textContent = 'Reason 必填';
            decisionError.style.display = '';
          }
          return;
        }
        const actionLabel = this.isPersistedDecision(caseObj.decision) ? '更新' : '建立';
        const confirmed = window.confirm(
          `確定${actionLabel} Decision 為 ${stance}？\n按「確定」後才會寫入 Investment Case。\n按「取消」則不會寫入。`
        );
        if (!confirmed) {
          window.alert('已取消，未寫入 Decision');
          return;
        }
        const result = await this.saveCaseDecision(caseObj.id, stance, reason);
        if (!result.ok) {
          window.alert(result.message || 'Failed to save Decision');
          return;
        }
        await this.renderInvestmentCase(DataEngine.getCase(caseObj.id), container);
      };
    }

    const savePlaybookBtn = container.querySelector('[data-case-playbook-save]');
    const targetInput = container.querySelector('[data-case-playbook-target]');
    const initialInput = container.querySelector('[data-case-playbook-initial]');
    const entryInput = container.querySelector('[data-case-playbook-entry-triggers]');
    const monitoringInput = container.querySelector('[data-case-playbook-monitoring-items]');
    const playbookError = container.querySelector('[data-case-playbook-error]');
    const triggerStatus = container.querySelector('[data-monitoring-trigger-status]');
    container.querySelectorAll('[data-monitoring-trigger]').forEach(btn => {
      btn.onclick = async (event) => {
        event.preventDefault();
        event.stopPropagation();
        const item = {
          text: btn.dataset.monitoringText || '',
          researchId: btn.dataset.monitoringResearchId || ''
        };
        if (!this.canTriggerMonitoringItem(item)) return;
        if (triggerStatus) {
          triggerStatus.style.display = 'none';
          triggerStatus.textContent = '';
        }
        btn.disabled = true;
        const result = await this.triggerMonitoringItem(caseObj.id, item);
        btn.disabled = false;
        if (triggerStatus) {
          triggerStatus.textContent = result.message || (result.ok ? this.monitoringTriggerSuccessMessage(item.researchId) : 'Failed to trigger research');
          triggerStatus.style.display = '';
        }
      };
    });
    if (savePlaybookBtn && targetInput && initialInput && entryInput && monitoringInput) {
      savePlaybookBtn.onclick = async () => {
        if (playbookError) {
          playbookError.style.display = 'none';
          playbookError.textContent = '';
        }
        const result = await this.saveCasePositionPlaybook(
          caseObj.id,
          targetInput.value,
          initialInput.value,
          this.parsePlaybookLines(entryInput.value),
          this.parseMonitoringEditorLines(monitoringInput.value)
        );
        if (!result.ok) {
          if (playbookError) {
            playbookError.textContent = result.message || 'Failed to save Position Playbook';
            playbookError.style.display = '';
          }
          return;
        }
        await this.renderInvestmentCase(DataEngine.getCase(caseObj.id), container);
      };
    }
  },

  cardTitle(id) {
    return this.researchCache[id]?.card?.title
      ?? DataEngine.researchCards[id]?.title
      ?? DataEngine.investmentThesis?.cards?.[id]?.title
      ?? id;
  }
};
