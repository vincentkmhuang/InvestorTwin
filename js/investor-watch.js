const InvestorWatch = {
  items: [],

  STATUSES: [
    { id: 'Pending', label: 'Pending｜待觀察' },
    { id: 'Watching', label: 'Watching｜持續觀察' },
    { id: 'NewEvidence', label: 'New Evidence｜新 Evidence' },
    { id: 'Challenge', label: 'Challenge｜出現挑戰' },
    { id: 'Supported', label: 'Supported｜得到支持' },
    { id: 'ThesisImpact', label: 'Thesis Impact｜可能影響投資假設' },
    { id: 'Closed', label: 'Closed｜已結束' }
  ],

  // Noisy enough to surface on Today (not a daily reminder for quiet Watching).
  ATTENTION_STATUSES: ['Pending', 'NewEvidence', 'Challenge', 'Supported', 'ThesisImpact'],

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

  async load() {
    const res = await fetch('/api/investor-watch?t=' + Date.now());
    if (!res.ok) {
      this.items = [];
      return this.items;
    }
    const data = await res.json();
    this.items = Array.isArray(data.items) ? data.items : [];
    return this.items;
  },

  async post(body) {
    const res = await fetch('/api/investor-watch', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body || {})
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) {
      return { ok: false, message: data.message || data.error || 'Investor Watch action failed' };
    }
    this.items = Array.isArray(data.items) ? data.items : this.items;
    return { ok: true, data };
  },

  attentionItems(list) {
    const rows = Array.isArray(list) ? list : this.items;
    return rows.filter(item => this.ATTENTION_STATUSES.includes(item?.status || 'Pending'));
  },

  quietWatchingCount(list) {
    const rows = Array.isArray(list) ? list : this.items;
    return rows.filter(item => (item?.status || '') === 'Watching').length;
  },

  shapeWatchTheme(raw) {
    let text = String(raw || '').trim();
    text = text
      .replace(/^請幫我注意[：:\s]*/u, '')
      .replace(/^幫我注意[：:\s]*/u, '')
      .replace(/^請注意[：:\s]*/u, '')
      .replace(/^我覺得/u, '')
      .trim();
    text = text.replace(/[。.!]+$/u, '');
    if (!/[？?]$/u.test(text)) text += '？';
    return text;
  },

  async addFromAttention(candidate) {
    const eventRef = String(candidate?.eventRef || '').trim();
    const question = String(candidate?.researchQuestion || '').trim();
    const basis = String(candidate?.relevanceBasis || '').trim();
    const defaultTheme = this.shapeWatchTheme(question || basis || eventRef || '請幫我持續注意這個投資變化');
    const input = window.prompt(
      '👁️ Investor Watch｜請確認／編輯你想持續注意的觀察（不是 FACT／結論）：',
      defaultTheme
    );
    if (input === null) return { ok: false, cancelled: true };
    const text = String(input).trim();
    if (!text) {
      window.alert('請先輸入觀察或疑問。');
      return { ok: false };
    }
    return this.post({
      action: 'add',
      text,
      watchTheme: this.shapeWatchTheme(text),
      eventRef: eventRef || null,
      source: 'today-attention'
    });
  },

  displayDirection(item) {
    const raw = String(item?.attentionDirection || '');
    if (!raw || raw.startsWith('Seek Evidence')) {
      return '持續尋找可驗證／可挑戰此觀察的 Evidence；無重大新 Evidence 前保持安靜。';
    }
    return raw;
  },

  displayVerification(item) {
    const raw = String(item?.verificationNote || '');
    if (!raw || raw.startsWith('Awaiting Evidence')) {
      return '目前尚待 Evidence 驗證。使用者觀察不是 FACT，也不是投資結論。';
    }
    return raw;
  },

  async render(container) {
    if (!container) return;
    await this.load();
    const formHtml = `
      <div class="investor-watch-form" data-investor-watch-form="1">
        <label class="sr-only" for="investorWatchInput">我想請 Investor Twin 幫我注意</label>
        <textarea id="investorWatchInput" rows="2" placeholder="例如：請幫我注意 CPO 商業化是不是正在加速。"></textarea>
        <button type="button" id="investorWatchAddBtn">加入觀察</button>
        <p class="muted investor-watch-hint">這是你的直覺／疑問，不是 FACT，也不是投資結論。Investor Twin 會保留為待驗證的觀察方向。</p>
      </div>`;

    const attention = this.attentionItems();
    const quiet = this.quietWatchingCount();
    let listHtml = '';
    if (!attention.length) {
      listHtml = quiet
        ? `<p class="investor-watch-quiet muted">目前沒有需要提高注意力的 Watch 變化。另有 ${quiet} 項持續觀察中（無新 Evidence，保持安靜）。</p>`
        : `<p class="investor-watch-quiet muted">目前沒有進行中的 Investor Watch。需要時，把你的直覺或疑問寫進來即可。</p>`;
    } else {
      listHtml = attention.map(item => this.cardHtml(item)).join('');
      if (quiet) {
        listHtml += `<p class="investor-watch-quiet muted">另有 ${quiet} 項持續觀察中（無新 Evidence，不每日打擾）。</p>`;
      }
    }

    container.innerHTML = formHtml + `<div class="investor-watch-list">${listHtml}</div>`;

    const addBtn = container.querySelector('#investorWatchAddBtn');
    const input = container.querySelector('#investorWatchInput');
    if (addBtn && input) {
      addBtn.onclick = async () => {
        const text = String(input.value || '').trim();
        if (!text) {
          window.alert('請先輸入你想請 Investor Twin 注意的觀察或疑問。');
          return;
        }
        const result = await this.post({
          action: 'add',
          text,
          watchTheme: this.shapeWatchTheme(text)
        });
        if (!result.ok) {
          window.alert(result.message || '新增失敗');
          return;
        }
        input.value = '';
        await this.render(container);
      };
    }

    container.querySelectorAll('[data-watch-status]').forEach(select => {
      select.onchange = async () => {
        const id = select.getAttribute('data-watch-id');
        const status = select.value;
        const result = await this.post({ action: 'updateStatus', id, status });
        if (!result.ok) {
          window.alert(result.message || '更新失敗');
          return;
        }
        await this.render(container);
      };
    });

    container.querySelectorAll('[data-watch-close]').forEach(button => {
      button.onclick = async () => {
        const id = button.getAttribute('data-watch-id');
        const result = await this.post({ action: 'close', id });
        if (!result.ok) {
          window.alert(result.message || '關閉失敗');
          return;
        }
        await this.render(container);
      };
    });

    container.querySelectorAll('[data-watch-to-queue]').forEach(button => {
      button.onclick = () => {
        if (typeof showPage === 'function') showPage('queue');
      };
    });
  },

  cardHtml(item) {
    const status = item.status || 'Pending';
    const options = this.STATUSES.map(row =>
      `<option value="${this.escapeHtml(row.id)}"${row.id === status ? ' selected' : ''}>${this.escapeHtml(row.label)}</option>`
    ).join('');
    return `<article class="investor-watch-card" data-watch-id="${this.escapeHtml(item.id)}">
      <p class="investor-watch-theme"><b>Watch 主題：</b>${this.escapeHtml(item.watchTheme || '--')}</p>
      <p class="muted"><b>原始觀察（非 FACT）：</b>${this.escapeHtml(item.rawObservation || '--')}</p>
      <p class="muted"><b>正在注意的方向：</b>${this.escapeHtml(this.displayDirection(item))}</p>
      <p class="investor-watch-verify muted">${this.escapeHtml(this.displayVerification(item))}</p>
      <p class="muted"><b>Evidence class：</b><span class="evidence-class-unknown">${this.escapeHtml(item.evidenceClass || 'UNKNOWN')}</span>（使用者觀察，尚未驗證）</p>
      ${item.eventRef ? `<p class="muted"><b>來源 eventRef：</b><code>${this.escapeHtml(item.eventRef)}</code></p>` : ''}
      <div class="investor-watch-actions">
        <label>Status
          <select data-watch-status="1" data-watch-id="${this.escapeHtml(item.id)}">${options}</select>
        </label>
        <button type="button" data-watch-close="1" data-watch-id="${this.escapeHtml(item.id)}">結束觀察</button>
        <button type="button" data-watch-to-queue="1">若值得正式研究 → Research Queue</button>
      </div>
    </article>`;
  }
};
