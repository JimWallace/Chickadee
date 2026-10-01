// Avatar contact sheet.
//
// Renders every drawn part in Resources/Views/_avatar-sprite.leaf across the
// palette in Public/styles.css, so the art can be looked at without booting
// the server or wiring a route.  It reads both files rather than holding its
// own copy of either: a preview that carries its own paths would keep looking
// right after the sprite stopped being.
//
//   node Tools/avatar-preview/preview.mjs > /tmp/avatars.html
//
// Nothing imports this and nothing in CI runs it; it is a looking-glass.

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '../..')
const sprite = readFileSync(`${root}/Resources/Views/_avatar-sprite.leaf`, 'utf8')
const css = readFileSync(`${root}/Public/styles.css`, 'utf8')

// A Set because the dark-mode block redeclares every backdrop: without it the
// backdrops are counted twice and the sheet claims twice the birds it has.
const tokens = (prefix, suffix = '') =>
  [...new Set([...css.matchAll(new RegExp(`--avatar-${prefix}([a-z]+)${suffix}:`, 'g'))]
    .map(m => m[1]))]

const caps = tokens('', '-cap')
const accents = tokens('accent-')
const backs = tokens('back-')
const sym = (family) =>
  [...sprite.matchAll(new RegExp(`id="av-${family}-([a-z]+)"`, 'g'))].map(m => m[1])
const wings = sym('wing')
const expressions = sym('expression')
const accessories = sym('accessory')
const tufts = sym('tuft')
const rings = sym('ring')

// The first-use draw picks from AvatarExpression.starterCases, the first six.
// Everything the sprite draws past those is a wardrobe unlock.
const STARTER_EXPRESSIONS = 6
const starterExpressions = expressions.slice(0, STARTER_EXPRESSIONS)
const unlockableExpressions = expressions.slice(STARTER_EXPRESSIONS)

// The gradcap is kept for a completion achievement and is not in the first-use
// draw. Mirrors AvatarAccessory.starterCases.
const starterAccessories = accessories.filter(a => a !== 'gradcap')

// A hat replaces the tuft. Mirrors AvatarAccessory.hidesTuft, which
// AvatarPresentation applies at render time.
const TUFT_HIDING_HATS = new Set(['beanie', 'gradcap'])

// Tilt is a transform, not a symbol, so there is nothing to read it from.
// These mirror AvatarTilt.degrees.
const tilts = [['upright', 0], ['left', -9], ['right', 9]]

// A border is a ring symbol plus, for the solid ring, the accent it is drawn
// in. Mirrors AvatarBorder.ring: an accent name draws the solid ring, 'none'
// draws nothing, and any other name is that ring's own art. 'staff' is never a
// student's border; AvatarPresentation draws it from a course role.
const ringOf = (border) => (accents.includes(border) ? 'solid' : border)

// A border that is not an accent uses the transparent --avatar-border-none,
// as AvatarPresentation.borderToken names it.
const style = (cap, accent, back, border = 'none') =>
  `--av-cap:var(--avatar-${cap}-cap);--av-wing:var(--avatar-${cap}-wing);` +
  `--av-accent:var(--avatar-accent-${accent});--av-backdrop:var(--avatar-back-${back});` +
  `--av-border:var(${accents.includes(border) ? `--avatar-accent-${border}` : '--avatar-border-none'})`

const bird = (size, { cap, wing, expression, accessory, accent, back, tuft = 'none', tilt = 0,
                      border = 'none' }) =>
  `<svg class="avatar${size <= 40 ? ' avatar-md' : ''}" style="${style(cap, accent, back, border)};width:${size}px;height:${size}px"
        viewBox="0 0 64 64" role="img" aria-label="chickadee avatar">
     <use href="#av-backdrop"/><g transform="rotate(${tilt} 32 34)">
     <use href="#av-tuft-${TUFT_HIDING_HATS.has(accessory) ? 'none' : tuft}"/><use href="#av-plumage"/><use href="#av-wing-${wing}"/>
     <use href="#av-expression-${expression}"/><use href="#av-accessory-${accessory}"/></g>
     <use href="#av-ring-${ringOf(border)}"/></svg>`

const label = (t, inner) => `<figure><div>${inner}</div><figcaption>${t}</figcaption></figure>`
const at = (list, i) => list[i % list.length]
const base = { cap: 'teal', wing: 'barred', expression: 'bright', accessory: 'none',
               accent: 'ember', back: 'aqua' }

