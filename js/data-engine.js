const DataEngine = {
  morningBrief: null,
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

  renderMorningBrief(container, onItemClick) {
    container.innerHTML = this.morningBrief.items.map(item => `
      <div class="item" data-id="${item.id}">
        <b>${item.icon} ${item.title}</b>
        <p>${item.summary}</p>
      </div>
    `).join('');
    container.querySelectorAll('.item').forEach(el => {
      el.onclick = () => onItemClick(el.dataset.id);
    });
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
