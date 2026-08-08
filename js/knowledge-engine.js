const KnowledgeEngine = {
  index: null,
  cardCache: {},
  indexedIds: null,

  async init() {
    if (this.index) return this.index;

    try {
      const response = await fetch('data/knowledge-index.json');
      this.index = response.ok
        ? await response.json()
        : { generatedAt: null, tags: {} };
    } catch (_) {
      this.index = { generatedAt: null, tags: {} };
    }

    this.indexedIds = this.buildIndexedIds();
    return this.index;
  },

  buildIndexedIds() {
    const ids = new Set();
    const tags = this.index?.tags ?? {};

    for (const tag of Object.keys(tags)) {
      for (const id of tags[tag] ?? []) {
        ids.add(id);
      }
    }

    return ids;
  },

  isIndexed(id) {
    return this.indexedIds?.has(id) ?? false;
  },

  searchByTag(tag) {
    const ids = this.index?.tags?.[tag];
    return Array.isArray(ids) ? [...ids] : [];
  },

  async searchById(id) {
    if (!this.isIndexed(id)) return null;

    if (this.cardCache[id]) return this.cardCache[id];

    try {
      const response = await fetch(`research/${id}/card.json`);
      if (!response.ok) return null;

      const card = WorkflowEngine.normalizeCard(await response.json());
      this.cardCache[id] = card;
      return card;
    } catch (_) {
      return null;
    }
  },

  async getRelated(id) {
    const card = await this.searchById(id);
    if (!card) return [];

    return Array.isArray(card.related) ? [...card.related] : [];
  },

  async researchExists(id) {
    if (id == null || id === '') return false;
    const researchId = String(id);
    if (this.cardCache[researchId] || WorkflowEngine.researchCache[researchId]) return true;

    try {
      const response = await fetch(`research/${researchId}/card.json`);
      return response.ok;
    } catch (_) {
      return false;
    }
  },

  async getResolvedRelated(id) {
    if (id == null || id === '') return [];

    const selfId = String(id);
    let related = await this.getRelated(selfId);

    if (!related.length) {
      const cached = WorkflowEngine.researchCache[selfId]?.card;
      if (cached && Array.isArray(cached.related)) related = cached.related;
    }

    const seen = new Set();
    const result = [];

    for (const item of related) {
      if (item == null || item === '') continue;
      const relatedId = String(item);
      if (relatedId === selfId) continue;
      if (seen.has(relatedId)) continue;
      seen.add(relatedId);
      if (!(await this.researchExists(relatedId))) continue;
      result.push(relatedId);
    }

    const incoming = await this.getIncomingLinks(selfId);
    for (const item of incoming) {
      if (item == null || item === '') continue;
      const relatedId = String(item);
      if (relatedId === selfId) continue;
      if (seen.has(relatedId)) continue;
      seen.add(relatedId);
      if (!(await this.researchExists(relatedId))) continue;
      result.push(relatedId);
    }

    return result;
  },

  dedupeIds(ids) {
    const seen = new Set();
    const result = [];

    for (const item of ids ?? []) {
      if (item == null || item === '') continue;
      const id = String(item);
      if (seen.has(id)) continue;
      seen.add(id);
      result.push(id);
    }

    return result;
  },

  async getNeighbors(id) {
    return this.dedupeIds(await this.getRelated(id));
  },

  async getIncomingLinks(id) {
    if (id == null || id === '') return [];

    const targetId = String(id);
    const incoming = [];
    const seen = new Set();

    for (const candidateId of this.indexedIds ?? []) {
      if (candidateId === targetId || seen.has(candidateId)) continue;

      const card = await this.searchById(candidateId);
      if (!card) continue;

      const related = Array.isArray(card.related) ? card.related : [];
      const linksToTarget = related.some(item => item != null && item !== '' && String(item) === targetId);
      if (!linksToTarget) continue;

      seen.add(candidateId);
      incoming.push(candidateId);
    }

    return incoming;
  },

  async getGraph(id) {
    const center = String(id);
    const outgoing = await this.getNeighbors(center);
    const incoming = await this.getIncomingLinks(center);
    return { center, outgoing, incoming };
  },

  getTags() {
    return Object.keys(this.index?.tags ?? {}).sort();
  }
};
