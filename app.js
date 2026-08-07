async function init() {
  await DataEngine.init();
  await WorkflowEngine.init();
  await KnowledgeEngine.init();
  await loadVersionInfo();

  for (const id of WorkflowEngine.getQueueIds()) {
    await WorkflowEngine.loadResearch(id);
  }

  DataEngine.renderMorningBrief(document.getElementById('morningBrief'), openFromMorningBrief);
  DataEngine.renderOpportunityRadar(document.getElementById('opportunityRadar'), openResearchCard);
  renderKnowledgeExplorer();
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
  document.getElementById('title').textContent = document.querySelector('[onclick="showPage(\'' + id + '\')"]').textContent.trim();
}

async function openFromMorningBrief(id) {
  const researchId = WorkflowEngine.resolveResearchId(id);
  const added = await WorkflowEngine.ensureInQueue(researchId, 'Morning Brief');
  if (added) render();
  await openResearchCard(id);
}

async function openResearchCard(id, container) {
  const researchId = WorkflowEngine.resolveResearchId(id);
  const bundle = await WorkflowEngine.loadResearch(researchId);
  WorkflowEngine.renderResearch(bundle, container || document.getElementById('card'));
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

  const ids = KnowledgeEngine.searchByTag(tag);
  if (!ids.length) {
    resultsEl.innerHTML = '<p>--</p>';
    return;
  }

  for (const id of ids) {
    const card = await KnowledgeEngine.searchById(id);
    const li = document.createElement('li');
    li.textContent = card?.title ?? WorkflowEngine.cardTitle(id);
    li.onclick = () => openResearchCard(id, cardEl);
    resultsEl.appendChild(li);
  }
}

function render() {
  queueList.innerHTML = '';
  cardList.innerHTML = '';
  WorkflowEngine.getQueueIds().forEach(q => {
    let li = document.createElement('li');
    li.textContent = WorkflowEngine.cardTitle(q);
    li.onclick = () => openResearchCard(q);
    queueList.appendChild(li);
    let li2 = document.createElement('li');
    li2.textContent = WorkflowEngine.cardTitle(q);
    li2.onclick = () => openResearchCard(q);
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
