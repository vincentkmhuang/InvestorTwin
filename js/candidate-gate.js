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

  async loadExistingCardIds() {
    // Reuse Cards / Explorer discovery: data/knowledge-index.json -> cardIds
    // Do not read Queue IDs; do not invent a separate Card registry.
    try {
      const index = await fetch('data/knowledge-index.json?t=' + Date.now()).then(r => r.ok ? r.json() : null);
      return Array.isArray(index?.cardIds)
        ? index.cardIds.map(id => String(id || '').trim()).filter(Boolean)
        : [];
    } catch (_) {
      return [];
    }
  },

  async pickExistingCard() {
    const ids = await this.loadExistingCardIds();
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

  // Sprint 008: Brief/Today Attention visibility (SPEC §4.2).
  // Pending + Watching only. Do not invent a new status model.
  isAttentionStatus(status) {
    const value = status || 'Pending';
    return value === 'Pending' || value === 'Watching';
  },

  attentionCandidates(list) {
    const rows = Array.isArray(list) ? list : this.candidates;
    return rows.filter(item => this.isAttentionStatus(item?.status || 'Pending'));
  },

  /**
   * Today entry: eligible attention status AND Investment Meaning Gate passed.
   * Do not use eligible + Pending/Watching alone.
   */
  async attentionCandidatesForToday() {
    if (!this.candidates.length) {
      await this.load();
    }
    const base = this.attentionCandidates();
    if (typeof InvestmentMeaningGate === 'undefined') {
      // Fail closed: without Meaning Gate, do not dump Candidates into Today.
      return [];
    }
    const ctx = await InvestmentMeaningGate.buildContext();
    return InvestmentMeaningGate.filterForToday(base, ctx);
  },

  goToHumanGate() {
    if (typeof showPage === 'function') {
      showPage('queue');
    }
    const gate = document.getElementById('queueResearchCandidates');
    if (gate && typeof gate.scrollIntoView === 'function') {
      try { gate.scrollIntoView({ block: 'start' }); } catch (_) {}
    }
  },

  // Display/attention only — never POST Gate disposition from Today.
  // Today V2: up to 3 investment-meaning change cards with Watch / Check / Research next steps.
  async renderAttention(container) {
    if (!container) return;
    if (!this.candidates.length) {
      await this.load();
    }
    const items = (await this.attentionCandidatesForToday()).slice(0, 3);
    if (!items.length) {
      container.innerHTML = '';
      return;
    }
    container.innerHTML = items.map(candidate => this.meaningChangeCardHtml(candidate)).join('');
    if (typeof InvestmentMeaningGate !== 'undefined') {
      const recorded = await InvestmentMeaningGate.recordPassed(items);
      if (recorded && recorded.ok === false) {
        console.error(
          '[CandidateGate] meaning-gate baseline persistence failed — Watching quiet rule will not work until POST /api/meaning-gate-state succeeds.',
          recorded.error || recorded
        );
      }
    }
    container.querySelectorAll('[data-next-watch]').forEach(button => {
      button.onclick = async (event) => {
        event.preventDefault();
        event.stopPropagation();
        const eventRef = button.getAttribute('data-event-ref');
        const candidate = this.candidates.find(row => String(row?.eventRef || '') === eventRef);
        if (!candidate || typeof InvestorWatch === 'undefined') return;
        const result = await InvestorWatch.addFromAttention(candidate);
        if (result?.cancelled) return;
        if (!result?.ok) {
          window.alert(result?.message || '無法建立 Investor Watch');
          return;
        }
        const watchEl = document.getElementById('todayInvestorWatch');
        if (watchEl) await InvestorWatch.render(watchEl);
      };
    });

    container.querySelectorAll('[data-next-check]').forEach(button => {
      button.onclick = async (event) => {
        event.preventDefault();
        event.stopPropagation();
        if (button.disabled) return;
        const eventRef = button.getAttribute('data-event-ref');
        const candidate = this.candidates.find(row => String(row?.eventRef || '') === eventRef);
        if (!candidate || typeof InvestmentCheck === 'undefined') return;
        button.disabled = true;
        try {
          const result = await InvestmentCheck.createFromAttention(candidate);
          if (result?.cancelled || result?.busy) return;
          if (!result?.ok) {
            window.alert(result?.message || '無法建立 Investment Check');
            return;
          }
          const checkEl = document.getElementById('todayInvestmentCheck');
          if (checkEl) await InvestmentCheck.render(checkEl);
        } finally {
          button.disabled = false;
        }
      };
    });

    container.querySelectorAll('[data-next-research]').forEach(button => {
      button.onclick = (event) => {
        event.preventDefault();
        event.stopPropagation();
        this.goToHumanGate();
      };
    });
  },

  evidenceClassBlocks(candidate) {
    const impact = candidate?.impact;
    const status = impact && typeof impact === 'object' ? impact.evidenceStatus : null;
    const classes = ['FACT', 'ESTIMATE', 'INFERENCE', 'UNKNOWN'];
    if (!status || typeof status !== 'object') {
      // Preserve honesty: do not invent claims; show structure with available evidenceRefs class.
      const refs = Array.isArray(candidate?.evidenceRefs) ? candidate.evidenceRefs : [];
      const byClass = { FACT: [], ESTIMATE: [], INFERENCE: [], UNKNOWN: [] };
      for (const row of refs) {
        const cls = String(row?.class || '').toUpperCase();
        if (byClass[cls]) {
          const claim = String(row?.claim || '').trim();
          if (claim) byClass[cls].push(claim);
        }
      }
      return classes.map(name => {
        const claims = byClass[name];
        const body = claims.length
          ? claims.slice(0, 2).map(c => this.escapeHtml(c)).join('；')
          : '—';
        return `<li data-evidence-class="${name}"><span class="evidence-class-${name.toLowerCase()}">${name}</span>: ${body}</li>`;
      }).join('');
    }
    return classes.map(name => {
      const rows = Array.isArray(status[name]) ? status[name] : [];
      const claims = rows
        .map(row => String(row?.claim || '').trim())
        .filter(Boolean)
        .slice(0, 2);
      const body = claims.length ? claims.map(c => this.escapeHtml(c)).join('；') : '—';
      return `<li data-evidence-class="${name}"><span class="evidence-class-${name.toLowerCase()}">${name}</span>: ${body}</li>`;
    }).join('');
  },

  unknownToVerify(candidate) {
    const impact = candidate?.impact;
    const status = impact && typeof impact === 'object' ? impact.evidenceStatus : null;
    const unknowns = status && Array.isArray(status.UNKNOWN) ? status.UNKNOWN : [];
    const claims = unknowns.map(row => String(row?.claim || '').trim()).filter(Boolean);
    if (claims.length) return claims.slice(0, 2).join('；');
    const refs = Array.isArray(candidate?.evidenceRefs) ? candidate.evidenceRefs : [];
    const fromRefs = refs
      .filter(row => String(row?.class || '').toUpperCase() === 'UNKNOWN')
      .map(row => String(row?.claim || '').trim())
      .filter(Boolean);
    if (fromRefs.length) return fromRefs.slice(0, 2).join('；');
    return '尚待 Human Gate 確認研究方向與 Evidence 缺口';
  },

  meaningChangeCardHtml(candidate) {
    const status = candidate.status || 'Pending';
    const title = candidate.researchQuestion || this.eventLabel(candidate) || '--';
    const summary = candidate.relevanceBasis || candidate.reason || '投資意義可能變化；細節見 Evidence。';
    const evidence = this.evidenceLines(candidate)
      .slice(0, 3)
      .map(item => `<li data-attention-source="${this.escapeHtml(item.source)}" data-attention-news-ref="${this.escapeHtml(item.newsRef || '')}">` +
        `${this.escapeHtml(item.source)}` +
        (item.newsRef ? ` <span class="muted">(${this.escapeHtml(item.newsRef)})</span>` : '') +
        `</li>`)
      .join('');
    const relevance = [
      candidate.relevance || '--',
      this.impactLabel(candidate.impact)
    ].join(' · ');
    const gate = candidate.meaningGate || {};
    const meaningBit = gate.meaningType
      ? `Meaning: ${this.escapeHtml(gate.meaningType)}`
      : 'Meaning: --';
    const linkBit = Array.isArray(gate.personalLinks) && gate.personalLinks.length
      ? `Relevance link: ${this.escapeHtml(gate.personalLinks.join(', '))}`
      : '';
    const eventRef = candidate.eventRef || '';
    // Three next-step paths when we have a real attention candidate (do not invent extra cards).
    return `<article class="candidate-attention-card candidate-attention-compact meaning-change-card" data-attention-event-ref="${this.escapeHtml(eventRef)}" data-meaning-gate-passed="1">
      <p class="candidate-attention-question meaning-change-title" data-attention-research-question="${this.escapeHtml(title)}"><span class="sr-only">Title:</span>${this.escapeHtml(title)}</p>
      <p class="meaning-change-summary">${this.escapeHtml(summary)}</p>
      <p class="candidate-attention-meta muted"><b>Investment Relevance:</b> ${this.escapeHtml(relevance)} · ${meaningBit}${linkBit ? ' · ' + linkBit : ''} · Status: ${this.escapeHtml(status)} · Importance: ${this.escapeHtml(this.stars(candidate.importance))} (${this.escapeHtml(candidate.importance ?? '--')})</p>
      <p class="muted"><b>Evidence / Sources:</b></p>
      <ul class="candidate-attention-evidence muted" data-attention-evidence>${evidence || '<li>--</li>'}</ul>
      <p class="muted"><b>FACT / ESTIMATE / INFERENCE / UNKNOWN:</b></p>
      <ul class="meaning-change-classes muted">${this.evidenceClassBlocks(candidate)}</ul>
      <p class="muted"><b>To be verified:</b> ${this.escapeHtml(this.unknownToVerify(candidate))}</p>
      <p class="muted"><b>Next Step:</b> 選一條路徑（三者不要混用）</p>
      <div class="meaning-change-next-steps">
        <button type="button" data-next-watch="1" data-event-ref="${this.escapeHtml(eventRef)}">👁️ 幫我持續注意</button>
        <button type="button" data-next-check="1" data-event-ref="${this.escapeHtml(eventRef)}">🔎 幫我檢查</button>
        <button type="button" data-next-research="1" data-event-ref="${this.escapeHtml(eventRef)}">🔬 進一步研究</button>
      </div>
      <p class="candidate-attention-event muted">eventRef: <code data-attention-event-ref-text>${this.escapeHtml(eventRef || '--')}</code></p>
    </article>`;
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
        try { await renderTodayMeaningChanges(); } catch (_) {}
        if (typeof render === 'function') render();
        try { await renderTodayQueueStrip(); } catch (_) {}
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
