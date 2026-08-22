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

const style = (cap, accent, back) =>
  `--av-cap:var(--avatar-${cap}-cap);--av-wing:var(--avatar-${cap}-wing);` +
  `--av-accent:var(--avatar-accent-${accent});--av-backdrop:var(--avatar-back-${back})`

const bird = (size, { cap, wing, expression, accessory, accent, back }) =>
  `<svg class="avatar" style="${style(cap, accent, back)};width:${size}px;height:${size}px"
        viewBox="0 0 64 64" role="img" aria-label="chickadee avatar">
     <use href="#av-backdrop"/><use href="#av-plumage"/><use href="#av-wing-${wing}"/>
     <use href="#av-expression-${expression}"/><use href="#av-accessory-${accessory}"/></svg>`

const label = (t, inner) => `<figure><div>${inner}</div><figcaption>${t}</figcaption></figure>`
const at = (list, i) => list[i % list.length]
const base = { cap: 'teal', wing: 'barred', expression: 'bright', accessory: 'none',
               accent: 'ember', back: 'aqua' }

const sections = [
  ['Cap — the loudest axis, so it carries the least detail', caps.map((cap, i) =>
    label(cap, bird(88, { ...base, cap, wing: at(wings, i) })))],
  ['Wing pattern — symmetrical, both flanks from one drawing', wings.map(wing =>
    label(wing, bird(88, { ...base, wing })))],
  ['Expression — reads first and from furthest away', expressions.map(expression =>
    label(expression, bird(88, { ...base, expression, wing: 'plain' })))],
  ['Accessory — where the personality lives', accessories.map((accessory, i) =>
    label(accessory, bird(88, { ...base, accessory, accent: at(accents, i), cap: 'slate',
                                back: 'straw' })))],
  ['Accent — the accessory\'s colour', accents.map(accent =>
    label(accent, bird(88, { ...base, accessory: 'scarf', accent, back: 'straw' })))],
  ['Backdrop — all near the same lightness so no bird shouts', backs.map(back =>
    label(back, bird(88, { ...base, cap: 'ink', back })))],
  ['At size — the bird earns its detail at 48px and up', [96, 64, 48, 40, 32, 24].map((s, i) =>
    label(`${s}px`, bird(s, { ...base, cap: at(caps, i), accessory: 'scarf', back: 'rose' })))],
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
&times; ${expressions.length} expressions &times; ${accessories.length} accessories in
${accents.length} accents &times; ${backs.length} backdrops =
${(caps.length * wings.length * expressions.length * accessories.length * accents.length * backs.length).toLocaleString()}
distinct birds</h1>
${sections.map(([t, cells]) => `<h2>${t}</h2><div class="sheet">${cells.join('')}</div>`).join('')}
`)
