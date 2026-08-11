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
  },

  cardTitle(id) {
    return this.researchCache[id]?.card?.title
      ?? DataEngine.researchCards[id]?.title
      ?? DataEngine.investmentThesis?.cards?.[id]?.title
      ?? id;
  }
};
