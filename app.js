const cards={
'Glass Bridge':['研究中','康寧、正崴、上詮','Morning Brief'],
'FAU':['待研究','上詮','Opportunity Radar'],
'CPO':['研究中','光通訊供應鏈','Morning Brief'],
'HBM':['持續追蹤','SK hynix、Micron','Research'],
'全球市場':['資訊','--','Morning Brief'],
'台灣市場':['資訊','--','Morning Brief'],
'今日問題':['待研究','Glass Bridge','Morning Brief']
};
let queue=['Glass Bridge','FAU'];
function showPage(id){
document.querySelectorAll('.page').forEach(p=>p.style.display='none');
document.getElementById(id).style.display='block';
document.getElementById('title').textContent=document.querySelector('[onclick="showPage(\''+id+'\')"]').textContent.trim();
}
function loadCard(name){
let c=cards[name];
document.getElementById('card').innerHTML=`<h3>${name}</h3>
<p><b>狀態：</b>${c[0]}</p>
<p><b>相關：</b>${c[1]}</p>
<p><b>來源：</b>${c[2]}</p>`;
}
function render(){
queueList.innerHTML='';cardList.innerHTML='';
queue.forEach(q=>{
let li=document.createElement('li');li.textContent=q;li.onclick=()=>loadCard(q);queueList.appendChild(li);
let li2=document.createElement('li');li2.textContent=q;li2.onclick=()=>loadCard(q);cardList.appendChild(li2);
});
}
function add(){
let t=topic.value.trim();if(!t)return;
if(!queue.includes(t)){queue.push(t);cards[t]=['待研究','--','Manual'];}
topic.value='';render();
}
render();