const sections = [
  ['Cap — the loudest axis, so it carries the least detail', caps.map((cap, i) =>
    label(cap, bird(88, { ...base, cap, wing: at(wings, i) })))],
  ['Wing pattern — symmetrical, both flanks from one drawing', wings.map(wing =>
    label(wing, bird(88, { ...base, wing })))],
  ['Expression — reads first and from furthest away', [
    ...starterExpressions.map(expression =>
      label(expression, bird(88, { ...base, expression, wing: 'plain' }))),
    ...unlockableExpressions.map(expression =>
      label(`${expression} (unlockable)`, bird(88, { ...base, expression, wing: 'plain' }))),
  ]],
  ['Tuft — the outline, without a hat', tufts.map((tuft, i) =>
    label(tuft, bird(88, { ...base, tuft, cap: at(caps, i) })))],
  ['Tuft × hat — beanie and gradcap replace the tuft; review the overlaps',
    tufts.flatMap(tuft => ['beanie', 'gradcap', 'headband', 'headphones', 'bloom'].map(accessory =>
      label(`${tuft} + ${accessory}`, bird(64, { ...base, tuft, accessory, back: 'straw' }))))],
  ['Tilt — a transform on everything but the backdrop', tilts.map(([name, tilt]) =>
    label(name, bird(88, { ...base, tilt, tuft: 'crest' })))],
  ['Accessory — where the personality lives', accessories.map((accessory, i) =>
    label(accessory, bird(88, { ...base, accessory, accent: at(accents, i), cap: 'slate',
                                back: 'straw' })))],
  ['Accent — the accessory\'s colour', accents.map(accent =>
    label(accent, bird(88, { ...base, accessory: 'scarf', accent, back: 'straw' })))],
  ['Ring — chosen on the account page; the solid ring in the five accents', ['none', ...accents].map(border =>
    label(border, bird(88, { ...base, border, accessory: 'headband', back: 'straw' })))],
  ['Patterned rings — rainbow is a starter; two-tone and stitched are earned; spectrum is special',
    rings.filter(r => !['none', 'solid', 'staff'].includes(r)).map(border =>
      label(border, bird(88, { ...base, border, accent: 'lagoon', back: 'straw' })))],
  ['Staff ring — drawn from a course role, never chosen; on each backdrop', backs.map(back =>
    label(back, bird(64, { ...base, border: 'staff', back })))],
  ['Rings at 36px and 24px', [...rings.filter(r => r !== 'solid'), 'ember'].flatMap(border =>
    [36, 24].map(s => label(`${border} ${s}`, bird(s, { ...base, border, back: 'sky' }))))],
  ['Backdrop — all near the same lightness so no bird shouts', backs.map(back =>
    label(back, bird(88, { ...base, cap: 'ink', back })))],
  ['At size — the bird earns its detail at 48px and up', [96, 64, 48, 40, 36, 32, 24].map((s, i) =>
    label(`${s}px`, bird(s, { ...base, cap: at(caps, i), accessory: 'scarf', back: 'rose',
                               tuft: at(tufts, i + 1) })))],
  ['At 36px — the roster size: every starter expression', starterExpressions.map((expression, i) =>
    label(expression, bird(36, { ...base, expression, cap: at(caps, i), back: at(backs, i),
                                  tuft: at(tufts, i) })))],
]

process.stdout.write(`<!doctype html><meta charset="utf-8">
<title>Chickadee avatar contact sheet</title>
<link rel="stylesheet" href="${root}/Public/styles.css">
<style>
 body{font:13px system-ui;margin:20px;background:var(--bg);color:var(--fg)}
 h2{font-size:14px;margin:18px 0 8px;font-weight:600}
 .sheet{display:flex;flex-wrap:wrap;align-items:flex-end;gap:14px}
 figure{text-align:center}
 figcaption{margin-top:4px;color:var(--muted);font-size:11px}
</style>
${sprite}
<h1 style="font-size:16px">Chickadee avatars — ${caps.length} caps &times; ${wings.length} wings
&times; ${starterExpressions.length} starter expressions &times; ${starterAccessories.length} starter accessories in
${accents.length} accents &times; ${backs.length} backdrops &times; ${tufts.length} tufts
&times; ${tilts.length} tilts =
${(caps.length * wings.length * starterExpressions.length * starterAccessories.length * accents.length
   * backs.length * tufts.length * tilts.length).toLocaleString()}
starter birds (plus ${unlockableExpressions.length} unlockable expressions)</h1>
${sections.map(([t, cells]) => `<h2>${t}</h2><div class="sheet">${cells.join('')}</div>`).join('')}
`)
