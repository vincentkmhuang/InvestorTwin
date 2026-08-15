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
      fetch('data/morning-brief/latest.json').then(r => r.json()),
      fetch('data/opportunity-radar.json').then(r => r.json()),
      fetch('data/investment-thesis.json').then(r => r.json()),
      fetch('data/investment-cases.json')
        .then(r => r.ok ? r.json() : this.emptyCaseStore())
        .catch(() => this.emptyCaseStore())
    ]);
    this.morningBrief = morningBrief;
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
      const response = await fetch('data/morning-brief.json');
      this.morningBriefHome = response.ok
        ? await response.json()
        : null;
    } catch (_) {
      this.morningBriefHome = null;
    }
    return this.morningBriefHome;
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

    const bindResearchClick = (el, researchId) => {
      if (!researchId || typeof onItemClick !== 'function') {
        el.classList.add('morning-brief-static');
        return;
      }
      el.dataset.researchId = researchId;
      el.onclick = () => onItemClick(researchId);
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
        const text = (value || '').trim();
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
        bindResearchClick(li, item?.researchId);
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
        bindResearchClick(li, item?.researchId);
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
        bindResearchClick(li, item?.researchId);
        listEl.appendChild(li);
      });
      if (!listEl.children.length) renderEmpty(listEl);
    };

    const renderThreeThings = (listId, items) => {
      const listEl = document.getElementById(listId);
      if (!listEl) return;
      listEl.innerHTML = '';
      (items || []).forEach(item => {
        const text = (typeof item === 'string' ? item : item?.text || '').trim();
        if (!text) return;
        const li = document.createElement('li');
        li.textContent = text;
        bindResearchClick(li, typeof item === 'object' ? item?.researchId : null);
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

        bindResearchClick(li, id);
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

    setText('morningExecutiveSummary', data.executiveSummary);
    setText('morningGlobalMarket', data.globalMarket);
    setText('morningTaiwanMarket', data.taiwanMarket);
    renderTextList('morningTopThings', data.topThings);
    renderMarketTemperature();
    renderNews('morningGlobalNews', data.globalNews);
    renderNews('morningTaiwanNews', data.taiwanNews);
    renderHighlights('morningAiHighlights', data.aiHighlights);
    renderEvents('morningUpcomingEvents', data.upcomingEvents);
    renderThreeThings('morningTodaysThreeThings', data.todaysThreeThings);

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
    container.innerHTML = this.opportunityRadar.items.map(item =>
      `<li data-id="${item.id}">${item.name}</li>`
    ).join('');
    container.querySelectorAll('li').forEach(el => {
      el.onclick = () => onItemClick(el.dataset.id);
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
