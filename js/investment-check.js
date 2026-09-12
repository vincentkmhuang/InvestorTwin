const InvestmentCheck = {
  items: [],
  creating: false,

  STATUSES: [
    { id: 'Pending', label: 'Pending｜待檢查' },
    { id: 'Open', label: 'Open｜檢查中（入口）' },
    { id: 'EscalatedToQueue', label: 'Escalated｜已導向 Research Queue' },
    { id: 'Closed', label: 'Closed｜已結束' }
  ],

  OPEN_STATUSES: ['Pending', 'Open'],

  // Non-Closed counts as active for duplicate guard (includes EscalatedToQueue).
  isActiveStatus(status) {
    return String(status || 'Pending') !== 'Closed';
  },

  escapeHtml(value) {
    return String(value ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  },

  statusLabel(status) {
    const hit = this.STATUSES.find(row => row.id === status);
    return hit ? hit.label : (status || 'Pending');
  },

  shapeQuestion(raw) {
    let text = String(raw || '').trim();
    text = text.replace(/[。.!]+$/u, '');
    if (!/[？?]$/u.test(text)) text += '？';
    return text;
  },

  normalizeQuestionKey(raw) {
    return this.shapeQuestion(raw)
      .replace(/？/g, '?')
      .trim()
      .toLowerCase();
  },

  findActiveDuplicate(eventRef, question, list) {
    const keyEvent = String(eventRef || '').trim();
    const keyQuestion = this.normalizeQuestionKey(question);
    if (!keyQuestion) return null;
    const rows = Array.isArray(list) ? list : this.items;
    return rows.find(item => {
      if (!this.isActiveStatus(item?.status)) return false;
      const rowEvent = String(item?.triggerEventRef || '').trim();
      const rowQuestion = this.normalizeQuestionKey(item?.question || '');
      if (keyEvent) return rowEvent === keyEvent && rowQuestion === keyQuestion;
      return !rowEvent && rowQuestion === keyQuestion;
    }) || null;
  },

  async load() {
    const res = await fetch('/api/investment-check?t=' + Date.now());
    if (!res.ok) {
      this.items = [];
      return this.items;
    }
    const data = await res.json();
    this.items = Array.isArray(data.items) ? data.items : [];
    return this.items;
  },

  async post(body) {
    const res = await fetch('/api/investment-check', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body || {})
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      return { ok: false, message: data.message || data.error || 'Investment Check action failed' };
    }
    this.items = Array.isArray(data.items) ? data.items : this.items;
    return { ok: true, data, reused: !!data.reused };
  },

  openItems(list) {
    const rows = Array.isArray(list) ? list : this.items;
    return rows.filter(item => this.OPEN_STATUSES.includes(item?.status || 'Pending'));
  },

  async createFromAttention(candidate) {
    if (this.creating) {
      return { ok: false, busy: true, message: 'Investment Check 建立中，請稍候。' };
    }
    this.creating = true;
    try {
      const eventRef = String(candidate?.eventRef || '').trim();
      const triggerTitle = String(
        candidate?.researchQuestion || candidate?.relevanceBasis || eventRef || ''
      ).trim();
      const defaultQ = triggerTitle
        ? `這個變化會不會影響我的投資？依據：${triggerTitle}`
        : '這個市場變化會不會影響我的投資？';

      await this.load();
      const early = this.findActiveDuplicate(eventRef, this.shapeQuestion(defaultQ));
      if (early) {
        window.alert('這個問題已經在檢查中，不會建立第二筆。\nID: ' + (early.id || ''));
        return { ok: true, reused: true, data: { item: early, items: this.items, reused: true } };
      }

      const input = window.prompt(
        '🔎 Investment Check｜請輸入你想檢查的投資問題（這是待檢查問題，不是 FACT／結論）：\n' +
          '可選：若已知相關公司 ticker／名稱，可寫在問題中；系統不會自行猜測公司。',
        this.shapeQuestion(defaultQ)
      );
      if (input === null) return { ok: false, cancelled: true };
      const question = this.shapeQuestion(input);
      if (!question) {
        window.alert('請先輸入待檢查問題。');
        return { ok: false };
      }

      const localDup = this.findActiveDuplicate(eventRef, question);
      if (localDup) {
        window.alert('這個問題已經在檢查中，不會建立第二筆。\nID: ' + (localDup.id || ''));
        return { ok: true, reused: true, data: { item: localDup, items: this.items, reused: true } };
      }

      let relatedCompany = null;
      const companyInput = window.prompt(
        '相關公司／持股（可留空）。\n不要猜測：只有你明確知道時才填 ticker 或公司名。',
        ''
      );
      if (companyInput !== null && String(companyInput).trim()) {
        relatedCompany = String(companyInput).trim();
      }

      const result = await this.post({
        action: 'add',
        question,
        triggerEventRef: eventRef || null,
        triggerTitle: triggerTitle || null,
        relatedCompany
      });
      if (result.ok && result.reused) {
        window.alert(
          '這個問題已經在檢查中，已使用既有 Investment Check，未建立第二筆。\nID: ' +
            (result.data?.item?.id || '')
        );
      }
      return result;
    } finally {
      this.creating = false;
    }
  },

  async render(container) {
    if (!container) return;
    await this.load();
    const open = this.openItems();
    let listHtml = '';
    if (!open.length) {
      listHtml = '<p class="investment-check-empty muted">目前沒有進行中的 Investment Check。從「今日值得注意的投資變化」點 🔎 幫我檢查 即可建立入口（不做自動估值）。</p>';
    } else {
      listHtml = open.map(item => this.cardHtml(item)).join('');
    }
    container.innerHTML = `
      <p class="muted investment-check-hint">Investment Check 回答「這個變化會不會影響我的投資？」——目前只建立入口與待檢查問題，不產生估值結論或買賣建議。</p>
      <div class="investment-check-list">${listHtml}</div>`;

    container.querySelectorAll('[data-check-status]').forEach(select => {
      select.onchange = async () => {
        const id = select.getAttribute('data-check-id');
        const result = await this.post({ action: 'updateStatus', id, status: select.value });
        if (!result.ok) {
          window.alert(result.message || '更新失敗');
          return;
        }
        await this.render(container);
      };
    });

    container.querySelectorAll('[data-check-close]').forEach(button => {
      button.onclick = async () => {
        const id = button.getAttribute('data-check-id');
        const result = await this.post({ action: 'close', id });
        if (!result.ok) {
          window.alert(result.message || '關閉失敗');
          return;
        }
        await this.render(container);
      };
    });

    container.querySelectorAll('[data-check-to-queue]').forEach(button => {
      button.onclick = async () => {
        const id = button.getAttribute('data-check-id');
        await this.post({ action: 'updateStatus', id, status: 'EscalatedToQueue' });
        if (typeof showPage === 'function') showPage('queue');
        await this.render(container);
      };
    });
  },

  cardHtml(item) {
    const status = item.status || 'Pending';
    const options = this.STATUSES.map(row =>
      `<option value="${this.escapeHtml(row.id)}"${row.id === status ? ' selected' : ''}>${this.escapeHtml(row.label)}</option>`
    ).join('');
    const company = item.relatedCompany
      ? this.escapeHtml(item.relatedCompany)
      : '<span class="muted">未指定（系統不猜測）</span>';
    return `<article class="investment-check-card" data-check-id="${this.escapeHtml(item.id)}">
      <p class="investment-check-question"><b>待檢查問題：</b>${this.escapeHtml(item.question || '--')}</p>
      <p class="muted"><b>觸發事件：</b>${this.escapeHtml(item.triggerTitle || item.triggerEventRef || '--')}</p>
      <p class="muted"><b>相關公司／持股：</b>${company}</p>
      <p class="muted"><b>Evidence class：</b><span class="evidence-class-unknown">UNKNOWN</span>（使用者問題，尚未驗證／非結論）</p>
      <p class="muted"><b>建立時間：</b>${this.escapeHtml(item.createdAt || '--')}</p>
      <div class="investment-check-actions">
        <label>Status
          <select data-check-status="1" data-check-id="${this.escapeHtml(item.id)}">${options}</select>
        </label>
        <button type="button" data-check-to-queue="1" data-check-id="${this.escapeHtml(item.id)}">若值得正式研究 → Research Queue</button>
        <button type="button" data-check-close="1" data-check-id="${this.escapeHtml(item.id)}">結束</button>
      </div>
    </article>`;
  }
};
