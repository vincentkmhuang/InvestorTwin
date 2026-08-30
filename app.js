let navigationState = {
  currentId: null,
  breadcrumb: [],
  backStack: [],
  forwardStack: []
};
let navigationContainer = null;
let researchHistory = [];
let explorerCardIds = [];
let applyingHistory = false;
let skipNextViewHash = false;

async function init() {
  await DataEngine.init();
  await WorkflowEngine.init();
  await KnowledgeEngine.init();
  await loadVersionInfo();

  for (const id of WorkflowEngine.getQueueIds()) {
    await WorkflowEngine.loadResearch(id);
  }

  await bindTodayWorkspaceFromMorningBrief();
  await loadExplorerCardIds();
  renderKnowledgeExplorer();
  renderRecentResearch();
  render();
  renderCaseList();
  applyingHistory = true;
  try {
    await restoreViewFromHash();
  } finally {
    applyingHistory = false;
  }
}

async function bindTodayWorkspaceFromMorningBrief() {
  await DataEngine.loadMorningBrief();
  await DataEngine.renderMorningBrief(openMorningBriefResearch);
}

async function loadVersionInfo() {
  try {
    const res = await fetch('/api/version');
    if (res.ok) {
      const info = await res.json();
      document.getElementById('version').textContent = info.version;
      document.getElementById('sprint').textContent = info.sprint;
      document.getElementById('build').textContent = info.build;
      document.getElementById('commit').textContent = info.commit;
      return;
    }
  } catch (_) {}

  const fallback = await fetch('data/version.json').then(r => r.json()).catch(() => null);
  if (fallback) {
    document.getElementById('version').textContent = fallback.version;
    document.getElementById('sprint').textContent = fallback.sprint;
    document.getElementById('build').textContent = fallback.build;
    document.getElementById('commit').textContent = '--';
  }
}

function showPage(id, options) {
  document.querySelectorAll('.page').forEach(p => p.style.display = 'none');
  document.getElementById(id).style.display = 'block';
  document.getElementById('title').textContent = id === 'today'
    ? '今日工作台'
    : document.querySelector('[onclick="showPage(\'' + id + '\')"]').textContent.trim();
  const skipHash = options?.skipHash === true || skipNextViewHash;
  skipNextViewHash = false;
  if (skipHash) return;
  if (id !== 'cards' && id !== 'knowledge' && !options?.replay) {
    navigationState.currentId = null;
  }
  if (options?.replay || applyingHistory) {
    setViewHash(id);
    return;
  }
  pushViewHash(id);
}

