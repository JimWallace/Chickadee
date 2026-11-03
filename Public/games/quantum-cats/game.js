// Quantum Cats — HTML port of the Unity game (IQC / The Games Institute).
'use strict';
(() => {
const { World, DYNAMIC, STATIC, KINEMATIC } = Phys;
const DT = 0.005;                 // Unity fixed timestep for this project
const G_LAYERS = { Background: 0, Midground: 1, Foreground: 2, Default: 3, Ground: 4, LevelObjects: 5, GameObjects: 6, CatTails: 7, Cats: 8, Effects: 9 };
const LEVEL_KEYS = ['LEVEL_001_BaseCat', 'LEVEL_002_SuperpositionCat', 'LEVEL_003_TunnelCat', 'LEVEL_004_UncertaintyCat', 'LEVEL_005_Laser', 'LEVEL_006_Magnet', 'LEVEL_007_Helium', 'LEVEL_008_NewLevel', 'LEVEL_009_NewLevel', 'LEVEL_010_NewLevel'];
const CAT_BIT = 2;
const rand = (a, b) => a + Math.random() * (b - a);
const randInt = (a, b) => Math.floor(rand(a, b)); // Unity Random.Range(int,int): max exclusive
const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
const lerp = (a, b, t) => a + (b - a) * clamp(t, 0, 1);
const insideUnitCircle = () => { const a = Math.random() * 2 * Math.PI, r = Math.sqrt(Math.random()); return [Math.cos(a) * r, Math.sin(a) * r]; };
function spring(o, k, vk, target, zeta, omega, h) { // Springy.Spring
  const f = 1 + 2 * h * zeta * omega, oo = omega * omega, hoo = h * oo, hhoo = h * hoo, det = 1 / (f + hhoo);
  const x = (f * o[k] + h * o[vk] + hhoo * target) * det, v = (o[vk] + hoo * (target - o[k])) * det;
  o[k] = x; o[vk] = v;
}
function smoothDamp(cur, target, ref, st, dt) {
  st = Math.max(0.0001, st); const om = 2 / st, x = om * dt, e = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x);
  const ch = cur - target, tmp = (ref.v + om * ch) * dt; ref.v = (ref.v - om * tmp) * e;
  let out = target + (ch + tmp) * e;
  if ((target - cur > 0) === (out > target)) { out = target; ref.v = (out - target) / dt; }
  return out;
}

// ---------------------------------------------------------------- cats
const CATS = {
  tmpBaseCat: { key: 'classy', row: 0, tail: ['#8a6f66', '#3b2b27'],
    poly: [[0.434, -0.745], [0.804, -0.66], [1.041, -0.448], [1.099, -0.281], [1.114, -0.072], [1.052, 0.147], [0.848, 0.361], [0.44, 0.554], [0.036, 0.62], [-0.175, 0.605], [-0.567, 0.461], [-0.842, 0.244], [-0.955, 0.067], [-0.995, -0.177], [-0.906, -0.466], [-0.692, -0.638], [-0.463, -0.719], [-0.105, -0.788]] },
  tmpTunCat: { key: 'digger', row: 1, tail: ['#b8773c', '#4a2c13'],
    poly: [[0.604, -0.96], [0.933, -0.889], [1.051, -0.657], [0.764, 0.794], [0.52, 0.902], [0.1, 0.92], [-0.174, 0.814], [-0.396, 0.412], [-0.77, 0.005], [-0.987, -0.543], [-0.913, -0.87], [-0.413, -0.935], [-0.038, -0.941], [0.291, -0.941]] },
  superPositionCat: { key: 'schro', row: 2, tail: ['#9a9a9a', '#3c3c3c'],
    poly: [[0.65, -0.775], [1.211, -0.406], [1.145, 0.807], [-0.446, 0.787], [-1.199, 0.333], [-1.045, -0.787]] },
  tmpUncertaintyCat: { key: 'fuzzy', row: 3, tail: ['#d4a88f', '#7b5446'],
    poly: [[-0.1, -1.06], [-0.07, -1.05], [-0.07, -1.02], [-0.1, -1.01], [-0.12, -1.03]] }
};
const IDLE_ANIM = [[0, 0.7], [1, .1], [2, .1], [3, .1], [4, .1], [5, .1], [6, .1], [7, .1]];
const DMG_ANIM = [[0, 0.1], [1, 0.9], [2, .1], [3, .1], [4, .1], [5, .1], [6, .1], [7, .1]];
const KITTEN_ANIM = [[0, 0.9], [1, .1], [2, .1], [3, .1], [4, .1], [5, .1], [6, .1], [7, .1]];
function animFrame(anim, t) {
  let total = 0; for (const a of anim) total += a[1];
  t = ((t % total) + total) % total;
  for (const a of anim) { if (t < a[1]) return a[0]; t -= a[1]; }
  return anim[0][0];
}

// ---------------------------------------------------------------- assets
const A = { spr: null, img: [], levels: null, snd: {}, ready: false };
async function loadAssets(progress) {
  // data.js / sfx.js are plain scripts so the game also runs when index.html is opened straight from disk
  const D = window.QC_DATA || {};
  const [spr, levels] = D.sprites && D.levels ? [D.sprites, D.levels] : await Promise.all([fetch('sprites.json').then(r => r.json()), fetch('levels.json').then(r => r.json())]);
  A.spr = spr.spr; A.levels = levels;
  let done = 0;
  await Promise.all(spr.tex.map((src, i) => new Promise(res => {
    const im = new Image(); im.onload = im.onerror = () => { done++; progress(done / spr.tex.length); res(); }; im.src = src; A.img[i] = im;
  })));
  A.ready = true;
}

// ---------------------------------------------------------------- audio
const Audio = {
  ctx: null, buf: {}, sfx: true, music: true, musicEl: null,
  names: ['CatAbility', 'cat-impact', 'cat-in-air', 'catLaunch-whoosh', 'glass-impact', 'glass-break', 'metal-impact', 'metal-break', 'IceBreak', 'WoodImpact', 'WoodBreak', 'kitten', 'laser_gun_shot', 'magnet_activation', 'helimExplode', 'ui-click', 'button-click', 'win-riff', 'loss-stinger'],
  unlock() {
    if (this.ctx) { if (this.ctx.state === 'suspended') this.ctx.resume(); return; }
    try { this.ctx = new (window.AudioContext || window.webkitAudioContext)(); } catch (e) { return; }
    const fromB64 = b64 => { const bin = atob(b64), u = new Uint8Array(bin.length); for (let i = 0; i < bin.length; i++) u[i] = bin.charCodeAt(i); return u.buffer; };
    const decode = buf => new Promise((res, rej) => { const pr = this.ctx.decodeAudioData(buf, res, rej); if (pr && pr.then) pr.then(res, rej); });
    for (const n of this.names) {
      const src = window.QC_SFX && window.QC_SFX[n] ? Promise.resolve(fromB64(window.QC_SFX[n])) : fetch('snd/' + n + '.mp3').then(r => r.arrayBuffer());
      src.then(decode).then(d => { this.buf[n] = d; }).catch(() => {});
    }
    this.musicEl = new window.Audio('snd/music.mp3'); this.musicEl.loop = true; this.musicEl.volume = 0.35;
    this.applyMusic();
  },
  applyMusic() { if (!this.musicEl) return; if (this.music) this.musicEl.play().catch(() => {}); else this.musicEl.pause(); },
  play(n, vol = 1, pitch = 1, delay = 0) {
    if (!this.sfx || !this.ctx || !this.buf[n]) return null;
    const s = this.ctx.createBufferSource(); s.buffer = this.buf[n]; s.playbackRate.value = pitch;
    const g = this.ctx.createGain(); g.gain.value = vol; s.connect(g).connect(this.ctx.destination);
    s.start(this.ctx.currentTime + delay); return s;
  }
};

// ---------------------------------------------------------------- render
const cv = document.getElementById('game'), ctx = cv.getContext('2d');
let W = 0, H = 0, DPR = 1;
function resize() {
  DPR = Math.min(window.devicePixelRatio || 1, 2);
  W = cv.clientWidth; H = cv.clientHeight; cv.width = Math.round(W * DPR); cv.height = Math.round(H * DPR);
}
window.addEventListener('resize', resize);

const M_ID = [1, 0, 0, 1, 0, 0];
function mmul(m, n) { return [m[0] * n[0] + m[2] * n[1], m[1] * n[0] + m[3] * n[1], m[0] * n[2] + m[2] * n[3], m[1] * n[2] + m[3] * n[3], m[0] * n[4] + m[2] * n[5] + m[4], m[1] * n[4] + m[3] * n[5] + m[5]]; }
function mTRS(x, y, a, sx = 1, sy = sx) { const c = Math.cos(a), s = Math.sin(a); return [c * sx, s * sx, -s * sy, c * sy, x, y]; }
let VIEW = M_ID;
function drawSprite(key, m, alpha = 1, flipX = false, tint = null) {
  const s = A.spr[key]; if (!s) return;
  const im = A.img[s[0]]; if (!im || !im.complete || !im.naturalWidth) return;
  const t = mmul(VIEW, m);
  const fx = flipX ? -1 : 1;
  ctx.setTransform(t[0] * fx, t[1] * fx, -t[2], -t[3], t[4], t[5]);
  ctx.globalAlpha = alpha;
  const x = -s[7] * s[5], y = -(1 - s[8]) * s[6];
  if (tint && key.includes('Rectangle')) { ctx.fillStyle = `rgb(${tint[0] * 255},${tint[1] * 255},${tint[2] * 255})`; ctx.fillRect(x, y, s[5], s[6]); }
  else ctx.drawImage(im, s[1], s[2], s[3], s[4], x, y, s[5], s[6]);
}
function sprSize(key) { const s = A.spr[key]; return s ? [s[5], s[6]] : [1, 1]; }

// ---------------------------------------------------------------- state
const UI = window.QCUI; // DOM layer (index.html)
let S = null;            // current level state
const SAVE = (() => { // saved settings are untrusted input: keep only known fields of the right type
  let raw = {}; try { raw = JSON.parse(localStorage.getItem('qc-save') || '{}'); } catch (e) {}
  const out = Object.create(null);
  if (!raw || typeof raw !== 'object') return out;
  if (raw.lang === 'en' || raw.lang === 'fr') out.lang = raw.lang;
  if (typeof raw.sfx === 'boolean') out.sfx = raw.sfx;
  if (typeof raw.music === 'boolean') out.music = raw.music;
  if (raw.best && typeof raw.best === 'object') {
    out.best = {};
    for (let i = 0; i < 10; i++) { const v = raw.best[i]; if (Number.isFinite(v) && v >= 0 && v < 1e9) out.best[i] = Math.floor(v); }
  }
  return out;
})();
function persist() { try { localStorage.setItem('qc-save', JSON.stringify(SAVE)); } catch (e) {} }
Audio.sfx = SAVE.sfx !== false; Audio.music = SAVE.music !== false;

// ---------------------------------------------------------------- level objects
class Thing { // anything with a physics body and sprites
  constructor(def, body) { this.def = def; this.body = body; this.sprites = def.sprites || []; this.kind = def.kind || def.tag || 'static'; this.alive = true; body.userData = this; }
  get x() { return this.body.xf.px; } get y() { return this.body.xf.py; }
  matrix() { const xf = this.body.xf; return [xf.c, xf.s, -xf.s, xf.c, xf.px, xf.py]; }
  drawItems(out) {
    const M = this.matrix();
    for (const s of this.sprites) out.push({ L: s.L, o: s.o, f: () => drawSprite(s.s, mmul(M, s.m), s.c ? s.c[3] : 1, !!s.fx) });
  }
  onCollide() {}
  update() {}
}
const POINTS = [[100, 'Sprites/_TEMP/Points_100.png#21300000'], [200, 'Sprites/_TEMP/Points_200.png#21300000'], [400, 'Sprites/_TEMP/Points_400.png#21300000'], [500, 'Sprites/_TEMP/Points_500.png#21300000'], [800, 'Sprites/_TEMP/Points_800.png#21300000']];
class LevelObj extends Thing {
  constructor(def, body) {
    super(def, body);
    const p = def.props || {};
    this.isBox = def.kind === 'KittenBox';
    this.mat = this.isBox ? 2 : p.m_MaterialType; // 0 glass 1 metal 2 box
    this.mod = p.m_DamageModifier ?? 0.1;
    this.score = p.score ?? 100;
    this.health = p.m_StartBroken ? 49.9 : 100;
    this.state = 'healthy';
    this.spr = { h: p.m_HealthySprite, d: p.m_DamagedSprite, f: p.m_FrozenSprite };
    this.mainSprite = this.sprites[0];
    if (p.m_StartBroken && this.mainSprite) this.mainSprite.s = this.spr.d;
    this.destructSprite = p.DestructSprite;
    if (!this.destructSprite || !A.spr[this.destructSprite]) { const sc = this.score; this.destructSprite = (POINTS.find(q => sc <= q[0]) || POINTS[4])[1]; }
    this.minK = p.minKittens ?? 2; this.maxK = p.maxKittens ?? 6;
  }
  damage(d) { this.health -= d; }
  onCollide(other, rv, ob) {
    // Kitten boxes are a little more fragile than in the Unity game: they react to softer hits,
    // and landing on the floor or other fixed scenery hurts them like hitting a 1 kg object.
    if (rv > (this.isBox ? 4.5 : 6)) {
      if (ob.type !== STATIC || ob.hasRB) {
        this.health -= Math.trunc(0.5 * ob.mass * rv * rv * this.mod);
        if (this.health > 0) this.impactSound();
      } else if (this.isBox) { this.health -= Math.trunc(0.625 * rv * rv * this.mod); if (this.health > 0) this.impactSound(); }
      else { this.impactSound(); this.health -= Math.trunc(rv * this.mod); }
    }
  }
  takeDamage(v, mass) { // KittenBox.TakeDamage (tunnelling cat)
    if (v > 2) { this.health -= Math.trunc(0.5 * mass * v * v * this.mod); if (this.health > 0) this.impactSound(); }
  }
  impactSound() { if (!S.audible(this.x)) return; Audio.play(['glass-impact', 'metal-impact', 'WoodImpact'][this.mat] || 'glass-impact', this.isBox ? 1 : 0.25, rand(0.8, 1.4)); }
  freeze() { if (!this.alive) return; this.state = 'frozen'; if (this.mainSprite && this.spr.f && A.spr[this.spr.f]) this.mainSprite.s = this.spr.f; this.frozen = true; this.mod *= 200; }
  update() {
    if (!this.alive) return;
    if (this.health <= 50 && this.state === 'healthy') { this.state = 'damaged'; if (this.mainSprite && this.spr.d) this.mainSprite.s = this.spr.d; }
    if (this.health <= 0) this.destroy();
  }
  destroy() {
    if (!this.alive) return; this.alive = false;
    const x = this.x, y = this.y;
    for (const cb of this.onDestroyed || []) cb();
    S.world.destroyBody(this.body);
    S.removeThing(this);
    S.addScore(this.score);
    // break effect
    const shard = this.isBox ? (this.frozen ? 'Sprites/_TEMP/FrozenBoxShard.png#21300000' : 'Sprites/_TEMP/BoxShard.png#21300000')
      : this.mat === 0 ? (this.frozen ? 'Sprites/Objects/Glass_Shard_FRZ.png#21300000' : 'Sprites/Objects/Glass_Shard.png#21300000')
        : (this.frozen ? 'Sprites/Objects/Metal_Shard_FRZ.png#21300000' : 'Sprites/Objects/Metal_Shard.png#21300000');
    const n = this.isBox ? 14 : 9;
    for (let i = 0; i < n; i++) {
      const a = rand(0, Math.PI * 2), sp = rand(2, 7);
      S.fx.push(new Particle(shard, x + rand(-0.5, 0.5), y + rand(-0.4, 0.4), Math.cos(a) * sp, Math.sin(a) * sp + 3, rand(0.6, 1.4), { scale: rand(0.25, 0.55), grav: 12, spin: rand(-8, 8), fade: 0.5 }));
    }
    if (S.audible(x)) Audio.play(this.frozen ? 'IceBreak' : (['glass-break', 'metal-break', 'WoodBreak'][this.mat] || 'glass-break'), this.isBox ? 1 : 0.6, rand(0.9, 1.15));
    S.fx.push(new Particle(this.destructSprite, x, y + 0.5, 0, 1.4, 1.3, { L: 9, o: 50, scale: 1, fade: 0.6, grow: 0.3 }));
    if (this.isBox) {
      const nk = randInt(this.minK, this.maxK);
      for (let i = 0; i < nk; i++) { const o = insideUnitCircle(); S.kittens.push(new Kitten(x + o[0], y + o[1])); }
      S.boxBroken(this.score);
    }
  }
}
class Laser extends Thing {
  constructor(def, body) {
    super(def, body);
    const p = def.props; this.dmg = p.damage ?? 600; this.duration = p.duration ?? 1; this.on = false; this.fired = false; this.used = false;
    this.used0 = p.usedSprite; this.anch = def.anchors; this.beamSprite = this.sprites.find(s => s.s.includes('_TEMP/Laser.png'));
    this.indicator = this.sprites.find(s => s.s.includes('DualAlphaCutoff'));
    this.sprites = this.sprites.filter(s => s !== this.beamSprite && s !== this.indicator);
    this.rotTarget = body.a - 20 * Math.PI / 180; this.beamLen = 0; this.t = 0;
  }
  fire() {
    if (this.fired) return; this.on = true; this.fired = true; this.t = 0;
    Audio.play('laser_gun_shot', 0.6); S.cam.follow(this, false);
  }
  onCollide(other, rv) { if (rv > 1 || (other instanceof Cat && other.type === 'fuzzy')) this.fire(); }
  wasHit(v) { if (v > 1) this.fire(); }
  delayedActivate() {}  // Unity's Invoke("activate") cannot call activate(float), so this never fired
  step(dt) {
    if (!this.on) {
      if (this.fired && !this.used) { this.used = true; if (this.sprites[0] && this.used0) this.sprites[0].s = this.used0; S.fx.push(new Smoke(this, 'AimEnd')); }
      if (this.used && Math.abs(this.body.a - this.rotTarget) > 0.001) {
        const a = this.body.a + (this.rotTarget - this.body.a) * Math.min(1, dt);
        this.body.setTransform(this.body.xf.px, this.body.xf.py, a);
      }
      return;
    }
    this.t += dt;
    const xf = this.body.xf;
    const as = this.anch.AimStart, ae = this.anch.AimEnd;
    const sx = xf.px + xf.c * as[0] - xf.s * as[1], sy = xf.py + xf.s * as[0] + xf.c * as[1];
    const ex = xf.px + xf.c * ae[0] - xf.s * ae[1], ey = xf.py + xf.s * ae[0] + xf.c * ae[1];
    let dx = sx - ex, dy = sy - ey; const l = Math.hypot(dx, dy) || 1; dx /= l; dy /= l;
    const hits = S.world.rayCastAll(sx, sy, sx + dx * 100, sy + dy * 100, sh => !sh.sensor && sh.body !== this.body && !(sh.body.userData instanceof Cat));
    let hit = hits[0], i = 0;
    if (hit) {
      const o = hit.body.userData;
      if (o && o.delayedActivate) o.delayedActivate();
      let dead = false;
      if (o instanceof LevelObj) { o.damage(this.dmg * dt); dead = o.health <= 0; }
      if (dead && hits[1]) { i = 1; }
      hit = hits[i];
      this.beamLen = hit.distance;
      if (Math.random() < 0.3) S.fx.push(new Particle('Sprites/_TEMP/Dust.png#21300000', hit.x, hit.y, rand(-3, 3), rand(0, 4), 0.4, { L: 9, scale: rand(0.3, 0.6), grav: 6, tint: 'spark', fade: 1 }));
    } else this.beamLen = 100;
    this.beamFrom = [sx, sy]; this.beamDir = [dx, dy];
    if (this.t > this.duration) { this.on = false; S.cam.free(false, this); }
  }
  drawItems(out) {
    super.drawItems(out);
    const M = this.matrix();
    if (!this.fired && this.indicator) out.push({ L: this.indicator.L, o: this.indicator.o + 1, f: () => drawSprite(this.indicator.s, mmul(M, this.indicator.m), 0.35 + 0.35 * Math.sin(S.time * 5)) });
    if (this.on && this.beamFrom) {
      const [sx, sy] = this.beamFrom, [dx, dy] = this.beamDir, len = this.beamLen;
      out.push({ L: 9, o: 0, f: () => {
        const t = mmul(VIEW, [dx, dy, -dy, dx, sx, sy]);
        ctx.setTransform(t[0], t[1], t[2], t[3], t[4], t[5]); ctx.globalAlpha = 1;
        const w = 0.22 + 0.05 * Math.sin(S.time * 60);
        ctx.fillStyle = 'rgba(255,40,60,0.45)'; ctx.fillRect(0, -w * 1.8, len, w * 3.6);
        ctx.fillStyle = '#ff3b4f'; ctx.fillRect(0, -w, len, w * 2);
        ctx.fillStyle = '#fff4f4'; ctx.fillRect(0, -w * 0.35, len, w * 0.7);
      } });
    }
  }
}
class Magnet extends Thing {
  constructor(def, body) { super(def, body); const p = def.props; this.radius = p.radius ?? 10; this.maxForce = p.maxForce ?? 400; this.duration = p.duration ?? 1; this.used0 = p.usedSprite; this.used = false; this.pulling = false; this.indicator = this.sprites.find(s => s.s.includes('DualAlphaCutoff')); this.pullSprite = this.sprites.find(s => s.s.includes('magnetImplosion')); this.sprites = this.sprites.filter(s => s !== this.indicator && s !== this.pullSprite); }
  activate() { if (this.used) return; this.used = true; this.pulling = true; this.t = 0; Audio.play('magnet_activation', 1); }
  onCollide(o, rv) { if (rv > 7) this.activate(); }
  wasHit(v) { if (v > 1) this.activate(); }
  delayedActivate() {}
  step(dt) {
    if (!this.pulling) return;
    this.t += dt;
    if (this.t > this.duration) { this.pulling = false; if (this.sprites[0] && this.used0) this.sprites[0].s = this.used0; S.fx.push(new Smoke(this)); return; }
    const cx = this.x, cy = this.y;
    for (const th of S.things) {
      if (!(th instanceof LevelObj) || th.mat !== 1 || !th.alive) continue;
      const d = Math.hypot(th.x - cx, th.y - cy); if (d > this.radius) continue;
      const k = (this.radius - d) / this.radius * this.maxForce * 0.3; // Unity applied this once per rendered frame
      th.body.applyForce((cx - th.x) * k, (cy - th.y) * k);
    }
  }
  drawItems(out) {
    super.drawItems(out); const M = this.matrix();
    if (!this.used && this.indicator) out.push({ L: this.indicator.L, o: this.indicator.o + 1, f: () => drawSprite(this.indicator.s, mmul(M, this.indicator.m), 0.35 + 0.35 * Math.sin(S.time * 5)) });
    if (this.pulling) { const k = this.radius * (1 - this.t / this.duration); out.push({ L: 9, o: 0, f: () => drawSprite('Sprites/_TEMP/magnetImplosion.png#21300000', mTRS(this.x, this.y, 0, k / sprSize('Sprites/_TEMP/magnetImplosion.png#21300000')[0] * 2), Math.min(1, 0.2 + this.t / this.duration)) }); }
  }
}
class Helium extends Thing {
  constructor(def, body) { super(def, body); const p = def.props; this.radius = p.radius ?? 8; this.speed = p.speed ?? 20; this.exploding = false; this.done = false; this.indicator = this.sprites.find(s => s.s.includes('DualAlphaCutoff')); this.circle = this.sprites.find(s => s.s.includes('IceExplosion')); this.sprites = this.sprites.filter(s => s !== this.indicator && s !== this.circle); }
  onCollide(o, rv) { if (rv > 7 && !this.exploding) this.explode(); }
  wasHit(v) { if (v > 1 && !this.exploding) this.explode(); }
  delayedActivate() { if (!this.pending && !this.exploding) { this.pending = 1.0; } }
  explode() {
    if (this.exploding || this.done) return; this.exploding = true; this.scale = 0; this.alpha = 1;
    this.ex = this.x; this.ey = this.y; S.world.wakeAround(this.body); this.body.enabled = false;
    Audio.play('helimExplode', 1); S.cam.shake(0.5, 0.7);
    for (let i = 0; i < 12; i++) { const a = rand(0, 6.28), sp = rand(2, 6); S.fx.push(new Particle('Sprites/_TEMP/Dust.png#21300000', this.ex, this.ey, Math.cos(a) * sp, Math.sin(a) * sp, 0.7, { L: 9, scale: rand(0.6, 1.2), tint: 'ice', fade: 1, grow: 1.5 })); }
    for (const th of S.things) {
      if (th === this || th.body.type !== DYNAMIC) continue;
      const dx = th.x - this.ex, dy = th.y - this.ey;
      if (Math.hypot(dx, dy) < 2 + 0.5) th.body.applyImpulse(dx * 2.5, dy * 2.5);
    }
  }
  step(dt) {
    if (this.pending !== undefined && this.pending !== null) { this.pending -= dt; if (this.pending <= 0) { this.pending = null; this.explode(); } }
    if (!this.exploding) return;
    if (this.scale <= this.radius) { this.scale += this.speed * dt; this.alpha -= this.speed / this.radius * dt; }
    else {
      this.exploding = false; this.done = true;
      const hit = new Set(S.world.overlapCircle(this.ex, this.ey, this.radius).map(s => s.body.userData));
      for (const th of hit) if (th instanceof LevelObj) th.freeze();
      S.world.destroyBody(this.body); S.removeThing(this);
    }
  }
  drawItems(out) {
    if (this.exploding) { const k = this.scale; out.push({ L: 9, o: 0, f: () => drawSprite('Sprites/_TEMP/IceExplosion.png#21300000', mTRS(this.ex, this.ey, 0, k), Math.max(0, this.alpha)) }); return; }
    super.drawItems(out); const M = this.matrix();
    if (this.indicator) out.push({ L: this.indicator.L, o: this.indicator.o + 1, f: () => drawSprite(this.indicator.s, mmul(M, this.indicator.m), 0.35 + 0.35 * Math.sin(S.time * 5)) });
  }
}
class Geo extends Thing {
  drawItems(out) {
    const M = this.matrix(), shapes = this.def.shapes.filter(s => !s.trig && s.t === 'poly');
    out.push({ L: 5, o: 10, f: () => {
      const t = mmul(VIEW, M); ctx.setTransform(t[0], t[1], t[2], t[3], t[4], t[5]); ctx.globalAlpha = 1;
      ctx.fillStyle = '#2b2b2b'; ctx.strokeStyle = '#151515'; ctx.lineWidth = 0.08; ctx.lineJoin = 'round';
      for (const s of shapes) { ctx.beginPath(); s.p.forEach((p, i) => i ? ctx.lineTo(p[0], p[1]) : ctx.moveTo(p[0], p[1])); ctx.closePath(); ctx.fill(); ctx.stroke(); }
    } });
  }
}

// ---------------------------------------------------------------- effects
class Particle {
  constructor(spr, x, y, vx, vy, life, o = {}) { Object.assign(this, { spr, x, y, vx, vy, life, max: life, a: rand(0, 6.28), spin: 0, scale: 1, grav: 0, fade: 0, grow: 0, L: 9, o: 0 }, o); }
  step(dt) { this.vy -= this.grav * dt; this.x += this.vx * dt; this.y += this.vy * dt; this.a += this.spin * dt; this.life -= dt; this.scale += this.grow * dt; return this.life > 0; }
  drawItems(out) {
    const t = this.life / this.max; const al = this.fade ? Math.min(1, t / this.fade) : 1;
    out.push({ L: this.L, o: this.o, f: () => {
      if (this.tint === 'spark' || this.tint === 'ice') {
        const tt = mmul(VIEW, mTRS(this.x, this.y, 0, this.scale)); ctx.setTransform(tt[0], tt[1], tt[2], tt[3], tt[4], tt[5]);
        ctx.globalAlpha = al * 0.8; ctx.fillStyle = this.tint === 'spark' ? '#ffd2a0' : '#cdeeff';
        ctx.beginPath(); ctx.arc(0, 0, 0.3, 0, 6.29); ctx.fill(); return;
      }
      drawSprite(this.spr, mTRS(this.x, this.y, this.spr.includes('Points_') ? 0 : this.a, this.scale), al);
    } });
  }
}
class Smoke {
  constructor(thing, anchor) { this.thing = thing; this.anchor = anchor; this.t = 0; this.acc = 0; }
  step(dt) {
    this.t += dt; this.acc += dt;
    if (this.acc > 0.12) {
      this.acc = 0; const th = this.thing; let x = th.x, y = th.y;
      if (this.anchor && th.anch) { [x, y] = th.body.toWorld(...th.anch[this.anchor]); }
      S.fx.push(new Particle('Sprites/_TEMP/Dust.png#21300000', x, y, rand(-0.3, 0.3), rand(0.8, 1.5), 2.2, { L: 9, scale: rand(0.4, 0.7), grow: 0.6, fade: 2, o: -1, tint: null }));
    }
    return this.t < 6;
  }
  drawItems() {}
}
class Kitten {
  constructor(x, y) {
    this.x = x; this.y = y; this.fall = 0; this.hitGround = false; this.t = rand(0, 2);
    this.jump = rand(1.5, 2); this.alive = true;
    Audio.play('kitten', 0.8, rand(0.9, 1.5), rand(0, 1.7));
  }
  step(dt) {
    const gy = S.groundY, side = S.sidePos;
    this.t += dt;
    if (!this.hitGround) {
      if (Math.abs(gy - this.y) < 0.1 || this.y < gy) { this.hitGround = true; this.y = Math.max(this.y, gy); }
      else { this.y -= this.fall * dt; if (this.fall < 10) this.fall += 10 * dt; }
    } else {
      let dx = side[0] - this.x, dy = side[1] - this.y; const l = Math.hypot(dx, dy) || 1;
      this.x += dx / l * 5 * dt; this.y += dy / l * 5 * dt + this.jump * dt; this.jump -= 5 * dt;
      if (this.y <= gy) this.jump = rand(1.5, 2);
      if (l < 0.1 || this.x < side[0]) this.alive = false;
    }
    return this.alive;
  }
  drawItems(out) { const f = animFrame(KITTEN_ANIM, this.t); out.push({ L: 6, o: 20, f: () => drawSprite('Sprites/Objects/kitten_128_sheet.png#kitten_128_sheet_' + f, mTRS(this.x, this.y, 0), 1, true) }); }
}

// ---------------------------------------------------------------- cats
class Cat {
  constructor(tpl, x, y) {
    this.tpl = tpl; this.def = CATS[tpl]; this.type = this.def.key;
    this.state = 'waiting'; this.t = rand(0, 1.4); this.scaleX = 1; this.stretchV = 0; this.airT = 0;
    this.waitHeight = 0; this.up = false; this.yInitial = y; this.impacts = 0;
    const b = S.world.createBody({ type: DYNAMIC, x, y, mass: 1, angularDamping: 5 });
    b.addShape({ poly: Phys.hull(this.def.poly), friction: 0.4, restitution: 0, cat: CAT_BIT, mask: 0xffff & ~CAT_BIT });
    b.finalize(); b.userData = this; this.body = b; b.hasRB = true;
    this.tail = []; for (let i = 0; i < 6; i++) this.tail.push({ x: x - 1 - i * 0.3, y, px: x - 1 - i * 0.3, py: y });
    this.hidden = false; this.preV = [0, 0];
  }
  get x() { return this.body.xf.px; } get y() { return this.body.xf.py; }
  get speed() { return Math.hypot(this.body.vx, this.body.vy); }
  name() { return T('cat-type-' + this.type); }
  setScripted(on) { this.body.enabled = !on; if (on) { this.body.vx = this.body.vy = this.body.w = 0; } else this.body.wake(); }
  // physics-step logic
  step(dt) {
    this.preV = [this.body.vx, this.body.vy];
    if (this.state === 'waiting' && !this.swapping && !this.scripted) {
      if (!this.waitHeight) this.waitHeight = rand(0.25, 0.5);
      if (this.up) this.body.setVelocity(0, 3);
      if (this.y >= this.yInitial + this.waitHeight) { this.up = false; this.waitHeight = 0; }
    }
    if (this.state === 'inair') this.updateInAir(dt);
    else if (this.state === 'contact') {
      this.contactT = (this.contactT || 0) + dt;
      if (this.speed < 0.003 || !this.body.awake || this.contactT > 12) this.stop(true);
    }
    if (this.state !== 'dead' && (this.state === 'inair' || this.state === 'contact')) {
      if (this.x < S.bounds[0] || this.x > S.bounds[1] || this.y < -40) { if (this.state === 'inair') this.madeContact(0); this.stop(false); }
    }
  }
  updateInAir(dt) {
    const b = this.body; this.airT += dt;
    if (!this.frozen) {
      const ang = Math.atan2(b.vy, b.vx);
      b.a = ang; b.w = 0; b.syncXf();
      const o = this;
      if (this.airT > 0.4) spring(o, 'scaleX', 'stretchV', 1, 0.3, 4 * Math.PI, dt);
      else spring(o, 'scaleX', 'stretchV', lerp(1, 1.25, this.speed / 40), 0.1, 2 * Math.PI, dt);
    }
  }
  fired() { this.state = 'inair'; this.airT = 0; this.flight = Audio.play('cat-in-air', 0.5, rand(1, 1.2)); }
  onCollide(other, rv, ob) {
    if (other instanceof Cat) return;
    if (this.state === 'inair' && this.flight) { try { this.flight.stop(); } catch (e) {} this.flight = null; }
    if (this.state !== 'waiting' && rv > 6 && this.impacts < 3) { this.impacts++; Audio.play('cat-impact', 1, rand(1, 1.2)); }
    if (this.state === 'waiting') this.up = true;
    if (this.state === 'inair') {
      if (rv > 1) for (let i = 0; i < 4; i++) S.fx.push(new Particle('Sprites/_TEMP/Dust.png#21300000', this.x + rand(-0.5, 0.5), this.y + rand(-0.6, 0), rand(-1.5, 1.5), rand(0, 1.5), 0.6, { L: 9, scale: rand(0.4, 0.8), grow: 0.8, fade: 0.6 }));
      this.madeContact(rv);
    }
    if (other instanceof LevelObj) {
      const v = this.preV;
      const restore = () => { if (this.state !== 'dead') this.body.setVelocity(v[0] * 0.8, v[1] * 0.8); };
      if (!other.alive) restore(); else (other.onDestroyed = other.onDestroyed || []).push(restore), S.clearCallbacks.push(other);
    }
  }
  madeContact(impact) {
    if (this.state !== 'inair') return;
    this.state = 'contact'; this.scaleX = 1; this.damaged = true; this.t = 0;
    S.catContact(this, impact);
  }
  stop(dust) {
    if (this.state === 'dead') return;
    if (dust) for (let i = 0; i < 8; i++) S.fx.push(new Particle('Sprites/_TEMP/Dust.png#21300000', this.x + rand(-0.6, 0.6), this.y + rand(-0.6, 0.6), rand(-1, 1), rand(0, 1.5), 0.8, { L: 9, scale: rand(0.5, 0.9), grow: 1, fade: 0.8 }));
    this.state = 'dead';
    if (this.flight) { try { this.flight.stop(); } catch (e) {} }
    S.world.destroyBody(this.body);
    S.catStopped(this);
  }
  tailAnchor() { return this.body.toWorld(-0.9 * Math.sign(this.scaleX || 1), -0.15); }
  frameTick(dt) {
    this.t += dt;
    // verlet tail
    const [ax, ay] = this.tailAnchor();
    const seg = 0.32;
    this.tail[0].x = ax; this.tail[0].y = ay;
    for (let i = 1; i < this.tail.length; i++) {
      const p = this.tail[i]; const vx = (p.x - p.px) * 0.9, vy = (p.y - p.py) * 0.9;
      p.px = p.x; p.py = p.y; p.x += vx; p.y += vy + (this.state === 'inair' ? 0 : 0.6 * dt) - 0.2 * dt;
      // curl upward like the idle tail
      p.y += 1.6 * dt * (1 - i / this.tail.length);
    }
    for (let k = 0; k < 4; k++) for (let i = 1; i < this.tail.length; i++) {
      const a = this.tail[i - 1], b = this.tail[i]; const dx = b.x - a.x, dy = b.y - a.y, l = Math.hypot(dx, dy) || 1, d = (l - seg) / l;
      if (i === 1) { b.x -= dx * d; b.y -= dy * d; } else { a.x += dx * d * 0.5; a.y += dy * d * 0.5; b.x -= dx * d * 0.5; b.y -= dy * d * 0.5; }
    }
  }
  sheetKey() {
    const row = this.def.row;
    if (this.damaged) return 'Sprites/Animations/Cats_damaged_Sheet_256_v1b.png#Cats_damaged_Sheet_256_v1b_' + (row * 8 + animFrame(DMG_ANIM, this.t));
    return 'Sprites/Animations/Cats_Idle_Sheet_256_v1b.png#Cats_Idle_Sheet_256_v1b_' + (row * 8 + animFrame(IDLE_ANIM, this.t));
  }
  drawItems(out) {
    if (this.state === 'dead') return;
    if (!this.hidden) {
      const tail = this.tail, col = this.def.tail;
      out.push({ L: 7, o: 0, f: () => {
        const t = VIEW; ctx.setTransform(t[0], t[1], t[2], t[3], t[4], t[5]); ctx.globalAlpha = 1;
        ctx.lineCap = 'round'; ctx.lineJoin = 'round';
        for (const [w, c] of [[0.34, col[1]], [0.24, col[0]]]) {
          ctx.lineWidth = w; ctx.strokeStyle = c; ctx.beginPath();
          tail.forEach((p, i) => i ? ctx.lineTo(p.x, p.y) : ctx.moveTo(p.x, p.y)); ctx.stroke();
        }
      } });
      const xf = this.body.xf;
      const M = mmul([xf.c, xf.s, -xf.s, xf.c, xf.px, xf.py], [this.scaleX, 0, 0, 1, 0, 0]);
      const k = this.sheetKey();
      const flip = this.state === 'inair' && Math.cos(this.body.a) < 0 ? 0 : 0;
      out.push({ L: 8, o: this.selected ? 5 : 0, f: () => drawSprite(k, M, this.alpha ?? 1, !!flip) });
    }
    if (this.cloud) {
      const r = this.radius;
      out.push({ L: 9, o: 1, f: () => {
        for (const q of this.cloud) {
          const x = this.x + q[0] * r * 0.55, y = this.y + q[1] * r * 0.55;
          drawSprite('Sprites/_TEMP/UncertaintyParticle.png#21300000', mTRS(x, y, q[2] + S.time * q[3], 0.9 + 0.3 * Math.sin(S.time * 3 + q[2])), 0.35);
        }
      } });
    }
  }
}
class TunnelCat extends Cat {
  updateInAir(dt) {
    super.updateInAir(dt);
    if (this.used) return;
    const b = this.body, sp = this.speed; if (sp < 0.01) return;
    const dx = b.vx / sp, dy = b.vy / sp;
    const isTarget = s => !s.sensor && s.body.hasRB && !(s.body.userData instanceof Cat) && s.body.enabled;
    let found = false;
    for (let d = 0; d <= 1.4001 && !found; d += 0.35) if (S.world.overlapCircle(this.x + dx * d, this.y + dy * d, 1.2, isTarget).length) found = true;
    if (!found) return;
    // find safe place on the other side
    let dist = 1.4, r = 1.2, nx = this.x, ny = this.y;
    for (let i = 0; i < 100; i++) {
      nx = this.x + dx * dist; ny = this.y + dy * dist;
      if (!S.world.overlapCircle(nx, ny, r, s => !s.sensor && s.body !== b && !(s.body.userData instanceof Cat)).length) break;
      dist += 0.1; r -= 0.01;
    }
    S.fx.push(new TunnelFx(this.x, this.y, b.a)); S.fx.push(new TunnelFx(nx, ny, b.a));
    for (const h of S.world.rayCastAll(this.x, this.y, nx, ny, s => !s.sensor)) {
      const o = h.body.userData;
      if (o && o.wasHit) o.wasHit(sp);
      if (o instanceof LevelObj && o.isBox) o.takeDamage(sp, b.mass);
    }
    Audio.play('CatAbility', 0.3);
    b.setTransform(nx - (b.xf.px - b.cx) * 0, ny, b.a); b.cx = nx; b.cy = ny; b.syncXf();
    this.used = true; S.trailDot(true);
  }
}
class TunnelFx {
  constructor(x, y, a) { this.x = x; this.y = y; this.a = a; this.t = 0; }
  step(dt) { this.t += dt; return this.t < 0.5; }
  drawItems(out) { const f = Math.min(2, Math.floor(this.t / 0.5 * 3)); out.push({ L: 9, o: 2, f: () => drawSprite('Sprites/_TEMP/TunnelEffect.png#TunnelEffect_' + f, mTRS(this.x, this.y, this.a, 1.6), 1 - this.t / 0.5) }); }
}
class SuperCat extends Cat {
  updateInAir(dt) {
    if (!this.tripped) super.updateInAir(dt);
    if (this.tripped) return;
    const b = this.body, sp = this.speed; if (sp < 0.01) return;
    const dx = b.vx / sp, dy = b.vy / sp;
    // raycast 2 units ahead for a body; or the 3x2 trigger box touching anything solid
    let trip = S.world.rayCastAll(this.x, this.y, this.x + dx * 2, this.y + dy * 2, s => !s.sensor && s.body !== b && s.body.hasRB && !(s.body.userData instanceof SuperCat) && s.body.enabled).length > 0;
    if (!trip) {
      const xf = b.xf;
      for (const [lx, ly] of [[1.51, 0], [1.51, 1.0], [1.51, -1.0], [0, -1.0], [0, 1.0], [-1.51, -1.0]]) {
        const wx = xf.px + xf.c * lx - xf.s * ly, wy = xf.py + xf.s * lx + xf.c * ly;
        if (S.world.overlapCircle(wx, wy, 0.05, s => !s.sensor && s.body !== b && !(s.body.userData instanceof Cat) && s.body.enabled).length) { trip = true; break; }
      }
    }
    if (trip) S.superTrip();
  }
  freeze() { this.tripped = true; this.preFrozen = [this.body.vx, this.body.vy]; this.body.vx = this.body.vy = this.body.w = 0; this.body.gravityScale = 0; this.selectable = true; }
  release() { this.selectable = false; this.body.gravityScale = 1; this.body.setVelocity(this.preFrozen[0], this.preFrozen[1]); }
  onCollide(other, rv, ob) {
    super.onCollide(other, rv, ob);
    if (this.state === 'contact' && !this.tripped && !this.powerUsed && !(other instanceof Cat)) S.superTrip(this);
  }
  drawItems(out) {
    super.drawItems(out);
    if (this.selectable) {
      out.push({ L: 9, o: 9, f: () => drawSprite('Sprites/_TEMP/Ring.png#21300000', mTRS(this.x, this.y, 0, 1.0 + 0.15 * Math.sin(performance.now() / 120)), 0.9) });
      const sc = S.superCats || [];
      if (S.kbUsed && sc[(S.kbSuper || 0) % sc.length] === this) out.push({ L: 9, o: 10, f: () => {
        const t = mmul(VIEW, mTRS(this.x, this.y, 0, 1)); ctx.setTransform(t[0], t[1], t[2], t[3], t[4], t[5]); ctx.globalAlpha = 1;
        ctx.strokeStyle = '#ffd400'; ctx.lineWidth = 0.22; ctx.beginPath(); ctx.arc(0, 0, 1.75, 0, 6.29); ctx.stroke();
      } });
    }
  }
}
class FuzzyCat extends Cat {
  constructor(...a) { super(...a); this.radius = 2; }
  fired() { super.fired(); this.radius = 2; this.ghost = true; this.body.shapes[0].mask = 0; S.setClicker(this); }
  updateInAir(dt) {
    const b = this.body;
    if (!this.abilityUsed) {
      this.radius = lerp(this.radius, 10, dt);
      if (this.radius > 4 && !this.cloud) { this.hidden = true; this.cloud = Array.from({ length: 26 }, () => { const o = insideUnitCircle(); return [o[0], o[1], rand(0, 6), rand(-1, 1)]; }); }
    }
    if (!this.frozen) super.updateInAir(dt);
    if (this.ghost && !this.abilityUsed) { // floor check: materialise when the floor is near
      const hits = S.world.rayCastAll(this.x, this.y, this.x, this.y - 5, s => s.body.userData && s.body.userData.kind === 'Floor');
      if (hits.length) { this.enable(); this.madeContact(0); }
    }
  }
  enable() { this.hidden = false; this.cloud = null; this.ghost = false; this.body.shapes[0].cat = CAT_BIT; this.body.shapes[0].mask = 0xffff & ~CAT_BIT; }
  tap() {
    if (this.abilityUsed || this.state !== 'inair') return;
    this.abilityUsed = true; S.setClicker(null);
    this.pickT = rand(-0.25, 0.5); this.switchT = 0;
    S.pause(true, 'fuzzy');
    const cand = new Set(S.world.overlapCircle(this.x, this.y, this.radius * 1.1, s => s.body !== this.body && s.body.type === DYNAMIC && !(s.body.userData instanceof Cat) && s.body.userData && s.body.userData.kind !== 'Floor').map(s => s.body.userData));
    const list = [...cand].map(o => ({ o, d: Math.hypot(o.x - this.x, o.y - this.y) })).filter(q => q.d <= 10).sort((p, q) => p.d - q.d).slice(0, 6);
    this.targets = list.map(q => q.o); this.pick = 0;
    if (!this.targets.length) { this.shoot(); }
  }
  pickStep(udt) {
    if (!this.targets || this.shot) return;
    this.pickT += udt;
    if (this.pickT >= 2.0) { this.shoot(); return; }
    this.switchT -= udt;
    if (this.switchT <= 0) { this.switchT = 0.1; this.pick = randInt(0, this.targets.length); Audio.play('button-click', 0.25, rand(0.9, 1.3)); }
  }
  shoot() {
    if (this.shot) return; this.shot = true;
    Audio.play('CatAbility', 0.4);
    S.pause(false);
    const o = insideUnitCircle(); let nx = this.x + o[0] * this.radius / 2, ny = this.y + o[1] * this.radius / 2;
    if (ny < S.groundY + 1.1) ny = S.groundY + 1.1;
    const b = this.body; b.cx = nx; b.cy = ny; b.syncXf();
    const tgt = this.targets && this.targets[this.pick];
    const sp = rand(20, 50);
    if (tgt && tgt.alive !== false) { const dx = tgt.x - nx, dy = tgt.y - ny, l = Math.hypot(dx, dy) || 1; b.setVelocity(dx / l * sp, dy / l * sp); }
    else b.setVelocity(rand(-1, 1) * sp, rand(-1, 0) * sp);
    this.targetShown = tgt; this.targets = null; this.enable(); S.trailDot(true);
  }
  onCollide(other, rv, ob) { this.targetShown = null; super.onCollide(other, rv, ob); }
  drawItems(out) {
    super.drawItems(out);
    const ts = this.targets ? this.targets : this.targetShown && this.state === 'inair' ? [this.targetShown] : [];
    ts.forEach((t, i) => { if (!t || t.alive === false) return; const hl = !this.targets || i === this.pick; out.push({ L: 9, o: 10, f: () => {
      const tt = mmul(VIEW, mTRS(t.x, t.y, 0, 1)); ctx.setTransform(tt[0], tt[1], tt[2], tt[3], tt[4], tt[5]); ctx.globalAlpha = 0.9;
      ctx.strokeStyle = hl ? '#1fe05a' : '#ff3030'; ctx.lineWidth = 0.18; ctx.beginPath(); ctx.arc(0, 0, 0.9, 0, 6.29); ctx.stroke();
      ctx.beginPath(); ctx.moveTo(-1.2, 0); ctx.lineTo(-0.5, 0); ctx.moveTo(1.2, 0); ctx.lineTo(0.5, 0); ctx.moveTo(0, -1.2); ctx.lineTo(0, -0.5); ctx.moveTo(0, 1.2); ctx.lineTo(0, 0.5); ctx.stroke();
    } }); });
  }
}
function makeCat(tpl, x, y) {
  const C = tpl === 'tmpTunCat' ? TunnelCat : tpl === 'superPositionCat' ? SuperCat : tpl === 'tmpUncertaintyCat' ? FuzzyCat : Cat;
  return new C(tpl, x, y);
}

// ---------------------------------------------------------------- level state
class Level {
  constructor(idx, retry) {
    S = this;
    this.idx = idx; this.retry = retry; this.key = LEVEL_KEYS[idx]; this.L = A.levels[this.key];
    const L = this.L;
    this.world = new World({ gravity: -9.81 });
    this.things = []; this.fx = []; this.kittens = []; this.trail = []; this.cats = []; this.queue = [];
    this.events = []; this.clearCallbacks = [];
    this.time = 0; this.timeScale = 1; this.pausedBy = null; this.optionsOpen = false;
    this.score = 0; this.boxes = 0; this.state = 'ready'; this.overT = 0; this.won = false; this.resultShown = false;
    this.world.onBegin = c => { c.preRV = Math.hypot(c.bB.vx - c.bA.vx, c.bB.vy - c.bA.vy); this.events.push(c); };
    // bodies
    let left = null, right = null;
    for (const d of L.bodies) {
      if (d.boundary || d.tag === 'Boundary') { if (d.name === 'LeftBoundary') left = d.tx; else if (d.name === 'RightBoundary') right = d.tx; continue; }
      const solid = d.shapes.filter(s => !s.trig);
      const type = d.dyn ? DYNAMIC : d.static ? STATIC : KINEMATIC;
      const b = this.world.createBody({ type, x: d.x, y: d.y, angle: d.rot, mass: d.mass, angularDamping: d.angDrag || 0, linearDamping: d.linDrag || 0, gravityScale: d.grav ?? 1 });
      b.hasRB = !d.static;
      for (const s of solid) {
        const fr = 0.4, re = s.mat ? 0.4 : 0;
        if (s.t === 'circle') b.addShape({ circle: [s.c[0], s.c[1], s.r], friction: fr, restitution: re });
        else if (Phys.isConvex(s.p)) b.addShape({ poly: s.p, friction: fr, restitution: re });
        else if (type === DYNAMIC) b.addShape({ poly: Phys.hull(s.p), friction: fr, restitution: re });
        else for (const t of Phys.triangulate(s.p)) b.addShape({ poly: t, friction: fr, restitution: re });
      }
      b.finalize();
      if (type === DYNAMIC) b.sleep(); // structures rest until something touches them
      const def = JSON.parse(JSON.stringify(d));
      if (d.tag === 'Floor') for (const s of def.sprites) s.s = L.groundSprite;
      let th;
      if (d.kind === 'LevelObject' || d.kind === 'KittenBox') th = new LevelObj(def, b);
      else if (d.kind === 'Laser') th = new Laser(def, b);
      else if (d.kind === 'Magnet') th = new Magnet(def, b);
      else if (d.kind === 'LiquidHelium') th = new Helium(def, b);
      else if (d.kind === 'CustomGeo') th = new Geo(def, b);
      else th = new Thing(def, b);
      th.kind = d.kind || d.tag;
      this.things.push(th);
    }
    this.bounds = [left ?? -60, right ?? 80];
    this.boxGoal = this.things.filter(t => t instanceof LevelObj && t.isBox).length;
    const floors = L.bodies.filter(b => b.tag === 'Floor');
    this.groundY = floors.length ? floors[0].ty : -3.5;
    this.sidePos = [this.bounds[0], 0.8];
    this.decor = L.decor;
    // camera
    const c = L.camera;
    this.cam = new Camera(c, this.bounds, retry);
    // railgun
    this.rail = new Railgun(L.railgun);
    this.railBoundX = this.rail.boundX;
    // cats
    const q = this.rail.queuePos; let px = q[0];
    for (const ci of L.cats) {
      const tpl = L.catTemplates[ci];
      const cat = makeCat(tpl, px, q[1]);
      this.queue.push(cat); this.cats.push(cat);
      px -= Math.hypot(1.28, 1.28) + (L.queue.extraSpace ?? 1.5);
    }
    this.bonus = L.cats.length * 1000;
    this.curIdx = 0; this.firstLoad = true; this.fireId = 0;
    this.clicker = null;
    UI.levelStarted(this);
  }
  T(k) { return T(k); }
  audible(x) { return Math.abs(x - this.cam.x) < this.cam.halfW() + 6; }
  removeThing(t) { const i = this.things.indexOf(t); if (i >= 0) this.things.splice(i, 1); }
  addScore(n) { this.score += n; UI.score(this.score, this.boxes, this.boxGoal); }
  boxBroken(n) { this.score += n; this.boxes++; UI.score(this.score, this.boxes, this.boxGoal, true); UI.announce(T('box-freed').replace('{n}', this.boxes).replace('{m}', this.boxGoal)); if (this.boxes >= this.boxGoal) { this.won = true; this.gameOver(); } }
  gameOver() { if (this.state !== 'over') { this.state = 'over'; this.overT = 0; } }
  setClicker(o) { this.clicker = o; }
  loadNextCat() {
    if (this.state === 'over') return;
    this.state = 'ready';
    const cat = this.queue.shift(); if (!cat) return;
    // shift the rest of the queue right
    for (let i = this.queue.length - 1; i >= 0; i--) { const tgt = i === 0 ? cat.x : this.queue[i - 1].x; this.queue[i].moveTo = tgt; }
    this.rail.loadCat(cat);
    UI.tutorial(cat);
  }
  catFired(cats) {
    this.state = 'flight'; this.bonus -= 1000; this.fireId++;
    for (const c of cats) { c.fireId = this.fireId; c.fired(); }
    this.trail = []; this.trailCats = cats.slice(); this.trailMainHit = false; this.trailT = 0; this.dotCount = 0;
    this.cam.follow(cats[0], true);
    UI.catFired();
  }
  catContact(cat, impact) {
    this.trailStop(cat);
    if (impact >= 10) this.cam.shake(0.1 * clamp(impact / 40, 0, 1), 0.75 * clamp(impact / 40, 0, 1));
    if (this.contactFire === cat.fireId) return;
    this.contactFire = cat.fireId;
    if (this.state !== 'ready' && this.state !== 'over') {
      this.state = 'contact';
      this.cam.free(true);
      this.curIdx++;
      if (this.curIdx < this.L.cats.length) this.loadNextCat();
    }
  }
  catStopped(cat) {
    const i = this.cats.indexOf(cat); if (i >= 0) this.cats.splice(i, 1);
    this.trailStop(cat);
    if (this.cam.target === cat) this.cam.free(true);
    if (this.state !== 'ready' && this.curIdx >= this.L.cats.length && !this.cats.some(c => c.state === 'inair' || c.state === 'contact')) this.gameOver();
  }
  trailStop(cat) { if (this.trailCats) { if (cat === this.trailCats[0]) this.trailMainHit = true; else this.trailCats = this.trailCats.filter(c => c !== cat); } }
  trailDot(big) {
    const c = this.trailCats && this.trailCats[0];
    if (c) this.trail.push([c.x, c.y, big ? 0.5 : [0.1, 0.15, 0.2][this.dotCount++ % 3]]);
  }
  superTrip(only) {
    const sc = this.cats.filter(c => c instanceof SuperCat && c.state !== 'waiting' && c.state !== 'dead' && !c.powerUsed);
    if (only) { for (const c of sc) c.tripped = true; this.superSelect(only, true); return; }
    if (sc.some(c => c.tripped)) return;
    for (const c of sc) c.freeze();
    this.pause(true, 'super');
    this.superCats = sc; this.kbSuper = 0;
    UI.announce(T('pick-cat'));
  }
  superSelect(cat, immediate) {
    const sc = this.cats.filter(c => c instanceof SuperCat && c.state !== 'waiting' && c.state !== 'dead' && c.fireId === cat.fireId);
    for (const c of sc) {
      c.powerUsed = true;
      if (c === cat) { if (!immediate) c.release(); c.selectable = false; }
      else { this.fx.push(new TunnelFx(c.x, c.y, c.body.a)); c.state = 'dead'; this.world.destroyBody(c.body); this.trailStop(c); const i = this.cats.indexOf(c); if (i >= 0) this.cats.splice(i, 1); }
    }
    this.superCats = null;
    Audio.play('CatAbility', 0.2);
    if (this.trailCats) this.trailCats = [cat];
    if (!immediate) this.pause(false);
    this.cam.follow(cat, true);
  }
  pause(on, by) {
    if (on) { this.pausedBy = by; this.pauseT = 0; this.timeScale = 0; }
    else { this.pausedBy = null; this.timeScale = 1; }
  }
  // input -------------------------------------------------------------
  pointerDown(wx, wy) {
    if (this.state === 'over') return;
    if (this.pausedBy === 'super') {
      const c = (this.superCats || []).find(c => Math.hypot(c.x - wx, c.y - wy) < 1.6);
      if (c) this.superSelect(c);
      return;
    }
    if (this.pausedBy) return;
    const fuzzy = this.cats.find(c => c instanceof FuzzyCat && c.state === 'inair' && !c.abilityUsed);
    if (fuzzy) { fuzzy.tap(); return; }
    if (this.rail.tryGrab(wx, wy)) return;
    // swap waiting cats
    const wc = this.queue.find(c => Math.hypot(c.x - wx, c.y - wy) < 1.1);
    if (wc) {
      if (this.swapSel === wc) { this.swapSel = null; wc.swapping = false; wc.body.gravityScale = 1; wc.selected = false; }
      else if (this.swapSel) {
        const a = this.swapSel, b = wc, ia = this.queue.indexOf(a), ib = this.queue.indexOf(b);
        if (ia >= 0 && ib >= 0) {
          const ax = a.x, ay = a.y, bx = b.x, by = b.y;
          a.body.setTransform(bx, by, 0); b.body.setTransform(ax, ay, 0);
          [a.moveTo, b.moveTo] = [b.moveTo, a.moveTo];
          this.queue[ia] = b; this.queue[ib] = a;
        }
        for (const c of [a, b]) { c.swapping = false; c.body.gravityScale = 1; c.selected = false; }
        this.swapSel = null; Audio.play('ui-click', 0.5);
      } else { this.swapSel = wc; wc.swapping = true; wc.selected = true; wc.body.setVelocity(0, 0); wc.body.gravityScale = 0; Audio.play('ui-click', 0.5); }
      return;
    }
    this.cam.dragStart(wx);
  }
  arrowClick(sx, sy) { // tapping an off-screen arrow brings the camera to what it points at
    const a = (this.arrows || []).find(a => Math.hypot(a.x - sx, a.y - sy) < 34);
    if (!a) return false;
    const cam = this.cam;
    if (a.t.rail) { cam.target = null; cam.firstMove = true; cam.inertia = 0; cam.tx = cam.startX; }
    else { cam.target = null; cam.follow(a.t, true); }
    Audio.play('ui-click', 0.5);
    return true;
  }
  keyDown(k) {
    if (this.state === 'over' || this.optionsOpen) return false;
    const r = this.rail, act = k === ' ' || k === 'Enter';
    const arrows = ['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'];
    if (this.pausedBy === 'super') {
      const sc = this.superCats || []; if (!sc.length) return false;
      this.kbSuper = this.kbSuper || 0;
      if (arrows.includes(k)) { this.kbSuper = (this.kbSuper + (k === 'ArrowLeft' || k === 'ArrowDown' ? -1 : 1) + sc.length) % sc.length; this.kbUsed = true; return true; }
      if (act) { this.superSelect(sc[this.kbSuper % sc.length]); this.kbSuper = 0; return true; }
      return false;
    }
    if (this.pausedBy) return false;
    const fuzzy = this.cats.find(c => c instanceof FuzzyCat && c.state === 'inair' && !c.abilityUsed);
    if (fuzzy && act) { fuzzy.tap(); return true; }
    if (r.aiming && r.kb) {
      if (k === 'ArrowUp') r.kb.ang = Math.min(85, r.kb.ang + 3);
      else if (k === 'ArrowDown') r.kb.ang = Math.max(-40, r.kb.ang - 3);
      else if (k === 'ArrowRight') r.kb.power = Math.min(1, r.kb.power + 0.05);
      else if (k === 'ArrowLeft') r.kb.power = Math.max(0.2, r.kb.power - 0.05);
      else if (act) { r.kb = null; r.release(); return true; }
      else if (k === 'Escape') { r.kb = null; r.stretch = 0; r.release(); return true; }
      else return false;
      r.kbAim(); return true;
    }
    if (act && r.state === 'ready' && r.cat) {
      const st = r.startPos(); this.kbUsed = true;
      if (r.tryGrab(st[0], st[1])) { r.kb = { ang: 25, power: 0.75 }; r.kbAim(); }
      return true;
    }
    if (k === 'ArrowLeft' || k === 'ArrowRight') { this.cam.target = null; this.cam.firstMove = true; this.cam.inertia = 0; this.cam.tx += k === 'ArrowLeft' ? -5 : 5; return true; }
    return false;
  }
  pointerMove(wx, wy, sx) { if (this.rail.aiming) this.rail.aim(wx, wy); else this.cam.dragMove(sx); }
  pointerUp() { if (this.rail.aiming) this.rail.release(); this.cam.dragEnd(); }
  // update --------------------------------------------------------------
  frame(rdt) {
    this.frameDt = rdt;
    if (this.optionsOpen) { this.cam.update(0, true); return; }
    if (this.firstLoad) { this.firstLoad = false; this.loadNextCat(); }
    if (this.pausedBy) {
      this.pauseT += rdt;
      if (this.pausedBy === 'super' && this.pauseT > 4) { const sc = this.superCats || []; if (sc.length) this.superSelect(sc[randInt(0, sc.length)]); else this.pause(false); }
      if (this.pausedBy === 'fuzzy') { for (const c of this.cats) if (c instanceof FuzzyCat && c.targets) c.pickStep(rdt); if (this.pauseT > 4) { for (const c of this.cats) if (c instanceof FuzzyCat && !c.shot && c.abilityUsed) c.shoot(); this.pause(false); } }
    }
    const dt = rdt * this.timeScale;
    this.time += dt;
    this.acc = (this.acc || 0) + dt;
    let n = 0;
    while (this.acc >= DT && n < 14) { this.acc -= DT; n++; this.physStep(DT); }
    if (n >= 14) this.acc = 0;
    // per-frame logic
    this.rail.frame(rdt * (this.timeScale ? 1 : 0));
    for (const c of this.cats) c.frameTick(dt);
    // queue movement
    for (const c of this.queue) {
      if (c.moveTo !== undefined && c.moveTo !== null) {
        const nx = c.x + 2 * dt; if (Math.abs(nx - c.moveTo) <= 0.1 || nx > c.moveTo) { c.body.setTransform(c.moveTo, c.y, c.body.a); c.moveTo = null; c.yInitial = c.y; } else c.body.setTransform(nx, c.y, c.body.a);
      }
    }
    this.fx = this.fx.filter(p => p.step(dt));
    this.kittens = this.kittens.filter(k => k.step(dt));
    // trail
    if (this.trailCats && this.state !== 'over') {
      this.trailT += dt;
      while (this.trailT >= 0.05) {
        this.trailT -= 0.05;
        const sz = [0.1, 0.15, 0.2][this.dotCount++ % 3];
        if (!this.trailMainHit && this.trailCats[0] && this.trailCats[0].state === 'inair') this.trail.push([this.trailCats[0].x, this.trailCats[0].y, sz]);
        for (const c of this.trailCats.slice(1)) if (c.state === 'inair') this.trail.push([c.x, c.y, sz]);
      }
    }
    this.cam.update(rdt, this.timeScale === 0);
    if (this.state === 'over') {
      this.overT += dt;
      if (this.overT >= 2 && !this.resultShown) {
        this.resultShown = true;
        const total = this.score + (this.won ? this.bonus : 0);
        if (this.won) { const best = (SAVE.best || {})[this.idx] || 0; SAVE.best = SAVE.best || {}; if (total > best) SAVE.best[this.idx] = total; persist(); }
        UI.results(this.won, this.score, this.bonus, this.idx);
        Audio.play(this.won ? 'win-riff' : 'loss-stinger', 0.5);
      }
    }
  }
  physStep(dt) {
    for (const c of this.cats) if (c.state !== 'dead') c.step(dt);
    for (const t of this.things) if (t.step) t.step(dt);
    this.world.step(dt);
    // contact callbacks
    const ev = this.events; this.events = [];
    for (const c of ev) {
      const a = c.bA.userData, b = c.bB.userData; if (!a || !b) continue;
      const rv = Math.hypot(c.bB.vx - c.bA.vx, c.bB.vy - c.bA.vy);
      const rvPre = c.preRV ?? rv;
      a.onCollide(b, rvPre, c.bB); b.onCollide(a, rvPre, c.bA);
    }
    for (const t of this.things.slice()) {
      if (t instanceof LevelObj) {
        if (t.alive && (t.x < this.bounds[0] || t.x > this.bounds[1] || (t.x < this.railBoundX + 0.5 && t.x > this.railBoundX - 0.5) || t.y < -40)) t.health = 0;
        t.update();
      }
    }
    for (const t of this.clearCallbacks) t.onDestroyed = null;
    this.clearCallbacks = [];
  }
  // render ----------------------------------------------------------------
  render() {
    const cam = this.cam, k = cam.ppu() * DPR;
    const camY = cam.drawY();
    VIEW = [k, 0, 0, -k, (W / 2 - cam.x * cam.ppu() + cam.sx * cam.ppu()) * DPR, (H / 2 + (camY + cam.sy) * cam.ppu()) * DPR];
    ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.globalAlpha = 1;
    ctx.fillStyle = '#20252f'; ctx.fillRect(0, 0, cv.width, cv.height);
    const items = [];
    const c0 = this.L.camera;
    for (const d of this.decor) {
      let m = d.m;
      if (d.px) m = [m[0], m[1], m[2], m[3], m[4] + (cam.x - c0.x) * d.px, m[5]];
      items.push({ L: d.L, o: d.o, f: () => drawSprite(d.s, m, d.c ? d.c[3] : 1, !!d.fx, d.c) });
    }
    for (const t of this.things) t.drawItems(items);
    this.rail.drawItems(items);
    for (const c of this.cats) c.drawItems(items);
    for (const p of this.fx) p.drawItems(items);
    for (const kt of this.kittens) kt.drawItems(items);
    if (this.trail.length) items.push({ L: 9, o: -5, f: () => { for (const d of this.trail) drawSprite('Sprites/Tileset/dot.png#21300000', mTRS(d[0], d[1], 0, d[2]), 0.9); } });
    items.forEach((it, i) => it.i = i);
    items.sort((a, b) => a.L - b.L || a.o - b.o || a.i - b.i);
    for (const it of items) it.f();
    ctx.globalAlpha = 1;
    this.renderOverlay();
  }
  renderOverlay() {
    // off-screen arrows for flying cats and the waiting launcher
    const cam = this.cam, ppu = cam.ppu();
    const toS = (x, y) => [(x - cam.x) * ppu + W / 2, H / 2 - (y - cam.drawY()) * ppu];
    const targets = this.cats.filter(c => c.state === 'inair');
    const r = this.rail;
    if (r.state === 'ready' && r.readyT > 3) targets.push({ x: r.startPos()[0], y: r.startPos()[1], rail: true });
    ctx.setTransform(DPR, 0, 0, DPR, 0, 0);
    this.arrows = [];
    for (const t of targets) {
      const [sx, sy] = toS(t.x, t.y);
      if (sx > 0 && sx < W && sy > 0 && sy < H) continue;
      const cx = W / 2, cy = H / 2; let dx = sx - cx, dy = sy - cy;
      const s = Math.min((W * 0.45) / Math.abs(dx || 1e-6), (H * 0.42) / Math.abs(dy || 1e-6));
      const ax = cx + dx * s, ay = cy + dy * s, ang = Math.atan2(dy, dx);
      this.arrows.push({ x: ax, y: ay, t });
      ctx.save(); ctx.translate(ax, ay); ctx.rotate(ang);
      ctx.fillStyle = t.rail ? '#ff4d3d' : '#3b7bff'; ctx.strokeStyle = '#fff'; ctx.lineWidth = 3;
      ctx.beginPath(); ctx.moveTo(18, 0); ctx.lineTo(-10, -13); ctx.lineTo(-4, 0); ctx.lineTo(-10, 13); ctx.closePath(); ctx.stroke(); ctx.fill();
      ctx.restore();
    }
    // click indicator
    const ring = (x, y, sc) => { const [sx, sy] = toS(x, y); const p = (performance.now() / 900) % 1; ctx.strokeStyle = `rgba(255,255,255,${0.9 * (1 - p)})`; ctx.lineWidth = 4; ctx.beginPath(); ctx.arc(sx, sy, ppu * sc * (0.6 + p * 0.9), 0, 6.29); ctx.stroke(); };
    if (r.state === 'ready' && !r.everAimed) { const p = r.startPos(); ring(p[0], p[1], 1.6); }
    if (this.clicker && this.clicker.state === 'inair') ring(this.clicker.x, this.clicker.y, 2.2);
  }
}

// ---------------------------------------------------------------- railgun
class Railgun {
  constructor(R) {
    this.p = R.params; this.parts = R.parts;
    const P = this.parts;
    this.railsPos = [P['rail-rails'].x, P['rail-rails'].y];
    const rel = n => [P[n].x - this.railsPos[0], P[n].y - this.railsPos[1]];
    this.lStart = rel('startPosition'); this.lLaunch = rel('launchPosn'); this.lRear = rel('rearPosition'); this.lBack = rel('rail-gun_BackRail');
    this.initStart = [P.startPosition.x, P.startPosition.y];
    this.chairYOffset = P.startPosition.y - P.launchPosn.y;
    this.queuePos = [P.catQueuePosition.x, P.catQueuePosition.y];
    this.boundX = P['rail-boundary'] ? P['rail-boundary'].x : -1e9;
    this.rot = 0; this.state = 'waiting'; this.stretch = 0; this.chair = this.launchPoint(); this.chairV = [0, 0]; this.readyT = 0;
    this.aiming = false; this.cat = null;
  }
  w(l) { const c = Math.cos(this.rot), s = Math.sin(this.rot); return [this.railsPos[0] + c * l[0] - s * l[1], this.railsPos[1] + s * l[0] + c * l[1]]; }
  launchPoint() { return this.w(this.lLaunch); }
  rearPoint() { return this.w(this.lRear); }
  startPos() { return this.initStart; }
  loadCat(cat) {
    this.cat = cat; cat.state = 'loaded'; cat.scripted = true; cat.setScripted(true);
    cat.arc = { x: cat.x, y: cat.y, vx: 0, vy: 0, up: S.L.queue.m_ToLaunchHeight ?? 3, done: false };
    this.state = 'ready'; this.readyT = 0;
  }
  tryGrab(wx, wy) {
    if (this.state !== 'ready' || !this.cat) return false;
    const st = this.initStart;
    if (Math.hypot(wx - st[0], wy - st[1]) >= (this.p.m_ClickRange ?? 5)) return false;
    this.aiming = true; this.state = 'aiming'; this.everAimed = true; this.readyT = 0;
    this.cat.arc = null; this.aimBall = st.slice(); this.offset = [0, 0];
    S.cam.follow(this.cat, true);
    return true;
  }
  kbAim() { // keyboard aiming: launch angle (degrees) and power (0..1) -> an equivalent drag point
    const st = this.initStart, maxS = this.p.m_MaxStretch ?? 10, maxA = this.p.m_MaxAngle ?? 90, minA = this.p.m_MinAngle ?? -45;
    const a = this.kb.ang, len = this.kb.power * maxS;
    let dy = a >= 0 ? -a / maxA * maxS : a / minA * maxS;
    if (Math.abs(dy) > len) dy = Math.sign(dy) * len;
    const dx = -Math.sqrt(Math.max(0, len * len - dy * dy));
    this.aim(st[0] + dx, st[1] + dy);
  }
  aim(wx, wy) {
    const st = this.initStart, maxS = this.p.m_MaxStretch ?? 10, ratio = this.p.m_DragRatio ?? 1;
    const ox = wx - st[0], oy = wy - st[1];
    let ax = ratio * ox, ay = ratio * oy; const l = Math.hypot(ax, ay); if (l > maxS) { ax *= maxS / l; ay *= maxS / l; }
    let bx = st[0] + ax, by = st[1] + ay; if (wx > st[0]) bx = st[0];
    this.aimBall = [bx, by];
    this.stretch = Math.hypot(bx - st[0], by - st[1]) / maxS;
    const dy = by - st[1];
    this.targetRot = (dy > 0 ? lerp(0, this.p.m_MinAngle ?? -45, dy / maxS) : lerp(0, this.p.m_MaxAngle ?? 90, Math.abs(dy) / maxS)) * Math.PI / 180;
  }
  release() {
    this.aiming = false;
    if (this.stretch < 0.15) { this.state = 'ready'; this.stretch = 0; this.chair = this.launchPoint(); S.cam.free(true); return; }
    this.state = 'fire'; this.chairV = [0, 0];
    const r = this.rearPoint(), l = this.launchPoint(); const dx = l[0] - r[0], dy = l[1] - r[1], ll = Math.hypot(dx, dy);
    this.fireVec = [dx / ll, dy / ll];
  }
  frame(dt) {
    if (!dt) return;
    const cat = this.cat;
    if (this.state === 'ready') this.readyT += dt;
    if (cat && cat.arc) { // QueueManager.CatToLaunch arc
      const a = cat.arc, st = this.initStart;
      if (Math.hypot(a.x - st[0], a.y - st[1]) <= 0.1) { cat.arc = null; cat.body.setTransform(st[0], st[1], this.rot); }
      else {
        spring(a, 'x', 'vx', st[0], 0.8, 4 * Math.PI, dt); spring(a, 'y', 'vy', st[1], 0.8, 4 * Math.PI, dt);
        cat.body.setTransform(a.x, a.y + a.up, 0); a.up += (S.L.queue.m_GravityForce ?? -0.15) * dt * 60;
      }
    }
    if (this.state === 'aiming' || this.state === 'ready' && !this.aiming) {
      const tr = this.state === 'aiming' ? this.targetRot ?? 0 : this.rot;
      this.rot += (tr - this.rot) * (1 - Math.pow(0.1, dt * 60));
    }
    if (this.state === 'aiming') {
      const l = this.launchPoint(), r = this.rearPoint();
      this.chair = [l[0] + (r[0] - l[0]) * this.stretch, l[1] + (r[1] - l[1]) * this.stretch];
      if (cat) cat.body.setTransform(this.chair[0] - Math.sin(this.rot) * this.chairYOffset, this.chair[1] + Math.cos(this.rot) * this.chairYOffset, this.rot);
    } else if (this.state === 'ready' && cat && !cat.arc) {
      this.chair = this.launchPoint(); cat.body.setTransform(this.initStart[0], this.initStart[1], this.rot);
    } else if (this.state === 'fire') {
      const lp = this.launchPoint(), o = { x: this.chair[0], y: this.chair[1], vx: this.chairV[0], vy: this.chairV[1] };
      spring(o, 'x', 'vx', lp[0], 0.4, 6 * Math.PI, dt); spring(o, 'y', 'vy', lp[1], 0.4, 6 * Math.PI, dt);
      this.chair = [o.x, o.y]; this.chairV = [o.vx, o.vy];
      cat.body.setTransform(this.chair[0], this.chair[1] + 1, this.rot);
      if (Math.hypot(this.chair[0] - lp[0], this.chair[1] - lp[1]) < 0.5) this.fire();
    } else if (this.state !== 'aiming') {
      const lp = this.launchPoint(), o = { x: this.chair[0], y: this.chair[1], vx: this.chairV[0], vy: this.chairV[1] };
      spring(o, 'x', 'vx', lp[0], 0.4, 6 * Math.PI, dt); spring(o, 'y', 'vy', lp[1], 0.4, 6 * Math.PI, dt);
      this.chair = [o.x, o.y]; this.chairV = [o.vx, o.vy];
    }
  }
  fire() {
    const cat = this.cat; this.cat = null; this.state = 'waiting';
    const power = (this.p.m_LaunchPower ?? 40) * this.stretch;
    const fv = [this.fireVec[0] * power, this.fireVec[1] * power];
    cat.scripted = false; cat.setScripted(false); cat.body.gravityScale = 1;
    cat.body.setVelocity(fv[0], fv[1]);
    const cats = [cat];
    if (cat instanceof SuperCat) {
      let up = false;
      for (let j = 1; j <= 2; j++) {
        const a = (up ? 5 : -5) * Math.PI / 180; up = !up;
        const c2 = makeCat('superPositionCat', cat.x, cat.y); c2.state = 'loaded';
        c2.body.setVelocity(fv[0] * Math.cos(a) - fv[1] * Math.sin(a), fv[0] * Math.sin(a) + fv[1] * Math.cos(a));
        c2.t = cat.t; S.cats.push(c2); cats.push(c2);
      }
    }
    Audio.play('catLaunch-whoosh', 1, rand(1, 3));
    this.stretch = 0;
    S.catFired(cats);
  }
  drawItems(out) {
    const P = this.parts;
    const put = (name, M) => { const p = P[name]; if (!p) return; for (const s of p.sprites) out.push({ L: s.L, o: s.o, f: () => drawSprite(s.s, M) }); };
    put('rail-stand', mTRS(P['rail-stand'].x, P['rail-stand'].y, 0));
    put('rail-guide', mTRS(P['rail-guide'].x, P['rail-guide'].y, 0));
    put('rail-rails', mTRS(this.railsPos[0], this.railsPos[1], this.rot));
    const b = this.w(this.lBack); put('rail-gun_BackRail', mTRS(b[0], b[1], this.rot));
    put('rail-chair', mTRS(this.chair[0], this.chair[1], this.rot));
    if (this.state === 'aiming' && this.stretch > 0.02) {
      const st = this.initStart, ab = this.aimBall;
      out.push({ L: 9, o: -10, f: () => {
        ctx.setTransform(VIEW[0], VIEW[1], VIEW[2], VIEW[3], VIEW[4], VIEW[5]);
        ctx.globalAlpha = 0.85; ctx.strokeStyle = this.stretch < 0.15 ? 'rgba(255,255,255,0.5)' : '#ffb347'; ctx.lineWidth = 0.12; ctx.setLineDash([0.3, 0.25]);
        ctx.beginPath(); ctx.moveTo(st[0], st[1]); ctx.lineTo(ab[0], ab[1]); ctx.stroke(); ctx.setLineDash([]);
        ctx.fillStyle = ctx.strokeStyle; ctx.beginPath(); ctx.arc(ab[0], ab[1], 0.3, 0, 6.29); ctx.fill();
      } });
    }
  }
}

// ---------------------------------------------------------------- camera
class Camera {
  constructor(c, bounds, retry) {
    this.c = c; this.bounds = bounds; this.x = c.x; this.y = c.y; this.ortho0 = c.ortho || 15; this.ortho = this.ortho0;
    this.vel = { v: 0 }; this.target = null; this.time = 0; this.firstMove = false; this.startX = c.x;
    if (!retry && c.showX !== undefined) this.x = c.showX;
    this.tx = this.x; this.drag = null; this.inertia = 0; this.cv = 0; this.shakeT = 0; this.shakeI = 0; this.sx = 0; this.sy = 0; this.lockFollow = false;
  }
  effOrtho() { const asp = W / H; const minHalfW = this.ortho0 * 1.45; return Math.max(this.ortho, minHalfW / asp); }
  ppu() { return H / (2 * this.effOrtho()); }
  halfW() { return this.effOrtho() * W / H; }
  drawY() { const e = this.effOrtho() - this.ortho0; return this.y + (W / H < 1 ? e * 0.4 : e); }
  follow(obj, isCat) {
    if (this.target && this.target instanceof Cat && !(obj instanceof Cat) && this.target.state !== 'dead') return;
    this.target = obj; this.inertia = 0; this.firstMove = true;
  }
  free(force, laser) { if (force || (laser && this.target === laser)) { this.target = null; this.inertia = 0; this.tx = this.x; } }
  shake(i, t) { if (REDUCED_MOTION.matches) return; this.shakeI = i; this.shakeT = t; }
  dragStart(wx) { this.drag = { lastSx: null }; this.firstMove = true; this.inertia = 0; this.target = null; }
  dragMove(sx) { if (!this.drag) return; if (this.drag.lastSx !== null) { const d = (sx - this.drag.lastSx) / this.ppu(); this.tx -= d; this.inertia = -d / Math.max(S.frameDt, 0.008); } this.drag.lastSx = sx; this.drag.t = performance.now(); }
  dragEnd() { if (this.drag && performance.now() - (this.drag.t || 0) > 80) this.inertia = 0; this.drag = null; }
  update(dt, paused) {
    if (paused) return;
    this.time += dt;
    if (!this.firstMove && this.time >= (this.c.m_StartTime ?? 2.5)) { this.tx = this.startX; this.firstMove = true; this.started = true; }
    if (this.target) {
      const t = this.target; let fx = t.x;
      if (t.body && t.body.type === DYNAMIC) fx += t.body.vx / 2;
      this.tx = fx;
      const dy = t.y - this.y;
      const target = dy > (this.c.m_AllowableHeightDelta ?? 2) ? (this.c.m_MaxOrthoSize ?? 16) : this.ortho0;
      this.ortho += (target - this.ortho) * (1 - Math.pow(1 - (this.c.m_ZoomLerpTime ?? 0.009), dt * 200));
    } else {
      this.ortho += (this.ortho0 - this.ortho) * (1 - Math.pow(0.991, dt * 200));
      if (!this.drag && Math.abs(this.inertia) > 0.01) { this.tx += this.inertia * dt; this.inertia *= Math.pow(0.04, dt); }
    }
    const hw = this.halfW();
    const lo = this.bounds[0] + hw, hi = this.bounds[1] - hw;
    this.tx = lo > hi ? (lo + hi) / 2 : clamp(this.tx, lo, hi);
    this.x = this.drag ? this.tx : smoothDamp(this.x, this.tx, this.vel, this.c.m_LerpTime ?? 0.25, dt);
    this.x = lo > hi ? (lo + hi) / 2 : clamp(this.x, lo - 0.5, hi + 0.5);
    if (this.shakeT > 0) { this.shakeT -= dt; const o = insideUnitCircle(); this.sx = o[0] * this.shakeI; this.sy = o[1] * this.shakeI; } else { this.sx = this.sy = 0; }
  }
}

// ---------------------------------------------------------------- strings
let LANG = SAVE.lang || ((navigator.language || 'en').toLowerCase().startsWith('fr') ? 'fr' : 'en');
function T(k) { return (STRINGS[LANG] && STRINGS[LANG][k]) ?? STRINGS.en[k] ?? k; }

// ---------------------------------------------------------------- main loop & input
let last = performance.now();
const REDUCED_MOTION = window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : { matches: false };
function loop(now) {
  const dt = Math.min(0.05, (now - last) / 1000); last = now;
  if (S && A.ready) { S.frame(dt); S.render(); }
  requestAnimationFrame(loop);
}
function toWorld(e) {
  const r = cv.getBoundingClientRect(); const sx = e.clientX - r.left, sy = e.clientY - r.top;
  const cam = S.cam, ppu = cam.ppu();
  return [cam.x + (sx - W / 2) / ppu, cam.drawY() - (sy - H / 2) / ppu, sx, sy];
}
let activePointer = null;
cv.addEventListener('pointerdown', e => { if (!S || activePointer !== null) return; activePointer = e.pointerId; cv.setPointerCapture(e.pointerId); Audio.unlock(); const [x, y, sx, sy] = toWorld(e); if (S.arrowClick(sx, sy)) { activePointer = null; return; } S.pointerDown(x, y); S.cam.dragMove && S.cam.drag && S.cam.dragMove(sx); });
cv.addEventListener('pointermove', e => { if (!S || e.pointerId !== activePointer) return; const [x, y, sx] = toWorld(e); S.pointerMove(x, y, sx); });
const up = e => { if (!S || e.pointerId !== activePointer) return; activePointer = null; S.pointerUp(); };
cv.addEventListener('pointerup', up); cv.addEventListener('pointercancel', up); cv.addEventListener('lostpointercapture', up);
window.addEventListener('keydown', e => {
  if (!S || S.resultShown || e.altKey || e.ctrlKey || e.metaKey) return;
  const ae = document.activeElement;
  if (ae && ae !== cv && ae !== document.body && ae.closest && ae.closest('button, input, [role=dialog]')) return;
  Audio.unlock();
  if (S.keyDown(e.key)) { e.preventDefault(); e.stopPropagation(); }
}, true);
document.addEventListener('visibilitychange', () => {
  if (!Audio.musicEl) return;
  if (document.hidden) Audio.musicEl.pause(); else Audio.applyMusic();
});

window.QC = {
  start: async (progress) => { resize(); await loadAssets(progress); requestAnimationFrame(loop); },
  loadLevel: (i, retry) => { new Level(i, !!retry); },
  unload: () => { S = null; ctx.setTransform(1, 0, 0, 1, 0, 0); ctx.clearRect(0, 0, cv.width, cv.height); },
  get level() { return S; },
  T, setLang: l => { if (l !== 'en' && l !== 'fr') return; LANG = l; SAVE.lang = l; persist(); },
  get lang() { return LANG; },
  Audio, SAVE, persist, LEVEL_KEYS,
  setOptions: open => { if (S) S.optionsOpen = open; },
  resize
};
})();