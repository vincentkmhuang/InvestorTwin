const DataEngine = {
  morningBrief: null,
  morningBriefHome: null,
  opportunityRadar: null,
  investmentThesis: null,
  investmentCases: null,
  researchCards: {},

  emptyCaseStore() {
    return { schemaVersion: '1.0', updated: null, cases: [] };
  },

  async init() {
    const [morningBrief, opportunityRadar, investmentThesis, investmentCases] = await Promise.all([
      fetch('data/morning-brief.json?t=' + Date.now()).then(r => r.json()),
      fetch('data/opportunity-radar.json').then(r => r.json()),
      fetch('data/investment-thesis.json').then(r => r.json()),
      fetch('data/investment-cases.json')
        .then(r => r.ok ? r.json() : this.emptyCaseStore())
        .catch(() => this.emptyCaseStore())
    ]);
    this.morningBrief = this.normalizeMorningBrief(morningBrief);
    this.morningBriefHome = this.morningBrief;
    this.opportunityRadar = opportunityRadar;
    this.investmentThesis = investmentThesis;
    this.investmentCases = investmentCases && Array.isArray(investmentCases.cases)
      ? investmentCases
      : this.emptyCaseStore();
  },

  async loadInvestmentCases() {
    try {
      const response = await fetch('data/investment-cases.json?t=' + Date.now());
      this.investmentCases = response.ok
        ? await response.json()
        : this.emptyCaseStore();
    } catch (_) {
      if (!this.investmentCases) this.investmentCases = this.emptyCaseStore();
    }
    if (!Array.isArray(this.investmentCases.cases)) this.investmentCases.cases = [];
    return this.investmentCases;
  },

  getCases() {
    return Array.isArray(this.investmentCases?.cases) ? this.investmentCases.cases : [];
  },

  getCase(id) {
    return this.getCases().find(item => item.id === id) ?? null;
  },

  findCasesByResearchId(researchId) {
    return this.getCases().filter(item =>
      Array.isArray(item.researchIds) && item.researchIds.includes(researchId)
    );
  },

  findCasesByThesisId(thesisId) {
    if (!thesisId) return [];
    return this.getCases().filter(item => item && item.thesisId === thesisId);
  },

  upsertCase(caseObj) {
    if (!this.investmentCases) this.investmentCases = this.emptyCaseStore();
    if (!Array.isArray(this.investmentCases.cases)) this.investmentCases.cases = [];
    const index = this.investmentCases.cases.findIndex(item => item.id === caseObj.id);
    if (index >= 0) this.investmentCases.cases[index] = caseObj;
    else this.investmentCases.cases.push(caseObj);
    return caseObj;
  },

  async loadMorningBrief() {
    try {
      const response = await fetch('data/morning-brief.json?t=' + Date.now());
      this.morningBriefHome = response.ok
        ? this.normalizeMorningBrief(await response.json())
        : this.emptyMorningBrief();
    } catch (_) {
      this.morningBriefHome = this.emptyMorningBrief();
    }
    this.morningBrief = this.morningBriefHome;
    return this.morningBriefHome;
  },

  emptyMorningBrief() {
    return {
      date: null,
      executiveSummary: null,
      summary: null,
      macroDecisionLens: [],
      marketTemperature: {},
      globalMarketAndNews: { summary: null, items: [] },
      taiwanMarketAndNews: { summary: null, items: [] },
      aiIndustryHighlights: [],
      upcomingEvents: [],
      today3Things: [],
      opportunityRadar: [],
      opportunityRadarException: false
    };
  },

  researchLinkId(item) {
    if (item == null) return null;
    if (typeof item === 'string') {
      const id = item.trim();
      return id || null;
    }
    if (typeof item !== 'object') return null;
    const raw = item.researchId != null ? item.researchId : item.cardRef;
    const id = String(raw == null ? '' : raw).trim();
    return id || null;
  },

  normalizeNewsGroup(raw, legacySummary, legacyItems) {
    if (raw && typeof raw === 'object' && !Array.isArray(raw)) {
      const items = Array.isArray(raw.items) ? raw.items : (Array.isArray(raw.news) ? raw.news : []);
      const summary = raw.summary != null ? String(raw.summary) : (legacySummary != null ? String(legacySummary) : null);
      return { summary, items };
    }
    return {
      summary: legacySummary == null ? null : String(legacySummary),
      items: Array.isArray(legacyItems) ? legacyItems : []
    };
  },

  normalizeMorningBrief(raw) {
    const empty = this.emptyMorningBrief();
    if (!raw || typeof raw !== 'object') return empty;
    const executiveSummary = raw.executiveSummary != null
      ? String(raw.executiveSummary)
      : (raw.summary != null ? String(raw.summary) : null);
    return {
      date: raw.date == null ? null : String(raw.date).trim() || null,
      executiveSummary,
      summary: raw.summary != null ? String(raw.summary) : executiveSummary,
      macroDecisionLens: Array.isArray(raw.macroDecisionLens)
        ? raw.macroDecisionLens
        : (Array.isArray(raw.topThings) ? raw.topThings : []),
      marketTemperature: raw.marketTemperature && typeof raw.marketTemperature === 'object'
        ? raw.marketTemperature
        : {},
      globalMarketAndNews: this.normalizeNewsGroup(raw.globalMarketAndNews, raw.globalMarket, raw.globalNews),
      taiwanMarketAndNews: this.normalizeNewsGroup(raw.taiwanMarketAndNews, raw.taiwanMarket, raw.taiwanNews),
      aiIndustryHighlights: Array.isArray(raw.aiIndustryHighlights)
        ? raw.aiIndustryHighlights
        : (Array.isArray(raw.aiHighlights) ? raw.aiHighlights : []),
      upcomingEvents: Array.isArray(raw.upcomingEvents) ? raw.upcomingEvents : [],
      today3Things: Array.isArray(raw.today3Things)
        ? raw.today3Things
        : (Array.isArray(raw.todaysThreeThings) ? raw.todaysThreeThings : []),
      opportunityRadar: Array.isArray(raw.opportunityRadar) ? raw.opportunityRadar : [],
      opportunityRadarException: raw.opportunityRadarException === true
    };
  },

  collectMorningBriefResearchIds(data) {
    const brief = data || this.morningBriefHome || this.emptyMorningBrief();
    const ids = [];
    const seen = {};
    const push = (value) => {
      const id = this.researchLinkId(value);
      if (!id || seen[id]) return;
      seen[id] = true;
      ids.push(id);
    };
    const group = (block) => {
      (block && Array.isArray(block.items) ? block.items : []).forEach(push);
    };
    group(brief.globalMarketAndNews);
    group(brief.taiwanMarketAndNews);
    (brief.aiIndustryHighlights || []).forEach(push);
    (brief.upcomingEvents || []).forEach(push);
    (brief.today3Things || []).forEach(push);
    (brief.opportunityRadar || []).forEach(push);
    return ids;
  },

  async getCard(id) {
    if (!this.researchCards[id]) {
      try {
        const response = await fetch(`research/${id}/card.json`);
        if (response.ok) {
          this.researchCards[id] = await response.json();
        }
      } catch (_) {}
    }
    return this.researchCards[id] ?? this.investmentThesis?.cards?.[id] ?? null;
  },

  weekdayFromBriefDate(dateStr) {
    if (!dateStr || typeof dateStr !== 'string') return null;
    const matched = /^(\d{4})-(\d{2})-(\d{2})$/.exec(dateStr.trim());
    if (!matched) return null;
    const year = Number(matched[1]);
    const month = Number(matched[2]);
    const day = Number(matched[3]);
    const utc = new Date(Date.UTC(year, month - 1, day));
    if (
      utc.getUTCFullYear() !== year
      || utc.getUTCMonth() !== month - 1
      || utc.getUTCDate() !== day
    ) return null;
    return utc.getUTCDay();
  },

  shouldShowOpportunityRadar(data) {
    const weekday = this.weekdayFromBriefDate(data?.date);
    if (weekday === 1) return true;
    if (data?.opportunityRadarException === true && weekday >= 2 && weekday <= 5) return true;
    return false;
  },

  async renderMorningBrief(onItemClick) {
    const data = this.morningBriefHome;
    if (!data) return;

    const setText = (id, value) => {
      const el = document.getElementById(id);
      if (el) el.textContent = value || '--';
    };

    const bindResearchClick = (el, researchId, clickFn) => {
      const handler = clickFn || onItemClick;
      if (!researchId || typeof handler !== 'function') {
        el.classList.add('morning-brief-static');
        return;
      }
      el.classList.add('morning-brief-linked');
      el.dataset.researchId = researchId;
      el.onclick = () => handler(researchId);
    };

    const renderEmpty = (listEl) => {
      const li = document.createElement('li');
      li.className = 'morning-brief-static';
      li.textContent = '--';
      listEl.appendChild(li);
    };

    const renderTextList = (listId, values) => {
      const listEl = document.getElementById(listId);
      if (!listEl) return;
      listEl.innerHTML = '';
      (values || []).forEach(value => {
        const text = typeof value === 'string'
          ? value.trim()
          : String(value && value.text != null ? value.text : '').trim();
        if (!text) return;
        const li = document.createElement('li');
        li.className = 'morning-brief-static';
        li.textContent = text;
        listEl.appendChild(li);
      });
      if (!listEl.children.length) renderEmpty(listEl);
    };

    const renderNews = (listId, items) => {
      const listEl = document.getElementById(listId);
      if (!listEl) return;
      listEl.innerHTML = '';
      (items || []).forEach(item => {
        const title = (item?.title || '').trim();
        if (!title) return;
        const li = document.createElement('li');
        const titleEl = document.createElement('div');
        titleEl.className = 'morning-brief-title';
        titleEl.textContent = title;
        li.appendChild(titleEl);
        const source = (item?.source || '').trim();
        if (source) {
          const sourceEl = document.createElement('div');
          sourceEl.className = 'morning-brief-summary';
          sourceEl.textContent = source;
          li.appendChild(sourceEl);
        }
        bindResearchClick(li, this.researchLinkId(item));
        listEl.appendChild(li);
      });
      if (!listEl.children.length) renderEmpty(listEl);
    };

    const renderHighlights = (listId, items) => {
      const listEl = document.getElementById(listId);
      if (!listEl) return;
      listEl.innerHTML = '';
      (items || []).forEach(item => {
        const title = (item?.title || '').trim();
        if (!title) return;
        const li = document.createElement('li');
        li.textContent = title;
        bindResearchClick(li, this.researchLinkId(item));
        listEl.appendChild(li);
      });
      if (!listEl.children.length) renderEmpty(listEl);
    };

    const renderEvents = (listId, items) => {
      const listEl = document.getElementById(listId);
      if (!listEl) return;
      listEl.innerHTML = '';
      (items || []).forEach(item => {
        const title = (item?.title || '').trim();
        if (!title) return;
        const li = document.createElement('li');
        const titleEl = document.createElement('div');
        titleEl.className = 'morning-brief-title';
        titleEl.textContent = title;
        li.appendChild(titleEl);
        const when = (item?.when || '').trim();
        if (when) {
          const whenEl = document.createElement('div');
          whenEl.className = 'morning-brief-summary';
          whenEl.textContent = when;
          li.appendChild(whenEl);
        }
        bindResearchClick(li, this.researchLinkId(item));
        listEl.appendChild(li);
      });
      if (!listEl.children.length) renderEmpty(listEl);
    };

    const renderThreeThings = (listId, items) => {
      const listEl = document.getElementById(listId);
      if (!listEl) return;
      listEl.innerHTML = '';
      (items || []).forEach(item => {
        if (item == null) return;
        if (typeof item === 'string') {
          const text = item.trim();
          if (!text) return;
          const li = document.createElement('li');
          li.className = 'morning-brief-static';
          li.textContent = text;
          listEl.appendChild(li);
          return;
        }
        const title = String(item.title || item.text || '').trim();
        if (!title) return;
        const li = document.createElement('li');
        const titleEl = document.createElement('div');
        titleEl.className = 'morning-brief-title';
        titleEl.textContent = title;
        li.appendChild(titleEl);
        const why = String(item.whyItMatters || '').trim();
        if (why) {
          const whyEl = document.createElement('div');
          whyEl.className = 'morning-brief-summary';
          whyEl.textContent = why;
          li.appendChild(whyEl);
        }
        const source = String(item.source || '').trim();
        const evidenceIds = Array.isArray(item.evidence)
          ? item.evidence.map(value => String(value || '').trim()).filter(Boolean)
          : [];
        const meta = [];
        if (source) meta.push(source);
        if (evidenceIds.length) meta.push(evidenceIds.join(', '));
        if (meta.length) {
          const metaEl = document.createElement('div');
          metaEl.className = 'morning-brief-evidence';
          metaEl.textContent = meta.join(' · ');
          li.appendChild(metaEl);
        }
        bindResearchClick(li, this.researchLinkId(item));
        listEl.appendChild(li);
      });
      if (!listEl.children.length) renderEmpty(listEl);
    };

    const renderResearchIds = async (listId, ids) => {
      const listEl = document.getElementById(listId);
      if (!listEl) return;
      listEl.innerHTML = '';

      for (const rawId of ids || []) {
        const id = typeof rawId === 'string' ? rawId : rawId?.id;
        if (!id) continue;

        const card = await this.getCard(id);
        const title = card?.title || id;
        let summary = (card?.summary || '').trim();
        if (summary.startsWith(title)) {
          summary = summary.slice(title.length).replace(/^[\s—\-–：:]+/, '').trim();
        }

        const li = document.createElement('li');
        const titleEl = document.createElement('div');
        titleEl.className = 'morning-brief-title';
        titleEl.textContent = title;
        li.appendChild(titleEl);

        if (summary) {
          const summaryEl = document.createElement('div');
          summaryEl.className = 'morning-brief-summary';
          summaryEl.textContent = summary;
          li.appendChild(summaryEl);
        }

        const radarClick = (typeof openFromOpportunityRadar === 'function')
          ? ((rid) => openFromOpportunityRadar(rid, 'today'))
          : onItemClick;
        bindResearchClick(li, id, radarClick);
        listEl.appendChild(li);
      }
      if (!listEl.children.length) renderEmpty(listEl);
    };

    const renderMarketTemperature = () => {
      const el = document.getElementById('morningMarketTemperature');
      if (!el) return;
      el.innerHTML = '';
      el.className = 'morning-market';
      const table = data.marketTemperature || {};
      ['Nasdaq', 'S&P 500', 'Dow', 'SOX'].forEach(name => {
        const row = table[name] || {};
        const item = document.createElement('div');
        item.className = 'morning-market-item';
        const nameEl = document.createElement('div');
        nameEl.className = 'morning-market-name';
        nameEl.textContent = name;
        const valueEl = document.createElement('div');
        valueEl.className = 'morning-market-value';
        valueEl.textContent = row.value || '--';
        const asOfEl = document.createElement('div');
        asOfEl.className = 'morning-market-asof';
        asOfEl.textContent = row.asOf || '--';
        item.appendChild(nameEl);
        item.appendChild(valueEl);
        item.appendChild(asOfEl);
        el.appendChild(item);
      });
    };

    setText('morningBriefDate', data.date || '--');
    setText('morningExecutiveSummary', data.executiveSummary || data.summary);
    setText('morningGlobalMarket', data.globalMarketAndNews && data.globalMarketAndNews.summary);
    setText('morningTaiwanMarket', data.taiwanMarketAndNews && data.taiwanMarketAndNews.summary);
    renderTextList('morningTopThings', data.macroDecisionLens);
    renderMarketTemperature();
    renderNews('morningGlobalNews', data.globalMarketAndNews && data.globalMarketAndNews.items);
    renderNews('morningTaiwanNews', data.taiwanMarketAndNews && data.taiwanMarketAndNews.items);
    renderHighlights('morningAiHighlights', data.aiIndustryHighlights);
    renderEvents('morningUpcomingEvents', data.upcomingEvents);
    renderThreeThings('morningTodaysThreeThings', data.today3Things);

    const radarSection = document.getElementById('morningRadarSection');
    const radarTitle = document.getElementById('morningRadarTitle');
    const showRadar = this.shouldShowOpportunityRadar(data);
    if (radarSection) radarSection.style.display = showRadar ? '' : 'none';
    if (showRadar) {
      const weekday = this.weekdayFromBriefDate(data.date);
      if (radarTitle) {
        radarTitle.textContent = weekday === 1
          ? 'Opportunity Radar｜上週機會變化'
          : 'Opportunity Radar';
      }
      await renderResearchIds('morningOpportunityRadar', data.opportunityRadar);
    }
  },

  renderOpportunityRadar(container, onItemClick) {
    if (!container) return;
    const items = Array.isArray(this.opportunityRadar?.items) ? this.opportunityRadar.items : [];
    container.innerHTML = items.map(item =>
      `<li data-id="${item.id}">${item.name}</li>`
    ).join('');
    container.querySelectorAll('li').forEach(el => {
      el.onclick = () => {
        if (typeof onItemClick === 'function') onItemClick(el.dataset.id);
      };
    });
  },

  renderCard(card, container) {
    if (!card) {
      container.innerHTML = '找不到研究卡';
      return;
    }
    container.innerHTML = `<h3>${card.title}</h3>
<p><b>狀態：</b>${card.status}</p>
<p><b>相關：</b>${card.related}</p>
<p><b>來源：</b>${card.source}</p>`;
  }
};