function hashPath() {
  return (window.location.hash || '').replace(/^#/, '');
}

function decodeHashSegment(value) {
  try {
    return decodeURIComponent(value || '').trim();
  } catch (_) {
    return (value || '').trim();
  }
}

function navSnapshot() {
  return {
    currentId: navigationState.currentId,
    breadcrumb: navigationState.breadcrumb.slice(),
    backStack: JSON.parse(JSON.stringify(navigationState.backStack)),
    forwardStack: JSON.parse(JSON.stringify(navigationState.forwardStack))
  };
}

function applyNavSnapshot(snap) {
  if (!snap || typeof snap !== 'object') return;
  navigationState.currentId = snap.currentId == null ? null : snap.currentId;
  navigationState.breadcrumb = Array.isArray(snap.breadcrumb) ? snap.breadcrumb.slice() : [];
  navigationState.backStack = Array.isArray(snap.backStack) ? JSON.parse(JSON.stringify(snap.backStack)) : [];
  navigationState.forwardStack = Array.isArray(snap.forwardStack) ? JSON.parse(JSON.stringify(snap.forwardStack)) : [];
}

function buildViewHash(page, contentId) {
  const currentPage = (page || '').trim();
  if (!currentPage) return '';
  const content = (contentId || '').trim();
  if (currentPage === 'cases' && content) {
    return '#case/' + encodeURIComponent(content);
  }
  if (content) {
    return '#' + currentPage + '/' + encodeURIComponent(content);
  }
  return '#' + currentPage;
}

function setViewHash(page, contentId) {
  const next = buildViewHash(page, contentId);
  if (!next) return;
  history.replaceState({ nav: navSnapshot() }, '', next);
}

function pushViewHash(page, contentId) {
  if (applyingHistory) {
    setViewHash(page, contentId);
    return;
  }
  const next = buildViewHash(page, contentId);
  if (!next) return;
  const state = { nav: navSnapshot() };
  if (window.location.hash === next) {
    history.replaceState(state, '', next);
    return;
  }
  history.pushState(state, '', next);
}

function parseViewHash() {
  const raw = hashPath();
  if (!raw || raw === 'today') return { page: 'today' };

  if (raw.startsWith('case/')) {
    return { page: 'cases', caseId: decodeHashSegment(raw.slice('case/'.length)) };
  }
  if (raw.startsWith('cards/')) {
    return { page: 'cards', researchId: decodeHashSegment(raw.slice('cards/'.length)) };
  }
  if (raw.startsWith('knowledge/')) {
    return { page: 'knowledge', knowledgeKey: decodeHashSegment(raw.slice('knowledge/'.length)) };
  }

  const pages = ['today', 'queue', 'cards', 'cases', 'knowledge', 'sources', 'portfolio'];
  if (pages.includes(raw)) return { page: raw };
  return { page: 'today' };
}

async function restoreViewFromHash() {
  const resume = applyingHistory;
  applyingHistory = true;
  try {
    const view = parseViewHash();
    if (view.caseId) {
      if (DataEngine.getCase(view.caseId)) {
        await openInvestmentCase(view.caseId, { replay: true });
        return;
      }
      showPage('cases');
      return;
    }
    if (view.page === 'cards' && view.researchId) {
      showPage('cards', { skipHash: true });
      await openResearchCard(view.researchId, document.getElementById('card'), {
        resetPath: true,
        fromNavigation: true
      });
      return;
    }
    if (view.page === 'knowledge' && view.knowledgeKey) {
      showPage('knowledge', { skipHash: true });
      if (isKnowledgeTag(view.knowledgeKey)) {
        await selectKnowledgeTag(view.knowledgeKey);
        return;
      }
      await openResearchCard(view.knowledgeKey, document.getElementById('knowledgeExplorerCard'), {
        resetPath: true,
        fromNavigation: true
      });
      return;
    }
    showPage(view.page || 'today');
    if (view.page === 'cards' && !view.researchId) {
      const cardEl = document.getElementById('card');
      if (cardEl) cardEl.textContent = '請選擇研究卡';
    }
    if (!(view.page === 'cards' && view.researchId) && view.page !== 'knowledge') {
      navigationState.currentId = null;
    }
  } finally {
    applyingHistory = resume;
  }
}

window.addEventListener('popstate', async (event) => {
  if (applyingHistory) return;
  applyingHistory = true;
  try {
    if (event.state && event.state.nav) applyNavSnapshot(event.state.nav);
    await restoreViewFromHash();
  } finally {
    applyingHistory = false;
  }
});

function isKnowledgeTag(value) {
  return KnowledgeEngine.getTags().includes(value);
}

async function openMorningBriefResearch(id) {
  const researchId = WorkflowEngine.resolveResearchId(id);
  const added = await WorkflowEngine.ensureInQueue(researchId, 'Morning Brief');
  if (added) render();

  skipNextViewHash = true;
  showPage('cards');
  openResearchCard(id, document.getElementById('card'), {
    resetPath: true,
    fromPage: 'today'
  });
}

async function openFromOpportunityRadar(id, fromPage) {
  const researchId = WorkflowEngine.resolveResearchId(id);
  const added = await WorkflowEngine.ensureInQueue(researchId, 'Opportunity Radar');
  if (added) render();

  showPage('cards', { skipHash: true });
  openResearchCard(id, document.getElementById('card'), {
    resetPath: true,
    fromPage: fromPage || 'queue'
  });
}

async function openFromMorningBrief(id) {
  const researchId = WorkflowEngine.resolveResearchId(id);
  const added = await WorkflowEngine.ensureInQueue(researchId, 'Morning Brief');
  if (added) render();
  await openResearchCard(id, undefined, { resetPath: true });
}

async function openResearchCard(id, container, options) {
  const researchId = WorkflowEngine.resolveResearchId(id);
  const fromNavigation = options?.fromNavigation === true;
  const target = container || document.getElementById('card');
  navigationContainer = target;

  if (!fromNavigation) {
    if (navigationState.currentId != null && navigationState.currentId !== researchId) {
      navigationState.backStack.push({
        id: navigationState.currentId,
        breadcrumb: [...navigationState.breadcrumb]
      });
    } else if (navigationState.currentId == null && options?.fromPage) {
      navigationState.backStack = [{ type: 'page', pageId: options.fromPage }];
    }
    navigationState.forwardStack = [];

    if (options?.resetPath) {
      navigationState.breadcrumb = [researchId];
    } else {
      navigationState.breadcrumb = [...navigationState.breadcrumb, researchId];
    }
  }

  navigationState.currentId = researchId;
  trackResearchHistory(researchId);

  const bundle = await WorkflowEngine.loadResearch(researchId);
  await WorkflowEngine.renderResearch(bundle, target);
  renderResearchNavigation(target);

  const replayHash = fromNavigation || applyingHistory;
  if (target && target.id === 'knowledgeExplorerCard') {
    const graph = await KnowledgeEngine.getGraph(researchId);
    renderKnowledgeConnections(graph);
    renderKnowledgeMap(graph);
    if (replayHash) setViewHash('knowledge', researchId);
    else pushViewHash('knowledge', researchId);
  } else if (replayHash) {
    setViewHash('cards', researchId);
  } else {
    pushViewHash('cards', researchId);
  }
}

function navigationBack() {
  if (!navigationState.backStack.length) return;

  const top = navigationState.backStack[navigationState.backStack.length - 1];
  if (history.state && history.state.nav) {
    history.back();
    return;
  }
  if (top?.type === 'page') {
    navigationState.backStack.pop();
    navigationState.currentId = null;
    if (top.pageId === 'cards') {
      const cardEl = document.getElementById('card');
      if (cardEl) cardEl.textContent = '請選擇研究卡';
    }
    applyingHistory = true;
    try {
      showPage(top.pageId);
    } finally {
      applyingHistory = false;
    }
    return;
  }

  navigationState.forwardStack.push({
    id: navigationState.currentId,
    breadcrumb: [...navigationState.breadcrumb]
  });
  const entry = navigationState.backStack.pop();
  navigationState.breadcrumb = [...entry.breadcrumb];

  openResearchCard(entry.id, navigationContainer, { fromNavigation: true });
}

function navigationForward() {
  if (history.state && history.state.nav) {
    history.forward();
    return;
  }
  if (!navigationState.forwardStack.length) return;

  navigationState.backStack.push({
    id: navigationState.currentId,
    breadcrumb: [...navigationState.breadcrumb]
  });
  const entry = navigationState.forwardStack.pop();
  navigationState.breadcrumb = [...entry.breadcrumb];

  openResearchCard(entry.id, navigationContainer, { fromNavigation: true });
}

function trackResearchHistory(researchId) {
  researchHistory = [researchId, ...researchHistory.filter(id => id !== researchId)].slice(0, 10);
  renderRecentResearch();
}

function renderKnowledgeConnections(graph) {
  const outgoingEl = document.getElementById('connectionsOutgoing');
  const incomingEl = document.getElementById('connectionsIncoming');
  if (!outgoingEl || !incomingEl || !graph) return;

  const cardEl = document.getElementById('knowledgeExplorerCard');
  const outgoing = Array.isArray(graph.outgoing) ? graph.outgoing : [];
  const incoming = Array.isArray(graph.incoming) ? graph.incoming : [];

  const renderLinks = (listEl, ids) => {
    listEl.innerHTML = '';
    if (!ids.length) {
      listEl.innerHTML = '<li>--</li>';
      return;
    }
    ids.forEach(nodeId => {
      const li = document.createElement('li');
      li.textContent = WorkflowEngine.cardTitle(nodeId);
      li.onclick = () => openResearchCard(nodeId, cardEl);
      listEl.appendChild(li);
    });
  };

  renderLinks(outgoingEl, outgoing);
  renderLinks(incomingEl, incoming);
}

function renderKnowledgeMap(graph) {
  const mapEl = document.getElementById('knowledgeMap');
  if (!mapEl || !graph) return;

  const cardEl = document.getElementById('knowledgeExplorerCard');
  const outgoing = Array.isArray(graph.outgoing) ? graph.outgoing : [];
  const incoming = Array.isArray(graph.incoming) ? graph.incoming : [];
  const center = graph.center;

  mapEl.textContent = '';

  const appendNode = (nodeId) => {
    const span = document.createElement('span');
    span.textContent = WorkflowEngine.cardTitle(nodeId);
    span.style.cursor = 'pointer';
    span.onclick = () => openResearchCard(nodeId, cardEl);
    mapEl.appendChild(span);
  };

  mapEl.appendChild(document.createTextNode('● '));
  appendNode(center);
  mapEl.appendChild(document.createTextNode('\n'));

  outgoing.forEach((nodeId, index) => {
    const branch = index === outgoing.length - 1 ? ' └─ ' : ' ├─ ';
    mapEl.appendChild(document.createTextNode(branch));
    appendNode(nodeId);
    mapEl.appendChild(document.createTextNode('\n'));
  });

  mapEl.appendChild(document.createTextNode('\nIncoming\n'));
  if (!incoming.length) {
    mapEl.appendChild(document.createTextNode('(none)'));
    return;
  }

  incoming.forEach((nodeId, index) => {
    if (index > 0) mapEl.appendChild(document.createTextNode('\n\n'));
    appendNode(nodeId);
    mapEl.appendChild(document.createTextNode('\n    │\n    ▼\n   '));
    appendNode(center);
  });
}

function renderRecentResearch() {
  const listEl = document.getElementById('recentResearch');
  if (!listEl) return;

  listEl.innerHTML = '';
  const cardEl = document.getElementById('knowledgeExplorerCard');

  researchHistory.forEach(id => {
    const li = document.createElement('li');
    li.textContent = WorkflowEngine.cardTitle(id);
    li.onclick = () => openResearchCard(id, cardEl, { resetPath: true });
    listEl.appendChild(li);
  });
}

function renderResearchNavigation(container) {
  const controls = document.createElement('p');
  controls.className = 'research-nav-controls';

  const backBtn = document.createElement('span');
  backBtn.textContent = '← Back';
  backBtn.style.cursor = 'pointer';
  backBtn.onclick = () => navigationBack();
  controls.appendChild(backBtn);

  const forwardBtn = document.createElement('span');
  forwardBtn.textContent = '→ Forward';
  forwardBtn.style.cursor = 'pointer';
  forwardBtn.style.marginLeft = '12px';
  forwardBtn.onclick = () => navigationForward();
  controls.appendChild(forwardBtn);

  container.insertBefore(controls, container.firstChild);

  if (!navigationState.breadcrumb.length) return;

  const crumb = document.createElement('p');
  crumb.className = 'research-breadcrumb';

  navigationState.breadcrumb.forEach((pathId, index) => {
    if (index > 0) crumb.appendChild(document.createTextNode(' > '));

    const item = document.createElement('span');
    item.textContent = WorkflowEngine.cardTitle(pathId);
    item.style.cursor = 'pointer';
    item.onclick = () => {
      const targetId = navigationState.breadcrumb[index];
      navigationState.breadcrumb = navigationState.breadcrumb.slice(0, index + 1);
      openResearchCard(targetId, container, { fromNavigation: true });
    };
    crumb.appendChild(item);
  });

  controls.insertAdjacentElement('afterend', crumb);
}

function renderKnowledgeExplorer() {
  const tagsEl = document.getElementById('knowledgeTags');
  tagsEl.innerHTML = '';

  KnowledgeEngine.getTags().forEach(tag => {
    const li = document.createElement('li');
    li.textContent = tag;
    li.onclick = () => selectKnowledgeTag(tag);
    tagsEl.appendChild(li);
  });
}

async function selectKnowledgeTag(tag) {
  setViewHash('knowledge', tag);
  document.getElementById('knowledgeResultsTitle').textContent = `Research Cards — ${tag}`;

  const resultsEl = document.getElementById('knowledgeResults');
  const cardEl = document.getElementById('knowledgeExplorerCard');
  resultsEl.innerHTML = '';
  cardEl.textContent = 'Select a research card';
  const outgoingEl = document.getElementById('connectionsOutgoing');
  const incomingEl = document.getElementById('connectionsIncoming');
  const mapEl = document.getElementById('knowledgeMap');
  if (outgoingEl) outgoingEl.innerHTML = '';
  if (incomingEl) incomingEl.innerHTML = '';
  if (mapEl) mapEl.textContent = '';

  const ids = KnowledgeEngine.searchByTag(tag);
  if (!ids.length) {
    resultsEl.innerHTML = '<p>--</p>';
    return;
  }

  for (const id of ids) {
    const card = await KnowledgeEngine.searchById(id);
    const li = document.createElement('li');
    li.textContent = card?.title ?? WorkflowEngine.cardTitle(id);
    li.onclick = () => openResearchCard(id, cardEl, { resetPath: true });
    resultsEl.appendChild(li);
  }
}

async function loadExplorerCardIds() {
  try {
    const index = await fetch('data/knowledge-index.json?t=' + Date.now()).then(r => r.ok ? r.json() : null);
    explorerCardIds = Array.isArray(index?.cardIds)
      ? index.cardIds.map(id => String(id || '').trim()).filter(Boolean)
      : [];
  } catch (_) {
    explorerCardIds = [];
  }
}

async function researchCardFileExists(id) {
  try {
    const res = await fetch('research/' + encodeURIComponent(id) + '/card.json');
    return res.ok;
  } catch (_) {
    return false;
  }
}

async function render() {
  queueList.innerHTML = '';
  cardList.innerHTML = '';
  WorkflowEngine.getQueueIds().forEach(q => {
    let li = document.createElement('li');
    li.textContent = WorkflowEngine.cardTitle(q);
    li.onclick = () => {
      showPage('cards', { skipHash: true });
      openResearchCard(q, document.getElementById('card'), {
        resetPath: true,
        fromPage: 'queue'
      });
    };
    queueList.appendChild(li);
  });
  for (const id of explorerCardIds) {
    if (!(await researchCardFileExists(id))) continue;
    const li2 = document.createElement('li');
    li2.textContent = WorkflowEngine.cardTitle(id);
    li2.onclick = () => openResearchCard(id, undefined, {
      resetPath: true,
      fromPage: 'cards'
    });
    cardList.appendChild(li2);
  }
  const radarEl = document.getElementById('queueOpportunityRadar');
  if (radarEl) {
    DataEngine.renderOpportunityRadar(radarEl, openFromOpportunityRadar);
  }
  renderCaseList();
}

function renderCaseList() {
  const listEl = document.getElementById('caseList');
  if (!listEl) return;
  listEl.innerHTML = '';
  DataEngine.getCases().forEach(item => {
    const li = document.createElement('li');
    li.textContent = item.title || item.id;
    li.onclick = () => openInvestmentCase(item.id);
    listEl.appendChild(li);
  });
}

async function openInvestmentCase(id, options) {
  showPage('cases', { skipHash: true });
  if (options?.replay || applyingHistory) setViewHash('cases', id);
  else pushViewHash('cases', id);
  const container = document.getElementById('caseView');
  await WorkflowEngine.renderInvestmentCase(DataEngine.getCase(id), container);
}

async function add() {
  let t = topic.value.trim();
  if (!t) return;
  const slug = t.toLowerCase().replace(/\s+/g, '-');
  await WorkflowEngine.ensureInQueue(slug, 'Manual');
  if (!DataEngine.investmentThesis.cards[slug]) {
    DataEngine.investmentThesis.cards[slug] = {
      id: slug,
      title: t,
      status: '待研究',
      related: '--',
      source: 'Manual'
    };
  }
  topic.value = '';
  render();
}

init();
