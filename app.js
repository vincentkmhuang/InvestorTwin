let navigationState = {
  currentId: null,
  breadcrumb: [],
  backStack: [],
  forwardStack: []
};
let navigationContainer = null;
let researchHistory = [];

async function init() {
  await DataEngine.init();
  await WorkflowEngine.init();
  await KnowledgeEngine.init();
  await loadVersionInfo();

  for (const id of WorkflowEngine.getQueueIds()) {
    await WorkflowEngine.loadResearch(id);
  }

  await DataEngine.loadMorningBrief();
  await DataEngine.renderMorningBrief(openMorningBriefResearch);
  renderKnowledgeExplorer();
  renderRecentResearch();
  render();
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

function showPage(id) {
  document.querySelectorAll('.page').forEach(p => p.style.display = 'none');
  document.getElementById(id).style.display = 'block';
  document.getElementById('title').textContent = id === 'today'
    ? '🌅 Morning Brief'
    : document.querySelector('[onclick="showPage(\'' + id + '\')"]').textContent.trim();
}

async function openMorningBriefResearch(id) {
  const researchId = WorkflowEngine.resolveResearchId(id);
  const added = await WorkflowEngine.ensureInQueue(researchId, 'Morning Brief');
  if (added) render();

  showPage('cards');
  openResearchCard(id, document.getElementById('card'), {
    resetPath: true,
    fromPage: 'today'
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
    if (options?.fromPage) {
      navigationState.backStack = [{ type: 'page', pageId: options.fromPage }];
    } else if (navigationState.currentId != null) {
      navigationState.backStack.push({
        id: navigationState.currentId,
        breadcrumb: [...navigationState.breadcrumb]
      });
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

  if (target && target.id === 'knowledgeExplorerCard') {
    const graph = await KnowledgeEngine.getGraph(researchId);
    renderKnowledgeConnections(graph);
    renderKnowledgeMap(graph);
  }
}

function navigationBack() {
  if (!navigationState.backStack.length) return;

  const top = navigationState.backStack[navigationState.backStack.length - 1];
  if (top?.type === 'page') {
    navigationState.backStack.pop();
    showPage(top.pageId);
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

function render() {
  queueList.innerHTML = '';
  cardList.innerHTML = '';
  WorkflowEngine.getQueueIds().forEach(q => {
    let li = document.createElement('li');
    li.textContent = WorkflowEngine.cardTitle(q);
    li.onclick = () => openResearchCard(q, undefined, { resetPath: true });
    queueList.appendChild(li);
    let li2 = document.createElement('li');
    li2.textContent = WorkflowEngine.cardTitle(q);
    li2.onclick = () => openResearchCard(q, undefined, { resetPath: true });
    cardList.appendChild(li2);
  });
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
