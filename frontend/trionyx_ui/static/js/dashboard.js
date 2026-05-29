const prefs = {
  _key: 'trionyx_prefs',
  _load() { return JSON.parse(localStorage.getItem(this._key)) || {}; },
  get(key, fallback) {
    const val = this._load()[key];
    return val === undefined ? fallback : val;
  },
  set(key, value) {
    const data = this._load();
    data[key] = value;
    localStorage.setItem(this._key, JSON.stringify(data));
  },
};

function getStarred() {
  return prefs.get('starredAgents', []);
}

function setStarred(list) {
  prefs.set('starredAgents', list);
}

function toggleStar(event, name) {
  event.preventDefault();
  event.stopPropagation();
  const starred = getStarred();
  const idx = starred.indexOf(name);
  if (idx === -1) {
    starred.push(name);
  } else {
    starred.splice(idx, 1);
  }
  setStarred(starred);
  applyStars();
}

function applyStars() {
  const grid = document.querySelector('.agent-grid');
  if (!grid) return;

  const starred = getStarred();
  const cards = Array.from(grid.querySelectorAll('.agent-card'));

  cards.forEach(card => {
    const name = card.dataset.agent;
    card.classList.toggle('starred', starred.includes(name));
  });

  const oldDivider = grid.querySelector('.starred-divider');
  if (oldDivider) oldDivider.remove();

  const starredCards = cards.filter(c => starred.includes(c.dataset.agent));
  const unstarredCards = cards.filter(c => !starred.includes(c.dataset.agent));

  starredCards.forEach(c => grid.prepend(c));

  if (starredCards.length > 0 && unstarredCards.length > 0) {
    const divider = document.createElement('div');
    divider.className = 'starred-divider';
    unstarredCards[0].before(divider);
  }
}

applyStars();

document.body.addEventListener('htmx:afterSwap', function(e) {
  if (e.detail.target.classList.contains('agent-grid')) {
    applyStars();
  }
});
