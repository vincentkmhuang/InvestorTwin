const DataEngine = {
  morningBrief: null,
  morningBriefHome: null,
  opportunityRadar: null,
  investmentThesis: null,
  researchCards: {},

  async init() {
    const [morningBrief, opportunityRadar, investmentThesis] = await Promise.all([
      fetch('data/morning-brief/latest.json').then(r => r.json()),
      fetch('data/opportunity-radar.json').then(r => r.json()),
      fetch('data/investment-thesis.json').then(r => r.json())
    ]);
    this.morningBrief = morningBrief;
    this.opportunityRadar = opportunityRadar;
    this.investmentThesis = investmentThesis;
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

  async renderMorningBrief(onItemClick) {
    const data = this.morningBriefHome;
    if (!data) return;

    const setText = (id, value) => {
      const el = document.getElementById(id);
      if (el) el.textContent = value || '--';
    };

    setText('morningExecutiveSummary', data.executiveSummary);
    setText('morningTodayQuestion', data.todayQuestion);
    setText('morningGlobalMarket', data.globalMarket);
    setText('morningTaiwanMarket', data.taiwanMarket);

    const renderList = async (listId, ids) => {
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
        li.dataset.researchId = id;

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

        if (typeof onItemClick === 'function') {
          li.onclick = () => onItemClick(id);
        }
        listEl.appendChild(li);
      }
    };

    await renderList('morningOpportunityRadar', data.opportunityRadar);
    await renderList('morningNewResearch', data.newResearch);
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
