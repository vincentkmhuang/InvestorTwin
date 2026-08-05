let queue = ['glass-bridge', 'FAU'];

function cardTitle(id) {
  return DataEngine.researchCards[id]?.title
    ?? DataEngine.investmentThesis?.cards?.[id]?.title
    ?? id;
}

async function init() {
  await DataEngine.init();
  for (const id of queue) {
    await DataEngine.getCard(id);
  }
  DataEngine.renderMorningBrief(document.getElementById('morningBrief'), loadCard);
  DataEngine.renderOpportunityRadar(document.getElementById('opportunityRadar'), loadCard);
  render();
}

function showPage(id) {
  document.querySelectorAll('.page').forEach(p => p.style.display = 'none');
  document.getElementById(id).style.display = 'block';
  document.getElementById('title').textContent = document.querySelector('[onclick="showPage(\'' + id + '\')"]').textContent.trim();
}

async function loadCard(name) {
  const card = await DataEngine.getCard(name);
  DataEngine.renderCard(card, document.getElementById('card'));
}

function render() {
  queueList.innerHTML = '';
  cardList.innerHTML = '';
  queue.forEach(q => {
    let li = document.createElement('li');
    li.textContent = cardTitle(q);
    li.onclick = () => loadCard(q);
    queueList.appendChild(li);
    let li2 = document.createElement('li');
    li2.textContent = cardTitle(q);
    li2.onclick = () => loadCard(q);
    cardList.appendChild(li2);
  });
}

function add() {
  let t = topic.value.trim();
  if (!t) return;
  if (!queue.includes(t)) {
    queue.push(t);
    if (!DataEngine.investmentThesis.cards[t]) {
      DataEngine.investmentThesis.cards[t] = {
        id: t,
        title: t,
        status: '待研究',
        related: '--',
        source: 'Manual'
      };
    }
  }
  topic.value = '';
  render();
}

init();
