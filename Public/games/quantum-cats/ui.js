// DOM layer: menus, HUD, pop-ups. Talks to the game through window.QC.
'use strict';
window.QCUI = (() => {
  const $ = s => document.querySelector(s);
  const T = k => window.QC.T(k);
  const L = () => STRINGS[window.QC.lang] || STRINGS.en;
  const click = (vol = 0.5) => window.QC.Audio.play('ui-click', vol);
  const show = (el, on) => { el.hidden = !on; };
  const C = () => window.QC.lang === 'fr' ? ' : ' : ': ';
  const LOC = () => window.QC.lang === 'fr' ? 'fr-CA' : 'en-CA';
  let currentLevel = -1;

  function applyText() {
    document.documentElement.lang = window.QC.lang;
    document.querySelectorAll('[data-t]').forEach(el => { el.textContent = T(el.dataset.t); });
    document.querySelectorAll('[data-tl]').forEach(el => { el.setAttribute('aria-label', T(el.dataset.tl)); });
    $('#btn-lang').textContent = T('language');
    $('#btn-lang').setAttribute('lang', window.QC.lang === 'en' ? 'fr' : 'en');
    renderLevels(); renderCredits(); updateToggles();
  }
  const EDU_ICONS = { classy: 'img/UI_Classical_png.webp', schro: 'img/UI_SuperPos_png.webp', digger: 'img/UI_Tunnelling_png.webp', fuzzy: 'img/UI_Uncertainty_png.webp' };
  const LEVEL_CATS = ['classy', 'schro', 'digger', 'fuzzy'];
  function renderLevels() {
    const best = (window.QC.SAVE.best || {});
    const mk = (i) => {
      const b = document.createElement('div'); b.className = 'lvl';
      const cat = LEVEL_CATS[i];
      const btn = document.createElement('button'); btn.className = 'btn-orange lvl-btn'; btn.textContent = String(i + 1);
      btn.setAttribute('aria-label', T('level') + ' ' + (i + 1));
      btn.onclick = () => { click(); startLevel(i); };
      if (cat) {
        const icon = document.createElement('button'); icon.className = 'lvl-icon'; icon.title = T('learn');
        icon.setAttribute('aria-label', T('learn') + C() + L().edu[cat].name);
        const im1 = document.createElement('img'); im1.src = EDU_ICONS[cat]; im1.alt = '';
        const im2 = document.createElement('img'); im2.className = 'help'; im2.src = 'img/TEMP_Help_png.webp'; im2.alt = '';
        icon.append(im1, im2);
        icon.onclick = () => { click(); eduOpener = icon; openEdu(cat); };
        b.appendChild(icon);
      } else if (i < 5) { const sp = document.createElement('div'); sp.className = 'lvl-icon spacer'; b.appendChild(sp); }
      b.appendChild(btn);
      const bs = document.createElement('div'); bs.className = 'best'; bs.textContent = best[i] ? '★ ' + best[i].toLocaleString(LOC()) : ''; b.appendChild(bs);
      return b;
    };
    const r1 = $('#row-cats'), r2 = $('#row-lab'); r1.replaceChildren(); r2.replaceChildren();
    for (let i = 0; i < 5; i++) r1.appendChild(mk(i));
    for (let i = 5; i < 10; i++) r2.appendChild(mk(i));
  }
  let eduOpener = null;
  function announce(t) { const el = $('#sr'); el.textContent = ''; setTimeout(() => { el.textContent = t; }, 50); }
  function openEdu(cat) {
    const e = L().edu[cat];
    $('#edu-title').textContent = e.title; $('#edu-name').textContent = e.name; $('#edu-bio').textContent = e.bio; $('#edu-facts').textContent = e.facts;
    $('#edu-img').src = EDU_ICONS[cat];
    show($('#edu'), true); $('#edu .close').focus();
  }
  function renderCredits() {
    const heads = L().creditHeads, box = $('#credit-list'); box.replaceChildren();
    CREDITS.forEach((names, i) => {
      const h = document.createElement('h3'); h.textContent = heads[i]; box.appendChild(h);
      const p = document.createElement('p'); names.forEach((n, j) => { if (j) p.appendChild(document.createElement('br')); p.appendChild(document.createTextNode(n)); }); box.appendChild(p);
    });
    const section = (head, names, cls) => {
      const h = document.createElement('h3'); h.textContent = head; box.appendChild(h);
      const p = document.createElement('p'); if (cls) p.className = cls;
      names.forEach((n, j) => { if (j) p.appendChild(document.createElement('br')); p.appendChild(document.createTextNode(n)); });
      box.appendChild(p);
    };
    section(heads[6], L().thanksList);
    section(L().bugsHead, [L().bugsLine], 'selectable');
  }
  function updateToggles() {
    const A = window.QC.Audio;
    for (const id of ['#opt-sound', '#menu-sound']) { const el = $(id); if (el) { el.textContent = T('sound') + C() + (A.sfx ? T('on') : T('off')); } }
    for (const id of ['#opt-music', '#menu-music']) { const el = $(id); if (el) { el.textContent = T('music') + C() + (A.music ? T('on') : T('off')); } }
  }
  function toggleSfx() { const A = window.QC.Audio; A.sfx = !A.sfx; window.QC.SAVE.sfx = A.sfx; window.QC.persist(); updateToggles(); click(); }
  function toggleMusic() { const A = window.QC.Audio; A.music = !A.music; window.QC.SAVE.music = A.music; window.QC.persist(); A.unlock(); A.applyMusic(); updateToggles(); click(); }

  function showMenu() {
    window.QC.unload(); currentLevel = -1;
    document.body.classList.remove('ingame'); $('#game').tabIndex = -1; show($('#menu'), true); show($('#hud'), false); show($('#results'), false); show($('#options'), false);
    show($('#levels'), false); show($('#start'), true);
    renderLevels();
  }
  function startLevel(i, retry) {
    currentLevel = i;
    document.body.classList.add('ingame'); $('#game').tabIndex = 0; show($('#menu'), false); show($('#results'), false); show($('#options'), false); show($('#hud'), true);
    $('#game').focus();
    window.QC.loadLevel(i, retry);
  }
  // ---- hooks called by the game
  function levelStarted(S) {
    $('#lvl-num').textContent = T('level') + ' ' + (S.idx + 1);
    score(S.score, S.boxes, S.boxGoal); catsLeft(S.L.cats.length - (S.fireId || 0));
    tutOpen = !S.retry; renderTut();
    announce(T('level') + ' ' + (S.idx + 1) + '. ' + T('boxes-label') + ': 0/' + S.boxGoal + '. ' + T('cats-left') + C() + S.L.cats.length + '.');
  }
  function score(sc, boxes, goal, pop) {
    $('#hud-score').textContent = T('score') + C() + sc.toLocaleString(LOC());
    $('#hud-boxes').textContent = boxes + '/' + goal;
    if (pop) { const b = $('#hud-box'); b.classList.remove('pop'); void b.offsetWidth; b.classList.add('pop'); }
  }
  let tutOpen = true, tutCat = null;
  function tutorial(cat) { tutCat = cat; renderTut(); announce(T('next-cat') + C() + T('cat-type-' + cat.type) + '. ' + T('cat-description-' + cat.type)); }
  function renderTut() {
    const box = $('#tut');
    if (!tutCat) { box.hidden = true; return; }
    box.hidden = false;
    $('#tut-name').textContent = T('cat-type-' + tutCat.type);
    $('#tut-desc').textContent = T('cat-description-' + tutCat.type);
    $('#tut-desc').hidden = !tutOpen;
    $('#tut-toggle span').textContent = tutOpen ? '×' : '?';
    $('#tut-toggle').setAttribute('aria-label', T(tutOpen ? 'hide-tip' : 'show-tip'));
    $('#tut-toggle').setAttribute('aria-expanded', tutOpen);
  }
  function catsLeft(n) { $('#hud-cats').textContent = T('cats-left') + C() + n; }
  function catFired() { catsLeft(window.QC.level.L.cats.length - window.QC.level.fireId); if (window.QC.level && window.QC.level.retry) { tutOpen = false; renderTut(); } }
  function results(won, sc, bonus, idx) {
    const r = $('#results');
    $('#res-title').textContent = won ? T('you-win') : T('try-again');
    $('#res-title').className = won ? 'won' : 'lost';
    const lines = $('#res-lines'); lines.replaceChildren();
    const add = (t, cls) => { const d = document.createElement('div'); d.textContent = t; if (cls) d.className = cls; lines.appendChild(d); };
    if (won) {
      add(T('score') + C() + sc.toLocaleString(LOC()));
      add('+ ' + T('cat-bonus') + C() + (1000).toLocaleString(LOC()) + ' × ' + Math.round(bonus / 1000));
      add(T('total-score') + C() + (sc + bonus).toLocaleString(LOC()), 'total');
    } else {
      const tips = L().tips; add(T('tip') + C() + tips[Math.floor(Math.random() * tips.length)], 'tip');
    }
    $('#res-next').disabled = idx >= 9;
    show(r, true); show($('#options'), false);
    $(won && idx < 9 ? '#res-next' : '#res-retry').focus();
  }
  function setOptions(open) {
    show($('#options'), open); window.QC.setOptions(open);
    $('#btn-options').setAttribute('aria-expanded', open);
  }

  function init() {
    $('#btn-play').onclick = () => { window.QC.Audio.unlock(); window.QC.Audio.play('cat-in-air', 1); show($('#start'), false); show($('#levels'), true); $('#row-cats .lvl-btn').focus(); };
    $('#levels .close').onclick = () => { click(); show($('#levels'), false); show($('#start'), true); $('#btn-play').focus(); };
    $('#edu .close').onclick = () => { click(); show($('#edu'), false); if (eduOpener) eduOpener.focus(); };
    $('#btn-credits').onclick = () => { window.QC.Audio.unlock(); click(); show($('#credits'), true); $('#credits .close').focus(); };
    $('#credits .close').onclick = () => { click(); show($('#credits'), false); $('#btn-credits').focus(); };
    $('#btn-lang').onclick = () => { window.QC.Audio.unlock(); click(); window.QC.setLang(window.QC.lang === 'en' ? 'fr' : 'en'); applyText(); if (window.QC.level) { levelStarted(window.QC.level); renderTut(); } };
    $('#menu-sound').onclick = () => { window.QC.Audio.unlock(); toggleSfx(); };
    $('#menu-music').onclick = () => { window.QC.Audio.unlock(); toggleMusic(); };
    $('#btn-options').onclick = () => { click(); const open = $('#options').hidden; setOptions(open); if (open) $('#opt-reset').focus(); };
    $('#opt-reset').onclick = () => { click(); startLevel(currentLevel, true); };
    $('#opt-menu').onclick = () => { click(); showMenu(); };
    $('#opt-sound').onclick = toggleSfx; $('#opt-music').onclick = toggleMusic;
    $('#opt-close').onclick = () => { click(); setOptions(false); $('#btn-options').focus(); };
    $('#tut-toggle').onclick = () => { click(); tutOpen = !tutOpen; renderTut(); };
    $('#res-menu').onclick = () => { click(); showMenu(); };
    $('#res-retry').onclick = () => { click(); startLevel(currentLevel, true); };
    $('#res-next').onclick = () => { click(); if (currentLevel < 9) startLevel(currentLevel + 1); };
    document.addEventListener('keydown', e => {
      if (e.key !== 'Escape') return;
      if (!$('#edu').hidden) $('#edu .close').click();
      else if (!$('#credits').hidden) $('#credits .close').click();
      else if (!$('#levels').hidden && !$('#menu').hidden) $('#levels .close').click();
      else if (!$('#options').hidden) $('#opt-close').click();
      else if (!$('#hud').hidden && $('#results').hidden) $('#btn-options').click();
    });
    // keep keyboard focus inside whichever dialog is open
    document.addEventListener('keydown', e => {
      if (e.key !== 'Tab') return;
      const dlg = ['#edu', '#credits', '#options', '#results', '#levels'].map(s => $(s)).find(d => !d.hidden && (d.id !== 'levels' || !$('#menu').hidden));
      if (!dlg) return;
      const f = [...dlg.querySelectorAll('button:not([disabled]), [href], [tabindex]:not([tabindex="-1"])')].filter(el => el.offsetParent !== null);
      if (!f.length) return;
      const i = f.indexOf(document.activeElement);
      if (e.shiftKey && (i <= 0)) { e.preventDefault(); f[f.length - 1].focus(); }
      else if (!e.shiftKey && (i === -1 || i === f.length - 1)) { e.preventDefault(); f[0].focus(); }
    });
    applyText();
  }
  return { announce, init, applyText, showMenu, startLevel, levelStarted, score, tutorial, catFired, results };
})();