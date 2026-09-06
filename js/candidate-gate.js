const CandidateGate = {
  candidates: [],

  escapeHtml(value) {
    return String(value ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  },

  stars(importance) {
    const n = Math.max(0, Math.min(5, Number(importance) || 0));
    return '★'.repeat(n) + '☆'.repeat(5 - n);
  },

  impactLabel(impact) {
    if (!impact) return '--';
    const direction = impact.direction || '--';
    const strength = impact.strength || '--';
    return `${direction} / ${strength}`;
  },

  eventLabel(candidate) {
    const event = candidate?.event;
    if (!event) return candidate?.eventRef || '--';
    const subject = event.subject || '';
    const what = event.what || '';
    if (subject && what) return `${subject}: ${what}`;
    return what || subject || candidate.eventRef || '--';
  },

  evidenceLines(candidate) {
    const refs = Array.isArray(candidate?.evidenceRefs) ? candidate.evidenceRefs : [];
    const seen = new Set();
    const lines = [];
    for (const item of refs) {
      const source = String(item?.source || '').trim();
      const newsRef = String(item?.newsRef || '').trim();
      const key = `${source}|${newsRef}`;
      if (!source || seen.has(key)) continue;
      seen.add(key);
      lines.push({ source, newsRef, url: item?.url || null });
    }
    return lines;
  },

  async load() {
    const res = await fetch('/api/candidate-gate?t=' + Date.now());
    if (!res.ok) {
      this.candidates = [];
      return this.candidates;
    }
    const data = await res.json();
    this.candidates = Array.isArray(data.candidates) ? data.candidates : [];
    return this.candidates;
  },

  async postAction(action, eventRef, cardId) {
    const body = { action, eventRef };
    if (cardId) body.cardId = cardId;
    const res = await fetch('/api/candidate-gate', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body)
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      const msg = data.message || data.error || 'Candidate Gate action failed';
      if (data.error === 'missing_card' || data.error === 'invalid_card') {
        return { ok: false, message: '請先選擇既有研究卡。' };
      }
      return { ok: false, message: msg };
    }
    this.candidates = Array.isArray(data.candidates) ? data.candidates : this.candidates;
    return { ok: true, data };
  },

  async pickExistingCard() {
    const ids = Array.isArray(window.explorerCardIds) ? window.explorerCardIds.slice() : [];
    if (!ids.length) {
      window.alert('目前沒有既有研究卡可選擇。');
      return null;
    }
    const titles = [];
    for (const id of ids) {
      const title = WorkflowEngine.cardTitle(id);
      titles.push(`${title} (${id})`);
    }
    const query = window.prompt(
      '請輸入既有研究卡 id 或 title 關鍵字：\n' + titles.slice(0, 12).join('\n'),
      ''
    );
    if (query === null) return null;
    const needle = String(query || '').trim().toLowerCase();
    if (!needle) {
      window.alert('請先選擇既有研究卡。');
      return null;
    }
    const exact = ids.find(id => id.toLowerCase() === needle);
    if (exact) return exact;
    const matched = ids.filter(id => {
      const title = String(WorkflowEngine.cardTitle(id) || '').toLowerCase();
      return title.includes(needle) || id.toLowerCase().includes(needle);
    });
    if (matched.length === 1) return matched[0];
    if (matched.length > 1) {
      window.alert('找到多張研究卡，請輸入更精確的 id：\n' + matched.join('\n'));
      return null;
    }
    window.alert('請先選擇既有研究卡。');
    return null;
  },

  canAct(status) {
    return status === 'Pending' || status === 'Watching';
  },

  async render(container) {
    if (!container) return;
    if (!this.candidates.length) {
      await this.load();
    }
    const visible = this.candidates.filter(item => item.status !== 'Ignored');
    if (!visible.length) {
      container.innerHTML = '<p class="candidate-gate-empty">目前沒有待處理的 Research Candidate。</p>';
      return;
    }
    container.innerHTML = visible.map(candidate => {
      const status = candidate.status || 'Pending';
      const actionable = this.canAct(status);
      const evidence = this.evidenceLines(candidate)
        .map(item => `<li>${this.escapeHtml(item.source)}${item.newsRef ? ` <span class="muted">(${this.escapeHtml(item.newsRef)})</span>` : ''}</li>`)
        .join('');
      const actions = actionable
        ? `<div class="candidate-gate-actions">
            <button type="button" data-gate-action="ignore" data-event-ref="${this.escapeHtml(candidate.eventRef)}">Ignore</button>
            <button type="button" data-gate-action="watch" data-event-ref="${this.escapeHtml(candidate.eventRef)}">Watch</button>
            <button type="button" data-gate-action="link" data-event-ref="${this.escapeHtml(candidate.eventRef)}">Link Research Card</button>
            <button type="button" data-gate-action="queue" data-event-ref="${this.escapeHtml(candidate.eventRef)}">Add to Queue</button>
          </div>`
        : `<p class="candidate-gate-status">Status: ${this.escapeHtml(status)}${candidate.cardId ? ` → ${this.escapeHtml(candidate.cardId)}` : ''}</p>`;
      return `<article class="candidate-gate-card" data-event-ref="${this.escapeHtml(candidate.eventRef)}">
        <h3>Research Candidate</h3>
        <p><b>Status:</b> ${this.escapeHtml(status)}</p>
        <p><b>Event:</b> ${this.escapeHtml(this.eventLabel(candidate))}</p>
        <p><b>Importance:</b> ${this.escapeHtml(this.stars(candidate.importance))} (${this.escapeHtml(candidate.importance)})</p>
        <p><b>Relevance:</b> ${this.escapeHtml(candidate.relevance || '--')}</p>
        <p><b>Impact:</b> ${this.escapeHtml(this.impactLabel(candidate.impact))}</p>
        <p><b>Why it matters:</b> ${this.escapeHtml(candidate.relevanceBasis || candidate.reason || '--')}</p>
        <p><b>Research Question:</b> ${this.escapeHtml(candidate.researchQuestion || '--')}</p>
        <p><b>Evidence / Sources:</b></p>
        <ul>${evidence || '<li>--</li>'}</ul>
        ${actions}
      </article>`;
    }).join('');

    container.querySelectorAll('[data-gate-action]').forEach(button => {
      button.onclick = async () => {
        const action = button.getAttribute('data-gate-action');
        const eventRef = button.getAttribute('data-event-ref');
        let cardId = null;
        if (action === 'link' || action === 'queue') {
          cardId = await this.pickExistingCard();
          if (!cardId) return;
        }
        const result = await this.postAction(action, eventRef, cardId);
        if (!result.ok) {
          window.alert(result.message || '請先選擇既有研究卡。');
          return;
        }
        if (cardId && typeof WorkflowEngine !== 'undefined') {
          try { await WorkflowEngine.loadResearch(cardId); } catch (_) {}
        }
        if (action === 'queue' && typeof WorkflowEngine !== 'undefined' && result.data?.queueItems) {
          WorkflowEngine.queue = { items: result.data.queueItems };
        }
        await this.render(container);
        if (typeof render === 'function') render();
      };
    });
  },

  queueDisplayLabel(cardId) {
    const id = String(cardId || '');
    const cached = WorkflowEngine.researchCache?.[id]?.card;
    const links = Array.isArray(cached?.candidateLinks) ? cached.candidateLinks : [];
    const fromCandidate = links.find(item => item && item.researchQuestion);
    if (fromCandidate?.researchQuestion) return fromCandidate.researchQuestion;
    const questions = Array.isArray(cached?.questions) ? cached.questions : [];
    if (questions.length) return questions[questions.length - 1];
    return null;
  }
};
