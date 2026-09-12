/**
 * Investment Meaning Gate — rule-based pass/fail (no LLM).
 * Decides whether an eligible Candidate may enter Today Workspace.
 *
 * Candidate Gate (Human disposition) remains separate.
 */
const InvestmentMeaningGate = {
  MEANING_TYPES: ['Supported', 'Challenged', 'Shift', 'NewQuestion', 'Opportunity'],
  WATCH_NOISE_STATUSES: ['NewEvidence', 'Challenge', 'Supported', 'ThesisImpact'],

  emptyContext() {
    return {
      watchEventRefs: new Set(),
      watchNoiseEventRefs: new Set(),
      checkEventRefs: new Set(),
      cardEventRefs: new Set(),
      caseCardIds: new Set(),
      seen: {}
    };
  },

  evidenceFingerprint(candidate) {
    const parts = [];
    const refs = Array.isArray(candidate?.evidenceRefs) ? candidate.evidenceRefs : [];
    for (const row of refs) {
      parts.push([
        String(row?.class || '').toUpperCase(),
        String(row?.newsRef || '').trim(),
        String(row?.claim || '').trim()
      ].join('|'));
    }
    const status = candidate?.impact && typeof candidate.impact === 'object'
      ? candidate.impact.evidenceStatus
      : null;
    if (status && typeof status === 'object') {
      for (const cls of ['FACT', 'ESTIMATE', 'INFERENCE', 'UNKNOWN']) {
        const rows = Array.isArray(status[cls]) ? status[cls] : [];
        for (const row of rows) {
          parts.push([
            cls,
            String(row?.newsRef || '').trim(),
            String(row?.claim || '').trim()
          ].join('|'));
        }
      }
    }
    return parts.filter(Boolean).sort().join(';;');
  },

  hasMaterialEvidence(candidate) {
    const refs = Array.isArray(candidate?.evidenceRefs) ? candidate.evidenceRefs : [];
    for (const row of refs) {
      const cls = String(row?.class || '').toUpperCase();
      if ((cls === 'FACT' || cls === 'ESTIMATE') && String(row?.claim || '').trim()) return true;
    }
    const status = candidate?.impact && typeof candidate.impact === 'object'
      ? candidate.impact.evidenceStatus
      : null;
    if (status && typeof status === 'object') {
      for (const cls of ['FACT', 'ESTIMATE']) {
        const rows = Array.isArray(status[cls]) ? status[cls] : [];
        if (rows.some(row => String(row?.claim || '').trim())) return true;
      }
    }
    return false;
  },

  detectMeaningType(candidate) {
    const explicit = String(
      candidate?.meaningType || candidate?.investmentMeaning || candidate?.meaning || ''
    ).trim();
    if (explicit) {
      const norm = explicit.replace(/\s+/g, '');
      if (/^supported$/i.test(norm)) return 'Supported';
      if (/^challenged$/i.test(norm)) return 'Challenged';
      if (/^shift$/i.test(norm)) return 'Shift';
      if (/^newquestion$/i.test(norm) || /^new_question$/i.test(norm)) return 'NewQuestion';
      if (/^opportunity$/i.test(norm)) return 'Opportunity';
    }

    const relevance = String(candidate?.relevance || '').trim();
    const question = String(candidate?.researchQuestion || '').trim();
    const impact = candidate?.impact && typeof candidate.impact === 'object' ? candidate.impact : {};
    const direction = String(impact.direction || '').trim();
    const strength = String(impact.strength || '').trim();
    const strengthOk = strength === 'High' || strength === 'Medium';
    const relevanceOk = relevance === 'High' || relevance === 'Medium';

    if (direction === 'Negative' && strengthOk) return 'Challenged';
    if (direction === 'Positive' && strengthOk) return 'Supported';
    if (direction === 'Mixed' && strength === 'High') return 'Shift';
    if (question && relevanceOk) return 'NewQuestion';
    return null;
  },

  personalRelevance(candidate, ctx) {
    const eventRef = String(candidate?.eventRef || '').trim();
    const links = [];
    if (!eventRef) return { ok: false, links };

    if (ctx.watchEventRefs.has(eventRef)) links.push('InvestorWatch');
    if (ctx.checkEventRefs.has(eventRef)) links.push('InvestmentCheck');
    if (ctx.cardEventRefs.has(eventRef)) links.push('ResearchCard');
    if (candidate?.cardId) links.push('GateCardId');

    return { ok: links.length > 0, links };
  },

  /**
   * Change / Evidence rule:
   * - Must have FACT or ESTIMATE material evidence.
   * - Watching without new evidence must not re-enter Today daily.
   */
  changeAndEvidence(candidate, ctx) {
    const reasons = [];
    if (!this.hasMaterialEvidence(candidate)) {
      return { ok: false, reasons: ['no_material_evidence'] };
    }
    reasons.push('has_fact_or_estimate');

    const status = String(candidate?.status || 'Pending');
    const eventRef = String(candidate?.eventRef || '').trim();
    const fp = this.evidenceFingerprint(candidate);

    if (status === 'Watching') {
      const seen = ctx.seen && eventRef ? ctx.seen[eventRef] : null;
      const prevFp = seen && seen.evidenceFingerprint ? String(seen.evidenceFingerprint) : '';
      const watchNoise = eventRef && ctx.watchNoiseEventRefs.has(eventRef);
      // Investor Watch noise statuses (NewEvidence / Challenge / Supported / ThesisImpact)
      // may re-enter Gate. Meaning labels like Shift are NOT new Evidence.
      if (watchNoise) {
        reasons.push('watch_has_new_evidence_signal');
        return { ok: true, reasons, fingerprint: fp };
      }
      if (prevFp) {
        if (prevFp === fp) {
          return { ok: false, reasons: ['watching_without_new_evidence'], fingerprint: fp };
        }
        reasons.push('evidence_fingerprint_changed');
        return { ok: true, reasons, fingerprint: fp };
      }
      // No baseline yet: allow one pass so Today can establish seen baseline via recordPassed.
      // Missing seen must not stay "new Evidence" forever — persistence must succeed after this.
      reasons.push('watching_first_evidence_pass');
      return { ok: true, reasons, fingerprint: fp };
    }

    // Pending (and other attention statuses): material evidence counts as change signal.
    reasons.push('pending_with_material_evidence');
    return { ok: true, reasons, fingerprint: fp };
  },

  evaluate(candidate, ctx) {
    const context = ctx || this.emptyContext();
    const reasons = [];
    const eventRef = String(candidate?.eventRef || '').trim();

    const change = this.changeAndEvidence(candidate, context);
    reasons.push(...change.reasons.map(r => (change.ok ? 'change:' : 'change_fail:') + r));
    if (!change.ok) {
      return {
        passed: false,
        reason: reasons,
        meaningType: null,
        personalLinks: [],
        evidenceFingerprint: change.fingerprint || this.evidenceFingerprint(candidate),
        evaluatedAt: new Date().toISOString()
      };
    }

    const personal = this.personalRelevance(candidate, context);
    if (!personal.ok) {
      reasons.push('personal_relevance_fail:no_explicit_link');
      return {
        passed: false,
        reason: reasons,
        meaningType: null,
        personalLinks: [],
        evidenceFingerprint: change.fingerprint,
        evaluatedAt: new Date().toISOString()
      };
    }
    reasons.push('personal_relevance:' + personal.links.join('+'));

    const meaningType = this.detectMeaningType(candidate);
    if (!meaningType) {
      reasons.push('meaning_fail:no_explicit_investment_meaning');
      return {
        passed: false,
        reason: reasons,
        meaningType: null,
        personalLinks: personal.links,
        evidenceFingerprint: change.fingerprint,
        evaluatedAt: new Date().toISOString()
      };
    }
    reasons.push('meaning:' + meaningType);

    // Attention threshold = all of the above (no numeric score).
    reasons.push('attention_threshold:pass');
    return {
      passed: true,
      reason: reasons,
      meaningType,
      personalLinks: personal.links,
      evidenceFingerprint: change.fingerprint,
      evaluatedAt: new Date().toISOString(),
      eventRef
    };
  },

  filterForToday(candidates, ctx) {
    const rows = Array.isArray(candidates) ? candidates : [];
    const passed = [];
    for (const candidate of rows) {
      const decision = this.evaluate(candidate, ctx);
      candidate.meaningGate = {
        passed: decision.passed,
        reason: decision.reason,
        meaningType: decision.meaningType,
        personalLinks: decision.personalLinks,
        evidenceFingerprint: decision.evidenceFingerprint,
        evaluatedAt: decision.evaluatedAt
      };
      if (decision.passed) passed.push(candidate);
    }
    passed.sort((a, b) => {
      const ia = Number(a?.importance);
      const ib = Number(b?.importance);
      const na = Number.isFinite(ia) ? ia : 0;
      const nb = Number.isFinite(ib) ? ib : 0;
      if (nb !== na) return nb - na;
      return String(a?.eventRef || '').localeCompare(String(b?.eventRef || ''));
    });
    return passed;
  },

  async buildContext() {
    const ctx = this.emptyContext();

    try {
      const watchRes = await fetch('/api/investor-watch?t=' + Date.now());
      if (watchRes.ok) {
        const data = await watchRes.json();
        for (const item of (Array.isArray(data.items) ? data.items : [])) {
          const eventRef = String(item?.eventRef || '').trim();
          if (!eventRef) continue;
          if (String(item?.status || '') === 'Closed') continue;
          ctx.watchEventRefs.add(eventRef);
          if (this.WATCH_NOISE_STATUSES.includes(String(item?.status || ''))) {
            ctx.watchNoiseEventRefs.add(eventRef);
          }
        }
      }
    } catch (_) {}

    try {
      const checkRes = await fetch('/api/investment-check?t=' + Date.now());
      if (checkRes.ok) {
        const data = await checkRes.json();
        for (const item of (Array.isArray(data.items) ? data.items : [])) {
          if (String(item?.status || '') === 'Closed') continue;
          const eventRef = String(item?.triggerEventRef || '').trim();
          if (eventRef) ctx.checkEventRefs.add(eventRef);
        }
      }
    } catch (_) {}

    try {
      const stateRes = await fetch('/api/meaning-gate-state?t=' + Date.now());
      if (stateRes.ok) {
        const data = await stateRes.json();
        const seen = data && data.seen && typeof data.seen === 'object' && !Array.isArray(data.seen)
          ? data.seen
          : {};
        ctx.seen = seen;
      } else {
        console.error('[InvestmentMeaningGate] GET /api/meaning-gate-state failed', stateRes.status);
      }
    } catch (err) {
      console.error('[InvestmentMeaningGate] GET /api/meaning-gate-state error', err);
    }

    // Explicit Research Card links only (candidateLinks.eventRef). No ticker guessing.
    try {
      const index = await fetch('data/knowledge-index.json?t=' + Date.now()).then(r => r.ok ? r.json() : null);
      const ids = Array.isArray(index?.cardIds) ? index.cardIds : [];
      for (const id of ids) {
        const rid = String(id || '').trim();
        if (!rid) continue;
        try {
          const card = await fetch('research/' + encodeURIComponent(rid) + '/card.json?t=' + Date.now())
            .then(r => r.ok ? r.json() : null);
          const links = Array.isArray(card?.candidateLinks) ? card.candidateLinks : [];
          for (const link of links) {
            const eventRef = String(link?.eventRef || '').trim();
            if (eventRef) ctx.cardEventRefs.add(eventRef);
          }
        } catch (_) {}
      }
    } catch (_) {}

    return ctx;
  },

  async recordPassed(candidates) {
    const rows = Array.isArray(candidates) ? candidates : [];
    if (!rows.length) return { ok: true, skipped: true };
    const evaluatedAt = new Date().toISOString();
    const updates = [];
    for (const candidate of rows) {
      const eventRef = String(candidate?.eventRef || '').trim();
      if (!eventRef) continue;
      const fp = candidate?.meaningGate?.evidenceFingerprint
        || this.evidenceFingerprint(candidate);
      updates.push({
        eventRef,
        evidenceFingerprint: fp,
        meaningType: candidate?.meaningGate?.meaningType || null,
        evaluatedAt: candidate?.meaningGate?.evaluatedAt || evaluatedAt
      });
    }
    if (!updates.length) return { ok: true, skipped: true };
    try {
      const res = await fetch('/api/meaning-gate-state', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ action: 'recordPassed', updates })
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok || data.ok === false) {
        const message = data.message || data.error || ('HTTP ' + res.status);
        console.error('[InvestmentMeaningGate] recordPassed failed:', message, data);
        return { ok: false, error: message, status: res.status, data };
      }
      return { ok: true, seen: data.seen || null };
    } catch (err) {
      console.error('[InvestmentMeaningGate] recordPassed network/error:', err);
      return { ok: false, error: String(err && err.message ? err.message : err) };
    }
  }
};
