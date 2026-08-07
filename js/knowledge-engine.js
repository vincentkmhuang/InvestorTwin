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

  getTags() {
    return Object.keys(this.index?.tags ?? {}).sort();
  }
};
