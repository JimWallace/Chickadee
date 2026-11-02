// Compact 2D rigid-body physics (Box2D-style sequential impulses), written for the
// Quantum Cats HTML port. Convex polygons + circles, persistent manifolds with warm
// starting, block solver, non-linear position correction, islands and sleeping.
'use strict';
const Phys = (() => {
  const LINEAR_SLOP = 0.005, POLY_RADIUS = 2 * LINEAR_SLOP, BAUMGARTE = 0.2, MAX_CORR = 0.2;
  const VEL_THRESHOLD = 1.0, MAX_SPEED = 100, MAX_ROT = 0.5 * Math.PI;
  const TIME_TO_SLEEP = 0.5, LIN_SLEEP = 0.01, ANG_SLEEP = 2 * Math.PI / 180;
  const STATIC = 0, KINEMATIC = 1, DYNAMIC = 2;
  const FACE_A = 1, FACE_B = 2, CIRCLES = 0;

  const cross = (ax, ay, bx, by) => ax * by - ay * bx;

  // ---------- shapes ----------
  function hull(pts) {
    const p = pts.map(q => [q[0], q[1]]).sort((a, b) => a[0] - b[0] || a[1] - b[1]);
    const out = [];
    const cr = (o, a, b) => (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
    for (const q of p) { while (out.length >= 2 && cr(out[out.length - 2], out[out.length - 1], q) <= 1e-9) out.pop(); out.push(q); }
    const lo = out.length + 1;
    for (let i = p.length - 2; i >= 0; i--) { const q = p[i]; while (out.length >= lo && cr(out[out.length - 2], out[out.length - 1], q) <= 1e-9) out.pop(); out.push(q); }
    out.pop();
    // weld near-duplicates
    const w = [];
    for (const q of out) if (!w.some(r => (r[0] - q[0]) ** 2 + (r[1] - q[1]) ** 2 < (0.5 * LINEAR_SLOP) ** 2)) w.push(q);
    return w;
  }
  function polyArea(pts) { let a = 0; for (let i = 0; i < pts.length; i++) { const p = pts[i], q = pts[(i + 1) % pts.length]; a += p[0] * q[1] - q[0] * p[1]; } return a / 2; }
  function isConvex(pts) {
    let sign = 0;
    for (let i = 0; i < pts.length; i++) {
      const a = pts[i], b = pts[(i + 1) % pts.length], c = pts[(i + 2) % pts.length];
      const z = cross(b[0] - a[0], b[1] - a[1], c[0] - b[0], c[1] - b[1]);
      if (Math.abs(z) < 1e-12) continue;
      if (!sign) sign = Math.sign(z); else if (Math.sign(z) !== sign) return false;
    }
    return true;
  }
  // ear clipping triangulation for simple polygons (used for static concave colliders)
  function triangulate(pts) {
    let p = pts.slice(); if (polyArea(p) < 0) p.reverse();
    const tris = []; let guard = 0;
    while (p.length > 3 && guard++ < 1000) {
      let clipped = false;
      for (let i = 0; i < p.length; i++) {
        const a = p[(i + p.length - 1) % p.length], b = p[i], c = p[(i + 1) % p.length];
        if (cross(b[0] - a[0], b[1] - a[1], c[0] - a[0], c[1] - a[1]) <= 1e-9) continue;
        let inside = false;
        for (const q of p) {
          if (q === a || q === b || q === c) continue;
          const d1 = cross(b[0] - a[0], b[1] - a[1], q[0] - a[0], q[1] - a[1]);
          const d2 = cross(c[0] - b[0], c[1] - b[1], q[0] - b[0], q[1] - b[1]);
          const d3 = cross(a[0] - c[0], a[1] - c[1], q[0] - c[0], q[1] - c[1]);
          if (d1 >= 0 && d2 >= 0 && d3 >= 0) { inside = true; break; }
        }
        if (inside) continue;
        tris.push([a, b, c]); p.splice(i, 1); clipped = true; break;
      }
      if (!clipped) break;
    }
    if (p.length === 3) tris.push(p);
    return tris;
  }

  class Shape {
    constructor(def) {
      this.friction = def.friction ?? 0.4; this.restitution = def.restitution ?? 0;
      this.cat = def.cat ?? 1; this.mask = def.mask ?? 0xffff; this.sensor = !!def.sensor;
      this.body = null; this.aabb = [0, 0, 0, 0]; this.userData = def.userData;
      if (def.circle) {
        this.type = 1; this.p = [def.circle[0], def.circle[1]]; this.radius = def.circle[2];
      } else {
        this.type = 0; this.radius = POLY_RADIUS;
        let v = def.poly; if (polyArea(v) < 0) v = v.slice().reverse();
        this.v = v.map(q => [q[0], q[1]]);
        const n = this.v.length; this.n = [];
        for (let i = 0; i < n; i++) {
          const a = this.v[i], b = this.v[(i + 1) % n];
          let ex = b[0] - a[0], ey = b[1] - a[1]; const l = Math.hypot(ex, ey) || 1;
          this.n.push([ey / l, -ex / l]);
        }
      }
    }
    massData(density) {
      if (this.type === 1) {
        const r2 = this.radius * this.radius, m = density * Math.PI * r2;
        return { m, cx: this.p[0], cy: this.p[1], I: m * (0.5 * r2 + this.p[0] ** 2 + this.p[1] ** 2) };
      }
      const v = this.v, n = v.length; let area = 0, cx = 0, cy = 0, I = 0;
      const sx = v[0][0], sy = v[0][1];
      for (let i = 0; i < n; i++) {
        const e1x = v[i][0] - sx, e1y = v[i][1] - sy, e2x = v[(i + 1) % n][0] - sx, e2y = v[(i + 1) % n][1] - sy;
        const D = cross(e1x, e1y, e2x, e2y), ta = 0.5 * D; area += ta;
        cx += ta * (e1x + e2x) / 3; cy += ta * (e1y + e2y) / 3;
        const intx2 = e1x * e1x + e2x * e1x + e2x * e2x, inty2 = e1y * e1y + e2y * e1y + e2y * e2y;
        I += 0.25 / 3 * D * (intx2 + inty2);
      }
      const m = density * area; cx /= area; cy /= area;
      const ccx = cx + sx, ccy = cy + sy;
      let Ic = density * I + m * (ccx * ccx + ccy * ccy - (cx * cx + cy * cy));
      return { m, cx: ccx, cy: ccy, I: Ic };
    }
    computeAABB(xf) {
      const b = this.body;
      if (this.type === 1) {
        const x = xf.px + xf.c * this.p[0] - xf.s * this.p[1], y = xf.py + xf.s * this.p[0] + xf.c * this.p[1];
        this.aabb[0] = x - this.radius; this.aabb[1] = y - this.radius; this.aabb[2] = x + this.radius; this.aabb[3] = y + this.radius;
      } else {
        let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
        for (const q of this.v) {
          const x = xf.px + xf.c * q[0] - xf.s * q[1], y = xf.py + xf.s * q[0] + xf.c * q[1];
          if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
        }
        this.aabb[0] = x0 - this.radius; this.aabb[1] = y0 - this.radius; this.aabb[2] = x1 + this.radius; this.aabb[3] = y1 + this.radius;
      }
    }
    // world-space test point
    testPoint(x, y) {
      const xf = this.body.xf; const dx = x - xf.px, dy = y - xf.py;
      const lx = xf.c * dx + xf.s * dy, ly = -xf.s * dx + xf.c * dy;
      if (this.type === 1) return (lx - this.p[0]) ** 2 + (ly - this.p[1]) ** 2 <= this.radius ** 2;
      for (let i = 0; i < this.v.length; i++) if (this.n[i][0] * (lx - this.v[i][0]) + this.n[i][1] * (ly - this.v[i][1]) > 0) return false;
      return true;
    }
    // ray cast in world space, returns fraction or -1
    rayCast(x1, y1, x2, y2, maxF) {
      const xf = this.body.xf;
      const tx = (x, y) => [xf.c * (x - xf.px) + xf.s * (y - xf.py), -xf.s * (x - xf.px) + xf.c * (y - xf.py)];
      const [p1x, p1y] = tx(x1, y1), [p2x, p2y] = tx(x2, y2);
      const dx = p2x - p1x, dy = p2y - p1y;
      if (this.type === 1) {
        const sx = p1x - this.p[0], sy = p1y - this.p[1];
        const b = sx * sx + sy * sy - this.radius ** 2;
        const c = sx * dx + sy * dy, rr = dx * dx + dy * dy, sigma = c * c - rr * b;
        if (sigma < 0 || rr < 1e-12) return b <= 0 ? 0 : -1;
        let a = -(c + Math.sqrt(sigma));
        if (b <= 0) return 0;
        if (0 <= a && a <= maxF * rr) return a / rr;
        return -1;
      }
      let lower = 0, upper = maxF, inside = true;
      for (let i = 0; i < this.v.length; i++) {
        const num = this.n[i][0] * (this.v[i][0] - p1x) + this.n[i][1] * (this.v[i][1] - p1y);
        const den = this.n[i][0] * dx + this.n[i][1] * dy;
        if (num < 0) inside = false;
        if (den === 0) { if (num < 0) return -1; }
        else if (den < 0 && num < lower * den) lower = num / den;
        else if (den > 0 && num < upper * den) upper = num / den;
        if (upper < lower) return -1;
      }
      return lower;
    }
  }

  // ---------- body ----------
  let nextId = 1;
  class Body {
    constructor(def) {
      this.id = nextId++;
      this.type = def.type ?? DYNAMIC;
      this.xf = { px: def.x || 0, py: def.y || 0, c: Math.cos(def.angle || 0), s: Math.sin(def.angle || 0) };
      this.a = def.angle || 0; this.lc = [0, 0]; this.cx = this.xf.px; this.cy = this.xf.py;
      this.vx = 0; this.vy = 0; this.w = 0;
      this.mass = def.mass ?? 1; this.invMass = 0; this.I = 0; this.invI = 0;
      this.gravityScale = def.gravityScale ?? 1; this.linDamp = def.linearDamping || 0; this.angDamp = def.angularDamping || 0;
      this.shapes = []; this.contacts = []; this.awake = true; this.sleepTime = 0; this.userData = def.userData;
      this.fx = 0; this.fy = 0; this.destroyed = false; this.enabled = true; this.fixedRotation = false;
    }
    addShape(def) { const s = new Shape(def); s.body = this; this.shapes.push(s); return s; }
    finalize() {
      if (this.type !== DYNAMIC) { this.invMass = 0; this.invI = 0; this.lc = [0, 0]; this.syncCenter(); return this; }
      let m = 0, cx = 0, cy = 0, I = 0;
      for (const s of this.shapes) { if (s.sensor) continue; const md = s.massData(1); m += md.m; cx += md.m * md.cx; cy += md.m * md.cy; I += md.I; }
      if (m <= 0) { m = 1; I = 1; }
      cx /= m; cy /= m;
      const scale = this.mass / m;
      I = (I - m * (cx * cx + cy * cy)) * scale;
      this.lc = [cx, cy]; this.invMass = 1 / this.mass; this.I = I; this.invI = this.fixedRotation ? 0 : 1 / I;
      this.syncCenter(); return this;
    }
    syncCenter() { const xf = this.xf; this.cx = xf.px + xf.c * this.lc[0] - xf.s * this.lc[1]; this.cy = xf.py + xf.s * this.lc[0] + xf.c * this.lc[1]; }
    syncXf() { const xf = this.xf; xf.c = Math.cos(this.a); xf.s = Math.sin(this.a); xf.px = this.cx - (xf.c * this.lc[0] - xf.s * this.lc[1]); xf.py = this.cy - (xf.s * this.lc[0] + xf.c * this.lc[1]); }
    setTransform(x, y, a) { this.xf.px = x; this.xf.py = y; this.a = a; this.xf.c = Math.cos(a); this.xf.s = Math.sin(a); this.syncCenter(); this.wake(); }
    setPosition(x, y) { this.setTransform(x, y, this.a); }
    get x() { return this.xf.px; } get y() { return this.xf.py; }
    wake() { if (this.type === DYNAMIC) { this.awake = true; this.sleepTime = 0; } }
    sleep() { this.awake = false; this.sleepTime = 0; this.vx = this.vy = this.w = 0; }
    setVelocity(vx, vy) { this.vx = vx; this.vy = vy; this.wake(); }
    applyImpulse(px, py, x, y) { if (this.type !== DYNAMIC) return; this.wake(); this.vx += px * this.invMass; this.vy += py * this.invMass; if (x !== undefined) this.w += this.invI * cross(x - this.cx, y - this.cy, px, py); }
    applyForce(fx, fy) { if (this.type !== DYNAMIC) return; this.wake(); this.fx += fx; this.fy += fy; }
    toLocal(x, y) { const xf = this.xf, dx = x - xf.px, dy = y - xf.py; return [xf.c * dx + xf.s * dy, -xf.s * dx + xf.c * dy]; }
    toWorld(x, y) { const xf = this.xf; return [xf.px + xf.c * x - xf.s * y, xf.py + xf.s * x + xf.c * y]; }
  }

  // ---------- collision ----------
  function mulX(xf, x, y) { return [xf.c * x - xf.s * y + xf.px, xf.s * x + xf.c * y + xf.py]; }
  function mulTX(xf, x, y) { const dx = x - xf.px, dy = y - xf.py; return [xf.c * dx + xf.s * dy, -xf.s * dx + xf.c * dy]; }

  function findMaxSeparation(p1, xf1, p2, xf2) {
    // transform poly1 into poly2 frame
    const c = xf2.c * xf1.c + xf2.s * xf1.s, s = xf2.c * xf1.s - xf2.s * xf1.c;
    const dx = xf1.px - xf2.px, dy = xf1.py - xf2.py;
    const tx = xf2.c * dx + xf2.s * dy, ty = -xf2.s * dx + xf2.c * dy;
    let best = -Infinity, bestI = 0;
    const v2 = p2.v;
    for (let i = 0; i < p1.v.length; i++) {
      const nx = c * p1.n[i][0] - s * p1.n[i][1], ny = s * p1.n[i][0] + c * p1.n[i][1];
      const vx = c * p1.v[i][0] - s * p1.v[i][1] + tx, vy = s * p1.v[i][0] + c * p1.v[i][1] + ty;
      let si = Infinity;
      for (let j = 0; j < v2.length; j++) { const d = nx * (v2[j][0] - vx) + ny * (v2[j][1] - vy); if (d < si) si = d; }
      if (si > best) { best = si; bestI = i; }
    }
    return [bestI, best];
  }

  function collidePolygons(m, A, xfA, B, xfB) {
    m.count = 0;
    const totalR = A.radius + B.radius;
    const [eA, sA] = findMaxSeparation(A, xfA, B, xfB); if (sA > totalR) return;
    const [eB, sB] = findMaxSeparation(B, xfB, A, xfA); if (sB > totalR) return;
    let p1, p2, xf1, xf2, e1, flip;
    if (sB > sA + 0.1 * LINEAR_SLOP) { p1 = B; p2 = A; xf1 = xfB; xf2 = xfA; e1 = eB; m.type = FACE_B; flip = 1; }
    else { p1 = A; p2 = B; xf1 = xfA; xf2 = xfB; e1 = eA; m.type = FACE_A; flip = 0; }
    // incident edge
    const n1 = p1.n[e1];
    const nwx = xf1.c * n1[0] - xf1.s * n1[1], nwy = xf1.s * n1[0] + xf1.c * n1[1];
    const nlx = xf2.c * nwx + xf2.s * nwy, nly = -xf2.s * nwx + xf2.c * nwy;
    let idx = 0, minD = Infinity;
    for (let i = 0; i < p2.n.length; i++) { const d = nlx * p2.n[i][0] + nly * p2.n[i][1]; if (d < minD) { minD = d; idx = i; } }
    const i1 = idx, i2 = (idx + 1) % p2.v.length;
    const ia = mulX(xf2, p2.v[i1][0], p2.v[i1][1]), ib = mulX(xf2, p2.v[i2][0], p2.v[i2][1]);
    let cv = [{ x: ia[0], y: ia[1], id: (e1) | (i1 << 8) | (0 << 16) | (1 << 24) }, { x: ib[0], y: ib[1], id: (e1) | (i2 << 8) | (0 << 16) | (1 << 24) }];
    const iv1 = e1, iv2 = (e1 + 1) % p1.v.length;
    const v11l = p1.v[iv1], v12l = p1.v[iv2];
    let ltx = v12l[0] - v11l[0], lty = v12l[1] - v11l[1]; const ll = Math.hypot(ltx, lty) || 1; ltx /= ll; lty /= ll;
    const lnx = lty, lny = -ltx;
    const ppx = 0.5 * (v11l[0] + v12l[0]), ppy = 0.5 * (v11l[1] + v12l[1]);
    const tx = xf1.c * ltx - xf1.s * lty, ty = xf1.s * ltx + xf1.c * lty;
    const nx = ty, ny = -tx;
    const v11 = mulX(xf1, v11l[0], v11l[1]), v12 = mulX(xf1, v12l[0], v12l[1]);
    const front = nx * v11[0] + ny * v11[1];
    const side1 = -(tx * v11[0] + ty * v11[1]) + totalR, side2 = tx * v12[0] + ty * v12[1] + totalR;
    cv = clip(cv, -tx, -ty, side1, iv1); if (cv.length < 2) return;
    cv = clip(cv, tx, ty, side2, iv2); if (cv.length < 2) return;
    m.lnx = lnx; m.lny = lny; m.lpx = ppx; m.lpy = ppy;
    let k = 0;
    for (let i = 0; i < 2; i++) {
      const sep = nx * cv[i].x + ny * cv[i].y - front;
      if (sep <= totalR) {
        const lp = mulTX(xf2, cv[i].x, cv[i].y);
        const mp = m.pts[k];
        mp.lx = lp[0]; mp.ly = lp[1];
        let id = cv[i].id;
        if (flip) { const a = id & 255, b = (id >> 8) & 255, ta = (id >> 16) & 255, tb = (id >> 24) & 255; id = b | (a << 8) | (tb << 16) | (ta << 24); }
        mp.id = id; k++;
      }
    }
    m.count = k;
  }
  function clip(vIn, nx, ny, offset, vA) {
    const out = [];
    const d0 = nx * vIn[0].x + ny * vIn[0].y - offset, d1 = nx * vIn[1].x + ny * vIn[1].y - offset;
    if (d0 <= 0) out.push(vIn[0]); if (d1 <= 0) out.push(vIn[1]);
    if (d0 * d1 < 0) {
      const t = d0 / (d0 - d1);
      out.push({ x: vIn[0].x + t * (vIn[1].x - vIn[0].x), y: vIn[0].y + t * (vIn[1].y - vIn[0].y), id: vA | (((vIn[0].id >> 8) & 255) << 8) | (1 << 16) | (0 << 24) });
    }
    return out;
  }
  function collidePolyCircle(m, A, xfA, B, xfB) {
    m.count = 0;
    const cw = mulX(xfB, B.p[0], B.p[1]); const c = mulTX(xfA, cw[0], cw[1]);
    let normalIndex = 0, sep = -Infinity; const r = A.radius + B.radius;
    for (let i = 0; i < A.v.length; i++) {
      const s = A.n[i][0] * (c[0] - A.v[i][0]) + A.n[i][1] * (c[1] - A.v[i][1]);
      if (s > r) return; if (s > sep) { sep = s; normalIndex = i; }
    }
    const v1 = A.v[normalIndex], v2 = A.v[(normalIndex + 1) % A.v.length];
    if (sep < 1e-9) {
      m.type = FACE_A; m.lnx = A.n[normalIndex][0]; m.lny = A.n[normalIndex][1];
      m.lpx = 0.5 * (v1[0] + v2[0]); m.lpy = 0.5 * (v1[1] + v2[1]);
    } else {
      const u1 = (c[0] - v1[0]) * (v2[0] - v1[0]) + (c[1] - v1[1]) * (v2[1] - v1[1]);
      const u2 = (c[0] - v2[0]) * (v1[0] - v2[0]) + (c[1] - v2[1]) * (v1[1] - v2[1]);
      if (u1 <= 0) {
        const d2 = (c[0] - v1[0]) ** 2 + (c[1] - v1[1]) ** 2; if (d2 > r * r) return;
        const l = Math.sqrt(d2) || 1; m.type = FACE_A; m.lnx = (c[0] - v1[0]) / l; m.lny = (c[1] - v1[1]) / l; m.lpx = v1[0]; m.lpy = v1[1];
      } else if (u2 <= 0) {
        const d2 = (c[0] - v2[0]) ** 2 + (c[1] - v2[1]) ** 2; if (d2 > r * r) return;
        const l = Math.sqrt(d2) || 1; m.type = FACE_A; m.lnx = (c[0] - v2[0]) / l; m.lny = (c[1] - v2[1]) / l; m.lpx = v2[0]; m.lpy = v2[1];
      } else {
        const fx = 0.5 * (v1[0] + v2[0]), fy = 0.5 * (v1[1] + v2[1]);
        const s = (c[0] - fx) * A.n[normalIndex][0] + (c[1] - fy) * A.n[normalIndex][1]; if (s > r) return;
        m.type = FACE_A; m.lnx = A.n[normalIndex][0]; m.lny = A.n[normalIndex][1]; m.lpx = fx; m.lpy = fy;
      }
    }
    m.count = 1; m.pts[0].lx = B.p[0]; m.pts[0].ly = B.p[1]; m.pts[0].id = 0;
  }
  function collideCircles(m, A, xfA, B, xfB) {
    m.count = 0;
    const pa = mulX(xfA, A.p[0], A.p[1]), pb = mulX(xfB, B.p[0], B.p[1]);
    const d2 = (pb[0] - pa[0]) ** 2 + (pb[1] - pa[1]) ** 2, r = A.radius + B.radius;
    if (d2 > r * r) return;
    m.type = CIRCLES; m.lpx = A.p[0]; m.lpy = A.p[1]; m.lnx = 0; m.lny = 0;
    m.count = 1; m.pts[0].lx = B.p[0]; m.pts[0].ly = B.p[1]; m.pts[0].id = 0;
  }
  function newManifold() { return { type: 0, lnx: 0, lny: 0, lpx: 0, lpy: 0, count: 0, pts: [{ lx: 0, ly: 0, id: 0, ni: 0, ti: 0 }, { lx: 0, ly: 0, id: 0, ni: 0, ti: 0 }] }; }

  function worldManifold(m, xfA, rA, xfB, rB, out) {
    out.count = m.count;
    if (m.count === 0) return out;
    if (m.type === CIRCLES) {
      const pA = mulX(xfA, m.lpx, m.lpy), pB = mulX(xfB, m.pts[0].lx, m.pts[0].ly);
      let nx = 1, ny = 0; const dx = pB[0] - pA[0], dy = pB[1] - pA[1], l = Math.hypot(dx, dy);
      if (l > 1e-9) { nx = dx / l; ny = dy / l; }
      const cAx = pA[0] + rA * nx, cAy = pA[1] + rA * ny, cBx = pB[0] - rB * nx, cBy = pB[1] - rB * ny;
      out.nx = nx; out.ny = ny; out.p[0][0] = 0.5 * (cAx + cBx); out.p[0][1] = 0.5 * (cAy + cBy); out.sep[0] = (cBx - cAx) * nx + (cBy - cAy) * ny;
    } else if (m.type === FACE_A) {
      const nx = xfA.c * m.lnx - xfA.s * m.lny, ny = xfA.s * m.lnx + xfA.c * m.lny;
      const pp = mulX(xfA, m.lpx, m.lpy);
      for (let i = 0; i < m.count; i++) {
        const cp = mulX(xfB, m.pts[i].lx, m.pts[i].ly);
        const d = (cp[0] - pp[0]) * nx + (cp[1] - pp[1]) * ny;
        const cAx = cp[0] + (rA - d) * nx, cAy = cp[1] + (rA - d) * ny, cBx = cp[0] - rB * nx, cBy = cp[1] - rB * ny;
        out.p[i][0] = 0.5 * (cAx + cBx); out.p[i][1] = 0.5 * (cAy + cBy); out.sep[i] = (cBx - cAx) * nx + (cBy - cAy) * ny;
      }
      out.nx = nx; out.ny = ny;
    } else {
      const nx = xfB.c * m.lnx - xfB.s * m.lny, ny = xfB.s * m.lnx + xfB.c * m.lny;
      const pp = mulX(xfB, m.lpx, m.lpy);
      for (let i = 0; i < m.count; i++) {
        const cp = mulX(xfA, m.pts[i].lx, m.pts[i].ly);
        const d = (cp[0] - pp[0]) * nx + (cp[1] - pp[1]) * ny;
        const cBx = cp[0] + (rB - d) * nx, cBy = cp[1] + (rB - d) * ny, cAx = cp[0] - rA * nx, cAy = cp[1] - rA * ny;
        out.p[i][0] = 0.5 * (cAx + cBx); out.p[i][1] = 0.5 * (cAy + cBy); out.sep[i] = (cAx - cBx) * nx + (cAy - cBy) * ny;
      }
      out.nx = -nx; out.ny = -ny;
    }
    return out;
  }

  class Contact {
    constructor(sA, sB) {
      this.sA = sA; this.sB = sB; this.bA = sA.body; this.bB = sB.body;
      this.m = newManifold(); this.touching = false; this.flagged = true;
      this.friction = Math.sqrt(sA.friction * sB.friction);
      this.restitution = Math.max(sA.restitution, sB.restitution);
      this.wm = { nx: 0, ny: 0, count: 0, p: [[0, 0], [0, 0]], sep: [0, 0] };
      // solver data
      this.vc = { nx: 0, ny: 0, pts: [{}, {}], K: [0, 0, 0], NM: [0, 0, 0], count: 0 };
    }
    update() {
      const old = this.m; const oc = old.count;
      const oldIds = [old.pts[0].id, old.pts[1].id], oldN = [old.pts[0].ni, old.pts[1].ni], oldT = [old.pts[0].ti, old.pts[1].ti];
      const sA = this.sA, sB = this.sB;
      if (sA.type === 0 && sB.type === 0) collidePolygons(old, sA, this.bA.xf, sB, this.bB.xf);
      else if (sA.type === 0) collidePolyCircle(old, sA, this.bA.xf, sB, this.bB.xf);
      else collideCircles(old, sA, this.bA.xf, sB, this.bB.xf);
      for (let i = 0; i < old.count; i++) {
        const p = old.pts[i]; p.ni = 0; p.ti = 0;
        for (let j = 0; j < oc; j++) if (oldIds[j] === p.id) { p.ni = oldN[j]; p.ti = oldT[j]; break; }
      }
      const was = this.touching; this.touching = old.count > 0;
      return [was, this.touching];
    }
  }

  // ---------- world ----------
  class World {
    constructor(opts = {}) {
      this.gx = 0; this.gy = opts.gravity ?? -9.81;
      this.bodies = []; this.contacts = new Map(); this.velIters = opts.velIters ?? 8; this.posIters = opts.posIters ?? 3;
      this.onBegin = null; this.onEnd = null; this.pairTouch = new Map();
    }
    createBody(def) { const b = new Body(def); this.bodies.push(b); return b; }
    wakeAround(b, margin = 0.25) {
      let x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
      for (const s of b.shapes) { s.computeAABB(b.xf); x0 = Math.min(x0, s.aabb[0]); y0 = Math.min(y0, s.aabb[1]); x1 = Math.max(x1, s.aabb[2]); y1 = Math.max(y1, s.aabb[3]); }
      x0 -= margin; y0 -= margin; x1 += margin; y1 += margin;
      for (const o of this.bodies) {
        if (o === b || o.type !== DYNAMIC || o.awake) continue;
        for (const s of o.shapes) { s.computeAABB(o.xf); const a = s.aabb; if (a[0] <= x1 && a[2] >= x0 && a[1] <= y1 && a[3] >= y0) { o.wake(); break; } }
      }
    }
    destroyBody(b) {
      if (b.destroyed) return; this.wakeAround(b); b.destroyed = true;
      for (const c of b.contacts.slice()) this.destroyContact(c);
      const i = this.bodies.indexOf(b); if (i >= 0) this.bodies.splice(i, 1);
    }
    key(sA, sB) { return sA.body.id < sB.body.id ? sA.body.id + ':' + sB.body.id + ':' + sA.body.shapes.indexOf(sA) + ':' + sB.body.shapes.indexOf(sB) : sB.body.id + ':' + sA.body.id + ':' + sB.body.shapes.indexOf(sB) + ':' + sA.body.shapes.indexOf(sA); }
    pairKey(a, b) { return a.id < b.id ? a.id * 100000 + b.id : b.id * 100000 + a.id; }
    destroyContact(c) {
      this.contacts.delete(c.key);
      let i = c.bA.contacts.indexOf(c); if (i >= 0) c.bA.contacts.splice(i, 1);
      i = c.bB.contacts.indexOf(c); if (i >= 0) c.bB.contacts.splice(i, 1);
      if (c.touching) this.touchChanged(c, false);
    }
    touchChanged(c, on) {
      const k = this.pairKey(c.bA, c.bB);
      const n = (this.pairTouch.get(k) || 0) + (on ? 1 : -1);
      if (n <= 0) this.pairTouch.delete(k); else this.pairTouch.set(k, n);
      if (on && n === 1 && this.onBegin) this.onBegin(c);
      if (!on && n <= 0 && this.onEnd) this.onEnd(c);
    }
    shouldCollide(sA, sB) {
      const a = sA.body, b = sB.body;
      if (a === b || a.destroyed || b.destroyed || !a.enabled || !b.enabled) return false;
      if (a.type !== DYNAMIC && b.type !== DYNAMIC) return false;
      if (sA.sensor || sB.sensor) return false;
      if (!(sA.cat & sB.mask) || !(sB.cat & sA.mask)) return false;
      return true;
    }
    collide() {
      // broadphase: sort and sweep over all shapes
      const shapes = [];
      for (const b of this.bodies) {
        if (!b.enabled) continue;
        for (const s of b.shapes) { if (b.type === DYNAMIC && b.awake || b.type === KINEMATIC || s._aabbInit === undefined) { s.computeAABB(b.xf); s._aabbInit = 1; } shapes.push(s); }
      }
      shapes.sort((p, q) => p.aabb[0] - q.aabb[0]);
      for (const c of this.contacts.values()) c.flagged = false;
      const n = shapes.length;
      for (let i = 0; i < n; i++) {
        const s = shapes[i], ab = s.aabb, bi = s.body;
        for (let j = i + 1; j < n; j++) {
          const t = shapes[j], bb = t.aabb;
          if (bb[0] > ab[2]) break;
          if (bb[1] > ab[3] || bb[3] < ab[1]) continue;
          const bj = t.body;
          const awakeA = bi.type === DYNAMIC && bi.awake, awakeB = bj.type === DYNAMIC && bj.awake;
          if (!awakeA && !awakeB) { // keep existing contact untouched
            const ex = this.contacts.get(this.key(s, t)); if (ex) ex.flagged = true; continue;
          }
          if (!this.shouldCollide(s, t)) continue;
          const k = this.key(s, t);
          let c = this.contacts.get(k);
          if (!c) {
            // order: polygon first when mixed
            let A = s, B = t; if (A.type === 1 && B.type === 0) { A = t; B = s; }
            c = new Contact(A, B); c.key = k; this.contacts.set(k, c); c.bA.contacts.push(c); c.bB.contacts.push(c);
          }
          c.flagged = true; c.live = true;
        }
      }
      for (const c of [...this.contacts.values()]) {
        if (!c.flagged) { this.destroyContact(c); continue; }
        const awakeA = c.bA.type === DYNAMIC && c.bA.awake, awakeB = c.bB.type === DYNAMIC && c.bB.awake;
        if (!awakeA && !awakeB) continue;
        const [was, now] = c.update();
        if (now && !was) this.touchChanged(c, true);
        else if (!now && was) this.touchChanged(c, false);
      }
    }
    step(dt) {
      // a body that just woke wakes sleeping neighbours within a small gap, so pieces resting
      // on slightly undersized colliders do not stay floating when their support moves
      const queue = this.bodies.filter(b => b.type === DYNAMIC && b.awake && !b._wasAwake && b.enabled);
      while (queue.length) {
        const b = queue.pop(); b._wasAwake = true;
        const before = this.bodies.filter(o => o.type === DYNAMIC && !o.awake);
        this.wakeAround(b, 0.15);
        for (const o of before) if (o.awake && !o._wasAwake) queue.push(o);
      }
      for (const b of this.bodies) if (!b.awake) b._wasAwake = false;
      this.collide();
      // islands (union-find over touching contacts among non-static bodies)
      const dyn = this.bodies.filter(b => b.type === DYNAMIC && b.enabled);
      const parent = new Map(); dyn.forEach(b => parent.set(b, b));
      const find = b => { let r = b; while (parent.get(r) !== r) r = parent.get(r); let x = b; while (parent.get(x) !== r) { const nx = parent.get(x); parent.set(x, r); x = nx; } return r; };
      const active = [];
      for (const c of this.contacts.values()) {
        if (!c.touching) continue;
        if (c.bA.type === DYNAMIC && c.bB.type === DYNAMIC) { const ra = find(c.bA), rb = find(c.bB); if (ra !== rb) parent.set(ra, rb); }
      }
      const groups = new Map();
      for (const b of dyn) { const r = find(b); let g = groups.get(r); if (!g) groups.set(r, g = { bodies: [], awake: false }); g.bodies.push(b); if (b.awake) g.awake = true; }
      for (const g of groups.values()) if (g.awake) for (const b of g.bodies) b.awake = true;
      const bodies = dyn.filter(b => b.awake);
      for (const c of this.contacts.values()) {
        if (!c.touching) continue;
        const aA = c.bA.type === DYNAMIC && c.bA.awake, aB = c.bB.type === DYNAMIC && c.bB.awake;
        if (aA || aB) active.push(c);
      }
      // integrate velocities
      for (const b of bodies) {
        b.vx += dt * (b.gravityScale * this.gx + b.invMass * b.fx); b.vy += dt * (b.gravityScale * this.gy + b.invMass * b.fy);
        b.vx *= 1 / (1 + dt * b.linDamp); b.vy *= 1 / (1 + dt * b.linDamp); b.w *= 1 / (1 + dt * b.angDamp);
        b.fx = b.fy = 0;
      }
      // init constraints
      for (const c of active) this.initVC(c);
      for (const c of active) this.warmStart(c);
      for (let it = 0; it < this.velIters; it++) for (const c of active) this.solveVC(c);
      for (const c of active) { const vc = c.vc; for (let i = 0; i < vc.count; i++) { c.m.pts[i].ni = vc.pts[i].ni; c.m.pts[i].ti = vc.pts[i].ti; } }
      // integrate positions
      for (const b of bodies) {
        let tx = dt * b.vx, ty = dt * b.vy; const mt = MAX_SPEED * dt;
        if (tx * tx + ty * ty > mt * mt) { const r = mt / Math.hypot(tx, ty); b.vx *= r; b.vy *= r; }
        let rot = dt * b.w; if (Math.abs(rot) > MAX_ROT) b.w *= MAX_ROT / Math.abs(rot);
        b.cx += dt * b.vx; b.cy += dt * b.vy; b.a += dt * b.w; b.syncXf();
      }
      for (let it = 0; it < this.posIters; it++) {
        let minSep = 0;
        for (const c of active) minSep = Math.min(minSep, this.solvePC(c));
        if (minSep >= -3 * LINEAR_SLOP) break;
      }
      // sleep
      for (const b of bodies) {
        if (b.w * b.w > ANG_SLEEP * ANG_SLEEP || b.vx * b.vx + b.vy * b.vy > LIN_SLEEP * LIN_SLEEP) b.sleepTime = 0;
        else b.sleepTime += dt;
      }
      for (const g of groups.values()) {
        if (!g.awake) continue;
        let minT = Infinity; for (const b of g.bodies) minT = Math.min(minT, b.awake ? b.sleepTime : Infinity);
        if (minT >= TIME_TO_SLEEP) for (const b of g.bodies) b.sleep();
      }
    }
    initVC(c) {
      const bA = c.bA, bB = c.bB, vc = c.vc;
      const wm = worldManifold(c.m, bA.xf, c.sA.radius, bB.xf, c.sB.radius, c.wm);
      vc.nx = wm.nx; vc.ny = wm.ny; vc.count = c.m.count;
      const mA = bA.invMass, mB = bB.invMass, iA = bA.invI, iB = bB.invI;
      const tx = vc.ny, ty = -vc.nx;
      for (let i = 0; i < vc.count; i++) {
        const p = vc.pts[i];
        p.rAx = wm.p[i][0] - bA.cx; p.rAy = wm.p[i][1] - bA.cy; p.rBx = wm.p[i][0] - bB.cx; p.rBy = wm.p[i][1] - bB.cy;
        p.ni = c.m.pts[i].ni; p.ti = c.m.pts[i].ti;
        const rnA = cross(p.rAx, p.rAy, vc.nx, vc.ny), rnB = cross(p.rBx, p.rBy, vc.nx, vc.ny);
        const kN = mA + mB + iA * rnA * rnA + iB * rnB * rnB; p.nm = kN > 0 ? 1 / kN : 0;
        const rtA = cross(p.rAx, p.rAy, tx, ty), rtB = cross(p.rBx, p.rBy, tx, ty);
        const kT = mA + mB + iA * rtA * rtA + iB * rtB * rtB; p.tm = kT > 0 ? 1 / kT : 0;
        const dvx = bB.vx - bB.w * p.rBy - bA.vx + bA.w * p.rAy, dvy = bB.vy + bB.w * p.rBx - bA.vy - bA.w * p.rAx;
        const vRel = vc.nx * dvx + vc.ny * dvy;
        p.bias = vRel < -VEL_THRESHOLD ? -c.restitution * vRel : 0;
      }
      vc.block = false;
      if (vc.count === 2) {
        const p1 = vc.pts[0], p2 = vc.pts[1];
        const rn1A = cross(p1.rAx, p1.rAy, vc.nx, vc.ny), rn1B = cross(p1.rBx, p1.rBy, vc.nx, vc.ny);
        const rn2A = cross(p2.rAx, p2.rAy, vc.nx, vc.ny), rn2B = cross(p2.rBx, p2.rBy, vc.nx, vc.ny);
        const k11 = mA + mB + iA * rn1A * rn1A + iB * rn1B * rn1B, k22 = mA + mB + iA * rn2A * rn2A + iB * rn2B * rn2B;
        const k12 = mA + mB + iA * rn1A * rn2A + iB * rn1B * rn2B;
        if (k11 * k11 < 1000 * (k11 * k22 - k12 * k12)) {
          vc.block = true; vc.K = [k11, k12, k22];
          const det = k11 * k22 - k12 * k12, id = det !== 0 ? 1 / det : 0;
          vc.NM = [id * k22, -id * k12, id * k11];
        } else vc.count = 1;
      }
    }
    warmStart(c) {
      const bA = c.bA, bB = c.bB, vc = c.vc, tx = vc.ny, ty = -vc.nx;
      for (let i = 0; i < vc.count; i++) {
        const p = vc.pts[i]; const Px = p.ni * vc.nx + p.ti * tx, Py = p.ni * vc.ny + p.ti * ty;
        bA.vx -= bA.invMass * Px; bA.vy -= bA.invMass * Py; bA.w -= bA.invI * cross(p.rAx, p.rAy, Px, Py);
        bB.vx += bB.invMass * Px; bB.vy += bB.invMass * Py; bB.w += bB.invI * cross(p.rBx, p.rBy, Px, Py);
      }
    }
    solveVC(c) {
      const bA = c.bA, bB = c.bB, vc = c.vc, mA = bA.invMass, mB = bB.invMass, iA = bA.invI, iB = bB.invI;
      const nx = vc.nx, ny = vc.ny, tx = ny, ty = -nx;
      // friction
      for (let i = 0; i < vc.count; i++) {
        const p = vc.pts[i];
        const dvx = bB.vx - bB.w * p.rBy - bA.vx + bA.w * p.rAy, dvy = bB.vy + bB.w * p.rBx - bA.vy - bA.w * p.rAx;
        const vt = dvx * tx + dvy * ty; let lambda = p.tm * -vt;
        const maxF = c.friction * p.ni; const ni = Math.max(-maxF, Math.min(p.ti + lambda, maxF)); lambda = ni - p.ti; p.ti = ni;
        const Px = lambda * tx, Py = lambda * ty;
        bA.vx -= mA * Px; bA.vy -= mA * Py; bA.w -= iA * cross(p.rAx, p.rAy, Px, Py);
        bB.vx += mB * Px; bB.vy += mB * Py; bB.w += iB * cross(p.rBx, p.rBy, Px, Py);
      }
      if (!vc.block) {
        for (let i = 0; i < vc.count; i++) {
          const p = vc.pts[i];
          const dvx = bB.vx - bB.w * p.rBy - bA.vx + bA.w * p.rAy, dvy = bB.vy + bB.w * p.rBx - bA.vy - bA.w * p.rAx;
          const vn = dvx * nx + dvy * ny; let lambda = -p.nm * (vn - p.bias);
          const ni = Math.max(p.ni + lambda, 0); lambda = ni - p.ni; p.ni = ni;
          const Px = lambda * nx, Py = lambda * ny;
          bA.vx -= mA * Px; bA.vy -= mA * Py; bA.w -= iA * cross(p.rAx, p.rAy, Px, Py);
          bB.vx += mB * Px; bB.vy += mB * Py; bB.w += iB * cross(p.rBx, p.rBy, Px, Py);
        }
        return;
      }
      // block solver (Box2D)
      const c1 = vc.pts[0], c2 = vc.pts[1];
      const ax = c1.ni, ay = c2.ni;
      const dv1x = bB.vx - bB.w * c1.rBy - bA.vx + bA.w * c1.rAy, dv1y = bB.vy + bB.w * c1.rBx - bA.vy - bA.w * c1.rAx;
      const dv2x = bB.vx - bB.w * c2.rBy - bA.vx + bA.w * c2.rAy, dv2y = bB.vy + bB.w * c2.rBx - bA.vy - bA.w * c2.rAx;
      let vn1 = dv1x * nx + dv1y * ny, vn2 = dv2x * nx + dv2y * ny;
      const K = vc.K, NM = vc.NM;
      let bx = vn1 - c1.bias - (K[0] * ax + K[1] * ay), by = vn2 - c2.bias - (K[1] * ax + K[2] * ay);
      const apply = (xx, yy) => {
        const dx = xx - ax, dy = yy - ay;
        const P1x = dx * nx, P1y = dx * ny, P2x = dy * nx, P2y = dy * ny;
        bA.vx -= mA * (P1x + P2x); bA.vy -= mA * (P1y + P2y);
        bA.w -= iA * (cross(c1.rAx, c1.rAy, P1x, P1y) + cross(c2.rAx, c2.rAy, P2x, P2y));
        bB.vx += mB * (P1x + P2x); bB.vy += mB * (P1y + P2y);
        bB.w += iB * (cross(c1.rBx, c1.rBy, P1x, P1y) + cross(c2.rBx, c2.rBy, P2x, P2y));
        c1.ni = xx; c2.ni = yy;
      };
      let xx = -(NM[0] * bx + NM[1] * by), yy = -(NM[1] * bx + NM[2] * by);
      if (xx >= 0 && yy >= 0) { apply(xx, yy); return; }
      xx = -c1.nm * bx; yy = 0; vn2 = K[1] * xx + by;
      if (xx >= 0 && vn2 >= 0) { apply(xx, yy); return; }
      xx = 0; yy = -c2.nm * by; vn1 = K[1] * yy + bx;
      if (yy >= 0 && vn1 >= 0) { apply(xx, yy); return; }
      xx = 0; yy = 0;
      if (bx >= 0 && by >= 0) { apply(xx, yy); return; }
    }
    solvePC(c) {
      const bA = c.bA, bB = c.bB, m = c.m, mA = bA.invMass, mB = bB.invMass, iA = bA.invI, iB = bB.invI;
      const rA = c.sA.radius, rB = c.sB.radius;
      let minSep = 0;
      for (let i = 0; i < m.count; i++) {
        const xfA = bA.xf, xfB = bB.xf;
        let nx, ny, px, py, sep;
        if (m.type === CIRCLES) {
          const pA = mulX(xfA, m.lpx, m.lpy), pB = mulX(xfB, m.pts[0].lx, m.pts[0].ly);
          const dx = pB[0] - pA[0], dy = pB[1] - pA[1], l = Math.hypot(dx, dy) || 1; nx = dx / l; ny = dy / l;
          px = 0.5 * (pA[0] + pB[0]); py = 0.5 * (pA[1] + pB[1]); sep = dx * nx + dy * ny - rA - rB;
        } else if (m.type === FACE_A) {
          nx = xfA.c * m.lnx - xfA.s * m.lny; ny = xfA.s * m.lnx + xfA.c * m.lny;
          const pp = mulX(xfA, m.lpx, m.lpy), cp = mulX(xfB, m.pts[i].lx, m.pts[i].ly);
          sep = (cp[0] - pp[0]) * nx + (cp[1] - pp[1]) * ny - rA - rB; px = cp[0]; py = cp[1];
        } else {
          nx = xfB.c * m.lnx - xfB.s * m.lny; ny = xfB.s * m.lnx + xfB.c * m.lny;
          const pp = mulX(xfB, m.lpx, m.lpy), cp = mulX(xfA, m.pts[i].lx, m.pts[i].ly);
          sep = (cp[0] - pp[0]) * nx + (cp[1] - pp[1]) * ny - rA - rB; px = cp[0]; py = cp[1]; nx = -nx; ny = -ny;
        }
        const rAx = px - bA.cx, rAy = py - bA.cy, rBx = px - bB.cx, rBy = py - bB.cy;
        minSep = Math.min(minSep, sep);
        const C = Math.max(-MAX_CORR, Math.min(BAUMGARTE * (sep + LINEAR_SLOP), 0));
        const rnA = cross(rAx, rAy, nx, ny), rnB = cross(rBx, rBy, nx, ny);
        const K = mA + mB + iA * rnA * rnA + iB * rnB * rnB;
        const imp = K > 0 ? -C / K : 0; const Px = imp * nx, Py = imp * ny;
        if (mA || iA) { bA.cx -= mA * Px; bA.cy -= mA * Py; bA.a -= iA * cross(rAx, rAy, Px, Py); bA.syncXf(); }
        if (mB || iB) { bB.cx += mB * Px; bB.cy += mB * Py; bB.a += iB * cross(rBx, rBy, Px, Py); bB.syncXf(); }
      }
      return minSep;
    }
    // queries ---------------------------------------------------------
    rayCastAll(x1, y1, x2, y2, filter) {
      const hits = []; const x0 = Math.min(x1, x2), x9 = Math.max(x1, x2), y0 = Math.min(y1, y2), y9 = Math.max(y1, y2);
      const len = Math.hypot(x2 - x1, y2 - y1);
      for (const b of this.bodies) {
        if (!b.enabled) continue;
        for (const s of b.shapes) {
          s.computeAABB(b.xf); const a = s.aabb;
          if (a[0] > x9 || a[2] < x0 || a[1] > y9 || a[3] < y0) continue;
          if (filter && !filter(s)) continue;
          const f = s.rayCast(x1, y1, x2, y2, 1);
          if (f >= 0) hits.push({ shape: s, body: b, fraction: f, distance: f * len, x: x1 + f * (x2 - x1), y: y1 + f * (y2 - y1) });
        }
      }
      hits.sort((p, q) => p.fraction - q.fraction);
      return hits;
    }
    overlapCircle(x, y, r, filter) {
      const out = []; const tmp = new Shape({ circle: [0, 0, r] }); const xf = { px: x, py: y, c: 1, s: 0 }; const m = newManifold();
      for (const b of this.bodies) {
        if (!b.enabled) continue;
        for (const s of b.shapes) {
          s.computeAABB(b.xf); const a = s.aabb;
          if (a[0] > x + r || a[2] < x - r || a[1] > y + r || a[3] < y - r) continue;
          if (filter && !filter(s)) continue;
          if (s.type === 0) collidePolyCircle(m, s, b.xf, tmp, xf); else collideCircles(m, s, b.xf, tmp, xf);
          if (m.count > 0) { out.push(s); }
        }
      }
      return out;
    }
  }
  return { World, Body, Shape, hull, isConvex, triangulate, polyArea, STATIC, KINEMATIC, DYNAMIC };
})();
if (typeof module !== 'undefined') module.exports = Phys;
