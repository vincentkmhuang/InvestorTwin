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

  addToQueue(id, source = 'Manual') {
    if (!this.queue.items.some(item => item.id === id)) {
      this.queue.items.push({ id, addedFrom: source });
    }
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

  createDefaultResearch(id) {
    const title = this.resolveTitle(id);
    const briefItem = DataEngine.morningBrief?.items?.find(item =>
      item.id === id || item.cardRef === id
    );
    const card = {
      id,
      title,
      summary: briefItem?.summary ?? '',
      status: 'active',
      updated: new Date().toISOString().slice(0, 10)
    };
    return { id, card, timeline: [], sources: [], notes: [] };
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

  renderResearch(bundle, container) {
    if (!bundle?.card) {
      container.innerHTML = '找不到研究卡';
      return;
    }

    const { card, timeline, sources, notes } = bundle;
    let html = `<h3>${card.title}</h3>`;
    if (card.summary) html += `<p>${card.summary}</p>`;
    html += `<p><b>狀態：</b>${card.status}</p>
<p><b>相關：</b>${card.related ?? '--'}</p>
<p><b>來源：</b>${card.source ?? '--'}</p>`;

    if (timeline.length) {
      html += '<p><b>時間軸：</b></p><ul>';
      html += timeline.map(entry => `<li>${entry.date} — ${entry.event}</li>`).join('');
      html += '</ul>';
    }

    if (sources.length) {
      html += '<p><b>資料來源：</b></p><ul>';
      html += sources.map(entry => `<li>${entry.title}</li>`).join('');
      html += '</ul>';
    }

    if (notes.length) {
      html += '<p><b>筆記：</b></p><ul>';
      html += notes.map(entry => `<li>${entry.date} — ${entry.text}</li>`).join('');
      html += '</ul>';
    }

    container.innerHTML = html;
  },

  cardTitle(id) {
    return this.researchCache[id]?.card?.title
      ?? DataEngine.researchCards[id]?.title
      ?? DataEngine.investmentThesis?.cards?.[id]?.title
      ?? id;
  }
};
